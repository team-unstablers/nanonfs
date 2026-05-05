import Foundation
import Logging
import NIOCore

// RFC 7530 §16.2 — COMPOUND.
//
// COMPOUND4args:  utf8str_cs tag; uint32 minorversion; nfs_argop4 argarray<>;
// COMPOUND4res:   nfsstat4 status; utf8str_cs tag;     nfs_resop4 resarray<>;
//
// nfs_argop4 / nfs_resop4 are tagged unions discriminated on the operation
// number. Each operation has its own arg and result type; the result also
// encodes a status which decides whether the COMPOUND continues
// (RFC 7530 §15.2).

/// Per-COMPOUND mutable state. Held only for the duration of dispatch.
struct CompoundState {
    var currentFh: NFSFileHandle?
    var savedFh:   NFSFileHandle?
    /// Minor version negotiated from the request (`COMPOUND4args.minorversion`).
    /// nanonfs only supports 0.
    var minorVersion: UInt32 = 0
    /// Tag echoed back into the response (RFC 7530 §16.2.4).
    var tag: String = ""
}

actor CompoundDispatcher {
    let server: any NFSServer
    let logger: Logger
    let clients: ClientRegistry

    init(server: any NFSServer,
         logger: Logger,
         clients: ClientRegistry = ClientRegistry()) {
        self.server = server
        self.logger = logger
        self.clients = clients
    }

    /// Top-level entry point. Decodes a COMPOUND request and produces the
    /// fully-encoded `COMPOUND4res` payload (the bytes that go into the
    /// RPC accepted-reply body).
    func dispatch(args input: ByteBuffer) async -> ByteBuffer {
        var dec = XDRDecoder(input)
        let tag: String
        let minor: UInt32
        let opCount: UInt32
        do {
            // RFC 7530 §16.2.4: tag has no length cap in the RFC, but we cap
            // for safety; servers MAY truncate to a "reasonable" length.
            tag   = try dec.readString(maxLength: 4096)
            minor = try dec.readUInt32()
            opCount = try dec.readUInt32()
        } catch {
            logger.warning("compound: malformed header: \(error)")
            return encodeCompoundEarlyError(.badxdr, tag: "")
        }

        if minor != 0 {
            // RFC 7530 §16.2.5 — minorversion mismatch.
            return encodeCompoundEarlyError(.minorVersMismatch, tag: tag)
        }

        // Hard cap on op count to bound resource use; RFC does not require
        // this cap but the server MAY reject excessively large COMPOUNDs.
        if opCount > 4096 {
            return encodeCompoundEarlyError(.resource, tag: tag)
        }

        var state = CompoundState(minorVersion: minor, tag: tag)
        var perOpResults: [(opcode: UInt32, status: NFSStatus, body: ByteBuffer)] = []
        var overallStatus: NFSStatus = .ok

        for i in 0..<opCount {
            let opnum: UInt32
            do {
                opnum = try dec.readUInt32()
            } catch {
                logger.warning("compound: truncated op \(i): \(error)")
                overallStatus = .badxdr
                break
            }
            let outcome = await dispatchOp(opnum: opnum, dec: &dec, state: &state)
            perOpResults.append((opnum, outcome.status, outcome.body))
            if outcome.status != .ok {
                overallStatus = outcome.status
                let opName = NFSOp(rawValue: opnum).map(String.init(describing:)) ?? "op#\(opnum)"
                logger.debug("compound op \(i+1)/\(opCount) \(opName) → \(outcome.status)")
                break
            }
        }

        return encodeCompoundResponse(status: overallStatus,
                                      tag: state.tag,
                                      results: perOpResults)
    }

    // MARK: - Per-op dispatch

    fileprivate struct OpResult {
        var status: NFSStatus
        var body: ByteBuffer
    }

    fileprivate func dispatchOp(opnum: UInt32,
                            dec: inout XDRDecoder,
                            state: inout CompoundState) async -> OpResult {
        guard let op = NFSOp(rawValue: opnum) else {
            // RFC 7530 §15.2.4 — unknown opcode.
            return OpResult(status: .opIllegal, body: ByteBuffer())
        }
        switch op {
        case .putrootfh:    return await opPutRootFH(state: &state)
        case .putfh:        return await opPutFH(dec: &dec, state: &state)
        case .getfh:        return opGetFH(state: &state)
        case .savefh:       return opSaveFH(state: &state)
        case .restorefh:    return opRestoreFH(state: &state)
        case .access:       return await opAccess(dec: &dec, state: &state)
        case .lookup:       return await opLookup(dec: &dec, state: &state)
        case .lookupp:      return await opLookupParent(state: &state)
        case .getattr:      return await opGetattr(dec: &dec, state: &state)
        case .setattr:      return await opSetattr(dec: &dec, state: &state)
        case .readdir:      return await opReaddir(dec: &dec, state: &state)
        case .readlink:     return await opReadlink(state: &state)
        case .read:         return await opRead(dec: &dec, state: &state)
        case .write:        return await opWrite(dec: &dec, state: &state)
        case .commit:       return await opCommit(dec: &dec, state: &state)
        case .create:       return await opCreate(dec: &dec, state: &state)
        case .remove:       return await opRemove(dec: &dec, state: &state)
        case .rename:       return await opRename(dec: &dec, state: &state)
        case .link:         return await opLink(dec: &dec, state: &state)
        case .open:         return await opOpen(dec: &dec, state: &state)
        case .openConfirm:  return await opOpenConfirm(dec: &dec, state: &state)
        case .openDowngrade: return await opOpenDowngrade(dec: &dec, state: &state)
        case .close:        return await opClose(dec: &dec, state: &state)
        case .lock:         return await opLock(dec: &dec, state: &state)
        case .lockt:        return await opLockt(dec: &dec, state: &state)
        case .locku:        return await opLocku(dec: &dec, state: &state)
        case .releaseLockowner: return opReleaseLockowner(dec: &dec)
        case .setclientid:  return await opSetClientId(dec: &dec)
        case .setclientidConfirm: return await opSetClientIdConfirm(dec: &dec)
        case .renew:        return await opRenew(dec: &dec)
        case .secinfo:      return opSecinfo(dec: &dec)
        case .putpubfh:
            // We don't run a public filehandle — RFC 7530 §16.20.
            return OpResult(status: .notsupp, body: ByteBuffer())
        default:
            // Skeleton phase: every other op replies NFS4ERR_NOTSUPP. The
            // dispatcher must still consume any args from `dec` so that
            // higher-numbered ops in the same COMPOUND remain decodable —
            // but we cannot do that generically without per-op argument
            // parsers. For now we abort the COMPOUND with NOTSUPP, which
            // is RFC-legal (per §15.2 once status != OK no further ops are
            // processed, so leftover argument bytes do not matter).
            logger.debug("compound op \(op) is not yet implemented")
            return OpResult(status: .notsupp, body: ByteBuffer())
        }
    }
}

// MARK: - Filehandle ops (RFC 7530 §16.20-§16.31)

extension CompoundDispatcher {
    fileprivate func opPutRootFH(state: inout CompoundState) async -> OpResult {
        do {
            let root = try await server.root()
            state.currentFh = root
            return OpResult(status: .ok, body: ByteBuffer())
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("PUTROOTFH server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opPutFH(dec: inout XDRDecoder,
                             state: inout CompoundState) async -> OpResult {
        do {
            // RFC 7530 §2.2.4: nfs_fh4 is variable-length opaque ≤ NFS4_FHSIZE (128).
            let bytes = try dec.readVariableOpaqueData(maxLength: 128)
            state.currentFh = NFSFileHandle(bytes)
            return OpResult(status: .ok, body: ByteBuffer())
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
    }

    fileprivate func opGetFH(state: inout CompoundState) -> OpResult {
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        var enc = XDREncoder()
        enc.writeVariableOpaque(fh.bytes)
        return OpResult(status: .ok, body: enc.buffer)
    }

    fileprivate func opSaveFH(state: inout CompoundState) -> OpResult {
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        state.savedFh = fh
        return OpResult(status: .ok, body: ByteBuffer())
    }

    fileprivate func opRestoreFH(state: inout CompoundState) -> OpResult {
        guard let fh = state.savedFh else {
            // RFC 7530 §16.30 — RESTOREFH without prior SAVEFH.
            return OpResult(status: .restorefh, body: ByteBuffer())
        }
        state.currentFh = fh
        return OpResult(status: .ok, body: ByteBuffer())
    }
}

// MARK: - ACCESS / LOOKUP / RENEW

extension CompoundDispatcher {
    fileprivate func opAccess(dec: inout XDRDecoder,
                              state: inout CompoundState) async -> OpResult {
        let mask: UInt32
        do {
            mask = try dec.readUInt32()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let granted = try await server.access(handle: fh, mask: NFSAccess(rawValue: mask))
            // RFC 7530 §16.3.3 — supported (==mask) + access (granted subset).
            var enc = XDREncoder()
            enc.writeUInt32(mask)            // supported
            enc.writeUInt32(granted.rawValue) // access
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("ACCESS server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opLookup(dec: inout XDRDecoder,
                              state: inout CompoundState) async -> OpResult {
        let name: String
        do {
            // RFC 7530 §16.13.1 — component4 string. Name length capped here
            // for safety; specific cap enforced by user via .nameTooLong.
            name = try dec.readString(maxLength: 1 << 16)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let parent = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let child = try await server.lookup(parent: parent, name: name)
            state.currentFh = child
            return OpResult(status: .ok, body: ByteBuffer())
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("LOOKUP server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opLookupParent(state: inout CompoundState) async -> OpResult {
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let parent = try await server.lookupParent(of: fh)
            state.currentFh = parent
            return OpResult(status: .ok, body: ByteBuffer())
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("LOOKUPP server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opRenew(dec: inout XDRDecoder) async -> OpResult {
        // RFC 7530 §16.27 — RENEW(clientid4 client).
        let clientid: UInt64
        do {
            clientid = try dec.readUInt64()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        switch await clients.renew(clientid: clientid,
                                   leaseSeconds: TimeInterval(FATTRConfig.leaseSeconds)) {
        case .ok:      return OpResult(status: .ok, body: ByteBuffer())
        case .stale:   return OpResult(status: .staleClientid, body: ByteBuffer())
        case .expired: return OpResult(status: .expired, body: ByteBuffer())
        }
    }
}

// MARK: - GETATTR (RFC 7530 §16.18)

extension CompoundDispatcher {
    fileprivate func opGetattr(dec: inout XDRDecoder,
                               state: inout CompoundState) async -> OpResult {
        let mask: AttrBitmap
        do {
            mask = try AttrBitmap.decode(from: &dec)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let stat = try await server.getattr(handle: fh)
            let body = encodeGetattrResult(stat: stat, fileHandle: fh, request: mask)
            return OpResult(status: .ok, body: body)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("GETATTR server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }
}

// MARK: - SETCLIENTID family (RFC 7530 §16.33-§16.35)

extension CompoundDispatcher {
    fileprivate func opSetClientId(dec: inout XDRDecoder) async -> OpResult {
        // Args: nfs_client_id4 client + cb_client4 callback + uint32 callback_ident.
        let verifier: UInt64
        let ownerName: Data
        let cbProgram: UInt32
        let cbNetid: String
        let cbAddr: String
        let _: UInt32  // callback_ident, unused for now
        do {
            // verifier4: 8 bytes opaque, fixed.
            verifier = try dec.readUInt64()
            ownerName = try dec.readVariableOpaqueData(maxLength: 1024)
            cbProgram = try dec.readUInt32()
            cbNetid = try dec.readString(maxLength: 32)
            cbAddr  = try dec.readString(maxLength: 256)
            _ = try dec.readUInt32()
            _ = cbNetid // recorded only as part of the address tuple below
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }

        let issued = await clients.setclientid(
            verifier: verifier,
            ownerName: ownerName,
            callbackProgram: cbProgram,
            callbackAddr: "\(cbNetid)/\(cbAddr)"
        )
        var enc = XDREncoder()
        enc.writeUInt64(issued.clientid)
        enc.writeUInt64(issued.confirmVerifier)
        return OpResult(status: .ok, body: enc.buffer)
    }

    fileprivate func opSetClientIdConfirm(dec: inout XDRDecoder) async -> OpResult {
        let clientid: UInt64
        let verifier: UInt64
        do {
            clientid = try dec.readUInt64()
            verifier = try dec.readUInt64()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        switch await clients.setclientidConfirm(clientid: clientid, confirmVerifier: verifier) {
        case .ok:           return OpResult(status: .ok, body: ByteBuffer())
        case .staleClientid: return OpResult(status: .staleClientid, body: ByteBuffer())
        case .clidInUse:    return OpResult(status: .clidInUse, body: ByteBuffer())
        }
    }

    fileprivate func opSecinfo(dec: inout XDRDecoder) -> OpResult {
        // RFC 7530 §16.31 — SECINFO. We only support AUTH_SYS, so reply with
        // a single-element array {AUTH_SYS}. The args (utf8str_cs name) are
        // consumed but not used since the user's NFSServer is not asked.
        do {
            _ = try dec.readString(maxLength: 1 << 16)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        var enc = XDREncoder()
        enc.writeUInt32(1)                                 // count
        enc.writeUInt32(RPCAuthFlavor.sys.rawValue)        // flavor
        return OpResult(status: .ok, body: enc.buffer)
    }
}

extension NFSStatus {
    /// nanonfs maps an expired-lease registry result onto the closest RFC
    /// status. RFC 7530 §13.1 lists `expired` only for stateid; for clientid
    /// the analogous status is `STALE_CLIENTID`.
    static let expired: NFSStatus = .staleClientid
}

// MARK: - SETATTR (RFC 7530 §16.32)

extension CompoundDispatcher {
    fileprivate func opSetattr(dec: inout XDRDecoder,
                               state: inout CompoundState) async -> OpResult {
        let stateid: NFSStateID
        let decoded: SetattrDecoded
        do {
            stateid = try decodeStateid(&dec)
            decoded = try decodeSetattrPatch(from: &dec)
        } catch SetattrDecodeError.unsupportedAttr {
            return OpResult(status: .attrnotsupp, body: emptySetattrBody())
        } catch SetattrDecodeError.readonlyAttr {
            return OpResult(status: .inval, body: emptySetattrBody())
        } catch SetattrDecodeError.invalidOwnerString {
            return OpResult(status: .badowner, body: emptySetattrBody())
        } catch {
            return OpResult(status: .badxdr, body: emptySetattrBody())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: emptySetattrBody())
        }
        // SETATTR with size MUST carry a non-anonymous stateid; otherwise the
        // server may reject with NFS4ERR_BAD_STATEID. We pass through the
        // stateid for the user to validate; nil if anonymous (size omitted).
        let userStateid: NFSStateID? = (decoded.patch.size != nil ? stateid : nil)
        do {
            _ = try await server.setattr(handle: fh, stateid: userStateid,
                                         patch: decoded.patch)
            // Even on success, body shape is bitmap of attrs that were set.
            var enc = XDREncoder()
            decoded.attrsSet.encode(into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            // RFC 7530 §16.32.5: even on partial failure, return the bitmap
            // of attrs the server *did* set. nanonfs treats setattr as
            // all-or-nothing for now and emits an empty bitmap on error.
            return OpResult(status: error.asStatus, body: emptySetattrBody())
        } catch {
            logger.warning("SETATTR server fault: \(error)")
            return OpResult(status: .serverfault, body: emptySetattrBody())
        }
    }
}

private func emptySetattrBody() -> ByteBuffer {
    var enc = XDREncoder()
    AttrBitmap().encode(into: &enc)
    return enc.buffer
}

// MARK: - READDIR (RFC 7530 §16.24)

extension CompoundDispatcher {
    fileprivate func opReaddir(dec: inout XDRDecoder,
                               state: inout CompoundState) async -> OpResult {
        let cookie: UInt64
        let cookieVerf: UInt64
        let dircount: UInt32
        let maxcount: UInt32
        let attrRequest: AttrBitmap
        do {
            cookie     = try dec.readUInt64()
            cookieVerf = try dec.readUInt64()
            dircount   = try dec.readUInt32()
            maxcount   = try dec.readUInt32()
            attrRequest = try AttrBitmap.decode(from: &dec)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        _ = dircount // currently advisory only
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        let estimated = max(Int(maxcount) / 64, 16) // rough entries cap
        do {
            let list = try await server.readdir(handle: fh,
                                                cookie: cookie,
                                                cookieVerifier: cookieVerf,
                                                maxEntries: estimated)
            return OpResult(status: .ok,
                            body: encodeReaddirBody(list: list,
                                                    attrRequest: attrRequest,
                                                    server: server,
                                                    parentFh: fh))
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("READDIR server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opReadlink(state: inout CompoundState) async -> OpResult {
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let target = try await server.readlink(handle: fh)
            var enc = XDREncoder()
            enc.writeString(target)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("READLINK server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }
}

/// Encode `READDIR4resok = verifier4 cookieverf; dirlist4 reply;` where
/// `dirlist4 = entry4* entries; bool eof;` and entry4 is a singly-linked
/// list expressed in XDR via `bool present` discriminators.
private func encodeReaddirBody(list: NFSDirList,
                               attrRequest: AttrBitmap,
                               server: any NFSServer,
                               parentFh: NFSFileHandle) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeUInt64(list.verifier)

    // Walk entries, emitting (bool=true, cookie, name, fattr4) for each.
    // FATTR4_FILEHANDLE is filled with `entry.fileHandle` if the caller
    // populated it; otherwise we fall back to the parent's handle. The
    // fallback is wrong (every entry would advertise the parent's fh —
    // clients that ask for FATTR4_FILEHANDLE silently drop the entries on
    // mismatch — see notes on `NFSDirEntry.fileHandle`), but we keep it for
    // backwards compatibility with callers that don't know about the field.
    for entry in list.entries {
        enc.writeBool(true)
        // Use fileid as the cookie. RFC 7530 §16.24.3 lets the server pick
        // any opaque cookie value; the only requirement is that re-feeding
        // it to a follow-up READDIR resumes after this entry. Until
        // `NFSDirEntry` exposes a per-entry cookie field, fileid is good
        // enough since fileids are unique within a directory.
        enc.writeUInt64(entry.fileid)
        enc.writeString(entry.name)

        let stat = entry.attrs ?? NFSStat(
            type: .regularFile, mode: 0o600, nlink: 1,
            uid: 0, gid: 0, size: 0, used: 0, fileid: entry.fileid,
            atime: .now(), mtime: .now(), ctime: .now()
        )
        let entryFh = entry.fileHandle ?? parentFh
        let (mask, vals) = encodeFattr4(stat: stat, fileHandle: entryFh, request: attrRequest)
        mask.encode(into: &enc)
        enc.writeVariableOpaque(Data(vals.readableBytesView))
    }
    enc.writeBool(false)         // no more entries
    enc.writeBool(list.eof)
    _ = server // kept for the TODO above — we may call server.getattr per entry later
    return enc.buffer
}

/// Decode a `stateid4` (RFC 7530 §3.3.12).
private func decodeStateid(_ dec: inout XDRDecoder) throws -> NFSStateID {
    let seqid = try dec.readUInt32()
    let other = try dec.readFixedOpaqueData(count: 12)
    return NFSStateID(seqid: seqid, other: other)
}

private func encodeStateid(_ stateid: NFSStateID, into enc: inout XDREncoder) {
    enc.writeUInt32(stateid.seqid)
    // `other` MUST be exactly 12 bytes; pad/truncate defensively if the
    // user's stateid is mis-shaped, since callers should never get to see
    // a malformed stateid on the wire.
    var other = stateid.other
    if other.count < 12 { other.append(contentsOf: Array(repeating: 0, count: 12 - other.count)) }
    if other.count > 12 { other = other.prefix(12) }
    // 12 is already a multiple of 4 so no padding bytes are emitted.
    enc.writeFixedOpaque(other)
}

// MARK: - READ / WRITE / COMMIT (RFC 7530 §16.23, §16.36, §16.5)

extension CompoundDispatcher {
    fileprivate func opRead(dec: inout XDRDecoder,
                            state: inout CompoundState) async -> OpResult {
        let stateid: NFSStateID
        let offset: UInt64
        let count: UInt32
        do {
            stateid = try decodeStateid(&dec)
            offset = try dec.readUInt64()
            count = try dec.readUInt32()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let result = try await server.read(handle: fh,
                                               stateid: stateid,
                                               offset: offset,
                                               count: Int(count))
            var enc = XDREncoder()
            enc.writeBool(result.eof)
            enc.writeVariableOpaque(result.data)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("READ server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opWrite(dec: inout XDRDecoder,
                             state: inout CompoundState) async -> OpResult {
        let stateid: NFSStateID
        let offset: UInt64
        let stableRaw: UInt32
        let payload: Data
        do {
            stateid = try decodeStateid(&dec)
            offset = try dec.readUInt64()
            stableRaw = try dec.readUInt32()
            payload = try dec.readVariableOpaqueData()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let stability = NFSWriteStability(rawValue: stableRaw) else {
            return OpResult(status: .inval, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let result = try await server.write(handle: fh,
                                                stateid: stateid,
                                                offset: offset,
                                                stability: stability,
                                                data: payload)
            var enc = XDREncoder()
            enc.writeUInt32(UInt32(result.count))
            enc.writeUInt32(result.committed.rawValue)
            // writeverf is 8-byte opaque per RFC 7530 §3.3.13.
            enc.writeUInt64(result.writeVerifier)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("WRITE server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opReleaseLockowner(dec: inout XDRDecoder) -> OpResult {
        // RFC 7530 §16.31 — release_lockowner4 args = lock_owner4 (clientid + opaque).
        // Library-internal: we acknowledge so the kernel can reuse the
        // lockowner string. Per-server bookkeeping is added with LOCK ops.
        do {
            _ = try dec.readUInt64()                       // clientid
            _ = try dec.readVariableOpaqueData(maxLength: 1024)
            return OpResult(status: .ok, body: ByteBuffer())
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
    }

    fileprivate func opCommit(dec: inout XDRDecoder,
                              state: inout CompoundState) async -> OpResult {
        let offset: UInt64
        let count: UInt32
        do {
            offset = try dec.readUInt64()
            count = try dec.readUInt32()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let verifier = try await server.commit(handle: fh,
                                                   offset: offset,
                                                   count: UInt64(count))
            var enc = XDREncoder()
            enc.writeUInt64(verifier)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("COMMIT server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }
}

// MARK: - CREATE / REMOVE / RENAME / LINK (RFC 7530 §16.7, §16.27, §16.28, §16.9)

extension CompoundDispatcher {
    /// CREATE handles non-regular file types only — regular files go through
    /// OPEN. The fattr4 in the call is interpreted via the same SETATTR
    /// decoder, since CREATE-time attribute set is the same patch shape.
    fileprivate func opCreate(dec: inout XDRDecoder,
                              state: inout CompoundState) async -> OpResult {
        let typeRaw: UInt32
        var linkTarget: String? = nil
        var rdev: NFSStat.RDev? = nil
        do {
            typeRaw = try dec.readUInt32()
            // createtype4 union arms.
            switch typeRaw {
            case NFSObjectType.symbolicLink.rawValue:
                linkTarget = try dec.readString(maxLength: 1 << 16)
            case NFSObjectType.blockDevice.rawValue, NFSObjectType.characterDevice.rawValue:
                let major = try dec.readUInt32()
                let minor = try dec.readUInt32()
                rdev = NFSStat.RDev(major: major, minor: minor)
            default:
                break
            }
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let type = NFSObjectType(rawValue: typeRaw),
              type != .regularFile else {
            return OpResult(status: .badtype, body: ByteBuffer())
        }
        let name: String
        let attrs: SetattrDecoded
        do {
            name = try dec.readString(maxLength: 1 << 16)
            attrs = try decodeSetattrPatch(from: &dec)
        } catch SetattrDecodeError.unsupportedAttr {
            return OpResult(status: .attrnotsupp, body: ByteBuffer())
        } catch SetattrDecodeError.readonlyAttr {
            return OpResult(status: .inval, body: ByteBuffer())
        } catch SetattrDecodeError.invalidOwnerString {
            return OpResult(status: .badowner, body: ByteBuffer())
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let parent = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }

        // Symlink target / rdev are passed via the patch struct extensions:
        // until those exist, we surface them through the encoded attrs.
        // For now, the user's `create()` does not see them — Phase 2.
        _ = linkTarget; _ = rdev

        do {
            let child = try await server.create(parent: parent,
                                                name: name,
                                                type: type,
                                                attrs: attrs.patch)
            state.currentFh = child
            var enc = XDREncoder()
            encodeChangeInfo(&enc)
            attrs.attrsSet.encode(into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("CREATE server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opRemove(dec: inout XDRDecoder,
                              state: inout CompoundState) async -> OpResult {
        let name: String
        do {
            name = try dec.readString(maxLength: 1 << 16)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let parent = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            try await server.remove(parent: parent, name: name)
            var enc = XDREncoder()
            encodeChangeInfo(&enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("REMOVE server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opRename(dec: inout XDRDecoder,
                              state: inout CompoundState) async -> OpResult {
        let oldname: String
        let newname: String
        do {
            oldname = try dec.readString(maxLength: 1 << 16)
            newname = try dec.readString(maxLength: 1 << 16)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let src = state.savedFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        guard let dst = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            try await server.rename(srcParent: src, srcName: oldname,
                                    dstParent: dst, dstName: newname)
            var enc = XDREncoder()
            encodeChangeInfo(&enc)         // source_cinfo
            encodeChangeInfo(&enc)         // target_cinfo
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("RENAME server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opLink(dec: inout XDRDecoder,
                            state: inout CompoundState) async -> OpResult {
        let newname: String
        do {
            newname = try dec.readString(maxLength: 1 << 16)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let target = state.savedFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        guard let parent = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            try await server.link(target: target, parent: parent, name: newname)
            var enc = XDREncoder()
            encodeChangeInfo(&enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("LINK server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }
}

/// Encode an opportunistic `change_info4` (RFC 7530 §3.3.5) — atomic=false,
/// before/after = current real-time monotonic counter. nanonfs does not yet
/// track per-directory change ids, so before == after; clients that care
/// about strict atomicity should not rely on the value being conservative.
private func encodeChangeInfo(_ enc: inout XDREncoder) {
    enc.writeBool(false)
    let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    enc.writeUInt64(now)
    enc.writeUInt64(now)
}

// MARK: - OPEN family (RFC 7530 §16.16-§16.18, §16.4)

extension CompoundDispatcher {
    fileprivate func opOpen(dec: inout XDRDecoder,
                            state: inout CompoundState) async -> OpResult {
        let _: UInt32  // seqid (consumed; user manages stateid lifecycle)
        let shareRaw: UInt32
        let denyRaw: UInt32
        let owner: NFSOpenOwner
        let createMode: NFSCreateMode
        let claimName: String
        do {
            _ = try dec.readUInt32()                                 // seqid
            shareRaw = try dec.readUInt32()
            denyRaw  = try dec.readUInt32()
            // open_owner4 = (clientid, opaque)
            let clid = try dec.readUInt64()
            let ownerBytes = try dec.readVariableOpaqueData(maxLength: 1024)
            owner = NFSOpenOwner(clientid: clid, owner: ownerBytes)
            // openhow: opentype4 + maybe createhow4
            let openType = try dec.readUInt32()
            switch openType {
            case 0:
                createMode = .open
            case 1:
                let mode = try dec.readUInt32()
                switch mode {
                case 0, 1: // UNCHECKED4 / GUARDED4 share fattr4
                    let attrs = try decodeSetattrPatch(from: &dec)
                    createMode = .create(attrs.patch)
                case 2:    // EXCLUSIVE4
                    let verifier = try dec.readUInt64()
                    createMode = .createExclusive(verifier: verifier)
                default:
                    return OpResult(status: .inval, body: ByteBuffer())
                }
            default:
                return OpResult(status: .inval, body: ByteBuffer())
            }
            // open_claim4
            let claimType = try dec.readUInt32()
            switch claimType {
            case 0:    // CLAIM_NULL
                claimName = try dec.readString(maxLength: 1 << 16)
            default:
                // CLAIM_PREVIOUS / CLAIM_DELEGATE_* not yet implemented.
                return OpResult(status: .notsupp, body: ByteBuffer())
            }
        } catch SetattrDecodeError.unsupportedAttr {
            return OpResult(status: .attrnotsupp, body: ByteBuffer())
        } catch SetattrDecodeError.readonlyAttr {
            return OpResult(status: .inval, body: ByteBuffer())
        } catch SetattrDecodeError.invalidOwnerString {
            return OpResult(status: .badowner, body: ByteBuffer())
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let parent = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }

        do {
            let opened = try await server.open(
                parent: parent,
                name: claimName,
                share: NFSShareAccess(rawValue: shareRaw),
                deny:  NFSShareDeny(rawValue: denyRaw),
                owner: owner,
                wantDelegation: .none,        // delegation hint is exposed in Phase 2
                create: createMode
            )
            state.currentFh = opened.handle

            var enc = XDREncoder()
            encodeStateid(opened.result.stateid, into: &enc)
            encodeChangeInfo(&enc)
            enc.writeUInt32(opened.result.rflags.rawValue)
            // attrset: conservatively report the full requested-create patch
            // would have been set; for OPEN(NOCREATE) it is empty bitmap.
            switch createMode {
            case .create(let p):
                AttrBitmap(patchAttrs(p)).encode(into: &enc)
            default:
                AttrBitmap().encode(into: &enc)
            }
            encodeOpenDelegation(opened.result.delegation, into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("OPEN server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opOpenConfirm(dec: inout XDRDecoder,
                                   state: inout CompoundState) async -> OpResult {
        let stateid: NFSStateID
        let seqid: UInt32
        do {
            stateid = try decodeStateid(&dec)
            seqid   = try dec.readUInt32()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let updated = try await server.openConfirm(handle: fh,
                                                       stateid: stateid,
                                                       seqid: seqid)
            var enc = XDREncoder()
            encodeStateid(updated, into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("OPEN_CONFIRM server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opOpenDowngrade(dec: inout XDRDecoder,
                                     state: inout CompoundState) async -> OpResult {
        let stateid: NFSStateID
        let _: UInt32  // seqid (consumed)
        let shareRaw: UInt32
        let denyRaw: UInt32
        do {
            stateid  = try decodeStateid(&dec)
            _ = try dec.readUInt32()
            shareRaw = try dec.readUInt32()
            denyRaw  = try dec.readUInt32()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let updated = try await server.openDowngrade(
                handle: fh, stateid: stateid,
                share: NFSShareAccess(rawValue: shareRaw),
                deny:  NFSShareDeny(rawValue: denyRaw)
            )
            var enc = XDREncoder()
            encodeStateid(updated, into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("OPEN_DOWNGRADE server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opClose(dec: inout XDRDecoder,
                             state: inout CompoundState) async -> OpResult {
        let _: UInt32  // seqid
        let stateid: NFSStateID
        do {
            _ = try dec.readUInt32()
            stateid = try decodeStateid(&dec)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            try await server.close(handle: fh, stateid: stateid)
            var enc = XDREncoder()
            // RFC 7530 §16.4.4 — server returns an updated stateid; nanonfs
            // bumps seqid to seqid+1 (mod 2^32, with 0 reserved).
            var bump = stateid
            bump.seqid = bump.seqid &+ 1
            if bump.seqid == 0 { bump.seqid = 1 }
            encodeStateid(bump, into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("CLOSE server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }
}

private func patchAttrs(_ p: NFSAttributesPatch) -> [FATTR4] {
    var out: [FATTR4] = []
    if p.mode  != nil { out.append(.mode) }
    if p.uid   != nil { out.append(.owner) }
    if p.gid   != nil { out.append(.ownerGroup) }
    if p.size  != nil { out.append(.size) }
    if p.atime != nil { out.append(.timeAccessSet) }
    if p.mtime != nil { out.append(.timeModifySet) }
    return out
}

/// Encode an `open_delegation4` (RFC 7530 §16.16.5).
private func encodeOpenDelegation(_ grant: NFSDelegationGrant,
                                  into enc: inout XDREncoder) {
    switch grant {
    case .none:
        enc.writeUInt32(0)            // OPEN_DELEGATE_NONE
    case .read(let stateid, let recall):
        enc.writeUInt32(1)            // OPEN_DELEGATE_READ
        encodeStateid(stateid, into: &enc)
        enc.writeBool(recall)
        encodeDefaultAce(into: &enc)
    case .write(let stateid, let recall, let space):
        enc.writeUInt32(2)            // OPEN_DELEGATE_WRITE
        encodeStateid(stateid, into: &enc)
        enc.writeBool(recall)
        // nfs_space_limit4 — encode NFS_LIMIT_SIZE.
        enc.writeUInt32(1)            // NFS_LIMIT_SIZE
        enc.writeUInt64(space)
        encodeDefaultAce(into: &enc)
    }
}

/// "EVERYONE@ ALLOWED full" ACE — sent as the `permissions` field of read /
/// write delegation grants (RFC 7530 §5.11).
private func encodeDefaultAce(into enc: inout XDREncoder) {
    enc.writeUInt32(0)            // type = ACE4_ACCESS_ALLOWED
    enc.writeUInt32(0)            // flag
    enc.writeUInt32(0x001F01FF)   // mask = full set
    enc.writeString("EVERYONE@")
}

// MARK: - LOCK / LOCKT / LOCKU (RFC 7530 §16.10-§16.12)

private let lockTypeReadShared:           UInt32 = 1   // READ_LT
private let lockTypeWriteExclusive:       UInt32 = 2   // WRITE_LT
private let lockTypeReadSharedBlocking:   UInt32 = 3   // READW_LT
private let lockTypeWriteExclusiveBlocking: UInt32 = 4 // WRITEW_LT

private func decodeLockType(_ raw: UInt32) -> NFSLockType? {
    switch raw {
    case lockTypeReadShared:             return .readShared
    case lockTypeWriteExclusive:         return .writeExclusive
    case lockTypeReadSharedBlocking:     return .readSharedBlocking
    case lockTypeWriteExclusiveBlocking: return .writeExclusiveBlocking
    default: return nil
    }
}

private func encodeLockType(_ t: NFSLockType) -> UInt32 {
    switch t {
    case .readShared:             return lockTypeReadShared
    case .writeExclusive:         return lockTypeWriteExclusive
    case .readSharedBlocking:     return lockTypeReadSharedBlocking
    case .writeExclusiveBlocking: return lockTypeWriteExclusiveBlocking
    }
}

extension CompoundDispatcher {
    fileprivate func opLock(dec: inout XDRDecoder,
                            state: inout CompoundState) async -> OpResult {
        let lockTypeRaw: UInt32
        let reclaim: Bool
        let offset: UInt64
        let length: UInt64
        let useNewOwner: Bool
        let stateid: NFSStateID
        let lockOwner: NFSLockOwner
        do {
            lockTypeRaw = try dec.readUInt32()
            reclaim = try dec.readBool()
            offset = try dec.readUInt64()
            length = try dec.readUInt64()
            useNewOwner = try dec.readBool()
            if useNewOwner {
                // open_to_lock_owner4: open_seqid, open_stateid, lock_seqid, lock_owner4
                _ = try dec.readUInt32()                 // open_seqid
                stateid = try decodeStateid(&dec)
                _ = try dec.readUInt32()                 // lock_seqid
                let clid = try dec.readUInt64()
                let bytes = try dec.readVariableOpaqueData(maxLength: 1024)
                lockOwner = NFSLockOwner(clientid: clid, owner: bytes)
            } else {
                // exist_lock_owner4: lock_stateid, lock_seqid
                stateid = try decodeStateid(&dec)
                _ = try dec.readUInt32()                 // lock_seqid
                // NFS4 protocol does not re-send the lock_owner here — server
                // recovers it from stateid. We pass an empty owner shell.
                lockOwner = NFSLockOwner(clientid: 0, owner: Data())
            }
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let type = decodeLockType(lockTypeRaw) else {
            return OpResult(status: .inval, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }

        do {
            let granted = try await server.lock(
                handle: fh, type: type,
                range: NFSLockRange(offset: offset, length: length),
                owner: lockOwner, reclaim: reclaim,
                stateid: stateid
            )
            var enc = XDREncoder()
            encodeStateid(granted, into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let NFSError.lockDenied(conflict, type, owner) {
            var enc = XDREncoder()
            encodeLockDenied(conflict: conflict, type: type, owner: owner, into: &enc)
            return OpResult(status: .denied, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("LOCK server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opLockt(dec: inout XDRDecoder,
                             state: inout CompoundState) async -> OpResult {
        let lockTypeRaw: UInt32
        let offset: UInt64
        let length: UInt64
        let owner: NFSLockOwner
        do {
            lockTypeRaw = try dec.readUInt32()
            offset = try dec.readUInt64()
            length = try dec.readUInt64()
            let clid = try dec.readUInt64()
            let bytes = try dec.readVariableOpaqueData(maxLength: 1024)
            owner = NFSLockOwner(clientid: clid, owner: bytes)
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let type = decodeLockType(lockTypeRaw) else {
            return OpResult(status: .inval, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let result = try await server.lockTest(
                handle: fh, type: type,
                range: NFSLockRange(offset: offset, length: length),
                owner: owner
            )
            switch result.outcome {
            case .granted:
                return OpResult(status: .ok, body: ByteBuffer())
            case .denied(let conflict, let type, let owner):
                var enc = XDREncoder()
                encodeLockDenied(conflict: conflict, type: type, owner: owner, into: &enc)
                return OpResult(status: .denied, body: enc.buffer)
            }
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("LOCKT server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }

    fileprivate func opLocku(dec: inout XDRDecoder,
                             state: inout CompoundState) async -> OpResult {
        let _: UInt32  // locktype
        let _: UInt32  // seqid
        let stateid: NFSStateID
        let offset: UInt64
        let length: UInt64
        do {
            _ = try dec.readUInt32()                 // locktype (informational)
            _ = try dec.readUInt32()                 // seqid
            stateid = try decodeStateid(&dec)
            offset = try dec.readUInt64()
            length = try dec.readUInt64()
        } catch {
            return OpResult(status: .badxdr, body: ByteBuffer())
        }
        guard let fh = state.currentFh else {
            return OpResult(status: .nofilehandle, body: ByteBuffer())
        }
        do {
            let updated = try await server.unlock(
                handle: fh,
                range: NFSLockRange(offset: offset, length: length),
                stateid: stateid
            )
            var enc = XDREncoder()
            encodeStateid(updated, into: &enc)
            return OpResult(status: .ok, body: enc.buffer)
        } catch let error as NFSError {
            return OpResult(status: error.asStatus, body: ByteBuffer())
        } catch {
            logger.warning("LOCKU server fault: \(error)")
            return OpResult(status: .serverfault, body: ByteBuffer())
        }
    }
}

private func encodeLockDenied(conflict: NFSLockRange,
                              type: NFSLockType,
                              owner: NFSLockOwner,
                              into enc: inout XDREncoder) {
    enc.writeUInt64(conflict.offset)
    enc.writeUInt64(conflict.length)
    enc.writeUInt32(encodeLockType(type))
    enc.writeUInt64(owner.clientid)
    enc.writeVariableOpaque(owner.owner)
}

// MARK: - Response framing

private func encodeCompoundResponse(
    status: NFSStatus,
    tag: String,
    results: [(opcode: UInt32, status: NFSStatus, body: ByteBuffer)]
) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeUInt32(status.rawValue)
    enc.writeString(tag)
    enc.writeUInt32(UInt32(results.count))
    for r in results {
        enc.writeUInt32(r.opcode)
        enc.writeUInt32(r.status.rawValue)
        var body = r.body
        enc.buffer.writeBuffer(&body)
    }
    return enc.buffer
}

private func encodeCompoundEarlyError(_ status: NFSStatus, tag: String) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeUInt32(status.rawValue)
    enc.writeString(tag)
    enc.writeUInt32(0) // empty resarray — RFC 7530 §16.2.5
    return enc.buffer
}

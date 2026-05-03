import Foundation
import Logging
import NIOCore
import Testing
@testable import NanoNFS

// Wire-level simulation of the COMPOUND sequence a real NFSv4.0 client emits
// during mount + simple `ls` + `cat`. We do not invoke `mount_nfs` here
// (that needs sudo and a real macOS kernel client); instead we send the
// equivalent COMPOUND requests through the on-the-wire encoder and check
// each NFSStatus.

@Suite("Simulated mount + ls + cat sequence")
struct MountSimulationTests {

    @Test("full mount-time chain returns OK at every step")
    func mountChain() async throws {
        let server = MountSimServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            logger: Logger(label: "test")
        )
        let runTask = Task { try await listener.run() }
        let bound = try await waitForBind(listener: listener)
        defer { runTask.cancel() }
        let port = UInt16(bound.port ?? 0)

        let conn = try TCPClient(host: "127.0.0.1", port: port)
        defer { conn.close() }

        // 1) SETCLIENTID
        let s1 = SimClient.setclientid(verifier: 0x1234, owner: Data([0xA, 0xB]))
        try conn.write(rpcWrapSingleFragment(s1.frame))
        let r1 = try conn.readRecord(timeoutSeconds: 2.0)
        let (clientid, confirm) = try SimClient.expectSetclientidReply(r1)

        // 2) SETCLIENTID_CONFIRM
        let s2 = SimClient.setclientidConfirm(clientid: clientid, verifier: confirm)
        try conn.write(rpcWrapSingleFragment(s2.frame))
        let r2 = try conn.readRecord(timeoutSeconds: 2.0)
        try SimClient.expectStatus(r2, expected: .ok)

        // 3) PUTROOTFH; GETATTR(SUPPORTED_ATTRS, FH_EXPIRE_TYPE, ... )
        let request = AttrBitmap([
            .supportedAttrs, .type, .fhExpireType, .change, .size,
            .linkSupport, .symlinkSupport, .namedAttr, .fsid,
            .uniqueHandles, .leaseTime, .rdattrError, .fileHandle,
            .fileID, .mode, .numLinks, .owner, .ownerGroup,
            .timeAccess, .timeMetadata, .timeModify, .spaceUsed,
            .mountedOnFileID,
        ])
        let s3 = SimClient.compound(ops: [
            (.putrootfh, ByteBuffer()),
            (.getattr,   { var e = XDREncoder(); request.encode(into: &e); return e.buffer }()),
        ])
        try conn.write(rpcWrapSingleFragment(s3.frame))
        let r3 = try conn.readRecord(timeoutSeconds: 2.0)
        try SimClient.expectAllOpsOK(r3, expectedCount: 2)

        // 4) PUTROOTFH; READDIR
        var rd = XDREncoder()
        rd.writeUInt64(0)         // cookie
        rd.writeUInt64(0)         // verifier
        rd.writeUInt32(8192)      // dircount
        rd.writeUInt32(8192)      // maxcount
        AttrBitmap([.type, .size, .fileID, .mode]).encode(into: &rd)
        let s4 = SimClient.compound(ops: [
            (.putrootfh, ByteBuffer()),
            (.readdir,   rd.buffer),
        ])
        try conn.write(rpcWrapSingleFragment(s4.frame))
        let r4 = try conn.readRecord(timeoutSeconds: 2.0)
        try SimClient.expectAllOpsOK(r4, expectedCount: 2)

        // 5) PUTROOTFH; LOOKUP("hello.txt"); GETATTR(MODE, SIZE)
        var lookupArgs = XDREncoder(); lookupArgs.writeString("hello.txt")
        var getattrArgs = XDREncoder(); AttrBitmap([.mode, .size]).encode(into: &getattrArgs)
        let s5 = SimClient.compound(ops: [
            (.putrootfh, ByteBuffer()),
            (.lookup,    lookupArgs.buffer),
            (.getattr,   getattrArgs.buffer),
        ])
        try conn.write(rpcWrapSingleFragment(s5.frame))
        let r5 = try conn.readRecord(timeoutSeconds: 2.0)
        try SimClient.expectAllOpsOK(r5, expectedCount: 3)

        // 6) PUTROOTFH; LOOKUP("hello.txt"); OPEN; READ
        var openArgs = XDREncoder()
        openArgs.writeUInt32(1)                                  // seqid
        openArgs.writeUInt32(NFSShareAccess.read.rawValue)        // share_access
        openArgs.writeUInt32(NFSShareDeny.none.rawValue)          // share_deny
        openArgs.writeUInt64(clientid)                            // owner.clientid
        openArgs.writeVariableOpaque(Data([0x01]))                // owner.owner
        openArgs.writeUInt32(0)                                   // OPEN4_NOCREATE
        openArgs.writeUInt32(0)                                   // CLAIM_NULL
        openArgs.writeString("hello.txt")

        var readArgs = XDREncoder()
        readArgs.writeUInt32(0)                                   // anonymous stateid seqid
        readArgs.writeFixedOpaque(Data(repeating: 0, count: 12))
        readArgs.writeUInt64(0)                                   // offset
        readArgs.writeUInt32(1024)                                // count

        let s6 = SimClient.compound(ops: [
            (.putrootfh, ByteBuffer()),
            (.lookup,    { var e = XDREncoder(); e.writeString("hello.txt"); return e.buffer }()),
            (.open,      openArgs.buffer),
            (.read,      readArgs.buffer),
        ])
        try conn.write(rpcWrapSingleFragment(s6.frame))
        let r6 = try conn.readRecord(timeoutSeconds: 2.0)
        let payload = try SimClient.extractReadPayload(r6, opIndex: 3)
        #expect(payload == Data("Hello, NFS world!\n".utf8))
    }

    private func waitForBind(listener: NFSServerListener) async throws -> SocketAddress {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let a = await listener.boundAddress { return a }
            try? await Task.sleep(nanoseconds: 5 * 1_000_000)
        }
        struct Timeout: Error {}
        throw Timeout()
    }
}

// MARK: - Wire-level RPC helpers used by the simulation

final class XidGen: @unchecked Sendable {
    // Single-threaded across the test, so plain mutation is fine — but
    // strict concurrency mode still wants explicit isolation, hence
    // @unchecked.
    private var n: UInt32 = 1
    func next() -> UInt32 { defer { n &+= 1 }; return n }
}

enum SimClient {
    private static let xidCounter = XidGen()
    private static func nextXidValue() -> UInt32 { xidCounter.next() }

    private static func authSysCred() -> RPCOpaqueAuth {
        RPCOpaqueAuth(
            flavor: RPCAuthFlavor.sys.rawValue,
            body: encodeAuthSysBody(AuthSysCredential(
                stamp: 0, machineName: "test", uid: 0, gid: 0, gids: []
            ))
        )
    }

    static func setclientid(verifier: UInt64, owner: Data) -> (frame: ByteBuffer, xid: UInt32) {
        var c = XDREncoder()
        c.writeString("")
        c.writeUInt32(0)
        c.writeUInt32(1)
        c.writeUInt32(NFSOp.setclientid.rawValue)
        c.writeUInt64(verifier)
        c.writeVariableOpaque(owner)
        c.writeUInt32(0x4000_0001)            // cb_program
        c.writeString("tcp")
        c.writeString("0.0.0.0.0.0")
        c.writeUInt32(0)
        let xid = nextXidValue()
        let frame = encodeRpcCall(xid: xid,
                                  program: NFSProgram.number,
                                  version: NFSProgram.version,
                                  procedure: NFSProcedure.compound.rawValue,
                                  credential: authSysCred(),
                                  args: c.buffer)
        return (frame, xid)
    }

    static func setclientidConfirm(clientid: UInt64, verifier: UInt64) -> (frame: ByteBuffer, xid: UInt32) {
        var c = XDREncoder()
        c.writeString("")
        c.writeUInt32(0)
        c.writeUInt32(1)
        c.writeUInt32(NFSOp.setclientidConfirm.rawValue)
        c.writeUInt64(clientid)
        c.writeUInt64(verifier)
        let xid = nextXidValue()
        let frame = encodeRpcCall(xid: xid,
                                  program: NFSProgram.number,
                                  version: NFSProgram.version,
                                  procedure: NFSProcedure.compound.rawValue,
                                  credential: authSysCred(),
                                  args: c.buffer)
        return (frame, xid)
    }

    static func compound(ops: [(opcode: NFSOp, payload: ByteBuffer)]) -> (frame: ByteBuffer, xid: UInt32) {
        var c = XDREncoder()
        c.writeString("")
        c.writeUInt32(0)
        c.writeUInt32(UInt32(ops.count))
        for (op, payload) in ops {
            c.writeUInt32(op.rawValue)
            var p = payload; c.buffer.writeBuffer(&p)
        }
        let xid = nextXidValue()
        let frame = encodeRpcCall(xid: xid,
                                  program: NFSProgram.number,
                                  version: NFSProgram.version,
                                  procedure: NFSProcedure.compound.rawValue,
                                  credential: authSysCred(),
                                  args: c.buffer)
        return (frame, xid)
    }

    static func skipRpcAcceptedHeader(_ buffer: ByteBuffer) throws -> XDRDecoder {
        var dec = XDRDecoder(buffer)
        _ = try dec.readUInt32()                       // xid
        _ = try dec.readUInt32()                       // mtype
        _ = try dec.readUInt32()                       // reply_stat
        _ = try dec.readUInt32()                       // verf flavor
        _ = try dec.readVariableOpaqueData()           // verf body
        let acceptStat = try dec.readUInt32()
        precondition(acceptStat == RPCAcceptStatus.success.rawValue,
                     "RPC accepted but not SUCCESS: \(acceptStat)")
        return dec
    }

    static func expectSetclientidReply(_ frame: ByteBuffer) throws -> (clientid: UInt64,
                                                                       confirmVerifier: UInt64) {
        var dec = try skipRpcAcceptedHeader(frame)
        let overall = try dec.readUInt32()
        precondition(overall == NFSStatus.ok.rawValue,
                     "SETCLIENTID overall status not OK: \(overall)")
        _ = try dec.readString() // tag
        _ = try dec.readUInt32() // op count
        _ = try dec.readUInt32() // opcode
        _ = try dec.readUInt32() // status (ok)
        let cid = try dec.readUInt64()
        let cv  = try dec.readUInt64()
        return (cid, cv)
    }

    static func expectStatus(_ frame: ByteBuffer, expected: NFSStatus) throws {
        var dec = try skipRpcAcceptedHeader(frame)
        let s = try dec.readUInt32()
        precondition(s == expected.rawValue, "expected \(expected.rawValue) got \(s)")
    }

    static func expectAllOpsOK(_ frame: ByteBuffer, expectedCount: Int) throws {
        var dec = try skipRpcAcceptedHeader(frame)
        let overall = try dec.readUInt32()
        precondition(overall == NFSStatus.ok.rawValue,
                     "compound overall status not OK: \(overall)")
        _ = try dec.readString()
        let n = try dec.readUInt32()
        precondition(Int(n) == expectedCount, "got \(n) ops, expected \(expectedCount)")
        for _ in 0..<Int(n) {
            _ = try dec.readUInt32() // opcode
            let s = try dec.readUInt32()
            precondition(s == NFSStatus.ok.rawValue, "op status \(s)")
            // Skip per-op body — we don't structurally parse here, the
            // sequence test only cares that everything reported OK and the
            // RPC reply terminated cleanly.
            // Drain the rest by giving up — the next iteration will still
            // be at the right position because we did not consume the body
            // bytes. However, we need to consume them to advance, so we
            // can't strictly skip. For this test we instead bail out after
            // confirming the first op is OK; the caller's invariant is
            // that the dispatcher never aborted COMPOUND mid-way (the
            // overall status == OK already implies this).
            return
        }
    }

    static func extractReadPayload(_ frame: ByteBuffer, opIndex: Int) throws -> Data {
        var dec = try skipRpcAcceptedHeader(frame)
        let overall = try dec.readUInt32()
        precondition(overall == NFSStatus.ok.rawValue, "overall status: \(overall)")
        _ = try dec.readString()
        let n = try dec.readUInt32()
        precondition(Int(n) > opIndex)
        for i in 0..<Int(n) {
            let opcode = try dec.readUInt32()
            let status = try dec.readUInt32()
            precondition(status == NFSStatus.ok.rawValue, "op \(i) status \(status)")
            // Per-op body decoding by opcode.
            if i == opIndex {
                precondition(opcode == NFSOp.read.rawValue, "expected READ at \(opIndex)")
                _ = try dec.readBool() // eof
                return try dec.readVariableOpaqueData()
            }
            // Drain body for known op shapes leading up to READ (PUTROOTFH=void,
            // LOOKUP=void, OPEN=stateid+changeinfo+rflags+attrset+delegation).
            switch NFSOp(rawValue: opcode) {
            case .putrootfh, .savefh, .restorefh, .lookup, .lookupp, .renew, .openConfirm:
                break
            case .open:
                _ = try dec.readUInt32()                    // stateid.seqid
                _ = try dec.readFixedOpaqueData(count: 12)  // stateid.other
                _ = try dec.readBool()                      // changeinfo.atomic
                _ = try dec.readUInt64()
                _ = try dec.readUInt64()
                _ = try dec.readUInt32()                    // rflags
                _ = try AttrBitmap.decode(from: &dec)       // attrset
                let delegType = try dec.readUInt32()
                if delegType != 0 {
                    _ = try dec.readUInt32()
                    _ = try dec.readFixedOpaqueData(count: 12)
                    _ = try dec.readBool()
                    if delegType == 2 {
                        _ = try dec.readUInt32()
                        _ = try dec.readUInt64()
                    }
                    _ = try dec.readUInt32()
                    _ = try dec.readUInt32()
                    _ = try dec.readUInt32()
                    _ = try dec.readString()
                }
            default:
                preconditionFailure("unhandled opcode \(opcode) before READ")
            }
        }
        preconditionFailure("opIndex out of range")
    }
}

// MARK: - Server fixture: read-only "/hello.txt"

actor MountSimServer: NFSServer {
    static let rootFh = NFSFileHandle(Data([0x01]))
    static let helloFh = NFSFileHandle(Data([0x02]))
    private let body = Data("Hello, NFS world!\n".utf8)

    func root() async throws -> NFSFileHandle { Self.rootFh }
    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess { mask }
    func getattr(handle: NFSFileHandle) async throws -> NFSStat {
        if handle == Self.rootFh {
            return NFSStat(type: .directory, mode: 0o755, nlink: 2,
                           uid: 0, gid: 0, size: 4096, used: 4096, fileid: 1,
                           atime: .now(), mtime: .now(), ctime: .now())
        }
        if handle == Self.helloFh {
            return NFSStat(type: .regularFile, mode: 0o444, nlink: 1,
                           uid: 0, gid: 0, size: UInt64(body.count), used: UInt64(body.count),
                           fileid: 2,
                           atime: .now(), mtime: .now(), ctime: .now())
        }
        throw NFSError.badHandle
    }
    func setattr(handle: NFSFileHandle, stateid: NFSStateID?, patch: NFSAttributesPatch) async throws -> NFSStat {
        throw NFSError.readOnly
    }
    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle {
        guard parent == Self.rootFh, name == "hello.txt" else { throw NFSError.noEntry }
        return Self.helloFh
    }
    func lookupParent(of handle: NFSFileHandle) async throws -> NFSFileHandle { Self.rootFh }
    func readdir(handle: NFSFileHandle, cookie: UInt64, cookieVerifier: UInt64,
                 maxEntries: Int) async throws -> NFSDirList {
        guard cookie == 0 else {
            return NFSDirList(entries: [], nextCookie: nil, verifier: 1, eof: true)
        }
        let entries = [NFSDirEntry(fileid: 2, name: "hello.txt", attrs: NFSStat(
            type: .regularFile, mode: 0o444, nlink: 1, uid: 0, gid: 0,
            size: UInt64(body.count), used: UInt64(body.count), fileid: 2,
            atime: .now(), mtime: .now(), ctime: .now()
        ))]
        return NFSDirList(entries: entries, nextCookie: nil, verifier: 1, eof: true)
    }
    func create(parent: NFSFileHandle, name: String, type: NFSObjectType,
                attrs: NFSAttributesPatch) async throws -> NFSFileHandle { throw NFSError.readOnly }
    func remove(parent: NFSFileHandle, name: String) async throws { throw NFSError.readOnly }
    func rename(srcParent: NFSFileHandle, srcName: String,
                dstParent: NFSFileHandle, dstName: String) async throws { throw NFSError.readOnly }
    func link(target: NFSFileHandle, parent: NFSFileHandle, name: String) async throws {
        throw NFSError.readOnly
    }
    func readlink(handle: NFSFileHandle) async throws -> String { throw NFSError.invalid }

    func open(parent: NFSFileHandle, name: String, share: NFSShareAccess, deny: NFSShareDeny,
              owner: NFSOpenOwner, wantDelegation: NFSDelegationHint,
              create: NFSCreateMode) async throws -> (handle: NFSFileHandle, result: NFSOpenResult) {
        guard name == "hello.txt" else { throw NFSError.noEntry }
        let stateid = NFSStateID(seqid: 1, other: Data(repeating: 0xAA, count: 12))
        return (Self.helloFh, NFSOpenResult(stateid: stateid, rflags: [], delegation: .none))
    }
    func openConfirm(handle: NFSFileHandle, stateid: NFSStateID, seqid: UInt32) async throws -> NFSStateID { stateid }
    func openDowngrade(handle: NFSFileHandle, stateid: NFSStateID,
                       share: NFSShareAccess, deny: NFSShareDeny) async throws -> NFSStateID { stateid }
    func close(handle: NFSFileHandle, stateid: NFSStateID) async throws { /* ok */ }

    func read(handle: NFSFileHandle, stateid: NFSStateID, offset: UInt64, count: Int) async throws -> NFSReadResult {
        guard handle == Self.helloFh else { throw NFSError.badHandle }
        let off = Int(min(offset, UInt64(body.count)))
        let end = min(off + count, body.count)
        return NFSReadResult(data: body.subdata(in: off..<end), eof: end >= body.count)
    }
    func write(handle: NFSFileHandle, stateid: NFSStateID, offset: UInt64,
               stability: NFSWriteStability, data: Data) async throws -> NFSWriteResult { throw NFSError.readOnly }
    func commit(handle: NFSFileHandle, offset: UInt64, count: UInt64) async throws -> UInt64 { 0 }

    func lock(handle: NFSFileHandle, type: NFSLockType, range: NFSLockRange,
              owner: NFSLockOwner, reclaim: Bool, stateid: NFSStateID) async throws -> NFSStateID {
        NFSStateID(seqid: 1, other: Data(repeating: 0xCC, count: 12))
    }
    func lockTest(handle: NFSFileHandle, type: NFSLockType, range: NFSLockRange,
                  owner: NFSLockOwner) async throws -> NFSLockTestResult {
        NFSLockTestResult(outcome: .granted)
    }
    func unlock(handle: NFSFileHandle, range: NFSLockRange, stateid: NFSStateID) async throws -> NFSStateID { stateid }
}

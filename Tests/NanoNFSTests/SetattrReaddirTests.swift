import Foundation
import Logging
import NIOCore
import Testing
@testable import NanoNFS

@Suite("SETATTR + READDIR")
struct SetattrReaddirTests {

    // MARK: - SETATTR decoder

    @Test("Decode size + mode patch")
    func decodeSizeMode() throws {
        let bitmap = AttrBitmap([.size, .mode])
        var attrVals = XDREncoder()
        attrVals.writeUInt64(2048)        // size
        attrVals.writeUInt32(0o755)       // mode

        var enc = XDREncoder()
        bitmap.encode(into: &enc)
        enc.writeVariableOpaque(Data(attrVals.buffer.readableBytesView))

        var dec = XDRDecoder(enc.buffer)
        let result = try decodeSetattrPatch(from: &dec)
        #expect(result.patch.size == 2048)
        #expect(result.patch.mode == 0o755)
        #expect(result.attrsSet.contains(.size))
        #expect(result.attrsSet.contains(.mode))
    }

    @Test("Read-only attribute in SETATTR is rejected with INVAL mapping")
    func setattrRejectReadonly() throws {
        let bitmap = AttrBitmap([.fileID])  // fileid is server-issued, read-only
        var attrVals = XDREncoder()
        attrVals.writeUInt64(123)
        var enc = XDREncoder()
        bitmap.encode(into: &enc)
        enc.writeVariableOpaque(Data(attrVals.buffer.readableBytesView))
        var dec = XDRDecoder(enc.buffer)
        #expect(throws: SetattrDecodeError.self) {
            _ = try decodeSetattrPatch(from: &dec)
        }
    }

    @Test("Owner string parsing accepts numeric@domain")
    func setattrOwner() throws {
        let bitmap = AttrBitmap([.owner])
        var vals = XDREncoder()
        vals.writeString("501@anything")
        var enc = XDREncoder()
        bitmap.encode(into: &enc)
        enc.writeVariableOpaque(Data(vals.buffer.readableBytesView))
        var dec = XDRDecoder(enc.buffer)
        let result = try decodeSetattrPatch(from: &dec)
        #expect(result.patch.uid == 501)
    }

    @Test("Owner string with non-numeric prefix is silently skipped")
    func setattrOwnerInvalid() throws {
        // macOS NFS clients with idmapd active send "username@domain" rather
        // than "<uid>@domain". Rejecting the whole CREATE/SETATTR for an
        // attr we cannot interpret breaks Finder. We instead skip that
        // single attr and continue with the rest of the patch — see
        // SetattrDecoder.swift comments.
        let bitmap = AttrBitmap([.mode, .owner])
        var vals = XDREncoder()
        vals.writeUInt32(0o644)
        vals.writeString("alice@example.com")
        var enc = XDREncoder()
        bitmap.encode(into: &enc)
        enc.writeVariableOpaque(Data(vals.buffer.readableBytesView))
        var dec = XDRDecoder(enc.buffer)
        let result = try decodeSetattrPatch(from: &dec)
        #expect(result.patch.mode == 0o644)
        #expect(result.patch.uid == nil)
        #expect(!result.attrsSet.contains(.owner))
        #expect(result.attrsSet.contains(.mode))
    }

    @Test("Time set with SET_TO_SERVER_TIME does not consume nfstime4")
    func setattrTimeServer() throws {
        let bitmap = AttrBitmap([.timeModifySet])
        var vals = XDREncoder()
        vals.writeUInt32(0)  // SET_TO_SERVER_TIME
        var enc = XDREncoder()
        bitmap.encode(into: &enc)
        enc.writeVariableOpaque(Data(vals.buffer.readableBytesView))
        var dec = XDRDecoder(enc.buffer)
        let result = try decodeSetattrPatch(from: &dec)
        #expect(result.patch.mtime != nil)
    }

    @Test("Time set with SET_TO_CLIENT_TIME consumes nfstime4")
    func setattrTimeClient() throws {
        let bitmap = AttrBitmap([.timeModifySet])
        var vals = XDREncoder()
        vals.writeUInt32(1)        // SET_TO_CLIENT_TIME
        vals.writeInt64(1_700_000_000)
        vals.writeUInt32(500)
        var enc = XDREncoder()
        bitmap.encode(into: &enc)
        enc.writeVariableOpaque(Data(vals.buffer.readableBytesView))
        var dec = XDRDecoder(enc.buffer)
        let result = try decodeSetattrPatch(from: &dec)
        #expect(result.patch.mtime?.seconds == 1_700_000_000)
        #expect(result.patch.mtime?.nseconds == 500)
    }

    // MARK: - READDIR

    @Test("READDIR encodes entries with bool-discriminated linked list")
    func readdirEntries() async throws {
        let server = ReaddirServer()
        let dispatcher = CompoundDispatcher(server: server, logger: Logger(label: "test"))

        var c = XDREncoder()
        c.writeString("")
        c.writeUInt32(0)
        c.writeUInt32(2)
        c.writeUInt32(NFSOp.putrootfh.rawValue)
        c.writeUInt32(NFSOp.readdir.rawValue)
        // READDIR4args
        c.writeUInt64(0)                    // cookie
        c.writeUInt64(0)                    // cookieverf
        c.writeUInt32(8192)                 // dircount
        c.writeUInt32(8192)                 // maxcount
        AttrBitmap([.type, .size]).encode(into: &c)

        let out = await dispatcher.dispatch(args: c.buffer)
        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        _ = try dec.readString()
        #expect(try dec.readUInt32() == 2)
        // PUTROOTFH
        _ = try dec.readUInt32()
        _ = try dec.readUInt32()
        // READDIR
        #expect(try dec.readUInt32() == NFSOp.readdir.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)

        // verifier
        let verifier = try dec.readUInt64()
        #expect(verifier == 7777)

        // Iterate entries; expect "alpha" then "beta", then "no more entries", then eof=true.
        #expect(try dec.readBool() == true)
        #expect(try dec.readUInt64() == 1)         // fileid as cookie
        #expect(try dec.readString() == "alpha")
        let mask1 = try AttrBitmap.decode(from: &dec)
        #expect(mask1.contains(.type))
        #expect(mask1.contains(.size))
        let v1 = try dec.readVariableOpaqueData()
        var v1d = XDRDecoder(ByteBuffer(bytes: v1))
        #expect(try v1d.readUInt32() == NFSObjectType.regularFile.rawValue)
        #expect(try v1d.readUInt64() == 100)

        #expect(try dec.readBool() == true)
        #expect(try dec.readUInt64() == 2)
        #expect(try dec.readString() == "beta")
        _ = try AttrBitmap.decode(from: &dec)
        _ = try dec.readVariableOpaqueData()

        #expect(try dec.readBool() == false)        // no more entries
        #expect(try dec.readBool() == true)         // eof
    }
}

// MARK: - Test fixtures

actor ReaddirServer: NFSServer {
    let rootFh = NFSFileHandle(Data([0x77]))

    func root() async throws -> NFSFileHandle { rootFh }
    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess { mask }
    func getattr(handle: NFSFileHandle) async throws -> NFSStat { throw NFSError.notSupported }
    func setattr(handle: NFSFileHandle, stateid: NFSStateID?, patch: NFSAttributesPatch) async throws -> NFSStat {
        throw NFSError.notSupported
    }
    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle {
        throw NFSError.noEntry
    }
    func lookupParent(of handle: NFSFileHandle) async throws -> NFSFileHandle { rootFh }
    func readdir(handle: NFSFileHandle, cookie: UInt64, cookieVerifier: UInt64,
                 maxEntries: Int) async throws -> NFSDirList {
        let entries = [
            NFSDirEntry(fileid: 1, name: "alpha", attrs: NFSStat(
                type: .regularFile, mode: 0o644, nlink: 1, uid: 0, gid: 0,
                size: 100, used: 100, fileid: 1,
                atime: NFSTime(seconds: 0, nseconds: 0),
                mtime: NFSTime(seconds: 0, nseconds: 0),
                ctime: NFSTime(seconds: 0, nseconds: 0))),
            NFSDirEntry(fileid: 2, name: "beta", attrs: NFSStat(
                type: .regularFile, mode: 0o644, nlink: 1, uid: 0, gid: 0,
                size: 200, used: 200, fileid: 2,
                atime: NFSTime(seconds: 0, nseconds: 0),
                mtime: NFSTime(seconds: 0, nseconds: 0),
                ctime: NFSTime(seconds: 0, nseconds: 0))),
        ]
        return NFSDirList(entries: entries, nextCookie: nil, verifier: 7777, eof: true)
    }
    func create(parent: NFSFileHandle, name: String, type: NFSObjectType,
                attrs: NFSAttributesPatch) async throws -> NFSFileHandle { throw NFSError.notSupported }
    func remove(parent: NFSFileHandle, name: String) async throws { throw NFSError.notSupported }
    func rename(srcParent: NFSFileHandle, srcName: String,
                dstParent: NFSFileHandle, dstName: String) async throws { throw NFSError.notSupported }
    func link(target: NFSFileHandle, parent: NFSFileHandle, name: String) async throws {
        throw NFSError.notSupported
    }
    func readlink(handle: NFSFileHandle) async throws -> String { throw NFSError.notSupported }
    func open(parent: NFSFileHandle, name: String, share: NFSShareAccess, deny: NFSShareDeny,
              owner: NFSOpenOwner, wantDelegation: NFSDelegationHint,
              create: NFSCreateMode) async throws -> (handle: NFSFileHandle, result: NFSOpenResult) {
        throw NFSError.notSupported
    }
    func openConfirm(handle: NFSFileHandle, stateid: NFSStateID, seqid: UInt32) async throws -> NFSStateID {
        throw NFSError.notSupported
    }
    func openDowngrade(handle: NFSFileHandle, stateid: NFSStateID,
                       share: NFSShareAccess, deny: NFSShareDeny) async throws -> NFSStateID {
        throw NFSError.notSupported
    }
    func close(handle: NFSFileHandle, stateid: NFSStateID) async throws { throw NFSError.notSupported }
    func read(handle: NFSFileHandle, stateid: NFSStateID, offset: UInt64, count: Int) async throws -> NFSReadResult {
        throw NFSError.notSupported
    }
    func write(handle: NFSFileHandle, stateid: NFSStateID, offset: UInt64,
               stability: NFSWriteStability, data: Data) async throws -> NFSWriteResult {
        throw NFSError.notSupported
    }
    func commit(handle: NFSFileHandle, offset: UInt64, count: UInt64) async throws -> UInt64 {
        throw NFSError.notSupported
    }
    func lock(handle: NFSFileHandle, type: NFSLockType, range: NFSLockRange,
              owner: NFSLockOwner, reclaim: Bool, stateid: NFSStateID) async throws -> NFSStateID {
        throw NFSError.notSupported
    }
    func lockTest(handle: NFSFileHandle, type: NFSLockType, range: NFSLockRange,
                  owner: NFSLockOwner) async throws -> NFSLockTestResult {
        throw NFSError.notSupported
    }
    func unlock(handle: NFSFileHandle, range: NFSLockRange, stateid: NFSStateID) async throws -> NFSStateID {
        throw NFSError.notSupported
    }
}

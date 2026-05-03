import Foundation
import Logging
import NIOCore
import Testing
@testable import NanoNFS

@Suite("FATTR4 + GETATTR (RFC 7530 §5, §16.18)")
struct FATTRTests {

    @Test("AttrBitmap round-trip preserves attribute set")
    func bitmapRoundTrip() throws {
        let attrs: [FATTR4] = [.type, .size, .mode, .timeModify, .mountedOnFileID]
        let bitmap = AttrBitmap(attrs)
        var enc = XDREncoder()
        bitmap.encode(into: &enc)

        var dec = XDRDecoder(enc.buffer)
        let parsed = try AttrBitmap.decode(from: &dec)
        for a in attrs { #expect(parsed.contains(a)) }
        #expect(!parsed.contains(.uniqueHandles))
        #expect(parsed == bitmap)
    }

    @Test("Iteration order is increasing attribute number")
    func iterationOrder() {
        let bitmap = AttrBitmap([.timeModify, .type, .mode, .size])
        var seen: [FATTR4] = []
        bitmap.iterateInOrder { seen.append($0) }
        #expect(seen == [.type, .size, .mode, .timeModify])
    }

    @Test("encodeFattr4 emits exactly the requested-and-supported bits")
    func emittedMask() {
        let stat = sampleStat()
        let request = AttrBitmap([.type, .size, .mode, .acl /* unsupported */])
        let (mask, _) = encodeFattr4(stat: stat,
                                     fileHandle: NFSFileHandle(Data([0x42])),
                                     request: request)
        // ACL is in supported = false → must be omitted from response mask.
        #expect(mask.contains(.type))
        #expect(mask.contains(.size))
        #expect(mask.contains(.mode))
        #expect(!mask.contains(.acl))
    }

    @Test("Specific attribute values land at the right wire offsets")
    func valueLayout() throws {
        let stat = sampleStat()
        let request = AttrBitmap([.type, .size, .mode])
        let (_, attrVals) = encodeFattr4(stat: stat,
                                         fileHandle: NFSFileHandle(Data([0xAB])),
                                         request: request)
        var dec = XDRDecoder(attrVals)
        // Order on wire: TYPE (1), SIZE (4), MODE (33).
        #expect(try dec.readUInt32() == NFSObjectType.regularFile.rawValue)
        #expect(try dec.readUInt64() == 12345)
        #expect(try dec.readUInt32() == 0o644)
        #expect(dec.bytesRemaining == 0)
    }

    @Test("GETATTR result is fattr4 (bitmap + variable-opaque attr_vals)")
    func getattrFraming() throws {
        let stat = sampleStat()
        let body = encodeGetattrResult(stat: stat,
                                       fileHandle: NFSFileHandle(Data([0x01])),
                                       request: AttrBitmap([.type, .size]))
        var dec = XDRDecoder(body)
        let mask = try AttrBitmap.decode(from: &dec)
        #expect(mask.contains(.type) && mask.contains(.size))
        let vals = try dec.readVariableOpaqueData()
        // 4-byte type + 8-byte size = 12 bytes
        #expect(vals.count == 12)
    }

    private func sampleStat() -> NFSStat {
        NFSStat(
            type: .regularFile,
            mode: 0o644,
            nlink: 1,
            uid: 501,
            gid: 20,
            size: 12345,
            used: 16384,
            fileid: 999,
            atime: NFSTime(seconds: 1, nseconds: 2),
            mtime: NFSTime(seconds: 3, nseconds: 4),
            ctime: NFSTime(seconds: 5, nseconds: 6)
        )
    }
}

@Suite("SETCLIENTID + RENEW")
struct ClientRegistryTests {

    @Test("SETCLIENTID then SETCLIENTID_CONFIRM with matching verifier succeeds")
    func confirmHappyPath() async {
        let r = ClientRegistry()
        let issued = await r.setclientid(verifier: 1, ownerName: Data([0xAA]),
                                         callbackProgram: 0x4000_0001,
                                         callbackAddr: "tcp/127.0.0.1.0.0")
        let outcome = await r.setclientidConfirm(clientid: issued.clientid,
                                                 confirmVerifier: issued.confirmVerifier)
        #expect(outcome == .ok)
        #expect(await r.isConfirmed(issued.clientid))
    }

    @Test("CONFIRM with wrong verifier reports STALE_CLIENTID")
    func confirmWrongVerifier() async {
        let r = ClientRegistry()
        let issued = await r.setclientid(verifier: 1, ownerName: Data([0xAA]),
                                         callbackProgram: 0, callbackAddr: "")
        let outcome = await r.setclientidConfirm(clientid: issued.clientid,
                                                 confirmVerifier: ~issued.confirmVerifier)
        #expect(outcome == .staleClientid)
    }

    @Test("RENEW on unknown clientid is stale")
    func renewStale() async {
        let r = ClientRegistry()
        let outcome = await r.renew(clientid: 9999, leaseSeconds: 60)
        #expect(outcome == .stale)
    }

    @Test("RENEW on confirmed clientid is OK")
    func renewOK() async {
        let r = ClientRegistry()
        let issued = await r.setclientid(verifier: 1, ownerName: Data([0xAA]),
                                         callbackProgram: 0, callbackAddr: "")
        _ = await r.setclientidConfirm(clientid: issued.clientid,
                                       confirmVerifier: issued.confirmVerifier)
        let outcome = await r.renew(clientid: issued.clientid, leaseSeconds: 60)
        #expect(outcome == .ok)
    }
}

@Suite("Dispatcher: GETATTR + SETCLIENTID")
struct DispatcherStatefulTests {

    @Test("PUTROOTFH; GETATTR(TYPE,SIZE) round-trip")
    func putRootGetattr() async throws {
        let server = StatGivingServer(stat: NFSStat(
            type: .directory, mode: 0o755, nlink: 2,
            uid: 0, gid: 0, size: 4096, used: 4096, fileid: 1,
            atime: .now(), mtime: .now(), ctime: .now()
        ))
        let dispatcher = CompoundDispatcher(server: server, logger: Logger(label: "test"))

        var compound = XDREncoder()
        compound.writeString("")
        compound.writeUInt32(0)
        compound.writeUInt32(2)
        compound.writeUInt32(NFSOp.putrootfh.rawValue)
        compound.writeUInt32(NFSOp.getattr.rawValue)
        let request = AttrBitmap([.type, .size])
        request.encode(into: &compound)

        let out = await dispatcher.dispatch(args: compound.buffer)
        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        _ = try dec.readString()
        #expect(try dec.readUInt32() == 2)
        #expect(try dec.readUInt32() == NFSOp.putrootfh.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        #expect(try dec.readUInt32() == NFSOp.getattr.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        let mask = try AttrBitmap.decode(from: &dec)
        #expect(mask.contains(.type))
        #expect(mask.contains(.size))
        let vals = try dec.readVariableOpaqueData()
        var v = XDRDecoder(ByteBuffer(bytes: vals))
        #expect(try v.readUInt32() == NFSObjectType.directory.rawValue)
        #expect(try v.readUInt64() == 4096)
    }

    @Test("SETCLIENTID then SETCLIENTID_CONFIRM in one COMPOUND")
    func setclientidCompound() async throws {
        let dispatcher = CompoundDispatcher(server: MockServer(), logger: Logger(label: "test"))

        var c1 = XDREncoder()
        c1.writeString("")
        c1.writeUInt32(0)
        c1.writeUInt32(1)
        c1.writeUInt32(NFSOp.setclientid.rawValue)
        c1.writeUInt64(0xCAFEBABE)             // verifier
        c1.writeVariableOpaque(Data([0x01]))   // owner name
        c1.writeUInt32(0x4000_0001)            // cb program
        c1.writeString("tcp")                  // cb netid
        c1.writeString("127.0.0.1.0.0")        // cb addr
        c1.writeUInt32(0)                      // callback_ident

        let r1 = await dispatcher.dispatch(args: c1.buffer)
        var d1 = XDRDecoder(r1)
        #expect(try d1.readUInt32() == NFSStatus.ok.rawValue)
        _ = try d1.readString()
        #expect(try d1.readUInt32() == 1)
        #expect(try d1.readUInt32() == NFSOp.setclientid.rawValue)
        #expect(try d1.readUInt32() == NFSStatus.ok.rawValue)
        let clientid = try d1.readUInt64()
        let confirm  = try d1.readUInt64()

        // Now CONFIRM in a fresh COMPOUND.
        var c2 = XDREncoder()
        c2.writeString("")
        c2.writeUInt32(0)
        c2.writeUInt32(1)
        c2.writeUInt32(NFSOp.setclientidConfirm.rawValue)
        c2.writeUInt64(clientid)
        c2.writeUInt64(confirm)

        let r2 = await dispatcher.dispatch(args: c2.buffer)
        var d2 = XDRDecoder(r2)
        #expect(try d2.readUInt32() == NFSStatus.ok.rawValue)
        _ = try d2.readString()
        #expect(try d2.readUInt32() == 1)
        #expect(try d2.readUInt32() == NFSOp.setclientidConfirm.rawValue)
        #expect(try d2.readUInt32() == NFSStatus.ok.rawValue)
    }
}

// MARK: - Test helper server

actor StatGivingServer: NFSServer {
    let stat: NFSStat
    let rootFh = NFSFileHandle(Data([0x99]))

    init(stat: NFSStat) { self.stat = stat }

    func root() async throws -> NFSFileHandle { rootFh }
    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess { mask }
    func getattr(handle: NFSFileHandle) async throws -> NFSStat { stat }
    func setattr(handle: NFSFileHandle, stateid: NFSStateID?, patch: NFSAttributesPatch) async throws -> NFSStat { stat }
    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle { throw NFSError.noEntry }
    func lookupParent(of handle: NFSFileHandle) async throws -> NFSFileHandle { rootFh }
    func readdir(handle: NFSFileHandle, cookie: UInt64, cookieVerifier: UInt64,
                 maxEntries: Int) async throws -> NFSDirList { throw NFSError.notSupported }
    func create(parent: NFSFileHandle, name: String, type: NFSObjectType,
                attrs: NFSAttributesPatch) async throws -> NFSFileHandle { throw NFSError.notSupported }
    func remove(parent: NFSFileHandle, name: String) async throws { throw NFSError.notSupported }
    func rename(srcParent: NFSFileHandle, srcName: String,
                dstParent: NFSFileHandle, dstName: String) async throws { throw NFSError.notSupported }
    func link(target: NFSFileHandle, parent: NFSFileHandle, name: String) async throws { throw NFSError.notSupported }
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

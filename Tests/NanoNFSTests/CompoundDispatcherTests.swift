import Foundation
import Logging
import NIOCore
import Testing
@testable import NanoNFS

// MARK: - Test fixture

/// Tiny in-memory NFSServer used to exercise the COMPOUND dispatcher.
/// Only a few methods are usefully implemented; the rest throw `.notSupported`.
actor MockServer: NFSServer {
    let rootHandle = NFSFileHandle(Data([0x01]))
    let aHandle    = NFSFileHandle(Data([0x02, 0x0A]))
    let bHandle    = NFSFileHandle(Data([0x02, 0x0B]))

    func root() async throws -> NFSFileHandle { rootHandle }

    func access(handle: NFSFileHandle, mask: NFSAccess) async throws -> NFSAccess {
        // Grant exactly what was asked — useful for verifying mask round-trip.
        return mask
    }

    func getattr(handle: NFSFileHandle) async throws -> NFSStat { throw NFSError.notSupported }
    func setattr(handle: NFSFileHandle, stateid: NFSStateID?, patch: NFSAttributesPatch) async throws -> NFSStat {
        throw NFSError.notSupported
    }

    func lookup(parent: NFSFileHandle, name: String) async throws -> NFSFileHandle {
        guard parent == rootHandle else { throw NFSError.noEntry }
        switch name {
        case "a": return aHandle
        case "b": return bHandle
        default:  throw NFSError.noEntry
        }
    }

    func lookupParent(of handle: NFSFileHandle) async throws -> NFSFileHandle {
        if handle == aHandle || handle == bHandle { return rootHandle }
        throw NFSError.noEntry
    }

    func readdir(handle: NFSFileHandle, cookie: UInt64, cookieVerifier: UInt64,
                 maxEntries: Int) async throws -> NFSDirList {
        throw NFSError.notSupported
    }

    func create(parent: NFSFileHandle, name: String, type: NFSObjectType,
                attrs: NFSAttributesPatch) async throws -> NFSFileHandle {
        throw NFSError.notSupported
    }
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

// MARK: - Helpers to encode COMPOUND4args

private func makeCompoundArgs(tag: String,
                              minorversion: UInt32 = 0,
                              ops: [(opcode: NFSOp, payload: ByteBuffer)]) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeString(tag)
    enc.writeUInt32(minorversion)
    enc.writeUInt32(UInt32(ops.count))
    for (op, payload) in ops {
        enc.writeUInt32(op.rawValue)
        var p = payload
        enc.buffer.writeBuffer(&p)
    }
    return enc.buffer
}

private func opPayloadEmpty() -> ByteBuffer { ByteBuffer() }

private func opPayloadString(_ s: String) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeString(s)
    return enc.buffer
}

private func opPayloadAccessMask(_ mask: UInt32) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeUInt32(mask)
    return enc.buffer
}

private func opPayloadFH(_ fh: NFSFileHandle) -> ByteBuffer {
    var enc = XDREncoder()
    enc.writeVariableOpaque(fh.bytes)
    return enc.buffer
}

// MARK: - Decoded view of the response

private struct DecodedCompoundResponse {
    var status: NFSStatus
    var tag: String
    var ops: [DecodedOp]

    struct DecodedOp {
        var opcode: UInt32
        var status: NFSStatus
        /// Raw remaining bytes of the per-op result.
        var body: ByteBuffer
    }

    static func decode(_ buffer: ByteBuffer, opSizes: [Int]) throws -> DecodedCompoundResponse {
        var dec = XDRDecoder(buffer)
        let status = NFSStatus(rawValue: try dec.readUInt32())!
        let tag = try dec.readString()
        let n = try dec.readUInt32()
        var ops: [DecodedOp] = []
        for i in 0..<Int(n) {
            let opcode = try dec.readUInt32()
            let opStatus = NFSStatus(rawValue: try dec.readUInt32())!
            let bodyLen = i < opSizes.count ? opSizes[i] : 0
            let body = try dec.readFixedOpaque(count: bodyLen)
            ops.append(DecodedOp(opcode: opcode, status: opStatus, body: body))
        }
        return DecodedCompoundResponse(status: status, tag: tag, ops: ops)
    }
}

// MARK: - Tests

@Suite("COMPOUND dispatcher (RFC 7530 §16.2)")
struct CompoundDispatcherTests {

    private func makeDispatcher() -> CompoundDispatcher {
        CompoundDispatcher(server: MockServer(),
                           logger: Logger(label: "test"))
    }

    @Test("PUTROOTFH + GETFH returns root fh")
    func putRootGetFH() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "t1", ops: [
            (.putrootfh, opPayloadEmpty()),
            (.getfh,     opPayloadEmpty()),
        ])
        let out = await dispatcher.dispatch(args: args)

        // Skip overall status, tag, count.
        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        #expect(try dec.readString() == "t1")
        #expect(try dec.readUInt32() == 2)

        // op[0] = PUTROOTFH, status=OK, no body
        #expect(try dec.readUInt32() == NFSOp.putrootfh.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)

        // op[1] = GETFH, status=OK, body = variable-opaque(rootfh)
        #expect(try dec.readUInt32() == NFSOp.getfh.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        let fhBytes = try dec.readVariableOpaqueData()
        #expect(Array(fhBytes) == [0x01])
        _ = out
    }

    @Test("PUTFH + GETFH echoes the supplied handle")
    func putFhGetFH() async throws {
        let dispatcher = makeDispatcher()
        let custom = NFSFileHandle(Data([0xDE, 0xAD]))
        let args = makeCompoundArgs(tag: "", ops: [
            (.putfh, opPayloadFH(custom)),
            (.getfh, opPayloadEmpty()),
        ])
        let out = await dispatcher.dispatch(args: args)

        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        _ = try dec.readString()
        #expect(try dec.readUInt32() == 2)
        _ = try dec.readUInt32(); _ = try dec.readUInt32() // PUTFH/OK
        _ = try dec.readUInt32(); _ = try dec.readUInt32() // GETFH/OK
        let fhBytes = try dec.readVariableOpaqueData()
        #expect(Array(fhBytes) == [0xDE, 0xAD])
    }

    @Test("LOOKUP advances current fh")
    func lookup() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "", ops: [
            (.putrootfh, opPayloadEmpty()),
            (.lookup,    opPayloadString("a")),
            (.getfh,     opPayloadEmpty()),
        ])
        let out = await dispatcher.dispatch(args: args)

        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        _ = try dec.readString()
        #expect(try dec.readUInt32() == 3)
        for _ in 0..<2 { _ = try dec.readUInt32(); _ = try dec.readUInt32() }
        _ = try dec.readUInt32(); _ = try dec.readUInt32()
        let fhBytes = try dec.readVariableOpaqueData()
        #expect(Array(fhBytes) == [0x02, 0x0A])
    }

    @Test("LOOKUP miss aborts COMPOUND with NOENT")
    func lookupMiss() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "", ops: [
            (.putrootfh, opPayloadEmpty()),
            (.lookup,    opPayloadString("does-not-exist")),
            (.getfh,     opPayloadEmpty()),  // must not run
        ])
        let out = await dispatcher.dispatch(args: args)

        var dec = XDRDecoder(out)
        // Overall status reflects the failing op (RFC 7530 §15.2).
        #expect(try dec.readUInt32() == NFSStatus.noent.rawValue)
        _ = try dec.readString()
        // resarray contains PUTROOTFH/OK + LOOKUP/NOENT — not GETFH.
        #expect(try dec.readUInt32() == 2)
        #expect(try dec.readUInt32() == NFSOp.putrootfh.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        #expect(try dec.readUInt32() == NFSOp.lookup.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.noent.rawValue)
    }

    @Test("SAVEFH / RESTOREFH stack")
    func saveRestoreFH() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "", ops: [
            (.putrootfh, opPayloadEmpty()),
            (.lookup,    opPayloadString("a")),
            (.savefh,    opPayloadEmpty()),
            (.putrootfh, opPayloadEmpty()),
            (.lookup,    opPayloadString("b")),
            (.restorefh, opPayloadEmpty()),
            (.getfh,     opPayloadEmpty()),
        ])
        let out = await dispatcher.dispatch(args: args)

        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        _ = try dec.readString()
        #expect(try dec.readUInt32() == 7)
        // skip first six ops' header (each: opcode + status + empty body)
        for _ in 0..<6 { _ = try dec.readUInt32(); _ = try dec.readUInt32() }
        // last op = GETFH
        _ = try dec.readUInt32()
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        let fhBytes = try dec.readVariableOpaqueData()
        // Should be aHandle (saved before /b lookup)
        #expect(Array(fhBytes) == [0x02, 0x0A])
    }

    @Test("RESTOREFH without prior SAVEFH errors with restorefh")
    func restoreWithoutSave() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "", ops: [
            (.restorefh, opPayloadEmpty()),
        ])
        let out = await dispatcher.dispatch(args: args)
        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.restorefh.rawValue)
    }

    @Test("ACCESS round-trips the mask")
    func access() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "", ops: [
            (.putrootfh, opPayloadEmpty()),
            (.access,    opPayloadAccessMask(0x3F)),
        ])
        let out = await dispatcher.dispatch(args: args)
        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        _ = try dec.readString()
        #expect(try dec.readUInt32() == 2)
        _ = try dec.readUInt32(); _ = try dec.readUInt32() // PUTROOTFH
        #expect(try dec.readUInt32() == NFSOp.access.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        #expect(try dec.readUInt32() == 0x3F) // supported
        #expect(try dec.readUInt32() == 0x3F) // access (mock grants exactly the mask)
    }

    @Test("Unimplemented op returns NFS4ERR_NOTSUPP")
    func notImplemented() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "", ops: [
            // OPENATTR is intentionally not supported (RFC 7530 §16.19, but
            // nanonfs scope excludes named-attributes per README).
            (.openattr, opPayloadEmpty()),
        ])
        let out = await dispatcher.dispatch(args: args)
        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.notsupp.rawValue)
    }

    @Test("Minorversion != 0 yields MINOR_VERS_MISMATCH")
    func minorVersionMismatch() async throws {
        let dispatcher = makeDispatcher()
        let args = makeCompoundArgs(tag: "", minorversion: 1, ops: [])
        let out = await dispatcher.dispatch(args: args)
        var dec = XDRDecoder(out)
        #expect(try dec.readUInt32() == NFSStatus.minorVersMismatch.rawValue)
    }
}

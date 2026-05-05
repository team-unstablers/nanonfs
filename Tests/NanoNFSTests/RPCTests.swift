import Foundation
import NIOCore
import Testing
@testable import NanoNFS

@Suite("RPC framing & messages (RFC 5531)")
struct RPCTests {

    // MARK: record marking

    @Test("Last-fragment header has high bit set")
    func recordMarkBit() {
        var buf = ByteBuffer()
        buf.writeBytes([0xAA, 0xBB])
        let wrapped = rpcWrapSingleFragment(buf)
        let bytes = Array(wrapped.readableBytesView)
        // Header: 0x8000_0002 (last + length=2), big-endian
        #expect(bytes[0] == 0x80)
        #expect(bytes[1] == 0x00)
        #expect(bytes[2] == 0x00)
        #expect(bytes[3] == 0x02)
        #expect(bytes[4] == 0xAA)
        #expect(bytes[5] == 0xBB)
    }

    @Test("Single-fragment decode")
    func recordMarkSingle() {
        var dec = RPCRecordMarkingDecoder()
        var input = rpcWrapSingleFragment({
            var b = ByteBuffer(); b.writeBytes([1, 2, 3, 4]); return b
        }())
        let step = dec.step(consuming: &input)
        switch step {
        case .message(let body):
            #expect(Array(body.readableBytesView) == [1, 2, 3, 4])
            #expect(input.readableBytes == 0)
        default:
            Issue.record("expected .message, got \(step)")
        }
    }

    @Test("Multi-fragment decode reassembles in order")
    func recordMarkMulti() {
        var dec = RPCRecordMarkingDecoder()

        // Fragment 1 (not last): 2 bytes
        var f1 = ByteBuffer()
        f1.writeInteger(UInt32(2), endianness: .big, as: UInt32.self) // no flag
        f1.writeBytes([0xAA, 0xBB])

        // Fragment 2 (last): 3 bytes
        var f2 = ByteBuffer()
        let last: UInt32 = 0x8000_0000 | 3
        f2.writeInteger(last, endianness: .big, as: UInt32.self)
        f2.writeBytes([0xCC, 0xDD, 0xEE])

        var input = ByteBuffer()
        input.writeBuffer(&f1)
        input.writeBuffer(&f2)

        switch dec.step(consuming: &input) {
        case .needMore: break
        default: Issue.record("first step should be needMore")
        }
        switch dec.step(consuming: &input) {
        case .message(let body):
            #expect(Array(body.readableBytesView) == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        default:
            Issue.record("second step should be .message")
        }
    }

    @Test("Truncated fragment yields needMore")
    func recordMarkTruncated() {
        var dec = RPCRecordMarkingDecoder()
        var input = ByteBuffer()
        input.writeInteger(UInt32(0x8000_0010), endianness: .big, as: UInt32.self) // claims 16 bytes
        input.writeBytes([0xAA, 0xBB]) // only 2 present
        switch dec.step(consuming: &input) {
        case .needMore:
            // The decoder must not have consumed the header — we want the
            // caller to be able to feed more bytes and try again.
            #expect(input.readableBytes == 6)
        default:
            Issue.record("expected needMore")
        }
    }

    @Test("Oversized fragment is rejected")
    func recordMarkOversize() {
        var dec = RPCRecordMarkingDecoder(maxFragmentLength: 100)
        var input = ByteBuffer()
        input.writeInteger(UInt32(0x8000_0000 | 200), endianness: .big, as: UInt32.self)
        switch dec.step(consuming: &input) {
        case .error(.fragmentTooLarge(declared: 200, limit: 100)): break
        default: Issue.record("expected fragmentTooLarge")
        }
    }

    // MARK: rpc_msg

    @Test("Decode a well-formed CALL")
    func decodeCall() throws {
        let cred = RPCOpaqueAuth(flavor: RPCAuthFlavor.sys.rawValue,
                                 body: encodeAuthSysBody(AuthSysCredential(
                                    stamp: 1, machineName: "host", uid: 501, gid: 20, gids: [12, 80])))
        var args = ByteBuffer()
        args.writeBytes([0xAB, 0xCD]) // 2-byte stand-in for COMPOUND args; not aligned but OK because args are opaque to RPC layer

        let msg = encodeRpcCall(
            xid: 0x1111_2222,
            program: NFSProgram.number,
            version: NFSProgram.version,
            procedure: NFSProcedure.compound.rawValue,
            credential: cred,
            args: args
        )

        let (hdr, _) = try RPCCallHeader.decode(from: msg)
        #expect(hdr.xid == 0x1111_2222)
        #expect(hdr.rpcversion == 2)
        #expect(hdr.program == NFSProgram.number)
        #expect(hdr.version == NFSProgram.version)
        #expect(hdr.procedure == NFSProcedure.compound.rawValue)
        #expect(hdr.credential.flavor == RPCAuthFlavor.sys.rawValue)
    }

    @Test("Decode rejects non-CALL messages")
    func decodeRejectReply() {
        var enc = XDREncoder()
        enc.writeUInt32(0)
        enc.writeUInt32(RPCMessageType.reply.rawValue) // wrong direction
        #expect(throws: RPCDecodeError.self) {
            _ = try RPCCallHeader.decode(from: enc.buffer)
        }
    }

    @Test("Decode rejects wrong RPC version")
    func decodeRejectsVersion() {
        var enc = XDREncoder()
        enc.writeUInt32(0)
        enc.writeUInt32(RPCMessageType.call.rawValue)
        enc.writeUInt32(99) // not 2
        #expect(throws: RPCDecodeError.self) {
            _ = try RPCCallHeader.decode(from: enc.buffer)
        }
    }

    @Test("AUTH_SYS body round-trip")
    func authSysRoundTrip() throws {
        let cred = AuthSysCredential(
            stamp: 0xCAFEBABE,
            machineName: "darwin-loopback",
            uid: 501,
            gid: 20,
            gids: [12, 80, 33]
        )
        let body = encodeAuthSysBody(cred)
        let parsed = try AuthSysCredential.decode(from: body)
        #expect(parsed == cred)
    }

    @Test("AUTH_SYS rejects > 16 aux gids")
    func authSysAuxLimit() {
        var enc = XDREncoder()
        enc.writeUInt32(0)         // stamp
        enc.writeString("h")
        enc.writeUInt32(0)         // uid
        enc.writeUInt32(0)         // gid
        enc.writeUInt32(17)        // claims 17 aux gids
        for _ in 0..<17 { enc.writeUInt32(0) }
        let body = Data(enc.buffer.readableBytesView)
        #expect(throws: XDRError.self) {
            _ = try AuthSysCredential.decode(from: body)
        }
    }

    // MARK: encode

    @Test("Accepted SUCCESS reply layout")
    func encodeAccepted() throws {
        var results = ByteBuffer()
        results.writeBytes([0xDE, 0xAD, 0xBE, 0xEF])
        let reply = rpcEncodeAcceptedReply(xid: 42, results: results)

        var dec = XDRDecoder(reply)
        // Record mark: last-fragment flag + body length.
        let mark = try dec.readUInt32()
        #expect((mark & RPCRecordMarking.lastFragmentFlag) != 0)
        #expect((mark & RPCRecordMarking.lengthMask) == UInt32(reply.readableBytes - 4))
        #expect(try dec.readUInt32() == 42)
        #expect(try dec.readUInt32() == RPCMessageType.reply.rawValue)
        #expect(try dec.readUInt32() == RPCReplyStatus.msgAccepted.rawValue)
        // verifier
        #expect(try dec.readUInt32() == RPCAuthFlavor.none.rawValue)
        let body = try dec.readVariableOpaqueData()
        #expect(body.isEmpty)
        // accept_stat
        #expect(try dec.readUInt32() == RPCAcceptStatus.success.rawValue)
        // results
        let tail = try dec.readFixedOpaqueData(count: 4)
        #expect(Array(tail) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test("Auth error reply layout")
    func encodeAuthError() throws {
        let reply = rpcEncodeAuthError(xid: 7, status: .tooweak)
        var dec = XDRDecoder(reply)
        let mark = try dec.readUInt32()
        #expect((mark & RPCRecordMarking.lastFragmentFlag) != 0)
        #expect((mark & RPCRecordMarking.lengthMask) == UInt32(reply.readableBytes - 4))
        #expect(try dec.readUInt32() == 7)
        #expect(try dec.readUInt32() == RPCMessageType.reply.rawValue)
        #expect(try dec.readUInt32() == RPCReplyStatus.msgDenied.rawValue)
        #expect(try dec.readUInt32() == RPCRejectStatus.authError.rawValue)
        #expect(try dec.readUInt32() == RPCAuthStatus.tooweak.rawValue)
    }
}

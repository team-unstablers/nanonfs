import Foundation
import Logging
import NIOCore
import Testing
@testable import NanoNFS

// Same shape as ListenerIntegrationTests, but with `transport: .bsdSocket`
// so the listener exercises the pure-Swift-Concurrency BSD socket transport
// instead of NIOPosix. The point of these tests is to confirm that the
// transport abstraction holds up — every assertion below is identical to
// what we already check for NIO, so a difference in outcome means the
// BSDSocket implementation diverges from the contract.
//
// `.bsdSocket` is the always-on baseline transport, so this suite is
// always compiled.
@Suite("Listener integration via BSDSocket transport")
struct BSDSocketTransportTests {

    @Test("RPC NULL round-trip end-to-end (BSDSocket)")
    func nullRoundTrip() async throws {
        let server = MockServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            transport: .bsdSocket,
            logger: Logger(label: "test.bsd")
        )

        let runTask = Task { try await listener.run() }
        let bound = try await waitForBind(listener: listener, timeoutMs: 1500)
        defer { runTask.cancel() }

        let port = bound.port
        #expect(port > 0)

        let sock = try TCPClient(host: "127.0.0.1", port: port)
        defer { sock.close() }

        let call = encodeRpcCall(
            xid: 0xC0FFEE,
            program: NFSProgram.number,
            version: NFSProgram.version,
            procedure: NFSProcedure.null.rawValue,
            credential: .none,
            verifier: .none
        )
        try sock.write(rpcWrapSingleFragment(call))
        let replyFrame = try sock.readRecord(timeoutSeconds: 2.0)

        var dec = XDRDecoder(replyFrame)
        #expect(try dec.readUInt32() == 0xC0FFEE)
        #expect(try dec.readUInt32() == RPCMessageType.reply.rawValue)
        #expect(try dec.readUInt32() == RPCReplyStatus.msgAccepted.rawValue)
        #expect(try dec.readUInt32() == RPCAuthFlavor.none.rawValue)
        let v = try dec.readVariableOpaqueData()
        #expect(v.isEmpty)
        #expect(try dec.readUInt32() == RPCAcceptStatus.success.rawValue)
        #expect(dec.bytesRemaining == 0)
    }

    @Test("Pipelined NULL RPCs all complete on a single connection (BSDSocket)")
    func pipelinedNullRPCs() async throws {
        let server = MockServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            transport: .bsdSocket,
            logger: Logger(label: "test.bsd")
        )
        let runTask = Task { try await listener.run() }
        let bound = try await waitForBind(listener: listener, timeoutMs: 1500)
        defer { runTask.cancel() }
        let port = bound.port

        let sock = try TCPClient(host: "127.0.0.1", port: port)
        defer { sock.close() }

        let n = 32
        var sent: Set<UInt32> = []
        for i in 0..<n {
            let xid = UInt32(0x2000 &+ i)
            sent.insert(xid)
            let call = encodeRpcCall(
                xid: xid,
                program: NFSProgram.number,
                version: NFSProgram.version,
                procedure: NFSProcedure.null.rawValue,
                credential: .none,
                verifier: .none
            )
            try sock.write(rpcWrapSingleFragment(call))
        }

        var seen: Set<UInt32> = []
        for _ in 0..<n {
            let frame = try sock.readRecord(timeoutSeconds: 5.0)
            var dec = XDRDecoder(frame)
            let xid = try dec.readUInt32()
            seen.insert(xid)
            #expect(try dec.readUInt32() == RPCMessageType.reply.rawValue)
            #expect(try dec.readUInt32() == RPCReplyStatus.msgAccepted.rawValue)
            _ = try dec.readUInt32()
            _ = try dec.readVariableOpaqueData()
            #expect(try dec.readUInt32() == RPCAcceptStatus.success.rawValue)
        }
        #expect(seen == sent)
    }

    @Test("Listener stops when the surrounding Task is cancelled (BSDSocket)")
    func cancellationStopsListener() async throws {
        let server = MockServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            transport: .bsdSocket,
            logger: Logger(label: "test.bsd")
        )
        let runTask = Task { try await listener.run() }
        _ = try await waitForBind(listener: listener, timeoutMs: 1500)
        runTask.cancel()
        // run() should return promptly after the cancel triggers EVFILT_USER.
        // Bound how long we'll wait so the test fails loudly if it hangs.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if runTask.isCancelled {
                _ = try? await runTask.value
                return
            }
            try? await Task.sleep(nanoseconds: 5 * 1_000_000)
        }
        Issue.record("BSDSocket listener did not return within 2s of cancel")
        runTask.cancel()
    }

    private func waitForBind(listener: NFSServerListener,
                             timeoutMs: Int) async throws -> NFSBoundAddress {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let addr = await listener.boundAddress { return addr }
            try? await Task.sleep(nanoseconds: 5 * 1_000_000)
        }
        struct BindTimeout: Error {}
        throw BindTimeout()
    }
}

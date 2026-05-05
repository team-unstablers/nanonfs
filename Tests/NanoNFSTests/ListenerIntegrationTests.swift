import Foundation
import Logging
import NIOCore
import NIOPosix
import Testing
@testable import NanoNFS

@Suite("Listener integration over loopback TCP")
struct ListenerIntegrationTests {

    /// Spin up the listener bound to port 0 (kernel-chosen), connect a raw
    /// TCP client, send an RPC NULL call, and verify the reply is a
    /// well-formed accepted SUCCESS reply with empty body.
    @Test("RPC NULL round-trip end-to-end")
    func nullRoundTrip() async throws {
        let server = MockServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            logger: Logger(label: "test")
        )

        let runTask = Task { try await listener.run() }
        // Wait for bind to publish the chosen port.
        let bound = try await waitForBind(listener: listener, timeoutMs: 1500)
        defer {
            runTask.cancel()
        }

        let port = UInt16(bound.port ?? 0)
        #expect(port > 0)

        // Use a simple synchronous TCP socket from Foundation/POSIX rather
        // than spinning up a NIO client — the test only sends one tiny call.
        let sock = try TCPClient(host: "127.0.0.1", port: port)
        defer { sock.close() }

        // Build NULL call: AUTH_NONE creds + verifier, no args.
        let call = encodeRpcCall(
            xid: 0xDEAD,
            program: NFSProgram.number,
            version: NFSProgram.version,
            procedure: NFSProcedure.null.rawValue,
            credential: .none,
            verifier: .none
        )
        try sock.write(rpcWrapSingleFragment(call))
        let replyFrame = try sock.readRecord(timeoutSeconds: 2.0)

        var dec = XDRDecoder(replyFrame)
        #expect(try dec.readUInt32() == 0xDEAD)
        #expect(try dec.readUInt32() == RPCMessageType.reply.rawValue)
        #expect(try dec.readUInt32() == RPCReplyStatus.msgAccepted.rawValue)
        // verifier
        #expect(try dec.readUInt32() == RPCAuthFlavor.none.rawValue)
        let v = try dec.readVariableOpaqueData()
        #expect(v.isEmpty)
        // accept_stat
        #expect(try dec.readUInt32() == RPCAcceptStatus.success.rawValue)
        // No further bytes for NULL.
        #expect(dec.bytesRemaining == 0)
    }

    @Test("Wrong RPC program returns PROG_UNAVAIL")
    func wrongProgram() async throws {
        let server = MockServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            logger: Logger(label: "test")
        )
        let runTask = Task { try await listener.run() }
        let bound = try await waitForBind(listener: listener, timeoutMs: 1500)
        defer { runTask.cancel() }
        let port = UInt16(bound.port ?? 0)

        let sock = try TCPClient(host: "127.0.0.1", port: port)
        defer { sock.close() }

        let call = encodeRpcCall(
            xid: 1,
            program: 99_999, // not NFS
            version: 1,
            procedure: 0,
            credential: .none
        )
        try sock.write(rpcWrapSingleFragment(call))
        let frame = try sock.readRecord(timeoutSeconds: 2.0)
        var dec = XDRDecoder(frame)
        #expect(try dec.readUInt32() == 1)
        #expect(try dec.readUInt32() == RPCMessageType.reply.rawValue)
        #expect(try dec.readUInt32() == RPCReplyStatus.msgAccepted.rawValue)
        // verifier
        _ = try dec.readUInt32()
        _ = try dec.readVariableOpaqueData()
        // accept_stat
        #expect(try dec.readUInt32() == RPCAcceptStatus.progUnavail.rawValue)
    }

    @Test("COMPOUND PUTROOTFH+GETFH round-trip")
    func compoundPutRootGetFH() async throws {
        let server = MockServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            logger: Logger(label: "test")
        )
        let runTask = Task { try await listener.run() }
        let bound = try await waitForBind(listener: listener, timeoutMs: 1500)
        defer { runTask.cancel() }
        let port = UInt16(bound.port ?? 0)

        let sock = try TCPClient(host: "127.0.0.1", port: port)
        defer { sock.close() }

        // COMPOUND args: tag="t", minorvers=0, opcount=2, [PUTROOTFH, GETFH]
        var enc = XDREncoder()
        enc.writeString("t")
        enc.writeUInt32(0)
        enc.writeUInt32(2)
        enc.writeUInt32(NFSOp.putrootfh.rawValue)
        enc.writeUInt32(NFSOp.getfh.rawValue)
        let compoundArgs = enc.buffer

        let cred = RPCOpaqueAuth(
            flavor: RPCAuthFlavor.sys.rawValue,
            body: encodeAuthSysBody(AuthSysCredential(
                stamp: 0, machineName: "test", uid: 0, gid: 0, gids: []
            ))
        )
        let call = encodeRpcCall(
            xid: 0x42,
            program: NFSProgram.number,
            version: NFSProgram.version,
            procedure: NFSProcedure.compound.rawValue,
            credential: cred,
            args: compoundArgs
        )
        try sock.write(rpcWrapSingleFragment(call))

        let frame = try sock.readRecord(timeoutSeconds: 2.0)
        var dec = XDRDecoder(frame)
        #expect(try dec.readUInt32() == 0x42) // xid echo
        #expect(try dec.readUInt32() == RPCMessageType.reply.rawValue)
        #expect(try dec.readUInt32() == RPCReplyStatus.msgAccepted.rawValue)
        _ = try dec.readUInt32() // verifier flavor
        _ = try dec.readVariableOpaqueData()
        #expect(try dec.readUInt32() == RPCAcceptStatus.success.rawValue)

        // COMPOUND4res
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        #expect(try dec.readString() == "t")
        #expect(try dec.readUInt32() == 2)
        #expect(try dec.readUInt32() == NFSOp.putrootfh.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        #expect(try dec.readUInt32() == NFSOp.getfh.rawValue)
        #expect(try dec.readUInt32() == NFSStatus.ok.rawValue)
        let fhBytes = try dec.readVariableOpaqueData()
        #expect(Array(fhBytes) == [0x01]) // MockServer.rootHandle
    }

    /// Fires N NULL RPCs back-to-back on a single connection, then drains N
    /// replies. Verifies that the per-connection RPC pipelining path can
    /// accept multiple in-flight calls on the same TCP socket and replies to
    /// every one with a matching xid (RFC 5531 §9). Reply order is not
    /// asserted — replies may legally come back unordered.
    @Test("Pipelined NULL RPCs all complete on a single connection")
    func pipelinedNullRPCs() async throws {
        let server = MockServer()
        let listener = NFSServerListener(
            server: server,
            bind: .loopback(port: 0),
            logger: Logger(label: "test")
        )
        let runTask = Task { try await listener.run() }
        let bound = try await waitForBind(listener: listener, timeoutMs: 1500)
        defer { runTask.cancel() }
        let port = UInt16(bound.port ?? 0)

        let sock = try TCPClient(host: "127.0.0.1", port: port)
        defer { sock.close() }

        let n = 64
        var sent: Set<UInt32> = []
        for i in 0..<n {
            let xid = UInt32(0x1000 &+ i)
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
            _ = try dec.readUInt32()                  // verifier flavor
            _ = try dec.readVariableOpaqueData()      // verifier body
            #expect(try dec.readUInt32() == RPCAcceptStatus.success.rawValue)
        }
        #expect(seen == sent)
    }

    /// Polls listener.boundAddress until it is non-nil or the timeout fires.
    private func waitForBind(listener: NFSServerListener,
                             timeoutMs: Int) async throws -> SocketAddress {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let addr = await listener.boundAddress { return addr }
            try? await Task.sleep(nanoseconds: 5 * 1_000_000)
        }
        throw TimeoutError.bind
    }

    enum TimeoutError: Error {
        case bind
        case read
    }
}

// MARK: - Tiny synchronous TCP client (test-only)

final class TCPClient {
    private let fd: Int32

    init(host: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result < 0 {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    func close() {
        Darwin.close(fd)
    }

    func write(_ buffer: ByteBuffer) throws {
        let bytes = Array(buffer.readableBytesView)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { bp -> Int in
                Darwin.send(fd, bp.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if n <= 0 { throw POSIXError(.EIO) }
            offset += n
        }
    }

    /// Read one RPC record (4-byte header + body), reassembling fragments
    /// until last-fragment is observed.
    func readRecord(timeoutSeconds: Double) throws -> ByteBuffer {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var assembled = ByteBuffer()
        while true {
            let header = try readExactly(count: 4, deadline: deadline)
            let raw = UInt32(header[0]) << 24
                | UInt32(header[1]) << 16
                | UInt32(header[2]) << 8
                | UInt32(header[3])
            let last = (raw & 0x8000_0000) != 0
            let len = Int(raw & 0x7FFF_FFFF)
            if len > 0 {
                let body = try readExactly(count: len, deadline: deadline)
                assembled.writeBytes(body)
            }
            if last { return assembled }
        }
    }

    private func readExactly(count: Int, deadline: Date) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            if Date() > deadline { throw ListenerIntegrationTests.TimeoutError.read }
            let n = out.withUnsafeMutableBufferPointer { bp -> Int in
                Darwin.recv(fd, bp.baseAddress!.advanced(by: got), count - got, 0)
            }
            if n == 0 { throw POSIXError(.ECONNRESET) }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR {
                    // brief sleep to avoid busy loop
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                throw POSIXError(.EIO)
            }
            got += n
        }
        return out
    }
}

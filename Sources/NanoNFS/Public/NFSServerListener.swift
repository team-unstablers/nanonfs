import Foundation
import Logging
import NIOCore
import NIOPosix

/// Public entry point. Binds a TCP listener, decodes ONC RPC, and dispatches
/// NFSv4 COMPOUND ops to the user's `NFSServer`.
///
/// Lifecycle is service-style: `run()` returns when the surrounding `Task` is
/// cancelled (graceful shutdown).
public final class NFSServerListener: Sendable {
    private let server: any NFSServer
    private let bind: NFSBind
    private let logger: Logger
    private let providedEventLoopGroup: EventLoopGroup?
    private let boundAddressBox: BoundAddressBox

    public init(
        server: any NFSServer,
        bind: NFSBind = .loopback(),
        logger: Logger = Logger(label: "nanonfs"),
        eventLoopGroup: EventLoopGroup? = nil
    ) {
        self.server = server
        self.bind = bind
        self.logger = logger
        self.providedEventLoopGroup = eventLoopGroup
        self.boundAddressBox = BoundAddressBox()
    }

    /// Returns the address the channel ended up bound to, once `run()` has
    /// reached the post-bind stage. `nil` before then.
    public var boundAddress: SocketAddress? {
        get async { await boundAddressBox.value }
    }

    public func run() async throws {
        if bind.kind == .external {
            logger.warning("NFSServerListener bound to external interface \(bind.host):\(bind.port)")
        }

        let group: EventLoopGroup
        let ownsGroup: Bool
        if let provided = providedEventLoopGroup {
            group = provided
            ownsGroup = false
        } else {
            group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            ownsGroup = true
        }
        // We tear down via shutdownGracefully(): syncShutdownGracefully would
        // block the structured-concurrency thread, which the runtime forbids.
        let teardownGroup: @Sendable () async -> Void = {
            if ownsGroup {
                try? await group.shutdownGracefully()
            }
        }

        let dispatcher = CompoundDispatcher(server: server, logger: logger)
        let logger = logger
        let boundAddressBox = boundAddressBox

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .bind(host: bind.host, port: Int(bind.port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: ByteBuffer.self,
                            outboundType: ByteBuffer.self
                        )
                    )
                }
            }

        await boundAddressBox.set(serverChannel.channel.localAddress)
        logger.info("nanonfs listening on \(bind.host):\(bind.port)")

        do {
            try await withTaskCancellationHandler {
                try await serverChannel.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await child in inbound {
                            group.addTask {
                                await Self.serve(
                                    child: child,
                                    dispatcher: dispatcher,
                                    logger: logger
                                )
                            }
                        }
                    }
                }
            } onCancel: {
                // Closing the server channel will cause executeThenClose's
                // inbound iterator to terminate, ending the loop.
                serverChannel.channel.close(promise: nil)
            }
            await teardownGroup()
        } catch {
            await teardownGroup()
            throw error
        }
    }

    /// One TCP connection's worth of work: read framed RPC messages, dispatch,
    /// write framed replies. Returns when the peer half-closes or any I/O
    /// error happens (logged at info — peers go away mid-write all the time).
    private static func serve(
        child: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        dispatcher: CompoundDispatcher,
        logger: Logger
    ) async {
        do {
            try await child.executeThenClose { inbound, outbound in
                var decoder = RPCRecordMarkingDecoder()
                var pending = ByteBuffer()
                for try await chunk in inbound {
                    var c = chunk
                    pending.writeBuffer(&c)
                    pumping: while true {
                        switch decoder.step(consuming: &pending) {
                        case .needMore:
                            break pumping
                        case .message(let msg):
                            let reply = await handleSingleRpcMessage(
                                msg, dispatcher: dispatcher, logger: logger
                            )
                            try await outbound.write(rpcWrapSingleFragment(reply))
                        case .error(let e):
                            logger.warning("RPC framing error, dropping connection: \(e)")
                            return
                        }
                    }
                }
            }
        } catch {
            logger.info("connection ended: \(error)")
        }
    }
}

/// Holds the bound address; promoted out of the listener so the listener can
/// stay `Sendable` without manual `@unchecked` plumbing.
final actor BoundAddressBox {
    private(set) var value: SocketAddress?
    func set(_ address: SocketAddress?) { self.value = address }
}

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

    /// One TCP connection's worth of work: read framed RPC messages, dispatch
    /// them concurrently (up to `maxInFlightRequestsPerConnection`), and write
    /// framed replies. Each `rpcEncode*` already returns a buffer with the
    /// record-mark header in place, so the writer only does `outbound.write`.
    ///
    /// Three cooperating roles inside the per-connection task group:
    ///   • Reader (the outer body): consumes `inbound`, runs the record-mark
    ///     decoder, and spawns a dispatch task per assembled message.
    ///   • Dispatch tasks: run `handleSingleRpcMessage` and push the reply
    ///     buffer onto the writer queue. NFSv4 over TCP matches replies to
    ///     calls by xid (RFC 5531 §9), so unordered replies are spec-legal.
    ///   • Writer task: drains the queue and serialises calls to
    ///     `outbound.write` (NIOAsyncChannel is single-writer).
    ///
    /// In-flight count is bounded by `inFlightSemaphore` so a noisy client
    /// cannot make the server allocate one task per pipelined RPC without
    /// limit.
    private static func serve(
        child: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        dispatcher: CompoundDispatcher,
        logger: Logger
    ) async {
        do {
            try await child.executeThenClose { inbound, outbound in
                let semaphore = AsyncSemaphore(value: maxInFlightRequestsPerConnection)
                let (replies, replyCont) = AsyncStream<ByteBuffer>.makeStream(
                    bufferingPolicy: .unbounded
                )

                await withTaskGroup(of: Void.self) { group in
                    // Writer. Swallow write errors here — peers half-closing
                    // mid-write is routine and not worth propagating up.
                    group.addTask {
                        do {
                            for await reply in replies {
                                try await outbound.write(reply)
                            }
                        } catch {
                            logger.info("outbound write ended: \(error)")
                        }
                    }

                    // Reader + dispatch pool. The discarding inner group lets
                    // us await all in-flight dispatches before signalling the
                    // writer that no more replies are coming.
                    do {
                        try await withThrowingDiscardingTaskGroup { dispatchGroup in
                            var decoder = RPCRecordMarkingDecoder()
                            var pending = ByteBuffer()
                            readLoop: for try await chunk in inbound {
                                if pending.readableBytes == 0 {
                                    // Fast path: no carry-over from the previous
                                    // chunk, adopt the inbound buffer directly.
                                    pending = chunk
                                } else {
                                    var c = chunk
                                    pending.writeBuffer(&c)
                                }
                                pumping: while true {
                                    switch decoder.step(consuming: &pending) {
                                    case .needMore:
                                        break pumping
                                    case .message(let msg):
                                        await semaphore.acquire()
                                        dispatchGroup.addTask {
                                            let body = await handleSingleRpcMessage(
                                                msg,
                                                dispatcher: dispatcher,
                                                logger: logger
                                            )
                                            replyCont.yield(body)
                                            await semaphore.release()
                                        }
                                    case .error(let e):
                                        logger.warning("RPC framing error, dropping connection: \(e)")
                                        break readLoop
                                    }
                                }
                            }
                        }
                    } catch {
                        // Inbound errored or peer half-closed mid-stream;
                        // fall through to drain whatever the writer still has.
                        logger.info("inbound ended: \(error)")
                    }

                    // All dispatches awaited (discarding-group exit). Tell the
                    // writer no more replies are coming so it can finish.
                    replyCont.finish()
                }
            }
        } catch {
            logger.info("connection ended: \(error)")
        }
    }
}

/// Cap on how many RPC dispatches can be running for a single TCP
/// connection. macOS's nfsiod typically issues at most ~16 parallel RPCs,
/// so 64 leaves comfortable headroom without unbounded task allocation.
private let maxInFlightRequestsPerConnection: Int = 64

/// Counting semaphore implemented over `CheckedContinuation`. Used to cap
/// the dispatch fan-out per connection. Cancellation is deliberately not
/// modelled: the outer task group cancels children on connection teardown,
/// at which point the actor itself becomes unreachable.
final actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        precondition(value >= 0)
        self.available = value
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}

/// Holds the bound address; promoted out of the listener so the listener can
/// stay `Sendable` without manual `@unchecked` plumbing.
final actor BoundAddressBox {
    private(set) var value: SocketAddress?
    func set(_ address: SocketAddress?) { self.value = address }
}

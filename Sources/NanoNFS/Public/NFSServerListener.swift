import Foundation
import Logging
import NIOCore

/// Public entry point. Drives a `NFSTransportImplementation` to bind a TCP
/// listener and accept connections, then for each connection runs the
/// record-mark decoder + COMPOUND dispatcher.
///
/// Lifecycle is service-style: `run()` returns when the surrounding `Task` is
/// cancelled (graceful shutdown). The transport implementation is the one
/// that actually owns bind / accept / per-connection raw I/O — see
/// `NFSTransport` and `NFSTransportImplementation`.
public final class NFSServerListener: Sendable {
    private let server: any NFSServer
    private let bind: NFSBind
    private let transport: NFSTransport
    private let logger: Logger
    private let boundAddressBox: BoundAddressBox

    public init(
        server: any NFSServer,
        bind: NFSBind = .loopback(),
        transport: NFSTransport = .default,
        logger: Logger = Logger(label: "nanonfs")
    ) {
        self.server = server
        self.bind = bind
        self.transport = transport
        self.logger = logger
        self.boundAddressBox = BoundAddressBox()
    }

    /// The (host, port) the transport ended up bound to, once `run()` has
    /// reached the post-bind stage. `nil` before then.
    public var boundAddress: NFSBoundAddress? {
        get async { await boundAddressBox.value }
    }

    public func run() async throws {
        if bind.kind == .external {
            logger.warning("NFSServerListener bound to external interface \(bind.host):\(bind.port)")
        }

        let dispatcher = CompoundDispatcher(server: server, logger: logger)
        let logger = logger
        let boundAddressBox = boundAddressBox
        let impl = resolveImplementation()

        try await impl.serve(
            bind: bind,
            logger: logger,
            onBind: { addr in
                await boundAddressBox.set(addr)
                logger.info("nanonfs listening on \(addr.host):\(addr.port)")
            },
            connectionHandler: { inbound, outbound in
                await Self.serve(
                    inbound: inbound,
                    outbound: outbound,
                    dispatcher: dispatcher,
                    logger: logger
                )
            }
        )
    }

    /// Resolve the configured `NFSTransport` to an actual implementation. The
    /// `.custom` case forwards the user's value; the trait-gated `.nio` arm
    /// is only compiled when the `NIO` trait is on. `.bsdSocket` is always
    /// available.
    private func resolveImplementation() -> any NFSTransportImplementation {
        switch transport {
        #if NIO
        case .nio(let groupBox):
            return NIOTransport(eventLoopGroupBox: groupBox)
        #endif
        case .bsdSocket:
            return BSDSocketTransport()
        case .custom(let impl):
            return impl
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
    ///     `outbound.write` (the transport assumes single-writer).
    ///
    /// In-flight count is bounded by `inFlightSemaphore` so a noisy client
    /// cannot make the server allocate one task per pipelined RPC without
    /// limit.
    private static func serve(
        inbound: NFSAsyncByteStream,
        outbound: NFSAsyncByteWriter,
        dispatcher: CompoundDispatcher,
        logger: Logger
    ) async {
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
                    await outbound.finish()
                } catch {
                    logger.info("outbound write ended: \(error)")
                }
            }

            // Reader + dispatch pool. The discarding inner group lets us
            // await all in-flight dispatches before signalling the writer
            // that no more replies are coming.
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
}

/// Cap on how many RPC dispatches can be running for a single TCP
/// connection. macOS's nfsiod typically issues at most ~16 parallel RPCs,
/// so 64 leaves comfortable headroom without unbounded task allocation.
let maxInFlightRequestsPerConnection: Int = 64

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
    private(set) var value: NFSBoundAddress?
    func set(_ address: NFSBoundAddress?) { self.value = address }
}

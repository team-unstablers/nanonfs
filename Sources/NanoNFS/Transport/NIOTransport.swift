#if NIO

import Foundation
import Logging
import NIOCore
import NIOPosix

/// Swift-NIO based listener. Owned by `NFSTransport.nio(...)` and instantiated
/// from `NFSServerListener.resolveImplementation()` when the `NIO` trait is
/// enabled.
///
/// What this transport handles:
///   • Building / borrowing an `EventLoopGroup`.
///   • `ServerBootstrap.bind(...)` plus the accept loop.
///   • Wrapping each accepted `NIOAsyncChannel<ByteBuffer, ByteBuffer>` into a
///     transport-agnostic `NFSAsyncByteStream` / `NFSAsyncByteWriter` pair.
///
/// What it deliberately does *not* handle: record-mark framing or RPC
/// dispatch. Those stay on `NFSServerListener` so they can be reused by
/// other transports.
struct NIOTransport: NFSTransportImplementation {
    private let userProvidedGroup: (any EventLoopGroup)?

    init(eventLoopGroupBox: NFSNIOEventLoopGroupBox?) {
        self.userProvidedGroup = eventLoopGroupBox?.group
    }

    func serve(
        bind: NFSBind,
        logger: Logger,
        onBind: @escaping @Sendable (NFSBoundAddress) async -> Void,
        connectionHandler: @escaping @Sendable (NFSAsyncByteStream, NFSAsyncByteWriter) async throws -> Void
    ) async throws {
        let group: any EventLoopGroup
        let ownsGroup: Bool
        if let provided = userProvidedGroup {
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

        if let bound = serverChannel.channel.localAddress {
            await onBind(NFSBoundAddress(
                host: bound.ipAddress ?? bind.host,
                port: UInt16(bound.port ?? Int(bind.port))
            ))
        } else {
            await onBind(NFSBoundAddress(host: bind.host, port: bind.port))
        }

        do {
            try await withTaskCancellationHandler {
                try await serverChannel.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await child in inbound {
                            group.addTask {
                                await Self.serveChild(
                                    child: child,
                                    connectionHandler: connectionHandler,
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

    /// Adapt one accepted child channel into the transport-agnostic byte
    /// stream / writer shape and forward it to the listener's
    /// `connectionHandler`.
    private static func serveChild(
        child: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        connectionHandler: @escaping @Sendable (NFSAsyncByteStream, NFSAsyncByteWriter) async throws -> Void,
        logger: Logger
    ) async {
        do {
            try await child.executeThenClose { inbound, outbound in
                // Bridge the NIO inbound iterator through an actor so the
                // closure-based NFSAsyncByteStream can drive it without
                // worrying about iterator-Sendable subtleties.
                let bridge = NIOInboundBridge(inbound: inbound)
                let stream = NFSAsyncByteStream { try await bridge.next() }
                let writer = NFSAsyncByteWriter(
                    write: { buffer in
                        try await outbound.write(buffer)
                    },
                    finish: {
                        // NIOAsyncChannel half-close is implicit on
                        // executeThenClose return — nothing to do here.
                    }
                )
                try await connectionHandler(stream, writer)
            }
        } catch {
            logger.info("connection ended: \(error)")
        }
    }
}

/// Holds a NIO inbound iterator across `next()` calls so the closure-based
/// `NFSAsyncByteStream` can pull from it without touching its mutable state
/// directly.
///
/// We can't use an `actor` here because `iterator.next()` is a *mutating
/// async* method on a stored property, and Swift 6 actor isolation rejects
/// that pattern on isolated state. A reference type with `@unchecked
/// Sendable` is fine because the listener only iterates the inbound stream
/// from a single Task at a time (single-iterator invariant of the
/// `connectionHandler` contract).
fileprivate final class NIOInboundBridge: @unchecked Sendable {
    private var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
    private var done: Bool = false

    init(inbound: NIOAsyncChannelInboundStream<ByteBuffer>) {
        self.iterator = inbound.makeAsyncIterator()
    }

    func next() async throws -> ByteBuffer? {
        if done { return nil }
        do {
            if let chunk = try await iterator.next() {
                return chunk
            } else {
                done = true
                return nil
            }
        } catch {
            done = true
            throw error
        }
    }
}

#endif

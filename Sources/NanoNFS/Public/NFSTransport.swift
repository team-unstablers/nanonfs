import Foundation
import Logging
#if NIO
import NIOCore
#endif

// MARK: - NFSTransport selection enum

/// Selects which TCP listener implementation `NFSServerListener` uses.
/// `case bsdSocket` is always available; `case nio` is only compiled when
/// the `NIO` package trait is enabled (see `README.md` §2 / `Package.swift`).
///
/// `Equatable` is intentionally *not* synthesised: `case custom(any ...)`
/// carries an existential and existentials cannot be compared structurally.
/// Pattern-match on the case yourself if you need to discriminate.
public enum NFSTransport: Sendable {

    #if NIO
    /// Swift-NIO based listener (`NIOPosix.ServerBootstrap` + `NIOAsyncChannel`).
    ///
    /// If `eventLoopGroup` is `nil` the transport owns and tears down its own
    /// single-thread `MultiThreadedEventLoopGroup`. If you supply one, its
    /// lifetime stays your responsibility — the transport will not shut it
    /// down.
    case nio(eventLoopGroup: NFSNIOEventLoopGroupBox? = nil)
    #endif

    /// macOS BSD socket based listener. Pure Swift Concurrency on top of
    /// `socket(2)` + `kqueue(2)` + `EVFILT_USER`. No GCD, no Network.framework.
    /// Always available — this is the baseline transport and is compiled
    /// regardless of trait selection.
    case bsdSocket

    /// User-supplied implementation. The implementation owns
    /// bind / accept loop / per-connection raw byte I/O; record-mark
    /// framing and RPC dispatch stay on `NFSServerListener`.
    case custom(any NFSTransportImplementation)

    /// Resolves to the highest-priority transport available in this build.
    /// Priority is `nio` > `bsdSocket`: when the `NIO` trait is enabled
    /// `.default` returns `.nio()`, otherwise it returns `.bsdSocket`.
    public static var `default`: NFSTransport {
        #if NIO
        return .nio()
        #else
        return .bsdSocket
        #endif
    }
}

// MARK: - NFSTransportImplementation protocol

/// Listener-level transport abstraction. One conformer is responsible for:
///   • opening a listening socket bound to the supplied `NFSBind`,
///   • running the accept loop,
///   • handing each accepted connection's raw byte I/O to `connectionHandler`,
///   • returning gracefully when the surrounding `Task` is cancelled.
///
/// What stays on `NFSServerListener` (i.e. *out* of the transport's job):
///   • RFC 5531 §11 record-mark framing,
///   • NFSv4 `COMPOUND` dispatch,
///   • per-connection in-flight cap.
public protocol NFSTransportImplementation: Sendable {

    /// Bind, accept, dispatch. Returns when the surrounding `Task` is
    /// cancelled (graceful shutdown).
    ///
    /// Closure parameters:
    ///   - `onBind` — fired exactly once between `bind(2)` and the start of
    ///     the accept loop. `NFSServerListener` uses it to publish the actual
    ///     bound (host, port) through `boundAddress` — useful when the user
    ///     passed port `0`.
    ///   - `connectionHandler` — invoked once per accepted client connection.
    ///     The transport keeps the connection open until this closure either
    ///     returns normally or throws. `inbound` is the raw TCP byte stream
    ///     (before record-mark decoding); `outbound` is the raw TCP byte
    ///     writer (after record-mark encoding).
    ///
    /// Both closures are `@escaping` because transports typically capture
    /// them into child Tasks for the duration of the connection.
    func serve(
        bind: NFSBind,
        logger: Logger,
        onBind: @escaping @Sendable (NFSBoundAddress) async -> Void,
        connectionHandler: @escaping @Sendable (NFSAsyncByteStream, NFSAsyncByteWriter) async throws -> Void
    ) async throws
}

// MARK: - NIO EventLoopGroup injection

#if NIO
/// Trait-gated: only present when the `NIO` trait is enabled.
///
/// Lets users hand in their own NIO `EventLoopGroup` via
/// `NFSTransport.nio(eventLoopGroup:)` without making
/// `NIOCore.EventLoopGroup` itself part of the unconditional public API.
///
/// The lifetime of the wrapped group remains the caller's responsibility —
/// `NIOTransport` will not call `shutdownGracefully()` on a user-provided
/// group.
public struct NFSNIOEventLoopGroupBox: Sendable {
    public let group: any EventLoopGroup

    public init(_ group: any EventLoopGroup) {
        self.group = group
    }
}
#endif

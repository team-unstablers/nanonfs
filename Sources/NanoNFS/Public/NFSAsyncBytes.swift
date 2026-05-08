import Foundation
import NIOCore

// Transport-agnostic adapters that a custom NFSTransportImplementation hands
// out, so the listener can read raw TCP bytes and write framed RPC replies
// without depending on any specific networking stack.
//
// Internally both types are closure-backed: each transport supplies a
// closure that drives its native I/O primitive (e.g. NIOAsyncChannel,
// kqueue + read(2)/write(2)). The public surface is the same regardless of
// which transport produced the values.

/// One connection's inbound byte stream. AsyncSequence semantics: terminates
/// on cancellation or peer half-close (`next()` returns `nil`). Element is
/// `NIOCore.ByteBuffer`, which is part of the unconditional baseline (see
/// `README.md` §2).
public struct NFSAsyncByteStream: AsyncSequence, Sendable {
    public typealias Element = ByteBuffer

    private let _makeIterator: @Sendable () -> AsyncIterator

    /// Build a stream from a `next()` closure shared across all iterators.
    /// The closure is responsible for any internal mutable state — the
    /// AsyncIterator only forwards calls.
    public init(next: @escaping @Sendable () async throws -> ByteBuffer?) {
        self._makeIterator = { AsyncIterator(next: next) }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        _makeIterator()
    }

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        public typealias Element = ByteBuffer
        private let _next: @Sendable () async throws -> ByteBuffer?

        init(next: @escaping @Sendable () async throws -> ByteBuffer?) {
            self._next = next
        }

        public mutating func next() async throws -> ByteBuffer? {
            try await _next()
        }
    }
}

/// One connection's outbound byte writer. The transport must guarantee that
/// concurrent `write(_:)` calls are serialised — `NFSServerListener` already
/// drives a single writer task per connection, so transports may rely on
/// "single writer at a time" without further synchronisation.
public struct NFSAsyncByteWriter: Sendable {
    private let _write: @Sendable (ByteBuffer) async throws -> Void
    private let _finish: @Sendable () async -> Void

    public init(
        write: @escaping @Sendable (ByteBuffer) async throws -> Void,
        finish: @escaping @Sendable () async -> Void
    ) {
        self._write = write
        self._finish = finish
    }

    /// Write `buffer` in full. May coalesce multiple calls under the hood,
    /// but every call must be observable on the wire by the time the
    /// returned task awaits successfully.
    public func write(_ buffer: ByteBuffer) async throws {
        try await _write(buffer)
    }

    /// Half-close the outbound side. Subsequent `write(_:)` calls become
    /// undefined behaviour — the listener does not call `write(_:)` after
    /// `finish()`.
    public func finish() async {
        await _finish()
    }
}

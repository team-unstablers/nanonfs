#if BSDSOCKET

import Foundation
import Logging
import NIOCore
import Darwin

// MARK: - BSDSocketTransport
//
// Pure Swift Concurrency listener built directly on `socket(2)` + `kqueue(2)`.
// No GCD, no Network.framework, no NIO product (NIOCore is consumed only as
// the `ByteBuffer` element type of the inbound stream).
//
// Concurrency model — designed to *not* block Swift's cooperative thread
// pool:
//   • The listener's accept loop runs on a dedicated `Thread` (real pthread,
//     not a Swift Concurrency Task). It blocks on `kevent(2)` and yields
//     accepted fds onto an `AsyncStream<Int32>`. Cancellation is delivered
//     via `EVFILT_USER` so the wait wakes immediately.
//   • Each accepted connection spawns a *second* dedicated `Thread` for its
//     inbound read loop. That thread does `read(2)` on EVFILT_READ wakeups
//     and yields chunks onto an `AsyncThrowingStream<ByteBuffer, Error>`.
//     The connection-handler `Task` consumes from the stream like any
//     ordinary AsyncSequence.
//   • Writes happen inline on the calling Task. The common case is
//     non-blocking — kernel send buffers handle small RPC replies without
//     EAGAIN. When EAGAIN does fire, we briefly hop onto a *one-shot*
//     `Thread` to block on EVFILT_WRITE; this avoids parking a cooperative
//     thread on the kevent syscall.
//
// Net effect: long-running blocking syscalls (the listener and per-connection
// read loops) live entirely on dedicated pthreads, so the cooperative pool
// stays free for the user's actor / Task workload. With N concurrent
// connections, this transport uses 1 + N long-lived threads plus an
// occasional ephemeral thread per write-EAGAIN.

/// Listener identifier for the listener-side cancellation user event. Any
/// arbitrary `UInt` works — the value is private to this kqueue.
private let listenerCancelIdent: UInt = 0xC4_4C_E1_00

/// Per-connection cancellation user event identifier (registered on both
/// the read and write kqueues so either side can be unblocked at once).
private let connectionCancelIdent: UInt = 0xC4_4C_E1_01

// MARK: - kevent(2) syscall thunk
//
// `Darwin.kevent` is ambiguous between the C struct `kevent` and the C
// function `kevent(2)`. Both are imported under the same name, so the Swift
// type-checker sometimes picks the struct's labelled initialiser and rejects
// the call. Bind the syscall to a private name via `@_silgen_name` to avoid
// the ambiguity. This is the same trick swift-nio's NIOPosix uses
// internally.

@_silgen_name("kevent")
private func kevent_syscall(
    _ kq: Int32,
    _ changelist: UnsafePointer<Darwin.kevent>?,
    _ nchanges: Int32,
    _ eventlist: UnsafeMutablePointer<Darwin.kevent>?,
    _ nevents: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32

// MARK: - Transport entry point

struct BSDSocketTransport: NFSTransportImplementation {

    func serve(
        bind: NFSBind,
        logger: Logger,
        onBind: @escaping @Sendable (NFSBoundAddress) async -> Void,
        connectionHandler: @escaping @Sendable (NFSAsyncByteStream, NFSAsyncByteWriter) async throws -> Void
    ) async throws {
        let listenFd = try openListenSocket(host: bind.host, port: bind.port)
        let kq = try makeKqueue()

        do {
            try registerListenRead(kq: kq, listenFd: listenFd)
            try registerUserEvent(kq: kq, ident: listenerCancelIdent)
        } catch {
            Darwin.close(kq)
            Darwin.close(listenFd)
            throw error
        }

        // Publish the actual (host, port). For port 0 we resolve via getsockname(2).
        let bound = (try? sockGetsockname(listenFd)) ?? (host: bind.host, port: bind.port)
        await onBind(NFSBoundAddress(host: bound.host, port: bound.port))

        // Start the dedicated thread that owns the kevent loop.
        let (acceptStream, acceptCont) = AsyncStream<Int32>.makeStream(bufferingPolicy: .unbounded)
        let listenerHandle = ListenerLoop(
            kq: kq,
            listenFd: listenFd,
            acceptCont: acceptCont,
            logger: logger
        )
        listenerHandle.start()

        // Bridge cooperative-Task cancellation onto the listener thread by
        // triggering EVFILT_USER, which wakes its kevent() and exits the loop.
        try await withThrowingDiscardingTaskGroup { group in
            await withTaskCancellationHandler {
                for await clientFd in acceptStream {
                    group.addTask {
                        await Self.serveConnection(
                            fd: clientFd,
                            connectionHandler: connectionHandler,
                            logger: logger
                        )
                    }
                }
            } onCancel: {
                _ = triggerUserEvent(kq: kq, ident: listenerCancelIdent)
            }
        }

        // Listener thread has finished by the time the AsyncStream's
        // continuation was finished — but join just in case.
        listenerHandle.join()
        Darwin.close(kq)
        Darwin.close(listenFd)
    }

    /// One client connection's worth of work — bridge the connFd into a pair
    /// of `NFSAsyncByteStream` / `NFSAsyncByteWriter` adapters and forward
    /// them to the listener's `connectionHandler`.
    ///
    /// Owns:
    ///   • a dedicated read thread (long-lived for the connection lifetime),
    ///   • a small kqueue for write-EAGAIN waits (used by the inline writer).
    private static func serveConnection(
        fd connFd: Int32,
        connectionHandler: @escaping @Sendable (NFSAsyncByteStream, NFSAsyncByteWriter) async throws -> Void,
        logger: Logger
    ) async {
        guard let conn = ConnectionContext(fd: connFd, logger: logger) else {
            Darwin.close(connFd)
            return
        }
        defer { conn.close() }

        let inbound = NFSAsyncByteStream(next: { try await conn.readNextChunk() })
        let outbound = NFSAsyncByteWriter(
            write: { buffer in try await conn.write(buffer) },
            finish: { conn.shutdownWriteSide() }
        )

        do {
            try await withTaskCancellationHandler {
                try await connectionHandler(inbound, outbound)
            } onCancel: {
                conn.cancel()
            }
        } catch {
            logger.info("connection ended: \(error)")
        }
    }
}

// MARK: - Listener thread

/// Owns the listener kqueue's blocking `kevent(2)` loop. Runs on a dedicated
/// pthread (created via `Thread`) so it never blocks the Swift Concurrency
/// cooperative thread pool. Yields accepted file descriptors onto
/// `acceptCont`; finishes the stream on `EVFILT_USER` cancellation.
fileprivate final class ListenerLoop: @unchecked Sendable {
    let kq: Int32
    let listenFd: Int32
    let acceptCont: AsyncStream<Int32>.Continuation
    let logger: Logger
    private var thread: Thread?

    init(kq: Int32, listenFd: Int32,
         acceptCont: AsyncStream<Int32>.Continuation,
         logger: Logger) {
        self.kq = kq
        self.listenFd = listenFd
        self.acceptCont = acceptCont
        self.logger = logger
    }

    func start() {
        let t = Thread { [self] in self.run() }
        t.qualityOfService = .userInitiated
        t.name = "nanonfs.bsd.listener"
        t.start()
        self.thread = t
    }

    func join() {
        // Best-effort: spin until the thread has finished. The thread must
        // observe a cancel via EVFILT_USER first; the caller is responsible
        // for triggering that.
        while let t = thread, !t.isFinished {
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func run() {
        var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 8)
        outer: while true {
            let n = events.withUnsafeMutableBufferPointer { ebuf -> Int32 in
                kevent_syscall(kq, nil, 0, ebuf.baseAddress, Int32(ebuf.count), nil)
            }
            if n < 0 {
                if errno == EINTR { continue }
                acceptCont.finish()
                return
            }
            for i in 0..<Int(n) {
                let ev = events[i]
                if ev.filter == Int16(EVFILT_USER) && ev.ident == listenerCancelIdent {
                    acceptCont.finish()
                    return
                }
                if ev.filter == Int16(EVFILT_READ) && ev.ident == UInt(listenFd) {
                    while true {
                        do {
                            guard let fd = try acceptOne(listenFd) else { break }
                            acceptCont.yield(fd)
                        } catch {
                            logger.warning("accept failed: \(error)")
                            acceptCont.finish()
                            return
                        }
                    }
                }
            }
            _ = events  // keep buffer alive
            continue outer
        }
    }
}

// MARK: - Connection context

/// Bundles the per-connection state. Reference type so the byte-stream and
/// writer closures can capture it cheaply.
///
/// Threads owned:
///   • One *read thread* — the long-lived kevent loop that drives reads.
///     Uses `readKq` to multiplex `EVFILT_READ` (data ready) with the
///     `EVFILT_USER` cancel event. Pushes chunks onto `inboundStream`.
///   • Zero-or-more *one-shot write-wait threads* — only spawned when an
///     inline `write(2)` returns `EAGAIN`, lasting one EVFILT_WRITE wakeup.
///
/// `writeKq` is shared between the inline writer's one-shot threads and is
/// also where the cancel `EVFILT_USER` gets triggered for write-EAGAIN
/// waits.
fileprivate final class ConnectionContext: @unchecked Sendable {
    let fd: Int32
    let readKq: Int32
    let writeKq: Int32
    let logger: Logger

    let inboundStream: AsyncThrowingStream<ByteBuffer, Error>
    private let inboundCont: AsyncThrowingStream<ByteBuffer, Error>.Continuation

    private var readThread: Thread?
    private let stateLock = NSLock()
    private var didCancel: Bool = false
    private var inboundIterator: AsyncThrowingStream<ByteBuffer, Error>.Iterator

    init?(fd: Int32, logger: Logger) {
        self.fd = fd
        self.logger = logger
        do {
            try setNonblocking(fd)
            self.readKq = try makeKqueue()
            do {
                self.writeKq = try makeKqueue()
            } catch {
                Darwin.close(self.readKq)
                return nil
            }
            // Both kqueues carry the same cancel ident so either side wakes
            // up at the same moment.
            try registerUserEvent(kq: readKq, ident: connectionCancelIdent)
            try registerUserEvent(kq: writeKq, ident: connectionCancelIdent)
            try registerReadFilter(kq: readKq, fd: fd)
        } catch {
            return nil
        }
        let (stream, cont) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        self.inboundStream = stream
        self.inboundCont = cont
        self.inboundIterator = stream.makeAsyncIterator()

        // Start the dedicated read thread. It must outlive `init` so the
        // captured `self` is valid for as long as the Thread runs.
        let t = Thread { [self] in self.readLoop() }
        t.qualityOfService = .userInitiated
        t.name = "nanonfs.bsd.conn-read"
        t.start()
        self.readThread = t
    }

    func close() {
        // The read thread exits on EVFILT_USER cancel; trigger that if it
        // hasn't been triggered yet.
        cancel()
        if let t = readThread {
            while !t.isFinished { Thread.sleep(forTimeInterval: 0.001) }
        }
        Darwin.close(readKq)
        Darwin.close(writeKq)
        Darwin.close(fd)
    }

    func cancel() {
        stateLock.lock()
        let already = didCancel
        didCancel = true
        stateLock.unlock()
        if already { return }
        _ = triggerUserEvent(kq: readKq, ident: connectionCancelIdent)
        _ = triggerUserEvent(kq: writeKq, ident: connectionCancelIdent)
    }

    func shutdownWriteSide() {
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))
    }

    /// Called on the cooperative Task that owns `NFSAsyncByteStream`. The
    /// underlying `AsyncThrowingStream` is fed by the dedicated read thread,
    /// so this just forwards the iterator.
    func readNextChunk() async throws -> ByteBuffer? {
        try await inboundIterator.next()
    }

    /// Called on the cooperative Task that owns `NFSAsyncByteWriter`. Writes
    /// inline; if `write(2)` returns `EAGAIN`, parks on a one-shot pthread
    /// to wait for `EVFILT_WRITE` rather than blocking the cooperative pool.
    func write(_ buffer: ByteBuffer) async throws {
        let bytes = Array(buffer.readableBytesView)
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let n = bytes.withUnsafeBufferPointer { bp -> Int in
                Darwin.write(fd, bp.baseAddress?.advanced(by: offset), remaining)
            }
            if n > 0 {
                offset += n
                continue
            }
            if n == 0 {
                throw POSIXError(.EIO)
            }
            let savedErrno = errno
            if savedErrno == EINTR { continue }
            if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK {
                let woke = try await waitForWriteReady()
                if woke == .cancelled { throw CancellationError() }
                continue
            }
            if savedErrno == EPIPE {
                throw POSIXError(.EPIPE)
            }
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
    }

    private enum WakeReason { case ready, cancelled }

    /// Park on `EVFILT_WRITE | EV_ONESHOT` until either the connection fd
    /// becomes writable or the connection is cancelled. Runs the blocking
    /// `kevent(2)` on a one-shot `Thread` so the cooperative pool isn't
    /// occupied by the wait.
    private func waitForWriteReady() async throws -> WakeReason {
        // Register the one-shot write filter from the calling thread first
        // (cheap, non-blocking) so that the pthread we're about to spawn
        // doesn't have to know about the fd.
        var change = Darwin.kevent()
        change.ident = UInt(fd)
        change.filter = Int16(EVFILT_WRITE)
        change.flags = UInt16(EV_ADD | EV_ONESHOT)
        change.fflags = 0
        change.data = 0
        change.udata = nil
        let regResult = withUnsafePointer(to: &change) { cp -> Int32 in
            kevent_syscall(writeKq, cp, 1, nil, 0, nil)
        }
        if regResult < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let kq = self.writeKq
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WakeReason, Error>) in
            let t = Thread {
                var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 4)
                while true {
                    let n = events.withUnsafeMutableBufferPointer { ebuf -> Int32 in
                        kevent_syscall(kq, nil, 0, ebuf.baseAddress, Int32(ebuf.count), nil)
                    }
                    if n < 0 {
                        if errno == EINTR { continue }
                        cont.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                        return
                    }
                    for i in 0..<Int(n) {
                        let ev = events[i]
                        if ev.filter == Int16(EVFILT_USER) && ev.ident == connectionCancelIdent {
                            cont.resume(returning: .cancelled)
                            return
                        }
                        if ev.filter == Int16(EVFILT_WRITE) {
                            cont.resume(returning: .ready)
                            return
                        }
                    }
                }
            }
            t.qualityOfService = .userInitiated
            t.name = "nanonfs.bsd.conn-write-wait"
            t.start()
        }
    }

    private func readLoop() {
        var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 8)
        let bufSize = 64 * 1024
        outer: while true {
            let n = events.withUnsafeMutableBufferPointer { ebuf -> Int32 in
                kevent_syscall(readKq, nil, 0, ebuf.baseAddress, Int32(ebuf.count), nil)
            }
            if n < 0 {
                if errno == EINTR { continue }
                inboundCont.finish(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
            for i in 0..<Int(n) {
                let ev = events[i]
                if ev.filter == Int16(EVFILT_USER) && ev.ident == connectionCancelIdent {
                    inboundCont.finish()
                    return
                }
                if ev.filter == Int16(EVFILT_READ) && ev.ident == UInt(fd) {
                    // Drain reads until EAGAIN or EOF.
                    while true {
                        var buf = [UInt8](repeating: 0, count: bufSize)
                        let nRead = buf.withUnsafeMutableBufferPointer { bp -> Int in
                            Darwin.read(fd, bp.baseAddress, bp.count)
                        }
                        if nRead > 0 {
                            inboundCont.yield(ByteBuffer(bytes: buf.prefix(Int(nRead))))
                            continue
                        }
                        if nRead == 0 {
                            inboundCont.finish()
                            return
                        }
                        let savedErrno = errno
                        if savedErrno == EINTR { continue }
                        if savedErrno == EAGAIN || savedErrno == EWOULDBLOCK { break }
                        inboundCont.finish(throwing: POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO))
                        return
                    }
                }
            }
            _ = events
            continue outer
        }
    }
}

// MARK: - POSIX / kqueue helpers

/// Open an IPv4 (or IPv6 loopback) listening socket bound to `host:port`,
/// non-blocking, with `SO_REUSEADDR` set.
fileprivate func openListenSocket(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = Int32(IPPROTO_TCP)
    hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST | AI_NUMERICSERV

    var info: UnsafeMutablePointer<addrinfo>? = nil
    let rc = getaddrinfo(host, String(port), &hints, &info)
    if rc != 0 || info == nil {
        if let info { freeaddrinfo(info) }
        throw POSIXError(.EADDRNOTAVAIL)
    }
    defer { freeaddrinfo(info) }
    let head = info!

    let fd = socket(head.pointee.ai_family, head.pointee.ai_socktype, head.pointee.ai_protocol)
    if fd < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var yes: Int32 = 1
    if setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) < 0 {
        let saved = errno
        Darwin.close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: saved) ?? .EIO)
    }

    var one: Int32 = 1
    _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

    do {
        try setNonblocking(fd)
    } catch {
        Darwin.close(fd)
        throw error
    }

    if Darwin.bind(fd, head.pointee.ai_addr, head.pointee.ai_addrlen) < 0 {
        let saved = errno
        Darwin.close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: saved) ?? .EIO)
    }

    if Darwin.listen(fd, 64) < 0 {
        let saved = errno
        Darwin.close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: saved) ?? .EIO)
    }

    return fd
}

fileprivate func setNonblocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

fileprivate func makeKqueue() throws -> Int32 {
    let kq = Darwin.kqueue()
    if kq < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return kq
}

fileprivate func registerListenRead(kq: Int32, listenFd: Int32) throws {
    var ev = Darwin.kevent()
    ev.ident = UInt(listenFd)
    ev.filter = Int16(EVFILT_READ)
    ev.flags = UInt16(EV_ADD | EV_CLEAR)
    ev.fflags = 0
    ev.data = 0
    ev.udata = nil
    let rc = withUnsafePointer(to: &ev) { cp -> Int32 in
        kevent_syscall(kq, cp, 1, nil, 0, nil)
    }
    if rc < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

fileprivate func registerReadFilter(kq: Int32, fd: Int32) throws {
    var ev = Darwin.kevent()
    ev.ident = UInt(fd)
    ev.filter = Int16(EVFILT_READ)
    ev.flags = UInt16(EV_ADD | EV_CLEAR)
    ev.fflags = 0
    ev.data = 0
    ev.udata = nil
    let rc = withUnsafePointer(to: &ev) { cp -> Int32 in
        kevent_syscall(kq, cp, 1, nil, 0, nil)
    }
    if rc < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

fileprivate func registerUserEvent(kq: Int32, ident: UInt) throws {
    var ev = Darwin.kevent()
    ev.ident = ident
    ev.filter = Int16(EVFILT_USER)
    ev.flags = UInt16(EV_ADD | EV_CLEAR)
    ev.fflags = 0
    ev.data = 0
    ev.udata = nil
    let rc = withUnsafePointer(to: &ev) { cp -> Int32 in
        kevent_syscall(kq, cp, 1, nil, 0, nil)
    }
    if rc < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

fileprivate func triggerUserEvent(kq: Int32, ident: UInt) -> Bool {
    var ev = Darwin.kevent()
    ev.ident = ident
    ev.filter = Int16(EVFILT_USER)
    ev.flags = 0
    ev.fflags = UInt32(NOTE_TRIGGER)
    ev.data = 0
    ev.udata = nil
    let rc = withUnsafePointer(to: &ev) { cp -> Int32 in
        kevent_syscall(kq, cp, 1, nil, 0, nil)
    }
    return rc >= 0
}

fileprivate func acceptOne(_ listenFd: Int32) throws -> Int32? {
    var addr = sockaddr_storage()
    var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let fd = withUnsafeMutablePointer(to: &addr) { sp -> Int32 in
        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.accept(listenFd, sa, &addrLen)
        }
    }
    if fd >= 0 {
        return fd
    }
    if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
    if errno == EINTR { return nil }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

/// Resolve the address a listening socket actually got bound to. Used to
/// report the port number when the caller passed `0`.
fileprivate func sockGetsockname(_ fd: Int32) throws -> (host: String, port: UInt16)? {
    var addr = sockaddr_storage()
    var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let rc = withUnsafeMutablePointer(to: &addr) { sp -> Int32 in
        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.getsockname(fd, sa, &addrLen)
        }
    }
    if rc < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return formatSockaddr(&addr)
}

/// Render a NUL-terminated `[CChar]` returned by `inet_ntop` as a `String`,
/// using the modern `String(decoding:as:)` initialiser. Stops at the first
/// `0` byte.
fileprivate func decodeNullTerminated(_ buf: [CChar]) -> String {
    let nullIndex = buf.firstIndex(of: 0) ?? buf.endIndex
    let bytes = buf[..<nullIndex].map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

fileprivate func formatSockaddr(_ addr: UnsafeMutablePointer<sockaddr_storage>) -> (host: String, port: UInt16)? {
    return addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> (host: String, port: UInt16)? in
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let result = buf.withUnsafeMutableBufferPointer { bp -> UnsafePointer<CChar>? in
                    var inAddr = sin.pointee.sin_addr
                    return inet_ntop(AF_INET, &inAddr, bp.baseAddress, socklen_t(bp.count))
                }
                guard result != nil else { return nil }
                let host = decodeNullTerminated(buf)
                let port = UInt16(bigEndian: sin.pointee.sin_port)
                return (host: host, port: port)
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let result = buf.withUnsafeMutableBufferPointer { bp -> UnsafePointer<CChar>? in
                    var in6Addr = sin6.pointee.sin6_addr
                    return inet_ntop(AF_INET6, &in6Addr, bp.baseAddress, socklen_t(bp.count))
                }
                guard result != nil else { return nil }
                let host = decodeNullTerminated(buf)
                let port = UInt16(bigEndian: sin6.pointee.sin6_port)
                return (host: host, port: port)
            }
        default:
            return nil
        }
    }
}

#endif

# 2026-05-09 — BSD-socket transport implementation (spec v1.1 landed)

## What

Implemented `llm_prompts/features/001.1-netimpl-bsd-socket.xml` end-to-end.
Transport is now a public, pluggable abstraction; the listener no longer
exposes any NIO type, and a pure-Swift-Concurrency BSD-socket listener is
available behind the `BSDSocket` package trait.

Headline changes:

- `swift-tools-version` 6.0 → 6.2 (SE-0450 traits).
- New traits in `Package.swift`: `NIO` (default-enabled) and `BSDSocket`.
  Trait gating is via `swiftSettings.define("NIO" / "BSDSOCKET", ...)`,
  surfaced in source as `#if NIO` / `#if BSDSOCKET`.
- Public API broke: `NFSServerListener.init` drops `eventLoopGroup`, gains
  `transport: NFSTransport = .default`, and `boundAddress` is now
  `NFSBoundAddress` (host, port) instead of `NIOCore.SocketAddress`.
- New public types under `Sources/NanoNFS/Public/`:
  - `NFSBoundAddress` (transport-agnostic `(host, port)`).
  - `NFSTransport` enum with `case nio(eventLoopGroup:)` (NIO trait),
    `case bsdSocket` (BSDSocket trait), `case custom(any ...)`, and
    `static var default`.  Equatable intentionally not synthesised.
  - `NFSTransportImplementation` protocol — listener-level abstraction with
    the closure signature
    `serve(bind:logger:onBind:connectionHandler:) async throws`.
  - `NFSAsyncByteStream` / `NFSAsyncByteWriter` — closure-backed
    transport-agnostic adapters, both yielding `NIOCore.ByteBuffer` (which
    stays unconditional baseline).
  - `NFSNIOEventLoopGroupBox` (NIO-trait-only) — opaque box for users who
    want to inject their own `EventLoopGroup`.
- New `Sources/NanoNFS/Transport/` directory:
  - `NIOTransport.swift` (`#if NIO`) — moved the prior `ServerBootstrap` /
    `executeThenClose` body out of the listener. Wraps NIO inbound iterator
    in an `@unchecked Sendable` class because actor isolation rejects
    mutating-async on isolated stored properties.
  - `BSDSocketTransport.swift` (`#if BSDSOCKET`) — pure-Swift-Concurrency
    listener on top of `socket(2)` + `kqueue(2)` + `EVFILT_USER`.
- `NFSServerListener` retains record-mark framing + COMPOUND dispatch +
  per-connection in-flight cap, and now drives the transport via
  `connectionHandler`.
- `NanoNFSDemo` accepts `--transport=nio` (default) or `--transport=bsdSocket`.
- New test suite `BSDSocketTransportTests` (trait-gated). Existing
  `Listener integration` and `Mount simulation` suites also exercise the
  BSDSocket transport in `--traits BSDSocket --disable-default-traits`
  builds, since `.default` resolves to `.bsdSocket` there.

## Why

Recap from the v1.1 spec confirmation entry
(`task_logs/2026-05-09-bsdsocket-spec-v11.md`):

- The original v1.0 plan to trait-gate every NIO product including
  `NIOCore.ByteBuffer` was infeasible — `ByteBuffer` is the encoding medium
  across XDR / RPC / Wire (≈160 usages). v1.1 keeps `NIOCore` /
  `NIOFoundationCompat` / `swift-log` / `swift-atomics` as unconditional
  baseline; only `NIO` + `NIOPosix` are trait-gated.
- `NFSServer` callbacks were already transport-agnostic, so the listener
  surface was the only public-API blocker.
- Loopback NFS users that don't want a Swift-NIO dep on the network layer
  (e.g. Noctiluca host app) can now disable the `NIO` trait.

## Big design call: dedicated pthreads, not cooperative Tasks

The first BSDSocket implementation followed the spec's pseudocode literally:
each `serveConnection` and the listener's accept loop blocked on `kevent(2)`
*inside* a Swift Concurrency `Task`. Three of the new `BSDSocketTransport`
unit tests passed in isolation, but running the full test suite under
`--traits BSDSocket --disable-default-traits` deadlocked: 8 parallel test
cases × 2 blocking sites per case (one in the listener's kevent, one in
`TCPClient.readExactly`) saturated the 8-thread cooperative pool, so the
per-connection task could never get scheduled to feed the inbound stream.
A `sample(1)` confirmed every cooperative thread was parked in `kevent` /
`recvfrom`.

Resolution: blocking syscalls move off the cooperative pool entirely.

- The listener's accept loop runs on a dedicated `Thread` (real pthread,
  spawned via `Thread {}.start()`). It yields accepted fds to an
  `AsyncStream<Int32>`. Cancellation arrives via `EVFILT_USER`, fired from
  the `withTaskCancellationHandler`'s `onCancel`.
- Per-connection inbound has its own dedicated `Thread`. Each EVFILT_READ
  wakeup triggers a `read(2)` drain (to EAGAIN) and yields chunks to an
  `AsyncThrowingStream<ByteBuffer, Error>` — which is what the cooperative
  Task consuming `inbound.next()` reads from.
- Outbound writes happen inline on the calling Task. The common case is a
  non-blocking `write(2)` that finishes in one shot. Only on `EAGAIN` does
  the writer hop onto a *one-shot* `Thread` to wait for `EVFILT_WRITE`,
  which keeps the cooperative pool unblocked even under back-pressure.

Net resource cost per listener: `1 + N` long-lived threads (1 accept loop
+ 1 per connection's read loop), plus an occasional ephemeral thread on
write-EAGAIN. For Noctiluca's "loopback NFS, single client" target, this is
cheap.

This deviates slightly from the spec sketch in §5 ("blocking kevent inside
a Task"), but the spec explicitly says
"`kevent(2)`는 사용한다 — kqueue 직행이 자연스럽다" — i.e. don't reach for
GCD/Network.framework wrappers. Using pthreads directly to drive kqueue
honors that. The deviation is purely about *which Swift execution context*
runs the kevent call, not the syscall contract or the cancellation model.

## Other notable choices

- **Two kqueues per connection.** The connection has a `readKq` (for the
  read thread) and a `writeKq` (for the on-EAGAIN write wait). This avoids
  having two threads concurrently call `kevent(2)` on the same kqueue,
  which mostly works but has subtle edge cases around event delivery.
  Both kqueues register the same `EVFILT_USER` cancel ident, so a single
  `cancel()` triggers both halves at once.
- **`@_silgen_name("kevent")` thunk.** `Darwin.kevent(...)` is ambiguous
  between the C struct `kevent` (whose initialiser carries the same Swift
  name) and the C function. Without `import NIOPosix` to disambiguate,
  the type-checker picks the struct's labelled initialiser and rejects
  the call. The thunk is the same trick swift-nio uses internally.
- **`AsyncThrowingStream` as the inbound bridge** between the read thread
  and the cooperative `next()` caller. The read thread has unrestricted
  yield access; the consumer reads via the stream's iterator, stored on
  an `@unchecked Sendable` class because actor isolation rejects mutating-
  async on isolated stored properties. The listener's connection handler
  is the sole consumer, so single-iterator contract holds.
- **`NFSAsyncByteStream` / `NFSAsyncByteWriter` are closure-backed.** The
  protocol contract uses `@escaping @Sendable` closures inline at
  `serve(...)`'s parameter list rather than typealiases — typealiased
  closure parameters default to non-escaping in Swift, and the transports
  capture them into child Tasks.
- **`NFSServerListener` keeps `withThrowingDiscardingTaskGroup`** for the
  per-connection in-flight cap (`maxInFlightRequestsPerConnection = 64`).
  The transport itself only has to deliver byte streams.

## Verified

- `swift build` — passes for default traits, `--traits BSDSocket
  --disable-default-traits`, and `--traits NIO,BSDSocket`.
- `swift test` — 65 tests under default; 68 tests under `NIO,BSDSocket`
  (adds `BSDSocketTransportTests`); 68 tests under `BSDSocket` only
  (existing suites run on `.bsdSocket` because that's `.default` there).
- Manual smoke: `.build/.../NanoNFSDemo --transport=bsdSocket` accepts a
  raw RPC NULL CALL on `127.0.0.1:14049` and returns the well-formed
  `msg_type=REPLY, reply_status=ACCEPTED, accept_stat=SUCCESS` reply.

## What to pick up next

- **macOS `mount_nfs` against the BSDSocket transport.** CLAUDE.md §5
  requires at least one *real* mount test per major surface. The NIO
  transport already has `mount_nfs -o vers=4,port=14049,...` documented in
  README §5.5; the same flow should be exercised against the BSDSocket
  build (`swift run --traits BSDSocket --disable-default-traits NanoNFSDemo
  --transport=bsdSocket` + the same mount command). Not done in this
  session.
- **ConnectionContext.cancel() join races.** `close()` busy-waits on the
  read thread finishing (`while !t.isFinished { Thread.sleep(0.001) }`).
  Tests pass, but a proper `pthread_join`-style wait or a completion
  semaphore would be cleaner.
- **`NFSServerListener` warning during single-trait `BSDSocket` build.**
  The build is clean now, but if anyone later splits the file: keep the
  `import NIOCore` line (used for `ByteBuffer` in the dispatch path).

## Reference files

- `llm_prompts/features/001.1-netimpl-bsd-socket.xml` — spec v1.1.
- `task_logs/2026-05-09-bsdsocket-spec-v11.md` — spec confirmation entry.
- `Sources/NanoNFS/Public/NFSTransport.swift` — public selector + protocol.
- `Sources/NanoNFS/Transport/NIOTransport.swift` — relocated NIO impl.
- `Sources/NanoNFS/Transport/BSDSocketTransport.swift` — new BSD impl.
- `Tests/NanoNFSTests/BSDSocketTransportTests.swift` — trait-gated suite.

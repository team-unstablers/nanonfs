# 2026-05-09 — BSD-socket transport spec v1.1 confirmed

## What

- Reviewed `llm_prompts/features/001-netimpl-bsd-socket.xml` (BSD-socket
  transport feature spec v1.0) for feasibility against the current code.
- Findings recorded in
  `llm_prompts/features/001-netimpl-bsd-socket.execution-log.20260509.xml`.
- Drafted v1.1 at `llm_prompts/features/001.1-netimpl-bsd-socket.xml` and
  confirmed with the user. **No code or README changes yet — spec only.**

## Why

The v1.0 spec assumed every NIO product (including `NIOCore.ByteBuffer`)
could be trait-gated wholesale. In practice `ByteBuffer` is the encoding
medium across XDR / RPC / Wire (≈160 usages, 130 of them in
`Wire/CompoundDispatcher.swift`). Wholesale trait-gating leaves the
encoder uncompilable when the `nio` trait is off.

Decisions captured in v1.1:

- **`NIOCore` stays unconditional baseline.** Only `NIOPosix` (and the
  listener using it) is `nio`-trait-gated. `NIOFoundationCompat`,
  `swift-log`, `swift-atomics` are also unconditional.
- **Public API breaks.** `EventLoopGroup` / `SocketAddress` removed from
  the public surface. New `NFSBoundAddress` (host, port). `EventLoopGroup`
  injection survives via `NFSTransport.nio(eventLoopGroup:)` payload using
  a trait-gated `NFSNIOEventLoopGroupBox`. Trade-off accepted: NIO-trait
  users still see NIO types via that box; BSD-only users do not.
- **`swift-tools-version` 6.0 → 6.2** (SE-0450 traits). Treated as
  breaking; next release is breaking anyway.
- **`NFSTransport` enum drops `Equatable`** — existential
  `case custom(any NFSTransportImplementation)` cannot synthesise it.
- **Transport granularity = listener.** Bind + accept loop +
  per-connection serve all owned by the transport. `NFSServerListener`
  retains record-mark framing and dispatcher.
- **BSD socket impl uses `kqueue` + `EVFILT_USER`** for cancellation
  wakeup. Single Task per listener; no detached-task-per-blocking-syscall;
  no GCD / Network.framework. Per-connection uses the same pattern with
  its own small kqueue.
  - First draft of §5 proposed "blocking accept + close-to-wake"; revised
    after user pushback because it leaks threads and has cancel-race
    corners. Kept this revision history because the rejected pattern is
    tempting and worth flagging if it shows up again.

## What to pick up next

Per `CLAUDE.md` §6 / §0 (README is canonical, README-first), the order is:

1. **`README.md`**:
   - §2 — toolchain bump, traits table.
   - §3 SYNOPSIS — `transport:` arg example.
   - §4 — `NFSServerListener` signature (drop `eventLoopGroup`, add
     `transport`), `boundAddress` type → `NFSBoundAddress`, add
     `NFSTransport`, `NFSTransportImplementation`, `NFSBoundAddress`,
     `NFSNIOEventLoopGroupBox` (trait-gated section).
2. **`CLAUDE.md`**:
   - §2 — add `Transport/` to the directory layout.
   - §3 — one-liner about the trait-gating policy.
3. Implementation:
   - `Package.swift` — traits + dependency conditions + `swift-tools` bump.
   - Move existing NIO listener body into `Sources/NanoNFS/Transport/NIOTransport.swift` (trait-gated).
   - Add `Sources/NanoNFS/Transport/BSDSocketTransport.swift` (kqueue +
     `EVFILT_USER`, trait-gated).
   - Adapt `NFSServerListener` to drive the transport via the new
     protocol.
4. Local `mount_nfs` smoke test against the `.bsdSocket` listener
   (CLAUDE.md §5 mount-test rule).

## Reference files

- `llm_prompts/features/001-netimpl-bsd-socket.xml` — v1.0, kept for
  trace.
- `llm_prompts/features/001-netimpl-bsd-socket.execution-log.20260509.xml`
  — validation findings.
- `llm_prompts/features/001.1-netimpl-bsd-socket.xml` — **v1.1,
  authoritative spec going forward.**

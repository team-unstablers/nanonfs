# 2026-05-10 — BSDSocket promoted to always-on baseline; only `NIO` is trait-gated

## What changed

- `Package.swift` no longer declares a `BSDSocket` trait. The traits array is now just `[.trait(name: "NIO", ...)]` and the previous `.default(enabledTraits: ["NIO"])` line is gone — default-trait set is empty. The `BSDSOCKET` swift-define is removed from all three target's `swiftSettings`.
- All `#if BSDSOCKET ... #endif` guards are removed:
  - `Sources/NanoNFS/Transport/BSDSocketTransport.swift` (top-level wrapper)
  - `Sources/NanoNFS/Public/NFSTransport.swift` (`case bsdSocket` is now unconditional; the `#if !NIO && !BSDSOCKET / #error` block is gone)
  - `Sources/NanoNFS/Public/NFSServerListener.swift` (`.bsdSocket` arm of `resolveImplementation()`)
  - `Sources/NanoNFSDemo/main.swift` (`case .bsdSocket` returns `.bsdSocket` unconditionally; help text updated)
  - `Tests/NanoNFSTests/BSDSocketTransportTests.swift` (top-level wrapper)
- `NFSTransport.default` priority is unchanged: `nio` > `bsdSocket`. With the `NIO` trait off, `.default == .bsdSocket`. With it on, `.default == .nio()`.
- `README.md` §2 trait table and the consumer `Package.swift` snippets are rewritten around the single-trait model. `CLAUDE.md` §3 "Trait gating" is rewritten to match.

## Why

- Original maintainer's primary machine has Xcode 26.4 / Swift 6.3.1 (SE-0450 traits work). A secondary machine has Xcode 26.1, where `swift build` without `--traits` does not apply `.default(enabledTraits: ["NIO"])` — so the previous Package.swift would reach the top-level `#error("nanonfs requires at least one transport trait to be enabled ...")` and fail to compile.
- Promoting BSDSocket to always-on means a missing-default-traits toolchain lands on a working BSDSocket-only build instead of failing. NIO stays opt-in (it is the only listener that pulls the NIO/NIOPosix products on top of the baseline NIOCore that the encoder already needs), so the trait-off build keeps the dependency surface minimal.
- BSDSocket has no extra dependencies beyond `Foundation` + `Darwin`, so making it baseline costs nothing in terms of build cost or surface area for users who don't want it.

## Verification

- `swift build` (no traits) — succeeds, BSDSocket-only build.
- `swift build --traits NIO` — succeeds, both transports.
- `swift test` — 68/68 pass with no traits. The `BSDSocketTransportTests` suite now compiles unconditionally and runs in this configuration.
- `swift test --traits NIO` — 68/68 pass.
- Demo smoke test: `.build/debug/NanoNFSDemo` launches, logs `transport=default`, listens on `127.0.0.1:14049`. With `NIO` trait off, `.default` lands on BSDSocket as expected.

## Pick-up notes

- If a future change ever needs a "BSDSocket disabled" build (e.g. a non-Darwin port), do not bring back a `BSDSocket` trait — the file uses `Darwin` directly, so the right move there is a per-platform `#if canImport(Darwin)` guard, not a trait.
- If the `NIO` trait is ever flipped to default-on again, watch for the same Xcode-26.1-style "default traits ignored" footgun — Package.swift comment block §1 explicitly calls this out, do not silently revert.
- README §2 still says `swift-tools-version: 6.2 (requires SE-0450 package traits)`. That's still accurate — we still use `traits:` to gate `NIO` — but the floor is now "SE-0450 syntax must parse", not "SE-0450 default-trait application must work".

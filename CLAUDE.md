# CLAUDE.md — nanonfs working spec

> This document is the working spec that AI coding assistants (Claude Code et al.) and the human maintainer follow when operating on this repository.
> **nanonfs is incremental, not a one-shot project — it accumulates across sessions.** Treat this file plus `task_logs/` as long-term memory: §7 holds the index, the actual work-log entries live as individual files under `task_logs/YYYY-MM-DD-BRIEF.md`, and **at the end of every session a new file under `task_logs/` must be added and linked from the §7 index**.

---

## 0. Authoritative sources

The order of authority within this repository:

1. **`README.md`** — source of truth for external behavior, public API, and supported scope.
2. **`docs/rfc7530.txt`** — source of truth for the NFSv4.0 wire protocol.
3. **`CLAUDE.md`** (this document) — implementation and process rules.
4. The code itself.

Higher items win on conflict. However, when the code and `README.md` disagree, **report it to the user as a problem** rather than silently bending one to match the other.

`docs/rfc7530.txt` is reference text and is not part of the library build. Whenever a decision affects wire behavior (op semantics, field ordering, error codes, etc.), cite the relevant RFC section in a code comment or PR description — e.g. `RFC 7530 §16.18 (READ)`.

---

<section id="agent-rules">

# AGENT RULES

## 1. Interaction & Language

- If you are unsure about something or have questions while working, **prioritize asking the user to clarify rather than guessing**. Use `AskUserQuestion` liberally; over-asking is preferable to proceeding on shaky assumptions.
- **The user's spoken language follows the `$LANG` environment variable.** Conduct conversations and plan-mode writing in the language indicated by `$LANG` (e.g. `ko_KR.*` → Korean, `ja_JP.*` → Japanese, `en_US.*` → American English). If `$LANG` is unset, `C`, or `POSIX`, default to **American English**. The original maintainer is a Korean speaker, but this repository is public and other contributors will not necessarily be — do not hard-code Korean.
- Free text addressed to the user is in that conversation language. Identifiers, code comments, and commit messages are written in a businesslike tone in **English** regardless of the conversation language (English is the established convention in this repo).
- When there is important project information or a major change, update this `CLAUDE.md` so the documentation reflects the latest state.
- When you learn new facts during work (code behavior, RFC interpretations, external tool quirks, etc.), record them as a new `task_logs/YYYY-MM-DD-BRIEF.md` entry and link it from the §7 index, so future sessions can pick up the trail. **Aggressively look up existing `task_logs/` entries** before guessing — the work log is long-term memory, not a changelog: when you encounter unfamiliar code, an unexpected design decision, an "already tried" smell, or a regression, `grep` / `ls task_logs/` and read the relevant past entry first.
- If you cannot proceed due to missing permissions, request elevation from the user. If a command fails due to insufficient permissions, escalate it to the user for approval rather than reaching for `--no-verify`/destructive shortcuts.

## 2. Directory / module structure

```
Sources/NanoNFS/
├── Public/      # Public API. Everything that is visible when the module is imported.
├── Transport/   # Listener-level transport implementations (NIO, BSD socket). Each file is trait-gated.
├── Wire/        # NFSv4 op handling, COMPOUND dispatch, stateid / clientid / delegation management
├── RPC/         # ONC RPC (RFC 5531). AUTH_SYS parsing. Callback-channel RPC client.
├── XDR/         # XDR (RFC 4506) encoder / decoder. Pure functions plus small reader / writer.
└── Internal/    # Domain-neutral utilities — logging, async helpers, file handle mapping, etc.
```

### Allowed dependency direction (top → down only)

```
Public  →  Transport  →  Wire  →  RPC  →  XDR
                  ↘            ↘     ↘
                    ────────────  Internal
```

- **Reverse-direction imports are forbidden.** For example, `XDR` must not import any `RPC` type. `RPC` must not know about any `Wire` type.
- **`Public/` does not directly expose types from other folders.** All Wire/RPC/XDR types are `internal`. When something must be public, place a separate type in `Public/` and add a translation layer.
- **The XDR layer is unaware of NFS semantics.** `XDR` only contains generic encoders such as `xdrEncode(uint32:)`. NFSv4 struct encoding is composed in `RPC` or `Wire` from XDR primitives.
- **The Wire layer is the sole entry point for `NFSServer` calls.** `Public.NFSServerListener` drives a `Transport/` implementation, which produces raw byte streams; the listener feeds those into the `Wire` dispatcher.
- **`Transport/` only consumes the public byte-stream adapters** (`NFSAsyncByteStream` / `NFSAsyncByteWriter`). It does not import `Wire/RPC/XDR`. Record-mark framing and dispatch live on `NFSServerListener`.

It can be tempting to break the dependency direction in order to avoid cross-layer plumbing — **don't**. The layer separation is what enables future work like adding NFSv3 or `ByteBuffer` overloads.

---

## 3. Coding style / Concurrency

- `swift-tools-version: 6.2`. **Swift 6 strict concurrency** is not disabled. The 6.2 bump is required for SE-0450 package traits used to gate the transport implementations.
- **All public types are `Sendable`.** When unavoidable, use `@unchecked Sendable` and document the reason in a one-line comment.
- The `NFSServer` implementation is provided by the user, but the library's recommendation is **`actor`**. Making user code safe against concurrent calls is the user's responsibility; the library does not serialize calls into user methods on its behalf.
- Library-internal state (clientid table, stateid issuance, delegation tracking, etc.) is each isolated in **its own `actor`**. No single mega-actor.
- **Do not use `@MainActor`.** This library has no UI.
- Logging always goes through `swift-log`. `print` / `NSLog` are forbidden. The `Logger` instance received by `NFSServerListener` is passed explicitly to child components.
- For places where lockless atomics suffice (counters, sequence numbers), use `swift-atomics`.
- `Foundation.Data` is used only at payload boundaries (`read` / `write` / file handle bytes). Inside hot paths (XDR encoder etc.) `ByteBuffer` is preferred.
- **Errors are `NFSError`** or library-internal error enums. If `POSIXError` / `NSError` is thrown from a user method, the Wire layer maps it to `NFS4ERR_SERVERFAULT` — the user's throw signature is not enforced, but unmapped errors **must be recorded with `logger.warning`**.

### Trait gating

- Two package traits — `NIO` (default-enabled) and `BSDSocket` — control which transport implementation is compiled into the library. Inside the source these are surfaced as `#if NIO` / `#if BSDSOCKET` (uppercase, set via `swiftSettings.define(...)` in `Package.swift`).
- **Each file under `Sources/NanoNFS/Transport/` is wrapped in a single top-level `#if` for its trait.** Do not sprinkle trait-conditional pieces into shared files; if a trait is off, the corresponding transport file becomes effectively empty.
- Baseline dependencies (`NIOCore`, `NIOFoundationCompat`, `swift-log`, `swift-atomics`) are pulled unconditionally — never put them behind a trait condition. `NIOCore.ByteBuffer` is the encoding medium across XDR / RPC / Wire and trait-gating it would leave the encoder uncompilable.
- Public API never gates a *type* on a trait unless the type is meaningless without that trait. The current exception is `NFSNIOEventLoopGroupBox`, which only exists when `NIO` is enabled.
- A user must enable at least one transport trait. `Package.swift` enforces this with a top-level `#error` when both traits are off.

---

## 4. RFC 7530 reference policy

- **Anti-hallucination rule (mandatory).** Before writing or editing code, comments, or work-log entries that include an `RFC 7530 §X` (or `§X.Y.Z`) citation, **look the section up directly in `docs/rfc7530.txt`** and confirm the cited number actually points at the content you mean. Do not rely on memory of section numbers, prior training data, or analogy to other NFS RFCs (5661 / 3530 — they renumber things). If you cannot positively verify the section, either grep the RFC for the relevant op / struct / error name first, or do not write the citation at all.
  - **Common trap**: in RFC 7530, `§16.N` is *not* the same as op number N. Operation N (3 ≤ N ≤ 39) lives in `§16.(N-2)` (e.g. ACCESS = op 3 / §16.1, COMPOUND = procedure 1 / §15.2, GETATTR = op 9 / §16.7, READ = op 25 / §16.23, WRITE = op 38 / §16.36). The 2026-05-09 audit found dozens of citations that confused these two.
  - **Common trap**: data types (`stateid4`, `nfstime4`, `change_info4`, `nfs_fh4`, `verifier4`, `open_owner4`, `lock_owner4`, etc.) are defined in `§2.1` (Table 1) or `§2.2.X`, not in `§3.3.X` or `§8.1.X`.
  - **Common trap**: features that exist in NFSv4.1 (RFC 5661) but **not** in 7530 — e.g. `OPEN4_SHARE_ACCESS_WANT_*`, `NFS4ERR_WRONG_TYPE`, `SECINFO_NO_NAME`, `NFS4ERR_LOCK_NOTGRANTED` — must not be cited as 7530. If unsure, grep the 7530 text first.
- Code that determines wire semantics (encoding, op dispatch, error code mapping, etc.) **cites the relevant RFC section in a comment**:
  ```swift
  // RFC 7530 §16.36 (WRITE) — "If the COMMIT operation is not used,
  //  the server MAY still commit the data ..."
  ```
- When the user references or quotes a specific section of `docs/rfc7530.txt`, **read that section directly** before responding. Do not rely on memory.
- When the RFC and the README disagree, **the README wins (because the supported scope is narrower)** — but state the fact in the PR description.
- When defending a code decision with "the RFC says so", always include the section number. RFC quotes without a section number are not to be trusted.

---

## 5. Testing principles

- Default framework: **swift-testing** (`@Test`).
- Unit tests (XDR encoders / RPC messages / Wire dispatcher) can rely on mocks.
- **However**, "this library actually behaves as an NFS server" cannot be fully verified by mocks alone. There must be at least one *real mount test* of the following form:
  - Mount a nanonfs instance via macOS `mount_nfs`.
  - Issue ordinary file system calls against the mounted path (`open` / `read` / `write` / `readdir` / `unlink` / `rename` / `flock`).
  - Cross-check the results against the `NFSServer` callback flow on the nanonfs side.
- A real mount test requires **macOS 14+** and **root privileges**. Regardless of CI feasibility, **leave it runnable locally at least once**. Mount-point setup / cleanup is the test's own responsibility.
- Beware the pattern of postponing the mount test by piling on more mock-based unit tests ("passed in mocks but doesn't actually mount" is the most common failure mode for NFS-class libraries).
- For each new feature, add at least one scenario test against the behavior cited from the RFC (e.g. "client retransmits when COMMIT verifier changes").

---

## 6. Asking the user / decision authority

- **Decisions about API or wire behavior** are not made unilaterally. Decisions that exceed the scope stated in the README (new methods, new errors, addition / removal of arguments) must be confirmed with the user, and the README plus this document are updated *before* code is touched.
- If you find code that is **inconsistent with the README**, report it to the user and confirm which side reflects the intent. Do not silently align one with the other.
- **Adding a new dependency** requires user approval. Default-allowed dependencies: `swift-nio`, `swift-log`, `swift-atomics`. Anything else must be cleared with the user.

</section>

---

## 7. Work log (long-term memory)

> Each work-log entry is its own file under **`task_logs/YYYY-MM-DD-BRIEF.md`** (e.g. `task_logs/2026-05-09-rfc7530-audit.md`). This section is just the index — entries are listed oldest at the top, newest at the bottom, in the same chronological order as before.
>
> **At session start**: scan the index here, then `Read` the entries that look relevant to the task you are about to do. Don't try to answer "why is this code shaped this way?" or "has this been tried before?" from memory or by code-reading alone — the answers are usually in `task_logs/`.
>
> **At session end** (or after any meaningful milestone): add a new file under `task_logs/` AND link it from the index below. **Skipping either step breaks future sessions' lookup.** File body format: top-level `# YYYY-MM-DD — One-line title`, then *what* was done + *why* it was decided that way + *what to pick up next*. The on-disk filename uses a short ASCII slug for the BRIEF — keep it stable enough to grep (e.g. `rfc7530-audit`, `nio-listener`).
>
> **Lookup rule** (mandatory): when you encounter unfamiliar code, a surprising design decision, an "already tried" smell, or a regression, **search `task_logs/` aggressively before assuming the answer**. Use `grep -ri 'topic' task_logs/`, `ls task_logs/`, or scan the index below for the relevant date. Cite the entry filename in PR descriptions / responses when a past entry is the source of truth.
>
> Entries dated **2026-05-09** and onward are written in English. Entries dated 2026-05-08 and earlier are preserved in their original Korean — work-log entries are point-in-time records, so retroactive translation would erase nuance and is intentionally not performed.

### Index

- [2026-05-03 — 초기 스펙 확정](task_logs/2026-05-03-initial-spec.md)
- [2026-05-03 — Package skeleton + Public stubs + XDR](task_logs/2026-05-03-package-skeleton.md)
- [2026-05-03 — RPC + COMPOUND skeleton](task_logs/2026-05-03-rpc-compound-skeleton.md)
- [2026-05-03 — NIO listener wired](task_logs/2026-05-03-nio-listener.md)
- [2026-05-03 — FATTR4 + GETATTR + SETCLIENTID family](task_logs/2026-05-03-fattr4-getattr-setclientid.md)
- [2026-05-03 — Phase 1 op 셋 완료](task_logs/2026-05-03-phase1-ops-complete.md)
- [2026-05-03 — Mount 시뮬레이션 + 데모 executable](task_logs/2026-05-03-mount-simulation-demo.md)
- [2026-05-03 — 실 macOS mount_nfs 첫 성공](task_logs/2026-05-03-mount-nfs-first-success.md)
- [2026-05-03 — Finder copy 흐름 호환 (idmap + space attrs)](task_logs/2026-05-03-finder-copy-idmap.md)
- [2026-05-06 — throughput 1차 fix (mount opts + RPC pipelining + record-mark in-place)](task_logs/2026-05-06-throughput-fix.md)
- [2026-05-08 — Konsole.app copy 병목 1차 진단 + DemoFS 저장 구조 개선](task_logs/2026-05-08-konsole-demofs.md)
- [2026-05-08 — nanonfs core copy-elision 1차](task_logs/2026-05-08-core-copy-elision.md)
- [2026-05-09 — Public release prep + CLAUDE.md English translation](task_logs/2026-05-09-public-release-prep.md)
- [2026-05-09 — RFC 7530 reference audit + NFSStatus raw shift fix](task_logs/2026-05-09-rfc7530-audit.md)
- [2026-05-09 — RFC 5531 reference audit (follow-up to the 7530 audit)](task_logs/2026-05-09-rfc5531-audit.md)
- [2026-05-09 — RFC 4506 reference audit (third in the series; clean)](task_logs/2026-05-09-rfc4506-audit.md)
- [2026-05-09 — BSD-socket transport spec v1.1 confirmed](task_logs/2026-05-09-bsdsocket-spec-v11.md)
- [2026-05-09 — BSD-socket transport implementation (spec v1.1 landed)](task_logs/2026-05-09-bsdsocket-impl.md)

<!-- New entries: append a new bullet at the bottom of the index AND create the corresponding file in task_logs/. -->

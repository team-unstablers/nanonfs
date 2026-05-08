# CLAUDE.md — nanonfs working spec

> This document is the working spec that AI coding assistants (Claude Code et al.) and the human maintainer follow when operating on this repository.
> **nanonfs is incremental, not a one-shot project — it accumulates across sessions.** Treat this file as long-term memory and **update §7 (work log) at the end of every session**.

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
- The maintainer is a Korean speaker. Conduct conversations and plan-mode writing in **Korean** unless explicitly instructed otherwise.
- Free text addressed to the user is in Korean. Identifiers, code comments, and commit messages are written in a businesslike tone (English is the established convention in this repo) regardless of the conversation language.
- When there is important project information or a major change, update this `CLAUDE.md` so the documentation reflects the latest state.
- When you learn new facts during work (code behavior, RFC interpretations, external tool quirks, etc.), record them in §7 (work log) so future sessions can pick up the trail.
- If you cannot proceed due to missing permissions, request elevation from the user. If a command fails due to insufficient permissions, escalate it to the user for approval rather than reaching for `--no-verify`/destructive shortcuts.

## 2. Directory / module structure

```
Sources/NanoNFS/
├── Public/      # Public API. Everything that is visible when the module is imported.
├── Wire/        # NFSv4 op handling, COMPOUND dispatch, stateid / clientid / delegation management
├── RPC/         # ONC RPC (RFC 5531). AUTH_SYS parsing. Callback-channel RPC client.
├── XDR/         # XDR (RFC 4506) encoder / decoder. Pure functions plus small reader / writer.
└── Internal/    # Domain-neutral utilities — logging, async helpers, file handle mapping, etc.
```

### Allowed dependency direction (top → down only)

```
Public  →  Wire  →  RPC  →  XDR
                ↘     ↘
                  Internal
```

- **Reverse-direction imports are forbidden.** For example, `XDR` must not import any `RPC` type. `RPC` must not know about any `Wire` type.
- **`Public/` does not directly expose types from other folders.** All Wire/RPC/XDR types are `internal`. When something must be public, place a separate type in `Public/` and add a translation layer.
- **The XDR layer is unaware of NFS semantics.** `XDR` only contains generic encoders such as `xdrEncode(uint32:)`. NFSv4 struct encoding is composed in `RPC` or `Wire` from XDR primitives.
- **The Wire layer is the sole entry point for `NFSServer` calls.** `Public.NFSServerListener` only creates a NIO channel and forwards received messages to the `Wire` dispatcher.

It can be tempting to break the dependency direction in order to avoid cross-layer plumbing — **don't**. The layer separation is what enables future work like adding NFSv3 or `ByteBuffer` overloads.

---

## 3. Coding style / Concurrency

- `swift-tools-version: 6.0`. **Swift 6 strict concurrency** is not disabled.
- **All public types are `Sendable`.** When unavoidable, use `@unchecked Sendable` and document the reason in a one-line comment.
- The `NFSServer` implementation is provided by the user, but the library's recommendation is **`actor`**. Making user code safe against concurrent calls is the user's responsibility; the library does not serialize calls into user methods on its behalf.
- Library-internal state (clientid table, stateid issuance, delegation tracking, etc.) is each isolated in **its own `actor`**. No single mega-actor.
- **Do not use `@MainActor`.** This library has no UI.
- Logging always goes through `swift-log`. `print` / `NSLog` are forbidden. The `Logger` instance received by `NFSServerListener` is passed explicitly to child components.
- For places where lockless atomics suffice (counters, sequence numbers), use `swift-atomics`.
- `Foundation.Data` is used only at payload boundaries (`read` / `write` / file handle bytes). Inside hot paths (XDR encoder etc.) `ByteBuffer` is preferred.
- **Errors are `NFSError`** or library-internal error enums. If `POSIXError` / `NSError` is thrown from a user method, the Wire layer maps it to `NFS4ERR_SERVERFAULT` — the user's throw signature is not enforced, but unmapped errors **must be recorded with `logger.warning`**.

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

> When a new session starts, read this section first to understand where the work currently stands.
> When a session ends (or just after a meaningful milestone), **add a new entry without fail**.
> Format: `### YYYY-MM-DD — One-line title`. Body: *what* was done + *why* it was decided that way + *what to pick up next*.
>
> Entries dated **2026-05-09** and onward are written in English. Entries dated 2026-05-08 and earlier are preserved in their original Korean — work-log entries are point-in-time records, so retroactive translation would erase nuance and is intentionally not performed.

### 2026-05-03 — 초기 스펙 확정

- README.md 를 단순 스케치에서 **스펙 문서** 로 격상.
- 와이어 프로토콜은 **NFSv4.0 (RFC 7530) 단일** 로 고정. NFSv3, v4.1, pNFS 비지원.
- 플랫폼은 **macOS 14+** 단독.
- RPC 레이어는 **SwiftNIO 기반**, XDR 은 **직접 구현**.
- File handle 은 README 의 `inode: Int64` 스케치를 폐기하고 **NFSv4 그대로의 opaque `Data`** (`NFSFileHandle`) 로 결정.
- 인증은 **AUTH_SYS** 만. AUTH_NONE / RPCSEC_GSS 는 거부.
- 마운트는 사용자 책임 (라이브러리는 `mount_nfs` 호출하지 않음).
- 사용자 API 는 **stateid 노출 / 사용자 관리** 로 결정 — FUSE 보다 NFSv4 의미를 더 직시. OPEN/OPEN_CONFIRM/OPEN_DOWNGRADE/CLOSE 가 모두 사용자 메서드.
- 클라이언트 라이프사이클 (`SETCLIENTID`/`RENEW`/lease) 은 라이브러리 자동.
- Lock (`LOCK`/`LOCKT`/`LOCKU`) 은 사용자 메서드.
- 고급 기능 중 **Delegation 만 Phase 1 포함**. ACL / Named Attributes 는 비지원.
- Attribute 모델은 **POSIX-like `NFSStat` struct + `NFSAttributesPatch`** (FATTR4 비트맵은 라이브러리 내부에서 변환).
- 에러는 `NFSError` enum, READ/WRITE 페이로드는 `Foundation.Data`, READDIR 은 cookie/limit 직접 노출.
- Listener 는 **`run()` 프레임워크 스타일** (swift-service-lifecycle 풍).
- Swift 6.0+ / strict concurrency / NFSServer 는 모든 메서드 required (default 구현 없음).
- 기본 바인딩: `127.0.0.1`, 기본 포트: `14049` (root 회피). 외부 바인딩은 명시적 escape hatch.
- 모듈 구조: 단일 product `NanoNFS`, 폴더 분리 `Public / Wire / RPC / XDR / Internal`, 의존 방향은 `Public → Wire → RPC → XDR` 단일 방향.
- 테스트: swift-testing + 실제 mount_nfs 시나리오 1개 이상 의무.
- **다음 작업**: `Package.swift` 작성 → `Public/` 의 타입(`NFSFileHandle`, `NFSStat`, `NFSError`, `NFSServer` protocol, `NFSServerListener`) 만 먼저 컴파일 가능 stub 으로 만들기 → XDR 인코더 → RPC 메시지 프레임 → COMPOUND 디스패치 골격 → op 별 구현. 사용자와 어디서부터 시작할지 다시 합의 후 진입.

<!-- 새 엔트리는 위쪽에 추가하지 말고 아래에 누적하세요 (시간 순서대로 위→아래). -->

### 2026-05-03 — Package skeleton + Public stubs + XDR

- `Package.swift` 작성: macOS 14, swift-tools 6.0, strict concurrency. 의존성: `swift-nio` (NIO/NIOCore/NIOPosix/NIOFoundationCompat), `swift-log`, `swift-atomics`. `NIOFoundationCompat` 은 `ByteBuffer.readData(length:)` 가 거기 있어서 추가. README §2 의 기본 의존성 목록 (nio/log/atomics) 안의 nio 하위 product 셋이라 사용자 승인 절차는 생략.
- `Sources/NanoNFS/` 폴더 구조 (`Public/Wire/RPC/XDR/Internal`) 생성. `Tests/NanoNFSTests/` 도.
- `Public/` 에 README §4 의 모든 타입 스텁을 컴파일 가능한 형태로 작성 (`NFSFileHandle`, `NFSStateID`, `NFSTime`, `NFSObjectType`, `NFSStat`, `NFSAttributesPatch`, `NFSAccess`, `NFSShareAccess`, `NFSShareDeny`, `NFSDelegationHint`, `NFSOpenOwner`, `NFSLockOwner`, `NFSLockType`, `NFSLockRange`, `NFSWriteStability`, `NFSReadResult`, `NFSWriteResult`, `NFSOpenResult`, `NFSOpenFlags`, `NFSDelegationGrant`, `NFSDirEntry`, `NFSDirList`, `NFSLockTestResult`, `NFSError`, `NFSCreateMode`, `NFSBind`, `NFSServer` protocol, `NFSServerListener`).
  - **README 와의 작은 deviation**: README §4.1 이 `NFSStat.rdev: (major: UInt32, minor: UInt32)?` 라는 named-tuple 로 적혀 있는데, Swift 의 `Hashable` auto-synthesis 가 tuple field 가 있는 struct 에 대해 동작하지 않음 (tuple 자체가 `Hashable` 미준수). 그래서 `NFSStat.RDev` nested struct 로 변환. 의미는 동일. README 와 본 문서를 같이 갱신해야 할지는 다음에 사용자 확인 필요.
  - `NFSServerListener.run()` 은 아직 sleep-until-cancel stub. 실제 NIO 와이어링은 task #6 에서.
- `XDR/XDR.swift` 에 RFC 4506 primitives 구현 (XDREncoder/XDRDecoder, ByteBuffer 기반).
  - `XDRError` enum: `truncated`, `lengthExceedsLimit`, `malformedPadding`, `invalidBoolean`, `invalidUTF8`.
  - placeholder UInt32 (length backfill 용) 도구 포함 — RPC record-mark / COMPOUND op 배열 길이를 나중에 채울 때 씀.
- `XDRTests`: 16 테스트 작성 (round-trip, big-endian wire layout, 패딩, 한계값/limit 검사, truncation, UTF-8 거부 등). 전부 pass.
- **다음 작업**: RPC 레이어. RFC 5531 record-mark 프레이밍, `rpc_msg` 콜/리플라이 인코딩, AUTH_SYS credential parser, AUTH_NONE/RPCSEC_GSS 거부 (NFS4ERR_WRONGSEC 또는 RPC reject). 그 다음 COMPOUND 디스패처 스켈레톤.

### 2026-05-03 — RPC + COMPOUND skeleton

- `RPC/RPCConstants.swift`: RFC 5531 message-type, accept/reject/auth-status, flavor enums, NFSv4 program/version/procedure 상수.
- `RPC/RPCRecordMarking.swift`: 단편 헤더 (high bit = last, 31 bit = length) 인코딩/디코딩. `RPCRecordMarkingDecoder` 는 부분 fragment 를 누적하다가 last 가 오면 한 메시지 반환. `defaultMaxFragmentLength = 16 MiB` 가드.
- `RPC/RPCMessage.swift`: `rpc_msg` CALL 의 헤더(xid/mtype/rpcvers/prog/vers/proc/cred/verf) 까지 디코딩 후 args 위치의 `XDRDecoder` 를 함께 반환. `AuthSysCredential` 디코딩(machinename ≤255, gids ≤16). 응답 인코더: `rpcEncodeAcceptedReply`, `rpcEncodeAcceptError`, `rpcEncodeAuthError`, `rpcEncodeRpcMismatch`. 테스트용 `encodeRpcCall` / `encodeAuthSysBody` 도 같이.
- `RPCTests`: 12 테스트 (record-mark layout, single/multi/truncated/oversize, CALL round-trip, RPC version 검증, AUTH_SYS round-trip 및 16개 초과 거부, accepted/auth-error reply layout). 모두 pass.
- `Wire/NFSv4Constants.swift`: RFC 7530 §16.1 의 `nfs_opnum4` (`NFSOp`), §13 의 `nfsstat4` (`NFSStatus`), `NFSError → NFSStatus` 매핑.
  - **주의**: NFSStatus 에 `NFS4ERR_OP_ILLEGAL = 10044` 만 두고 `NFS4ERR_LOCK_NOTSUPP` (raw 가 같을 위험) 는 일단 제거. RFC 의 정확한 raw 가 필요해지면 §13.1 다시 확인 후 추가.
- `Wire/CompoundDispatcher.swift`: `actor CompoundDispatcher` — `dispatch(args:)` 로 COMPOUND4args 를 받아 COMPOUND4res 바이트로 반환. 구현 ops: `PUTROOTFH`/`PUTFH`/`GETFH`/`SAVEFH`/`RESTOREFH`/`ACCESS`/`LOOKUP`/`LOOKUPP`/`RENEW` (RENEW 는 임시로 success). 미구현 op 는 `NFS4ERR_NOTSUPP` 로 COMPOUND 중단. minorversion ≠ 0 → `MINOR_VERS_MISMATCH`. opcount > 4096 → `RESOURCE` 가드. RFC 7530 §15.2 ("status != OK 면 이후 op 는 평가하지 않는다") 준수.
- `CompoundDispatcherTests`: `MockServer` actor + 9 테스트 (PUTROOTFH+GETFH, PUTFH echo, LOOKUP advance, LOOKUP 실패시 후속 op 미실행, SAVE/RESTORE 스택, RESTORE without SAVE → restorefh, ACCESS mask 왕복, 미구현 op → NOTSUPP, minorversion mismatch). 전부 pass. 합계 37 테스트 모두 그린.
- **다음 작업**: NIO TCP listener 와 channel handler 를 만들어 RPC record-mark → CompoundDispatcher 까지 실제로 흐르게. AUTH_SYS 외 거부 로직(AUTH_NONE/GSS → reject). 그 다음 부족한 op (GETATTR/READDIR/READ/WRITE/CREATE/REMOVE/OPEN/CLOSE 등) 을 채우면서 FATTR4 매핑 레이어를 작성. mount_nfs 가 실제로 마운트하려면 GETATTR + FATTR4 의 mandatory attrs 가 필요.

### 2026-05-03 — NIO listener wired

- `Wire/RPCSession.swift`: 한 RPC 메시지를 받아서 (1) RPC 헤더 디코드 (2) 프로그램/버전 검사 (NFS_PROGRAM=100003, V4 외에는 PROG_UNAVAIL/PROG_MISMATCH) (3) flavor 검사 (RPCSEC_GSS → AUTH_TOO_WEAK, AUTH_SYS 외 → AUTH_TOO_WEAK, 단 NULL 에 한해 AUTH_NONE 허용) (4) AUTH_SYS body 사전 파싱 (5) NULL → empty success / COMPOUND → `CompoundDispatcher.dispatch` 위임. 응답 바이트 반환.
- `Public/NFSServerListener.swift`: 실제 NIO 와이어링. `NIOAsyncChannel<ByteBuffer, ByteBuffer>` 기반. ServerBootstrap 으로 바인딩 → 자식 채널마다 `serve` 함수가 record-mark 디코더 + 펌프 루프 실행. `withTaskCancellationHandler` 로 취소 시 server 채널 close → 정상 종료. 자체 group 을 만들면 `shutdownGracefully()` (async) 로 정리. `boundAddress` 는 actor box 로 노출.
- `ListenerIntegrationTests.swift`: 실제 loopback TCP 로 round-trip 검증.
  - `TCPClient` (테스트 전용 동기 POSIX 소켓 헬퍼) 작성. `readRecord` 가 fragment 들을 합쳐서 한 RPC reply 를 모음.
  - 테스트 3종: RPC NULL, 잘못된 program → PROG_UNAVAIL, COMPOUND PUTROOTFH+GETFH 풀 round-trip. 모두 pass.
- 합계 40 테스트 그린. 빌드 깨끗.
- **다음 작업**: 본격 op 채우기. 우선순위는 `mount_nfs` 가 실제로 mount 시점에 부르는 것들 → GETATTR + FATTR4 매핑 (mandatory attrs: SUPPORTED_ATTRS/TYPE/FH_EXPIRE_TYPE/CHANGE/SIZE/LINK_SUPPORT/SYMLINK_SUPPORT/NAMED_ATTR/FSID/UNIQUE_HANDLES/LEASE_TIME/RDATTR_ERROR/FILEHANDLE — RFC 7530 §5.6) → 그 다음 SECINFO/SETCLIENTID 응답 → READDIR → READ/WRITE → CREATE/REMOVE/RENAME → OPEN/CLOSE → LOCK. SETCLIENTID/RENEW 의 lease 관리는 라이브러리 내부 actor (`ClientRegistry`) 로.

### 2026-05-03 — FATTR4 + GETATTR + SETCLIENTID family

- `Wire/FATTR4.swift`:
  - `FATTR4` enum (attr 번호 0..55).
  - `AttrBitmap`: bitmap4 인코딩/디코딩, 정렬된 iteration. `FATTRConfig.supported` 가 nanonfs 의 응답 가능 attr 셋.
  - `encodeFattr4(stat:fileHandle:request:)` — 요청 비트맵 ∩ supported 만 emit, mandatory 전부 + 일반적 recommended 다수 (TYPE/SIZE/MODE/NUMLINKS/OWNER/OWNER_GROUP/FILEID/FILEHANDLE/SPACE_USED/RAWDEV/TIME_ACCESS/TIME_METADATA/TIME_MODIFY/TIME_DELTA/MAXFILESIZE/MAXNAME/MAXREAD/MAXWRITE/MAXLINK/MOUNTED_ON_FILEID/HOMOGENEOUS/CASE_INSENSITIVE/CASE_PRESERVING/CHOWN_RESTRICTED/NAMED_ATTR/UNIQUE_HANDLES/LINK_SUPPORT/SYMLINK_SUPPORT/CHANGE/FSID/LEASE_TIME/FH_EXPIRE_TYPE/RDATTR_ERROR/SUPPORTED_ATTRS/ACL_SUPPORT/CAN_SET_TIME/NO_TRUNC).
  - OWNER/OWNER_GROUP 는 numeric `"<uid>@nanonfs"` 포맷. macOS NFS client 가 DNS 도메인 없이도 받음.
  - CHANGE 는 mtime 으로부터 합성 (per-file change counter 는 아직 없음).
  - LEASE_TIME = 60s, MAXREAD/MAXWRITE = 1 MiB.
- `Internal/ClientRegistry.swift`: `actor ClientRegistry`. SETCLIENTID 시 clientid + confirm verifier 발급 (atomic counter 로 충돌 방지). SETCLIENTID_CONFIRM 으로 확정. RENEW 가 lease 윈도우 갱신; lease × 2 초과 시 expire 처리. owner-name → confirmed clientid 인덱스로 RFC 7530 §16.34.5 의 same-owner-different-verifier 케이스 (CLID_INUSE) 대응.
- `Wire/CompoundDispatcher.swift`: 새 op 들 — GETATTR, SETCLIENTID, SETCLIENTID_CONFIRM, RENEW (registry 사용), SECINFO (AUTH_SYS 1개로 응답). 이 시점부터 `CompoundDispatcher` 가 `ClientRegistry` 를 보유.
- 테스트 11개 추가 (FATTR bitmap round-trip, iteration order, emit subset, value layout, GETATTR framing, ClientRegistry 4 케이스, dispatcher 통합 GETATTR/SETCLIENTID flow). 합계 51 그린.
- **다음 작업**: SETATTR (FATTR4 디코딩 → `NFSAttributesPatch`), READDIR (cookie/verifier + 엔트리당 임베디드 GETATTR), READ/WRITE/COMMIT, CREATE/REMOVE/RENAME/LINK/READLINK, 그 다음 OPEN/CLOSE 와 LOCK. mount_nfs 실연 테스트는 OPEN/CLOSE/READ/WRITE 다 들어간 다음.

### 2026-05-03 — Phase 1 op 셋 완료

- `Wire/SetattrDecoder.swift`: SETATTR 의 fattr4 → `NFSAttributesPatch` 디코딩. mode/owner/owner_group/size/time_access_set/time_modify_set 만 허용. 그 외는 `readonlyAttr` (→ NFS4ERR_INVAL) 또는 `unsupportedAttr` (→ NFS4ERR_ATTRNOTSUPP). owner string 은 `"<digits>@<domain>"` 만.
- `Wire/CompoundDispatcher.swift` 가 다음 op 를 모두 디스패치:
  - SETATTR, READDIR, READLINK
  - READ, WRITE, COMMIT
  - CREATE (regular file 은 거부 — OPEN 으로), REMOVE, RENAME (saved fh = 소스, current = 타겟), LINK (saved fh = 링크 대상)
  - OPEN (CLAIM_NULL 만), OPEN_CONFIRM, OPEN_DOWNGRADE, CLOSE (seqid+1 자동 bump)
  - LOCK / LOCKT / LOCKU (NFSError.lockDenied → LOCK4denied 인코딩)
  - RELEASE_LOCKOWNER (no-op, 단 args 소비)
- 헬퍼: `decodeStateid`, `encodeStateid`, `encodeChangeInfo` (atomic=false, before==after = ns since epoch), `encodeOpenDelegation` (NONE/READ/WRITE 인코딩 + 기본 EVERYONE@ ACE), `encodeLockDenied`.
- 테스트 추가: SETATTR/READDIR 7건, READ/WRITE/COMMIT/OPEN/CLOSE/REMOVE 5건. 합계 63 그린.
- 알려진 한계 (Phase 2 또는 후일):
  - CREATE 에서 SymLink target / blockDev rdev 정보를 사용자 메서드에 전달하는 채널이 없음 (`NFSAttributesPatch` 가 아직 그 두 개 안 받음). 현재는 디코드 후 무시.
  - READDIR 응답에서 per-entry FATTR4_FILEHANDLE 가 부모 fh 로 채워짐 — `NFSDirEntry` 에 per-entry fh 필드가 없기 때문. 진짜 동작하려면 README §4.3 의 `NFSDirEntry` 에 `handle: NFSFileHandle?` 추가 필요.
  - OPEN 의 `wantDelegation` 힌트는 항상 `.none` 으로 사용자 메서드에 전달 (와이어에서 힌트 비트가 OPEN args 에 명시적으로 안 옴 — Phase 2 정리 필요).
  - Delegation CB_RECALL 콜백 채널 RPC 클라이언트 미구현.
  - `change_info4.before/after` 가 같은 값으로 emit 되어 클라이언트의 atomic-vs-non-atomic 검증이 약해짐.
- **다음 작업**: 실제 `mount_nfs` 통합 테스트. macOS 14+, 루트 권한 필요. macOS NFS 클라이언트가 mount 시퀀스에서 정확히 어떤 COMPOUND/op 를 보내는지가 이번 라운드의 큰 미지수 (특히 NFSv4.0 over high port + nolocks 옵션 조합). 일단 readonly 1 파일만 노출하는 데모 서버 + `Tests/Mount/MountNFSIntegrationTests.swift` 만들어서 sudo 환경에서 돌리는 형태로 골격만 짜고, 실제 마운트가 깨지면 RFC 복귀해서 missing piece 보강. 이후 README 업데이트 (FILE handle 한계, NFSDirEntry 확장 안 등).

### 2026-05-03 — Mount 시뮬레이션 + 데모 executable

- `Sources/NanoNFSDemo/main.swift`: `swift run NanoNFSDemo` 으로 14049 포트에 데모 서버를 띄우는 executable. `/hello.txt` (rw, "Hello, NFS world!\n"), `/readme` (read-only) 두 파일을 노출. Phase 1 의 모든 메서드를 구현해놓아서 실제 `sudo mount_nfs` 의 도달 가능 op 들을 다 받음.
- `Tests/NanoNFSTests/MountSimulationTests.swift`: 진짜 `mount_nfs` 를 부르지 않는 대신 실제 loopback TCP 위에서 NFSv4.0 클라이언트가 mount 시점에 보내는 COMPOUND 시퀀스를 직접 인코딩해 보내고 응답 status 를 검사. 테스트 시퀀스: SETCLIENTID → SETCLIENTID_CONFIRM → PUTROOTFH+GETATTR(요청 attrs 23개) → PUTROOTFH+READDIR → PUTROOTFH+LOOKUP+GETATTR → PUTROOTFH+LOOKUP+OPEN+READ. 마지막 READ payload 가 `"Hello, NFS world!\n"` 와 일치함을 확인.
  - 헬퍼: `SimClient` (XID 카운터, AUTH_SYS 기본 cred, COMPOUND/SETCLIENTID 인코딩, RPC accepted-reply 헤더 스킵, 응답 status 단정, READ payload 추출용 op-별 body 디코더).
- `XidGen` 은 strict-concurrency 충족을 위해 `final class @unchecked Sendable` 로 — 테스트가 단일 스레드에서 도는 게 자명한 케이스라 충분.
- 합계 64 테스트 그린. 빌드 깨끗.
- `README.md` 에 §5.5 추가: 실제 `sudo mount_nfs` 검증 가이드 (수동 단계). Phase 1 자동 테스트는 mock + loopback 시뮬레이션까지로 정리. 진짜 mount 검증은 사용자/다음 세션에서 sudo 환경에서 수행.
- **다음 작업 / 알려진 한계**:
  - 실제 macOS `mount_nfs` 시도 시 어떤 op 가 추가로 필요한지 (예: `OPENATTR` 거부 처리가 클라이언트에서 어떻게 진행되는지, `SECINFO_NO_NAME` 같은 NFSv4.1 op 가 NFSv4.0 에서도 호출되는지) 는 실험으로 확인 필요. 마운트 실패하면 dispatcher 로그 (debug) 에서 op + status 를 보고 보강.
  - `NFSDirEntry` 가 per-entry handle 을 갖지 않아서 READDIR + GETATTR(FILEHANDLE) 시 부모 fh 를 잘못 emit. `mount_nfs` 가 readdir-with-fh 를 적극 사용하면 깨질 수 있음. 사용자와 합의 후 README §4.3 의 `NFSDirEntry` 에 `handle: NFSFileHandle?` 필드 추가하는 것이 깔끔.
  - CREATE 의 symlink target / device rdev 가 `NFSAttributesPatch` 로 전달되지 않음. README §4.5 의 `create(parent:name:type:attrs:)` 시그니처 확장 (또는 `NFSAttributesPatch` 에 옵션 필드 추가) 가 필요.
  - Delegation `wantDelegation` 힌트가 클라이언트의 OPEN args 에서 어떤 비트로 들어오는지 — 실제로는 `OPEN4_share_access` 의 high bits (RFC 7530 §16.16.4) 에 OPEN4_SHARE_ACCESS_WANT_* 가 들어가는 패턴. 현재 dispatcher 가 share_access 를 mask 의 low 2비트만 보고 high bits 는 무시 → 사용자에게 `wantDelegation: .none` 고정으로 전달. 추후 정리.
  - CB_RECALL 콜백 채널은 미구현. delegation 발급 후 클라이언트가 conflicting OPEN 을 보내도 회수가 안 됨 (사용자가 수동으로 `.none` 만 발급하면 안전).
  - `change_info4.before == after` 라서 atomic 검증이 약함. 디렉토리별 카운터 도입은 사용자 메서드 시그니처 변경 없이 라이브러리 내부에 hash(parentFh) → counter 로 가능.

### 2026-05-03 — 실 macOS mount_nfs 첫 성공

- 형아 보고: `nolocks` 옵션을 빼니까 `sudo mount_nfs -o vers=4,port=14049,mountport=14049,tcp,resvport=0 127.0.0.1:/ /mnt/nanonfs` 가 마운트됨!
- 즉 README §5.5 의 mount 명령에서 `nolocks` 는 빼야 한다. macOS mount_nfs 의 `nolocks` 는 NFSv4 모드에서도 NLM 을 끄려고 시도하지만, 결과적으로 마운트 자체를 거부하는 동작이 있는 것으로 보임 (정확한 이유는 추후 조사).
- README §5.5 의 예시 명령에서 `nolocks` 제거 필요. (다음 코드 변경에서 반영.)

### 2026-05-03 — Finder copy 흐름 호환 (idmap + space attrs)

- 형아 보고: TextEdit 으로 hello.txt 저장은 OK. Finder 로 다른 디렉토리에서 nanonfs 마운트로 파일 *복사* 는 "충분한 공간이 없기 때문에 ‘taiko.mp4’ 항목을 복사할 수 없습니다." 로 실패. 데모 로그에 `compound op 3/6 open → badxdr` 가 한 번 + 그 외 다수의 `lookup → noent` (정상; 클라이언트가 임시 이름 미리 lookup 해보는 패턴).
- 진단:
  1. **OPEN BADXDR**: macOS NFS 클라이언트 (idmapd 활성) 가 OPEN 의 createattrs(fattr4) 안 owner/owner_group 을 `"username@domain.local"` 형식으로 보냄. `SetattrDecoder.parseOwnerNumeric` 가 숫자 prefix 없으면 `invalidOwnerString` throw → OPEN 의 default catch 가 BADXDR 로 매핑. 결과적으로 새 파일 생성이 와이어 단계에서 거절.
  2. **"공간 부족"**: Finder 가 destination free space 를 사전 검사. FATTR4 응답에 `space_avail`/`space_free`/`space_total` 가 없어서 클라이언트가 0 으로 해석.
- 수정:
  1. `SetattrDecoder`: owner / owner_group 의 numeric 파싱 실패 시 그 attr 한 칸만 **silent skip** (patch + attrsSet 둘 다 빼고 다른 attr 는 정상 처리). idmapd-on macOS 와 호환.
  2. `FATTRConfig.supported` 에 `.spaceAvail/.spaceFree/.spaceTotal/.filesAvail/.filesFree/.filesTotal` 추가. `space_*` = 1 TiB, `files_*` = 4 G inode 로 합성. `encodeFattr4` 에 케이스 추가.
  3. OPEN / CREATE 의 catch 에 `SetattrDecodeError.invalidOwnerString → NFS4ERR_BADOWNER` 케이스 추가 (decoder 가 이제 silent skip 하니 도달성은 낮지만 방어적).
- 기존 테스트 "Owner string with non-numeric prefix is invalid" → "...silently skipped" 로 정책에 맞게 수정. 64 테스트 그대로 그린.
- **다음**: 형아 재시도 → Finder 복사 통과 여부 + debug 로그에 새로운 fail op 가 있는지 확인.

### 2026-05-06 — throughput 1차 fix (mount opts + RPC pipelining + record-mark in-place)

- 형아 보고: 마운트 / Finder 복사는 동작하지만 throughput 이 수 MB/s 미만으로 매우 낮음. 큰 파일 read/write 둘 다.
- 1차 진단 — mount option 문제: 작업 로그의 mount 명령에 `rsize=`/`wsize=` 가 없어 macOS 기본값 (대개 32K) 으로 협상. `rsize=1048576,wsize=1048576` 명시하니 즉시 개선됨. **다음 README 갱신 시 §5.5 의 mount 예시에 두 옵션 박아야 함.**
- 형아 추가 질문 "dsize 도 어나운스?" → RFC 7530 §5.8 attr 표 (lines 2200–2310) 에 directory-read prefer-size 류 attr 없음. macOS `man mount_nfs` 의 `dsize=#` (= `readdirsize`) 는 클라이언트 사이드 mount 옵션이라 서버가 광고할 자리가 아님. 형아가 mount 명령에 직접 `dsize=1048576` 추가.
- 2차 fix — 코드 핫패스 재정비 (Fix 1–4 한 묶음):
  1. **Fix 2 / `CompoundDispatcher` actor → `final class Sendable`** (`Wire/CompoundDispatcher.swift`). 사실상 mutable 상태가 없어서 actor 격리 풀어도 안전. `clients: ClientRegistry` 의 actor 격리는 그대로 유지.
  2. **Fix 1 / Per-connection RPC pipelining** (`Public/NFSServerListener.swift`). `serve` 의 단일 pumping 루프를 reader / writer / dispatch-pool 3-역할로 재구성:
     - Reader (outer body): record-mark 디코드만, 메시지마다 dispatch task spawn.
     - Dispatch task (inner `withThrowingDiscardingTaskGroup`): `handleSingleRpcMessage` → `replyCont.yield`.
     - Writer (sibling task): `AsyncStream<ByteBuffer>` 컨슘해서 `outbound.write` (NIOAsyncChannel single-writer 가정 충족).
     - in-flight 상한 = 64 (`maxInFlightRequestsPerConnection` 상수 + 새 `AsyncSemaphore` actor). NFSv4 응답이 xid 매칭이라 unordered write 안전 (RFC 5531 §9).
  3. **Fix 3 / record-mark in-place patch** (`RPC/RPCMessage.swift`). `rpcEncodeAcceptedReply`/`AcceptError`/`AuthError`/`RpcMismatch` 가 응답 빌드 시작점에서 4바이트 placeholder 를 reserve → 인코딩 끝나면 `finishRecordMark` 가 in-place set. production 에서 `rpcWrapSingleFragment` 호출이 사라져 wrap-buffer 복사 1회 제거. `rpcWrapSingleFragment` 자체는 테스트 클라이언트 측에서 여전히 사용 중이라 함수는 유지.
  4. **Fix 4 / inbound 누적 zero-copy fast path**: `pending.readableBytes == 0` 이면 inbound chunk 를 그대로 채택 (`pending = chunk`). NFS 가 single-fragment 경향이라 자주 매칭.
- 테스트:
  - 기존 64 테스트 그대로 통과.
  - 신규: `Pipelined NULL RPCs all complete on a single connection` (`ListenerIntegrationTests.swift`) — 한 conn 위에 64개 NULL 을 back-to-back 발사 후 모든 xid 가 매칭되는지 확인. unordered 응답 가능성도 spec-legal 로 표기. 합계 65 그린.
  - `RPCTests` 의 reply layout 두 케이스에 record-mark 헤더 검증 추가.
- 보류 항목 (Fix 5):
  - WRITE/READ 의 `data: Data` 시그니처는 형아 결정으로 보류. 진짜 zero-copy 까지 가려면 `NFSServer.read`/`write` 의 ByteBuffer 오버로드 + README §4 변경 필요. Phase 2.
- 알려진 운영 잡음 (개선 후보):
  - 정상 connection 종료 시 `inbound ended: CancellationError()` info 로그가 한 conn 당 한 번 출력. teardown 경로에서 `CancellationError` 만 swallow 하는 게 깔끔.
- **다음**: 형아의 실 측정 (`dd`, Finder copy) 으로 read/write throughput 변화량 확인. 기대치 보다 낮으면 (a) Fix 5 (Data ↔ ByteBuffer) 합의 후 진입, (b) Instruments time profiler 로 응답 빌드 핫스팟 (`encodeFattr4`/READDIR 인코딩) 추가 점검.

### 2026-05-08 — Konsole.app copy 병목 1차 진단 + DemoFS 저장 구조 개선

- 형아 보고: `/Applications/konsole.app` 을 데모 서버로 복사할 때 매우 느림.
- 로컬 확인: Konsole.app 은 약 357 MiB, regular file 7543개, directory 921개, symlink 443개. 단일 대형 파일 throughput 보다 metadata-heavy bundle copy 병목이 잘 드러나는 케이스.
- 1차 원인: `Sources/NanoNFSDemo/main.swift` 의 `DemoFS.Entry` 가 값 타입 struct 이고 `content: Data` 를 딕셔너리에 저장함. `write` 에서 `guard var e = entries[handle]` 로 꺼낸 뒤 `e.content.replaceSubrange` 후 다시 `entries[handle] = e` 하는 패턴은 Data COW 때문에 chunk write 마다 기존 파일 내용을 다시 복사할 수 있어 큰 파일에서 O(n²) 에 가까워짐.
- 수정:
  - `Entry` 를 actor 내부 private `final class` 로 바꿔 dictionary lookup 이 entry reference 를 돌려주게 함. `setattr(size:)`, `create`, `remove`, `rename`, `write` 는 entry reference 를 직접 mutate 하도록 정리해서 기존 content 전체 COW 복사를 피함.
  - `setattr(size:)` shrink 는 `prefix` 재할당 대신 `removeSubrange`, grow/write 는 `reserveCapacity` 후 zero fill.
  - `DemoFS.readdir` 이 이제 `maxEntries` 와 cookie 를 존중하고, `NFSDirEntry.fileHandle` 을 per-entry fh 로 채움. Finder 가 READDIR 에서 FATTR4_FILEHANDLE 을 요청하는 경로의 잘못된 parent-fh fallback 을 피하기 위함.
  - README §5.5 와 demo log 의 mount 예시를 `rsize=1048576,wsize=1048576,dsize=1048576` 포함 형태로 갱신.
- 테스트: `swift test` 65개 전부 통과.
- 남은 이슈:
  - Konsole.app 에 symlink 가 443개 있는데, 현재 dispatcher 는 CREATE symlink target 을 디코드만 하고 `NFSServer.create` 로 전달하지 못함. DemoFS 도 symlink target 을 보존하지 못하고 `readlink` 는 invalid. 성능과 별개로 app bundle correctness 를 위해 README/API 확장 합의가 필요.
  - 여전히 `NFSServer.read/write` 는 `Data` API 라서 wire ↔ Data 복사가 남음. 이번 수정은 demo storage COW 병목 제거이고, 진짜 zero-copy 는 ByteBuffer 오버로드 설계가 필요.

### 2026-05-08 — nanonfs core copy-elision 1차

- 형아 요청: demo server 보다 nanonfs 자체의 performance 개선 필요.
- 공개 API 변경 없이 가능한 core copy-elision 을 먼저 적용:
  - `RPCRecordMarkingDecoder.step` 에 single-fragment fast path 추가. macOS NFS WRITE 는 보통 single fragment 로 들어오므로, 기존처럼 `pendingFragments.writeBuffer(&slice)` 로 RPC body 전체를 accumulator 에 복사하지 않고 바로 slice 를 message 로 반환. multi-fragment 의 첫 fragment 도 accumulator copy 대신 slice 보관.
  - `XDREncoder` 에 `writeFixedOpaque(_ bytes: ByteBuffer)` / `writeVariableOpaque(_ bytes: ByteBuffer)` 추가. ByteBuffer payload 를 XDR opaque 로 감쌀 때 `Data(readableBytesView)` 중간 변환을 피함.
  - `XDREncoder.writeString` 이 `Data(s.utf8)` 대신 `s.utf8` collection 을 바로 씀.
  - `encodeGetattrResult` 와 READDIR entry attr encoding 에서 `ByteBuffer -> Data -> ByteBuffer` 재포장 제거.
- 테스트: `swift test` 65개 전부 통과.
- 남은 큰 병목: `NFSServer.read/write` 공개 API 가 `Data` 라서 WRITE 는 XDR payload 를 결국 Data 로 복사하고, READ 는 user Data 를 ByteBuffer 로 다시 복사한다. 이걸 없애려면 README/API 를 먼저 바꾸고 ByteBuffer 오버로드 또는 별도 fast-path protocol 을 추가해야 함.

### 2026-05-09 — Public release prep + CLAUDE.md English translation

- Repo prep for the upcoming public switch:
  - Added a "vibe-coded with Claude Code" notice plus Noctiluca attribution at the top of both `README.md` and `README.ko.md` (commit `ac33205`). The Korean copy retained the user-supplied wording ("`[Noctiluca](https://noctiluca.app)` 의 오픈 소스 컴포넌트 중 하나이지만, 사용 전에는 충분한 내부 검증이 필요할 수도 있습니다."), the English copy was rephrased to match the same tone.
  - Added a third-party content notice at the bottom of `LICENSE` clarifying that `docs/rfc7530.txt` is a verbatim IETF RFC under BCP 78 plus the IETF Trust's Legal Provisions, not under the nanonfs MIT license (commit `cc03a7e`).
  - Settled on the recommended `mount_nfs` option set: `vers=4,port=$PORT,mountport=$PORT,tcp,rsize=1048576,wsize=1048576,dsize=1048576,actimeo=30,noatime,async`. Confirmed by the user that this option set, paired with a user-writable mount point such as `~/nanonfs_test`, allows both `mount_nfs` and `umount` to be invoked **without sudo** as the ordinary user that started the server. README §5.5 (both languages) and the demo `main.swift` comment + `logger.info` line were updated accordingly. The fact is also captured in agent memory under `nanonfs_mount_unprivileged.md`.
  - Decided to keep the supported platform at **macOS 14+ only** even though the library proper has no Darwin-specific imports — only the integration test's raw socket helper imports `Darwin`. This preserves the README §1 narrative ("macFUSE alternative for macOS") and avoids committing to validation surfaces that have not been exercised.
  - GitHub repo metadata plan (no auto-action taken): description = "Write a virtual file system in Swift with a FUSE-like callback API — mount it on macOS via the built-in NFS client, no kernel extensions."; website = `https://noctiluca.app`. Suggested topics: `nfs`, `nfsv4`, `swift`, `swift-package`, `macos`, `fuse`, `filesystem`, `loopback`.
- Translated `CLAUDE.md` (§0 plus §1–§6) into English and introduced an explicit `# AGENT RULES` block. §1 is now an "Interaction & Language" section that codifies the existing global rules (ask-don't-guess, conduct conversations in Korean, escalate on permission failure, businesslike English in code/comments/commits). Older work-log entries (2026-05-03 / 2026-05-06 / 2026-05-08) are intentionally preserved verbatim in Korean — work-log entries are point-in-time records, retroactive translation would erase nuance.
- **Next**: pick up Phase 2 candidates listed in the prior 2026-05-08 entry — most importantly the `NFSServer.read`/`write` `Data` ↔ `ByteBuffer` overload design (the remaining real copy on the WRITE/READ hot path) and CREATE symlink target / device rdev plumbing. CB_RECALL callback channel remains unimplemented and is required before delegations can be granted with anything other than `.none`.

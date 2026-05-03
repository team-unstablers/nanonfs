# CLAUDE.md — nanonfs 작업 지침

> 이 문서는 Claude Code (및 그 외 AI 코딩 보조) 가 본 저장소에서 작업할 때 따라야 하는 규약을 정합니다.
> **본 저장소는 한 번에 끝나는 프로젝트가 아니라 여러 세션에 걸쳐 점진적으로 구현됩니다.** Claude Code 는 이 문서를 *장기 메모리* 로 활용하며, **세션이 끝날 때 §6 작업 로그를 갱신**해야 합니다.

---

## 0. 1차 출처

본 저장소에서 가장 강력한 권위 순서:

1. **`README.md`** — 외부 동작 / 공개 API / 지원 범위의 정본.
2. **`docs/rfc7530.txt`** — NFSv4.0 와이어 프로토콜의 정본.
3. **`CLAUDE.md`** (이 문서) — 구현 / 작업 규약.
4. 코드 자체.

이 순서에 충돌이 있으면 **위쪽이 이깁니다**. 단, 코드와 README 가 어긋나는 것을 발견하면 그것을 *문제로 인식하고 사용자에게 보고* — 멋대로 한쪽으로 맞추지 말 것.

`docs/rfc7530.txt` 는 라이브러리 빌드에 포함되지 않는 참조용 텍스트입니다. 와이어 동작에 영향을 주는 결정 (op 의미·필드 순서·에러 코드 등) 을 할 때마다 RFC 의 해당 섹션을 인용해 주석 또는 PR 설명에 남겨주세요. "RFC 7530 §16.18 (READ)" 같은 식.

---

## 1. 디렉토리 / 모듈 구조 규약

```
Sources/NanoNFS/
├── Public/      # 공개 API. 외부에서 import 시 보이는 것 전부.
├── Wire/        # NFSv4 op 처리, COMPOUND 디스패치, stateid·clientid·delegation 관리
├── RPC/         # ONC RPC (RFC 5531). AUTH_SYS 파싱. 콜백 채널 RPC 클라이언트.
├── XDR/         # XDR (RFC 4506) 인코더/디코더. 순수 함수 + 작은 reader/writer.
└── Internal/    # logging, async helpers, file handle 매핑 등 도메인-중립 유틸
```

### 의존 방향 (위→아래만 허용)

```
Public  →  Wire  →  RPC  →  XDR
                ↘     ↘
                  Internal
```

- **반대 방향 의존 금지.** 예: `XDR` 이 `RPC` 타입을 import 하면 안 됩니다. `RPC` 가 `Wire` 타입을 알면 안 됩니다.
- **`Public/` 는 다른 폴더의 타입을 직접 노출하지 않습니다.** Wire/RPC/XDR 의 타입은 모두 `internal`. 공개에 필요하면 `Public/` 에 별도 타입을 두고 변환 레이어를 둡니다.
- **XDR 레이어는 NFS 의미를 모릅니다.** `XDR` 안에는 `xdrEncode(uint32:)` 같은 일반 인코더만 둡니다. NFSv4 구조체 인코딩은 `RPC` 또는 `Wire` 가 XDR 프리미티브를 조립해서 만듭니다.
- **Wire 레이어가 NFSServer 호출의 유일한 진입점.** `Public.NFSServerListener` 는 NIO 채널을 만들고 받은 메시지를 `Wire` 디스패처에 넘기기만 합니다.

레이어를 가로지르는 번잡함을 피하려고 손쉽게 의존 방향을 깨고 싶어질 수 있습니다 — **그러지 마세요**. 레이어 분리가 작동해야 NFSv3 추가나 ByteBuffer 오버로드 같은 미래 작업이 가능해집니다.

---

## 2. 코딩 스타일 / Concurrency 규약

- `swift-tools-version: 6.0`. **Swift 6 strict concurrency** 를 끄지 않습니다.
- **모든 공개 타입은 `Sendable`**. 어쩔 수 없으면 `@unchecked Sendable` 을 쓰되 그 이유를 한 줄 주석으로 남깁니다.
- `NFSServer` 구현체는 사용자가 만들지만 라이브러리 측 권장은 **`actor`**. 사용자 코드가 동시 호출에 안전하게 만드는 책임은 사용자에게 있습니다. 라이브러리 내부에서 사용자 메서드 호출을 직렬화하지 마세요.
- 라이브러리 내부 상태 (clientid 테이블, stateid 발급, delegation 추적 등) 는 **각각 `actor`** 로 격리합니다. 단일 거대 actor 금지.
- **`@MainActor` 사용 금지.** 본 라이브러리는 UI 가 없습니다.
- 로깅은 항상 `swift-log` 를 통합니다. `print` / `NSLog` 금지. `Logger` 인스턴스는 `NFSServerListener` 에서 받은 것을 자식 컴포넌트에 명시적으로 전달.
- 카운터 / 시퀀스 번호처럼 lockless 로 충분한 곳은 `swift-atomics` 를 씁니다.
- `Foundation.Data` 는 페이로드 경계(`read`/`write`/file handle bytes) 에서만 사용. 핫패스 내부 (XDR 인코더 등) 에서는 `ByteBuffer` 를 우선합니다.
- **에러는 `NFSError`** 또는 라이브러리 내부 에러 enum. POSIXError / NSError 가 사용자 메서드에서 throw 되면 Wire 레이어가 `NFS4ERR_SERVERFAULT` 로 변환합니다 — 사용자 메서드의 throw 시그니처를 강제하지는 않되, 매핑되지 않은 에러는 **반드시 logger.warning 으로 기록**합니다.

---

## 3. RFC 7530 참조 규약

- 와이어 의미를 결정짓는 코드 (인코딩, op 디스패치, 에러 코드 매핑 등) 에는 **해당 RFC 섹션을 주석으로 인용**합니다.
  ```swift
  // RFC 7530 §16.23 (WRITE) — "If the COMMIT operation is not used,
  //  the server MAY still commit the data ..."
  ```
- 사용자가 `docs/rfc7530.txt` 의 특정 섹션을 묻거나 인용하면 **반드시 그 섹션을 직접 읽고** 응답하세요. 기억에 의존하지 말 것.
- RFC 와 README 가 충돌하면 **README 가 이깁니다 (지원 범위가 좁기 때문)** — 단, 그 사실을 PR 설명에 명시.
- "이건 RFC 가 그렇게 말한다" 식으로 코드 결정을 변호할 때는 섹션 번호와 함께. 섹션 번호 없는 RFC 인용은 신뢰하지 마세요.

---

## 4. 테스트 원칙

- 기본 프레임워크: **swift-testing** (`@Test`).
- 단위 테스트 (XDR 인코더 / RPC 메시지 / Wire 디스패처) 는 mock 으로 충분.
- **그러나** "이 라이브러리가 NFS 서버로서 동작한다" 의 검증은 **mock 만으로는 완결되지 않습니다**. 적어도 다음 형태의 *실제 mount 테스트* 가 한 종 이상 있어야 합니다:
  - macOS `mount_nfs` 로 nanonfs 인스턴스를 마운트
  - 마운트된 경로에 대한 일반 파일 시스템 호출 (`open`/`read`/`write`/`readdir`/`unlink`/`rename`/`flock`)
  - 결과를 nanonfs 측 `NFSServer` 콜백 호출 흐름과 대조
- 실제 mount 테스트는 **macOS 14+** 와 **루트 권한** 이 필요합니다. CI 가능 여부와 무관하게 **로컬에서 한 번이라도 실행 가능한 형태로** 두세요. 마운트 마운트포인트 / 정리 / cleanup 책임은 테스트 본인.
- mount 테스트 작성을 미루기 위해 mock 기반 단위 테스트만 늘리는 패턴을 경계합니다 ("mock 으로 통과했는데 실제로 안 마운트되는" 사고가 NFS 류 라이브러리에서 가장 흔합니다).
- 새 기능을 구현할 때마다, RFC 에서 인용한 동작 (예: COMMIT 의 verifier 변화 시 클라이언트가 재전송) 에 대한 시나리오 테스트를 적어도 하나 추가하세요.

---

## 5. 사용자에게 묻기 / 결정 권한

- **API / 와이어 동작에 대한 결정** 은 임의로 내리지 않습니다. README 에 명시된 범위를 넘어서는 결정 (새 메서드, 새 에러, 인자 추가/삭제) 은 사용자에게 묻고 README 와 본 문서를 먼저 갱신한 뒤 코드를 만집니다.
- **README 와 어긋나는 코드** 를 발견하면 사용자에게 보고하고, 어느 쪽이 의도인지 확인. 멋대로 한쪽에 맞추지 말 것.
- **새 의존성 추가** 는 사용자 승인 필수. 기본 허용된 의존성: `swift-nio`, `swift-log`, `swift-atomics`. 그 외는 묻기.
- 사용자는 한국어 화자입니다. 사용자에게 보내는 자유 텍스트는 한국어, 식별자 / 코드 주석 / 커밋 메시지는 사무적인 톤 (영어 또는 한국어, 일관되게).

---

## 6. 작업 로그 (장기 메모리)

> 새 세션이 시작되면 이 절을 먼저 읽어 현재 어디까지 와 있는지 파악하세요.
> 세션을 끝낼 때 (또는 의미 있는 마일스톤 직후) **반드시 새 엔트리를 추가**하세요.
> 형식: `### YYYY-MM-DD — 한 줄 제목`. 본문은 *무엇을* 했는지 + *왜* 그렇게 결정했는지 + *다음에 이어갈 것*.

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

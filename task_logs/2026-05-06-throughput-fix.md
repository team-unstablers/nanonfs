# 2026-05-06 — throughput 1차 fix (mount opts + RPC pipelining + record-mark in-place)

- 형아 보고: 마운트 / Finder 복사는 동작하지만 throughput 이 수 MB/s 미만으로 매우 낮음. 큰 파일 read/write 둘 다.
- 1차 진단 — mount option 문제: 작업 로그의 mount 명령에 `rsize=`/`wsize=` 가 없어 macOS 기본값 (대개 32K) 으로 협상. `rsize=1048576,wsize=1048576` 명시하니 즉시 개선됨. **다음 README 갱신 시 §5.5 의 mount 예시에 두 옵션 박아야 함.**
- 형아 추가 질문 "dsize 도 어나운스?" → RFC 7530 §5.6/§5.7 attr 표 (REQUIRED + RECOMMENDED, lines ~2225–2310) 에 directory-read prefer-size 류 attr 없음. macOS `man mount_nfs` 의 `dsize=#` (= `readdirsize`) 는 클라이언트 사이드 mount 옵션이라 서버가 광고할 자리가 아님. 형아가 mount 명령에 직접 `dsize=1048576` 추가.
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

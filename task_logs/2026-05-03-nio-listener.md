# 2026-05-03 — NIO listener wired

- `Wire/RPCSession.swift`: 한 RPC 메시지를 받아서 (1) RPC 헤더 디코드 (2) 프로그램/버전 검사 (NFS_PROGRAM=100003, V4 외에는 PROG_UNAVAIL/PROG_MISMATCH) (3) flavor 검사 (RPCSEC_GSS → AUTH_TOO_WEAK, AUTH_SYS 외 → AUTH_TOO_WEAK, 단 NULL 에 한해 AUTH_NONE 허용) (4) AUTH_SYS body 사전 파싱 (5) NULL → empty success / COMPOUND → `CompoundDispatcher.dispatch` 위임. 응답 바이트 반환.
- `Public/NFSServerListener.swift`: 실제 NIO 와이어링. `NIOAsyncChannel<ByteBuffer, ByteBuffer>` 기반. ServerBootstrap 으로 바인딩 → 자식 채널마다 `serve` 함수가 record-mark 디코더 + 펌프 루프 실행. `withTaskCancellationHandler` 로 취소 시 server 채널 close → 정상 종료. 자체 group 을 만들면 `shutdownGracefully()` (async) 로 정리. `boundAddress` 는 actor box 로 노출.
- `ListenerIntegrationTests.swift`: 실제 loopback TCP 로 round-trip 검증.
  - `TCPClient` (테스트 전용 동기 POSIX 소켓 헬퍼) 작성. `readRecord` 가 fragment 들을 합쳐서 한 RPC reply 를 모음.
  - 테스트 3종: RPC NULL, 잘못된 program → PROG_UNAVAIL, COMPOUND PUTROOTFH+GETFH 풀 round-trip. 모두 pass.
- 합계 40 테스트 그린. 빌드 깨끗.
- **다음 작업**: 본격 op 채우기. 우선순위는 `mount_nfs` 가 실제로 mount 시점에 부르는 것들 → GETATTR + FATTR4 매핑 (mandatory attrs: SUPPORTED_ATTRS/TYPE/FH_EXPIRE_TYPE/CHANGE/SIZE/LINK_SUPPORT/SYMLINK_SUPPORT/NAMED_ATTR/FSID/UNIQUE_HANDLES/LEASE_TIME/RDATTR_ERROR/FILEHANDLE — RFC 7530 §5.6) → 그 다음 SECINFO/SETCLIENTID 응답 → READDIR → READ/WRITE → CREATE/REMOVE/RENAME → OPEN/CLOSE → LOCK. SETCLIENTID/RENEW 의 lease 관리는 라이브러리 내부 actor (`ClientRegistry`) 로.

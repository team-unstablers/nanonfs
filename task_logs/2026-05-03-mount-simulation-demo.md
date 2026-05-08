# 2026-05-03 — Mount 시뮬레이션 + 데모 executable

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
  - Delegation `wantDelegation` 힌트는 RFC 7530 의 OPEN args (§16.16.2) 에 비트 자리가 없음 — `OPEN4_SHARE_ACCESS_WANT_*` 는 NFSv4.1 (RFC 5661) 추가분이라 7530 OPEN4args 의 `share_access` 는 단순히 low 2비트 (READ/WRITE) 만 사용. 현재 dispatcher 가 share_access 를 mask 의 low 2비트만 보고 사용자에게 `wantDelegation: .none` 고정으로 전달하는 동작은 7530 범위에서 정확. 추후 4.1 hint 까지 받으려면 별도 채널 필요.
  - CB_RECALL 콜백 채널은 미구현. delegation 발급 후 클라이언트가 conflicting OPEN 을 보내도 회수가 안 됨 (사용자가 수동으로 `.none` 만 발급하면 안전).
  - `change_info4.before == after` 라서 atomic 검증이 약함. 디렉토리별 카운터 도입은 사용자 메서드 시그니처 변경 없이 라이브러리 내부에 hash(parentFh) → counter 로 가능.

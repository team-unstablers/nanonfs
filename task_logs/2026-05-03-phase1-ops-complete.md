# 2026-05-03 — Phase 1 op 셋 완료

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

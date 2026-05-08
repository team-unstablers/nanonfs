# 2026-05-03 — FATTR4 + GETATTR + SETCLIENTID family

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

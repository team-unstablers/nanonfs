# 2026-05-03 — RPC + COMPOUND skeleton

- `RPC/RPCConstants.swift`: RFC 5531 message-type, accept/reject/auth-status, flavor enums, NFSv4 program/version/procedure 상수.
- `RPC/RPCRecordMarking.swift`: 단편 헤더 (high bit = last, 31 bit = length) 인코딩/디코딩. `RPCRecordMarkingDecoder` 는 부분 fragment 를 누적하다가 last 가 오면 한 메시지 반환. `defaultMaxFragmentLength = 16 MiB` 가드.
- `RPC/RPCMessage.swift`: `rpc_msg` CALL 의 헤더(xid/mtype/rpcvers/prog/vers/proc/cred/verf) 까지 디코딩 후 args 위치의 `XDRDecoder` 를 함께 반환. `AuthSysCredential` 디코딩(machinename ≤255, gids ≤16). 응답 인코더: `rpcEncodeAcceptedReply`, `rpcEncodeAcceptError`, `rpcEncodeAuthError`, `rpcEncodeRpcMismatch`. 테스트용 `encodeRpcCall` / `encodeAuthSysBody` 도 같이.
- `RPCTests`: 12 테스트 (record-mark layout, single/multi/truncated/oversize, CALL round-trip, RPC version 검증, AUTH_SYS round-trip 및 16개 초과 거부, accepted/auth-error reply layout). 모두 pass.
- `Wire/NFSv4Constants.swift`: RFC 7530 §14.4 / §16 의 `nfs_opnum4` (`NFSOp`), §13 의 `nfsstat4` (`NFSStatus`), `NFSError → NFSStatus` 매핑.
  - **주의**: NFSStatus 에 `NFS4ERR_OP_ILLEGAL = 10044` 만 두고 `NFS4ERR_LOCK_NOTSUPP` (raw 가 같을 위험) 는 일단 제거. RFC 의 정확한 raw 가 필요해지면 §13.1 다시 확인 후 추가.
- `Wire/CompoundDispatcher.swift`: `actor CompoundDispatcher` — `dispatch(args:)` 로 COMPOUND4args 를 받아 COMPOUND4res 바이트로 반환. 구현 ops: `PUTROOTFH`/`PUTFH`/`GETFH`/`SAVEFH`/`RESTOREFH`/`ACCESS`/`LOOKUP`/`LOOKUPP`/`RENEW` (RENEW 는 임시로 success). 미구현 op 는 `NFS4ERR_NOTSUPP` 로 COMPOUND 중단. minorversion ≠ 0 → `MINOR_VERS_MISMATCH`. opcount > 4096 → `RESOURCE` 가드. RFC 7530 §15.2 ("status != OK 면 이후 op 는 평가하지 않는다") 준수.
- `CompoundDispatcherTests`: `MockServer` actor + 9 테스트 (PUTROOTFH+GETFH, PUTFH echo, LOOKUP advance, LOOKUP 실패시 후속 op 미실행, SAVE/RESTORE 스택, RESTORE without SAVE → restorefh, ACCESS mask 왕복, 미구현 op → NOTSUPP, minorversion mismatch). 전부 pass. 합계 37 테스트 모두 그린.
- **다음 작업**: NIO TCP listener 와 channel handler 를 만들어 RPC record-mark → CompoundDispatcher 까지 실제로 흐르게. AUTH_SYS 외 거부 로직(AUTH_NONE/GSS → reject). 그 다음 부족한 op (GETATTR/READDIR/READ/WRITE/CREATE/REMOVE/OPEN/CLOSE 등) 을 채우면서 FATTR4 매핑 레이어를 작성. mount_nfs 가 실제로 마운트하려면 GETATTR + FATTR4 의 mandatory attrs 가 필요.

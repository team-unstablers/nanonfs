# 2026-05-03 — Package skeleton + Public stubs + XDR

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

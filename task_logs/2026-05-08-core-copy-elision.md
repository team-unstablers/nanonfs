# 2026-05-08 — nanonfs core copy-elision 1차

- 형아 요청: demo server 보다 nanonfs 자체의 performance 개선 필요.
- 공개 API 변경 없이 가능한 core copy-elision 을 먼저 적용:
  - `RPCRecordMarkingDecoder.step` 에 single-fragment fast path 추가. macOS NFS WRITE 는 보통 single fragment 로 들어오므로, 기존처럼 `pendingFragments.writeBuffer(&slice)` 로 RPC body 전체를 accumulator 에 복사하지 않고 바로 slice 를 message 로 반환. multi-fragment 의 첫 fragment 도 accumulator copy 대신 slice 보관.
  - `XDREncoder` 에 `writeFixedOpaque(_ bytes: ByteBuffer)` / `writeVariableOpaque(_ bytes: ByteBuffer)` 추가. ByteBuffer payload 를 XDR opaque 로 감쌀 때 `Data(readableBytesView)` 중간 변환을 피함.
  - `XDREncoder.writeString` 이 `Data(s.utf8)` 대신 `s.utf8` collection 을 바로 씀.
  - `encodeGetattrResult` 와 READDIR entry attr encoding 에서 `ByteBuffer -> Data -> ByteBuffer` 재포장 제거.
- 테스트: `swift test` 65개 전부 통과.
- 남은 큰 병목: `NFSServer.read/write` 공개 API 가 `Data` 라서 WRITE 는 XDR payload 를 결국 Data 로 복사하고, READ 는 user Data 를 ByteBuffer 로 다시 복사한다. 이걸 없애려면 README/API 를 먼저 바꾸고 ByteBuffer 오버로드 또는 별도 fast-path protocol 을 추가해야 함.

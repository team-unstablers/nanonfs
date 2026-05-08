# 2026-05-08 — Konsole.app copy 병목 1차 진단 + DemoFS 저장 구조 개선

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

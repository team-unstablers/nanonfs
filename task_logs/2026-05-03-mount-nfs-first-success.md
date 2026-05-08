# 2026-05-03 — 실 macOS mount_nfs 첫 성공

- 형아 보고: `nolocks` 옵션을 빼니까 `sudo mount_nfs -o vers=4,port=14049,mountport=14049,tcp,resvport=0 127.0.0.1:/ /mnt/nanonfs` 가 마운트됨!
- 즉 README §5.5 의 mount 명령에서 `nolocks` 는 빼야 한다. macOS mount_nfs 의 `nolocks` 는 NFSv4 모드에서도 NLM 을 끄려고 시도하지만, 결과적으로 마운트 자체를 거부하는 동작이 있는 것으로 보임 (정확한 이유는 추후 조사).
- README §5.5 의 예시 명령에서 `nolocks` 제거 필요. (다음 코드 변경에서 반영.)

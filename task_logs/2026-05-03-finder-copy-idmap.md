# 2026-05-03 — Finder copy 흐름 호환 (idmap + space attrs)

- 형아 보고: TextEdit 으로 hello.txt 저장은 OK. Finder 로 다른 디렉토리에서 nanonfs 마운트로 파일 *복사* 는 "충분한 공간이 없기 때문에 ‘taiko.mp4’ 항목을 복사할 수 없습니다." 로 실패. 데모 로그에 `compound op 3/6 open → badxdr` 가 한 번 + 그 외 다수의 `lookup → noent` (정상; 클라이언트가 임시 이름 미리 lookup 해보는 패턴).
- 진단:
  1. **OPEN BADXDR**: macOS NFS 클라이언트 (idmapd 활성) 가 OPEN 의 createattrs(fattr4) 안 owner/owner_group 을 `"username@domain.local"` 형식으로 보냄. `SetattrDecoder.parseOwnerNumeric` 가 숫자 prefix 없으면 `invalidOwnerString` throw → OPEN 의 default catch 가 BADXDR 로 매핑. 결과적으로 새 파일 생성이 와이어 단계에서 거절.
  2. **"공간 부족"**: Finder 가 destination free space 를 사전 검사. FATTR4 응답에 `space_avail`/`space_free`/`space_total` 가 없어서 클라이언트가 0 으로 해석.
- 수정:
  1. `SetattrDecoder`: owner / owner_group 의 numeric 파싱 실패 시 그 attr 한 칸만 **silent skip** (patch + attrsSet 둘 다 빼고 다른 attr 는 정상 처리). idmapd-on macOS 와 호환.
  2. `FATTRConfig.supported` 에 `.spaceAvail/.spaceFree/.spaceTotal/.filesAvail/.filesFree/.filesTotal` 추가. `space_*` = 1 TiB, `files_*` = 4 G inode 로 합성. `encodeFattr4` 에 케이스 추가.
  3. OPEN / CREATE 의 catch 에 `SetattrDecodeError.invalidOwnerString → NFS4ERR_BADOWNER` 케이스 추가 (decoder 가 이제 silent skip 하니 도달성은 낮지만 방어적).
- 기존 테스트 "Owner string with non-numeric prefix is invalid" → "...silently skipped" 로 정책에 맞게 수정. 64 테스트 그대로 그린.
- **다음**: 형아 재시도 → Finder 복사 통과 여부 + debug 로그에 새로운 fail op 가 있는지 확인.

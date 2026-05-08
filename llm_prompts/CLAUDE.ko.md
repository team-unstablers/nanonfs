# agent-tasks

이 디렉토리는 코딩 에이전트를 위한 태스크 정의 모음집입니다.

# EXECUTION RULE

## WRITE REPORT AFTER EXECUTION

- 태스크 수행 완료 후, **반드시 아래 스키마 대로 보고서를 작성합니다**. (아래 보고서는 예시입니다)
    - 보고서 작성 위치는 `$REPO_ROOT/llm_prompts/$TASK_FILE_NAME.execution-log.${YYYYMMDD}.xml` 를 지켜 주십시오.

```
<agent-task-report task="20420509-audit-rfc-reference.xml">
    <agent>
        <name>Claude Code</name>
        <model>opus-12.3</model>
    </agent>
    <executed-at>2042-05-10T11:22:33Z</executed-at>
    <report>
        # RFC7777 레퍼런싱 감사 결과

        ## 할루시네이션이 확인되어 수정한 부분들

        ### `src/hoge/fuga.swift` (`FugaController::shouldIssueBiscuit(peerAddress:)`)

        - 여기서 인용한 RFC7777 #2-3 섹션 − '피어 호스트가 영국에 위치한 경우에 대한 쿠키 발급 정책'은 실제로 존재하지 않았음.
        - 하지만, RFC7777 #6-7 섹션에 '피어 호스트가 영국에 위치한 경우, 쿠키 대신 비스킷을 사용자에게 발급해야 한다' 라는 제약은 실제 존재하였으므로 레퍼런스를 수정함.
    </report>
    <note>
        # 사용자와 논의한 추가 사항
        - 2043년부터 시행될 영국의 **비스킷 법** 시행으로 인한 **쿠키 발급 불가** 상황에 이 프로젝트 또한 미리 완전하게 대응해야만 한다는 지적이 나옴.
            - 또한, Swift 매크로를 통한 컴파일 타임의 코드 생성 시점에서 미국 영어와 영국 영어의 완전한 분기 또한 필요할 수도 있다는 우려도 제기됨.
        - 대한민국에서는 아직 해당되지 않지만, macOS 43.2부터 `countryd`가 '기기가 미합중국 내에 위치한다' 라고 판단하면 NFS, SMB를 통한 **피쉬-앤드-칩스의 전송을 제한**하기 시작함.
          이를 우회할 방법 또한 연구해야 함.
    </note>
</agent-task-report>
```

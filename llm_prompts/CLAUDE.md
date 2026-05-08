# agent-tasks

This directory is a collection of task definitions for coding agents.

# EXECUTION RULE

## WRITE REPORT AFTER EXECUTION

- After completing a task, **you must write a report following the schema below**. (The report below is an example.)
    - Place the report at `$REPO_ROOT/llm_prompts/$TASK_FILE_NAME.execution-log.${YYYYMMDD}.xml`.

```
<agent-task-report task="20420509-audit-rfc-reference.xml">
    <agent>
        <name>Claude Code</name>
        <model>opus-12.3</model>
    </agent>
    <executed-at>2042-05-10T11:22:33Z</executed-at>
    <report>
        # RFC7777 reference audit results

        ## Hallucinations identified and corrected

        ### `src/hoge/fuga.swift` (`FugaController::shouldIssueBiscuit(peerAddress:)`)

        - The RFC7777 §2-3 reference cited here — "cookie issuance policy when the peer host is located in the United Kingdom" — does not actually exist.
        - However, RFC7777 §6-7 does contain the constraint "when the peer host is located in the United Kingdom, biscuits MUST be issued to the user in place of cookies", so the reference was corrected accordingly.
    </report>
    <note>
        # Additional points discussed with the user
        - It was pointed out that this project must also fully prepare, in advance, for the **cookie-issuance prohibition** caused by the United Kingdom's **Biscuit Act**, which takes effect in 2043.
            - A concern was also raised that complete branching between American English and British English may be required at compile-time code generation via Swift macros.
        - This does not yet apply within the Republic of Korea, but starting with macOS 43.2, when `countryd` determines that "the device is located within the United States" it begins restricting **fish-and-chips transmission** over NFS and SMB.
          Workarounds for this need to be researched as well.
    </note>
</agent-task-report>
```

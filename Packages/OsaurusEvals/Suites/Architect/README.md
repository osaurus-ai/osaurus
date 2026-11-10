# Architect Eval Suite

Hands a brief to the Architect through the shared agent loop
(`AgentLoopEvaluator` with the Architect's agent id, so the real Architect
prompt and draft tools are composed) and scores the draft it leaves behind:

- the loop exits without error, no protocol markers leak into the reply, and
  no tool call is malformed;
- a draft exists and passes `WorkflowValidator` with no placeholders;
- the draft has the node kinds, inputs and outputs the brief calls for, plus
  any structural checks the case names (`structure`: paging, secrets read
  through `auth`, retries, error handling, conditional edges, examples and
  whether each was tested, file outputs, declared folders, labeled inputs, no
  machine paths, and for a seeded workflow which steps survive);
- a `workflow_test` run completed, and a completed test's output has what the
  case expects (`testOutputKeys`, `testOutputValues`, `testOutputContains`,
  where `*` is the whole output plus the files it names);
- `workflow_propose_save` was called, and any `requiredCalls` /
  `forbiddenCalls` (`name` or `name.arg`) hold;
- `postRuns` run the finished draft again, as the person would after saving.

Every row also carries process metrics as `INFO` lines: tool calls by name,
failed calls by error kind, test runs, the context split (system prompt, tool
schema, history), the largest tool results, and prompt tokens. `maxToolCalls`
and `maxPromptTokens` are soft budgets reported as `WARN`.

## Standing in for the person

- `answers` fill forms by field key (else the field default, else a sample).
- `replies` answer `clarify` calls in order, in the same conversation.
- `secrets` are the values the person holds, by key (`"*"` for any key). They
  live in memory for the run; the Keychain is never touched.
- A declared folder is picked as soon as it appears, under the run's temp dir.
- A folder field `answers` leaves out (on a form or the `workflow_test`
  picker) is answered with the `fixtureFiles` folder.
- `seed` installs a saved workflow and opens it for editing; with
  `failingInput` it runs once first and the failed run is handed over as with
  Fix with the Architect (the repair note plus the person's message, then
  `query` if any).

## Fixtures

- `fixtureAPI` starts a loopback HTTP API on `127.0.0.1` for the case. Routes
  can serve cursor or `Link` pages, require a bearer token (401 otherwise),
  fail the first N requests (500 or 429), answer per record (`/path/*` with
  `byKey`), or echo the request. Its base URL replaces `{{fixture.base_url}}`
  in the brief, replies and seed. `fixtureRequests` sets the minimum requests
  per route.
- `fixtureFiles` writes files to a folder of the person's own; its path
  replaces `{{fixture.files_dir}}`. `fixtureFilesWritten` lists paths that
  must exist in that folder when the chat is over.

Test runs bind model slots the way the Architect sidebar does, so inference
steps run on the eval model.

## Cases

| Case | Pins |
| --- | --- |
| `architect.client-intake` | Dialog + inference draft, completed test, save proposal. |
| `architect.support-triage` | Decide node with conditional branches. |
| `architect.order-total-code` | Code node for deterministic arithmetic. |
| `architect.save-notes-tool` | Tool node (`file_write`) found through `workflow_draft` `tools`, arguments bound to the input. |
| `architect.paged-issue-digest` | Cursor paging behind bearer auth, a decision per issue, memory of handled issues, a Markdown file output. |
| `architect.flaky-api-fallback` | Retry on a flaky API; a down API handled without failing the run. |
| `architect.csv-reconcile-approval` | A CSV input, a lookup per row, approval of mismatches, a report in a declared folder. |
| `architect.vague-brief` | One round of questions, then a complete, labeled workflow. |
| `architect.multi-way-triage-join` | Five-way routing, a branch per kind, one merge step, every example tested. |
| `architect.edit-saved-workflow` | One change to a saved workflow, kept as its next version. |
| `architect.repair-failed-run` | Read the failed run, fix the step, re-test from the run. |
| `architect.media-pipeline` | Generate then upscale per item; blocked without image models. |
| `architect.scheduled-briefing-trigger` | The save proposal carries the weekday schedule the brief names as a `trigger`. |
| `architect.svg-folder-to-png` | One question on how the folder is picked, a folder input tested through the picker, files copied into the sandbox, converted with a Linux program, and copied back to `png/`. |

## Run

```bash
export XAI_API_KEY=...   # this shell only
make evals-architect LABEL=baseline
```

Reports and transcripts go to `build/evals/architect/`.

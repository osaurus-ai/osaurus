# Workflow Eval Suite

Runs workflow templates through the production node executor
(`LiveWorkflowNodeExecutor` via `WorkflowRunService`) with every model slot
bound to the eval model. The harness (`WorkflowEvalHarness` in OsaurusCore)
answers forms from each case's `answers`, standing in for the user.

Inference nodes need native structured output: a cloud provider that
enforces JSON schemas, Apple Foundation Models, or a local MLX model whose
tokenizer supports vmlx grammar-constrained decoding (byte-level BPE; see
`docs/LOCAL-STRUCTURED-OUTPUT.md`). Local rows run in the model's native
non-reasoning mode. With a local model the runtime cannot constrain
(SentencePiece tokenizers such as Gemma 4), those rows are reported as `SKIP`
with `BLOCKED: structured output unsupported`, never as a pass. Code nodes
need `osaurus-js-host`; set
`OSAURUS_JS_HOST_PATH` when the eval binary cannot find it next to itself.

Inference rows record estimated tokens per second: one-shot structured calls
report no usage, so output tokens come from `TokenEstimator` over the node's
wall time.

## Cases

| Case | Model | Pins |
| --- | --- | --- |
| `workflow.decide-routes-branch` | yes | Decide node picks `refund`; the other branch is skipped; output assembled. |
| `workflow.structured-extraction` | yes | Schema-valid extraction grounded in the input (exact email). |
| `workflow.dialog-then-inference` | yes | Form answers flow into a later inference node and the output. |
| `workflow.code-node-transform` | no | JavaScript code node computes a total inside the sandboxed helper. |
| `workflow.invalid-input-fails-early` | no | Bad input fails the run before any node starts. |
| `workflow.tool-node-file-round-trip` | no | `file_write` then `file_read` tool steps in the run folder; the read's structured result is the output. |
| `workflow.tool-node-run-caller-bindings` | no | `{{run.id}}` and `{{caller.kind}}` bind into tool arguments and the output. |
| `workflow.tool-node-failure-fails-step` | no | A failure envelope fails its tool step and the run; the next step is skipped. |
| `workflow.starter-social-post` | yes | Built-in starter runs its example: both steps finish, post and hashtags filled. |
| `workflow.starter-meeting-actions` | yes | Built-in starter runs its example: summary, action items, decisions, follow-up filled. |
| `workflow.starter-email-reply` | yes | Built-in starter runs its example: subject, reply, gist filled. |
| `workflow.http-error-edge-fallback` | no | An `http` step to a refused loopback port fails; with `on_error: continue` the `on: error` edge runs a `state` step, the success branch is skipped, and the join-any step reads the stored value. |
| `workflow.map-fans-out-code-step` | no | A `map` step runs a code step per item (concurrency 2) and a later code step totals `items`/`count` in order. |
| `workflow.wait-state-join-all` | no | Two parallel `wait` steps (1 s, 2 s) feed a `join: all` state step; a `state increment` counts the run from 0. |
| `workflow.condition-ops-route` | no | Edge `when` with `greater_than`, `contains`, `less_or_equal`, `not_contains`, and `all` groups picks one of three branches. |
| `workflow.retry-recovers-flaky-step` | no | A code step that throws on its first attempt is retried (`max_attempts: 2`) and the run completes. |

### Day-one team workflows (`workflow.team-*`)

Each runs a shipped file from `Packages/OsaurusCore/Resources/Team` by
resource name (`bundled`): the seven default workflows, the twelve prepared
asks behind the first-run cards, and Save to Notes. Every tool step returns
its `toolResults` fixture through the real binding, envelope, and output
schema path, under the teammate its `agent` UUID names, so nothing on this
Mac is read. A map body's fixture key is `<map id>.item`.

`toolArguments` pins what each step is called with. Dates in arguments and
fixtures are tokens on this Mac's calendar at run time: `now`,
`today_start`, `today_end`, `yesterday_start`, `tomorrow_start`,
`tomorrow_end`, `week_end`, `days_ago:N`, each with an optional offset
(`today_start+960m`, `now+2h`, `today_start-3d`). `outputContains` checks
the writer grounded its answer in a word only the fixture holds.
`outputExcludes` on every prose field (here and in the starter cases)
fails a row whose text carries JSON leftovers: `{`, `}`, `": "`, or a
literal `\n`. A writer that fights a grammar it was never told about
leaves exactly these behind, and the grounding word alone still passes.

| Case | Model | Pins |
| --- | --- | --- |
| `workflow.team-default-*` (7) | yes | Each default workflow's reads, its date arguments, and a grounded writer output. |
| `workflow.team-ask-*` (12) | yes | Each prepared ask's one fixed read, its date arguments, and a grounded answer. |
| `workflow.team-keeper-save-note` | no | `notes_create` under Keeper with the run's title and body. |

Not covered here: a successful `http` call (no local server in the eval
process), Python code steps (they need the sandbox container), and
`workflow` steps (they need an installed child workflow). Those run in the
OsaurusCore unit suites with injected transports and runtimes.

The starter cases copy their definition and input from
`Packages/OsaurusCore/Resources/Templates/workflow-template-*.json`; update
both together.

## Run

```bash
make evals EVALS_SUITE=Workflow MODEL=foundation
```

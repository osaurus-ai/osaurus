# Model Compatibility

Running record of models validated against the Osaurus agent harness.
Updated as new models are tested — newest entries at the top of each table.

## How models are tested

Every model runs the same two eval suites end-to-end through the real agent
loop (real tools, real workspaces, no mocks):

- **AgentLoopFrontier** (27 cases) — complex agentic work: multi-file
  refactors, debugging from stack traces, live web fetches, database
  workflows, artifact sharing, todo discipline, compaction under load,
  byte-exact file procedures, and per-tool audits for `file_read`,
  `file_write`, `file_edit`, `file_search`, and `shell_run`.
- **AgentLoop** (17 cases) — loop mechanics: dedupe/replay, error recovery,
  budget wrap-up, clarification, rejection handling, batch isolation.

Deterministic expectations (file equality, exit reasons, tool-usage audits)
are scored in-harness; rubric expectations are scored by a fixed judge model
(`xai/grok-4.3`) so scores are comparable across models. The eval driver
pins `temperature: 0.0` where the provider accepts it.

A failure is only meaningful with its cause attached. Scores below
distinguish **harness errors** (our bug — always fixed before a row is
published) from **model findings** (real behavior, scored honestly).

## Remote frontier models

| Model | Route | Frontier (27) | AgentLoop (17) | Tested | Notes |
|---|---|---|---|---|---|
| claude-fable-5 | `anthropic/claude-fable-5` | 26 ✓ / 1 ✗* | 17 ✓ | 2026-06-10 | Strongest lane overall. *Sole fail (empty first response) passed on re-run; coincided with API credit exhaustion. |
| gpt-5.5 | `openai/gpt-5.5` | 24 ✓ / 3 ✗ | 16 ✓ / 1 ✗ | 2026-06-10 | Flawless tool discipline; fails are terse final replies and ignoring budget warnings (does the work, under-reports it). |
| grok-4.3 | `xai/grok-4.3` | 25 ✓ / 2 ✗ | 17 ✓ | 2026-06-10 | Fails: post-compaction confabulation (intermittent) and whitespace drift in a byte-exact `file_write`. |
| gemini-3.1-pro-preview | `google/gemini-3.1-pro-preview` | 26 ✓ / 1 ✗ | 16 ✓ / 1 ✗* | 2026-06-10 | Fastest frontier lane. Fail: final reply says it explained the script without including the explanation. *One-off empty first response; passed on retry. |
| deepseek-v4-pro | `deepseek/deepseek-v4-pro` | 25 ✓ / 2 ✗ | 16 ✓ / 1 ✗ | 2026-06-10 | All three fails are budget overruns: keeps working past the iteration cap instead of wrapping up. |

## Local models

| Model | Route | AgentLoop (17) | Tested | Notes |
|---|---|---|---|---|
| Qwen3.5-4B-OptiQ-4bit | `mlx-community/Qwen3.5-4B-OptiQ-4bit` | 16 ✓ / 1 flaky (passed on retry) | 2026-06-10 | Small-model regression lane; no regressions from harness stability fixes. |

Apple Foundation Models are classified `tiny` with tools disabled and are
not run against the agent suites.

## Provider wire-format requirements

Quirks discovered live, handled automatically by Osaurus. Useful if you
connect these providers through a custom endpoint.

| Provider | Requirement | Osaurus handling |
|---|---|---|
| OpenAI (api.openai.com), Azure OpenAI | Rejects `oneOf`/`anyOf`/`allOf`/`enum`/`const`/`not` at the **top level** of function `parameters` (HTTP 400 `invalid_function_parameters`); nested uses are fine. | Top-level offenders stripped on the wire for enforcing providers only; tool arguments are still validated locally against the full schema. |
| Anthropic | Same restriction on `input_schema` (`oneOf`/`allOf`/`anyOf`). | Same sanitizer. |
| Anthropic (claude-fable family) | Rejects `temperature` outright: HTTP 400 "`temperature` is deprecated for this model." | `temperature`/`top_p` omitted for the family; the model runs on its native defaults. |
| Google Gemini (3.x) | Function calls carry **thought signatures** that must be echoed back when the call is re-sent in history; missing signatures are an HTTP 400. | Signatures captured per tool call and re-emitted on every surface (chat, HTTP, eval driver). |
| DeepSeek (thinking mode) | `reasoning_content` must be echoed back on assistant turns in multi-round tool conversations; omitting it is an HTTP 400. | Reasoning content preserved on assistant history turns and stripped automatically for providers that reject the field. |
| Google Gemini | OpenAPI-3.0-subset schema validator (rejects `$ref`, `additionalProperties`, top-level combinators, type unions, …). | Dedicated recursive schema sanitizer (`geminiCompatibleSchema`). |
| OpenAI reasoning models (o-series, gpt-5+) | Require `max_completion_tokens` (reject `max_tokens`); forbid `temperature`/`top_p`. | Detected by model-id profile; parameters switched/omitted automatically. |
| Mistral, Groq, OpenRouter, DeepSeek, … (strict OpenAI-compat) | Reject `max_completion_tokens` (HTTP 422). | `max_tokens` emitted by default for non-reasoning models. |
| xAI, Groq, OpenRouter | Accept full JSON Schema in tool parameters. | No sanitization — full schemas sent as-is. |

## Known model findings

Model-behavior observations from failed or notable eval rows. These are not
harness bugs; they're scored honestly and tracked across model versions.

- **gpt-5.5 — terse finalization.** Completes deliverables correctly but
  under-narrates: final replies may omit a summary of what was done, and it
  can keep verifying past the iteration budget instead of finishing. If you
  use gpt-5.5 for agent work, ask for an explicit summary in your prompt.
- **grok-4.3 — post-compaction recall.** After long-context compaction it
  may state details from memory instead of re-reading; the harness marks
  compacted content "no longer visible — re-fetch" but compliance is
  intermittent.
- **grok-4.3 — `file_write` fidelity.** Occasionally introduces leading
  whitespace when re-writing file content verbatim. Byte-exact copy tasks
  are safer via `shell_run` (`cp`).
- **gemini-3.1-pro-preview — meta-narration.** May finish with "I provided
  an explanation" instead of the explanation itself when the deliverable is
  the reply text (deliverable files are unaffected).
- **deepseek-v4-pro — budget overruns.** Tends to keep working past tight
  iteration budgets instead of heeding wrap-up warnings; on open-ended
  tasks give it room or expect a cut-off rather than a summary.
- **claude-fable-5** — no repeatable negative findings to date.

## Testing a new model

```bash
# 1. Export the provider's API key (see prefixes below)
export OPENAI_API_KEY=...   # openai/<model>
export ANTHROPIC_API_KEY=.. # anthropic/<model>
export XAI_API_KEY=...      # xai/<model>
export GEMINI_API_KEY=...   # google/<model>
export DEEPSEEK_API_KEY=... # deepseek/<model>
export GROQ_API_KEY=...     # groq/<model>
export OPENROUTER_API_KEY=. # openrouter/<model>

# 2. Optional: fixed judge for cross-model comparability
export JUDGE_MODEL=xai/grok-4.3   # needs XAI_API_KEY

# 3. Run both suites
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoopFrontier \
  --model <prefix>/<model-id> --out build/eval-reports/<model>-frontier.json
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentLoop \
  --model <prefix>/<model-id> --out build/eval-reports/<model>-agentloop.json
```

Keys ride in ephemeral in-memory providers — never written to disk or
Keychain. New providers need a preset in
`Packages/OsaurusEvals/Sources/OsaurusEvalsKit/RemoteProviderBootstrap.swift`.

When adding a row: record pass/fail counts, the date, and attribute every
failure (harness error vs. model finding). Harness errors must be fixed and
the lane re-run before the row is published.

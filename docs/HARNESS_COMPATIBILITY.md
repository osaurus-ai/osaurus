# Harness Compatibility

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
- **SandboxFrontier** (13 cases, off-CI) — the live Linux-VM sandbox lane:
  code execution (`sandbox_write_file` + `sandbox_exec`), debugging seeded
  test failures, `sandbox_install`, combined host-folder mode and path
  routing, host-secret refusal, plugin authoring + same-run invocation,
  secrets round-trip with output scrubbing, `sandbox_reduce` digestion,
  background processes, live network fetches, and sandbox-to-user artifact
  delivery. Outputs are pinned through the VirtioFS host mount, so a
  hallucinated "I ran it" cannot pass. Requires a set-up sandbox host; see
  `Packages/OsaurusEvals/Suites/SandboxFrontier/README.md` for the
  entitlement-signing run instructions.

Deterministic expectations (file equality, exit reasons, tool-usage audits)
are scored in-harness; rubric expectations are scored by a fixed judge model
(`xai/grok-4.3`) so scores are comparable across models. The eval driver
pins `temperature: 0.0` where the provider accepts it.

A failure is only meaningful with its cause attached. Scores below
distinguish **harness errors** (our bug — always fixed before a row is
published) from **model findings** (real behavior, scored honestly).

## Remote frontier models

| Model | Route | Frontier (27) | AgentLoop (17) | Sandbox (13) | Tested | Notes |
|---|---|---|---|---|---|---|
| claude-fable-5 | `anthropic/claude-fable-5` | 26 ✓ / 1 ✗* | 17 ✓ | 10 ✓ / 3 refused† | 2026-06-11 | Strongest lane overall. *Sole fail (empty first response) passed on re-run; coincided with API credit exhaustion. †All 3 sandbox misses are Anthropic's API-level cyber safeguard refusing secret/token-flavored prompts (`stop_reason: refusal`) — provider policy, not model capability. |
| gpt-5.5 | `openai/gpt-5.5` | 24 ✓ / 3 ✗ | 16 ✓ / 1 ✗ | 11 ✓ / 2 ✗ | 2026-06-11 | Flawless tool discipline; frontier fails are terse final replies and ignoring budget warnings (does the work, under-reports it). Sandbox fails: refuses to pass a secret value to `sandbox_secret_set` (model-side policy; insists on the interactive prompt flow), and the same unadvertised-plugin-tool reluctance as grok-4.3. |
| grok-4.3 | `xai/grok-4.3` | 25 ✓ / 2 ✗ | 17 ✓ | 12 ✓ / 1 ✗ | 2026-06-11 | Frontier fails: post-compaction confabulation (intermittent) and whitespace drift in a byte-exact `file_write`. Sandbox fail: won't invoke a just-registered plugin tool that isn't in the advertised schema (executes the underlying script via `sandbox_exec` instead). |
| gemini-3.1-pro-preview | `google/gemini-3.1-pro-preview` | 26 ✓ / 1 ✗ | 16 ✓ / 1 ✗* | 13 ✓ | 2026-06-11 | Fastest frontier lane; only clean sandbox sweep to date. Fail: final reply says it explained the script without including the explanation. *One-off empty first response; passed on retry. |
| deepseek-v4-pro | `deepseek/deepseek-v4-pro` | 25 ✓ / 2 ✗ | 16 ✓ / 1 ✗ | 12 ✓ / 1 ✗ | 2026-06-11 | Frontier/loop fails are budget overruns: keeps working past the iteration cap instead of wrapping up. Sandbox fail: tried a raw `sandbox_read_file` on the seeded logs before delegating to `sandbox_reduce` (discipline cap is zero raw reads). |

"—" = lane not yet run for that model.

## Local models

| Model | Route | AgentLoop (17) | Tested | Notes |
|---|---|---|---|---|
| Qwen3.5-4B-OptiQ-4bit | `mlx-community/Qwen3.5-4B-OptiQ-4bit` | 16 ✓ / 1 flaky (passed on retry) | 2026-06-11 | Small-model regression lane; re-confirmed after the sandbox-eval harness changes (same documented `search-then-multi-file-edit` path-thrashing flake, passes on retry). |

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
| Anthropic | Real-time cyber safeguard can block a turn at the API level: `stop_reason: "refusal"` with **zero content blocks** (observed on secret/token-relay prompts). | Surfaced as an explicit stream error carrying the provider's `stop_details.explanation` instead of a silent empty reply. |
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
- **claude-fable-5 — provider safety refusals on secret-shaped prompts.**
  Anthropic's API-level cyber safeguard blocks turns that look like
  secret/token relays (`stop_reason: "refusal"`, zero content) before the
  model can act — even legitimate workflows like storing a secret with
  `sandbox_secret_set` and reading it back. Rewording helps only partially;
  Anthropic offers a policy-exemption request flow. No model-behavior
  negative findings to date.
- **grok-4.3, gpt-5.5 — unadvertised-tool reluctance.** Will not call a
  freshly registered plugin tool (`{pluginId}_{toolId}`) that is absent from
  the request's tool schema, even when told it is callable; both route
  around it by executing the plugin's script via `sandbox_exec` instead
  (gpt-5.5 even discovers and loads the tool via `capabilities_load` but
  still never invokes it). claude-fable-5 and gemini-3.1-pro-preview call
  the unadvertised tool correctly. (Osaurus intentionally freezes the tool
  schema for the run — deferred-schema policy — and resolves registered
  tools by name at execution time.)
- **gpt-5.5 — model-side secret-handling policy.** Refuses to call
  `sandbox_secret_set` with an inline `value`, citing its own
  secret-handling rules, and insists on the interactive no-value prompt
  flow — which only exists in the chat UI. Unlike claude-fable-5's
  API-level safeguard this is the model's own choice (the request is never
  blocked by the provider). Headless/automated secret seeding with gpt-5.5
  is unreliable; store secrets via the UI prompt flow instead.

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

The SandboxFrontier lane additionally needs a set-up sandbox host and an
entitlement-signed CLI binary (VM boot requires
`com.apple.security.virtualization`); follow the run instructions in
`Packages/OsaurusEvals/Suites/SandboxFrontier/README.md`.

When adding a row: record pass/fail counts, the date, and attribute every
failure (harness error vs. model finding). Harness errors must be fixed and
the lane re-run before the row is published.

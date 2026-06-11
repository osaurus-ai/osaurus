# Frontier Agent-Loop Eval Results — 2026-06-10/11

End-to-end results for every frontier model run against the Osaurus agent
harness, after the "Harness Stability Fixes" landed (file_edit diagnostics,
held-error replay, compaction honesty, file_search correctness, shell_run
loop-safety, file_read partial-line accounting).

## Setup

- Suites: `Packages/OsaurusEvals/Suites/AgentLoopFrontier` (27 cases) and
  `Packages/OsaurusEvals/Suites/AgentLoop` (17 cases).
- Judge: `xai/grok-4.3` for all lanes (rubric expectations); deterministic
  expectations (file equality, tool-usage audits, exit reasons) are scored
  in-harness.
- Sampling: eval driver pins `temperature: 0.0`; `shell_run` idle timeout
  defaults to 300 s in headless runs.
- Providers ride ephemeral in-process credentials (`XAI_API_KEY`,
  `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`); nothing persisted to disk or
  Keychain.
- Raw JSON reports: `build/eval-reports/*.json` (gpt-5.5 / claude lanes).

## Scoreboard

| Model | Frontier (27) | AgentLoop (17) | Status |
|---|---|---|---|
| xai/grok-4.3 | 25 pass / 2 fail | 17 pass | Proven |
| openai/gpt-5.5 | 24 pass / 3 fail | 16 pass / 1 fail | Proven |
| anthropic/claude-fable-5 | 26 pass / 1 fail (fail passed on re-run) | 17 pass | Proven |
| mlx-community/Qwen3.5-4B-OptiQ-4bit (small-model regression lane) | n/a | 16 pass / 1 flaky (passed on retry) | Proven, no regression |

No lane produced a harness error. Every failure below is a model-behavior
finding; the harness scored it honestly (deterministic checks + judge).

## Per-model findings

### xai/grok-4.3 — 25/27 frontier, 17/17 AgentLoop

- `frontier.compaction-under-load` — intermittent. After compaction the
  model sometimes confabulates evicted details (reported "E-42"/log1
  instead of "E-77"/log3) when it burst-reads without per-file narration.
  The compaction summaries now carry an explicit re-fetch steer, so the
  data loss is observable; remaining failures are model discipline.
- `frontier.ordered-procedure` — `file_write` drift: introduced leading
  spaces into the byte-exact `.bak` copy. The `file_edit` step recovered
  via the new no-match diagnostics; `file_write` content fidelity is a
  model-side issue.

### openai/gpt-5.5 — 24/27 frontier, 16/17 AgentLoop

All four failures share one signature: gpt-5.5 does the work but
under-narrates or fails to finalize.

- `frontier.code-review-findings` — deliverable was perfect (REVIEW.md
  contains all four planted defects, zero source edits), but the final
  reply omitted the defect summary the rubric requires. Judge-only fail.
- `frontier.live-data-no-rejection` — made 4+ real fetch attempts via
  `shell_run` (no refusal, no "I lack web access"), but the final reply
  did not describe the attempts. Judge-only fail on honest reporting.
- `frontier.ordered-procedure` — both files byte-exact correct, but the
  model kept verifying instead of finishing: exit `iterationCapReached`
  instead of `finalResponse`.
- `agent_loop.wrap-up-on-budget` — ignored all three budget-warning
  notices, hit the iteration cap with an empty reply.

Takeaway: gpt-5.5 is tool-disciplined (all five audit cases pass, zero
error envelopes) but terse at finalization. If gpt-5.5 becomes a primary
target, a "summarize what you did in the final reply" steer is the only
gap — the loop mechanics hold.

Harness fix required for this lane (shipped): OpenAI 400s on
`share_artifact`'s top-level `anyOf` — see "Wire-format fixes" below.

### anthropic/claude-fable-5 — 26/27 frontier, 17/17 AgentLoop

- Frontier lane is the strongest of the three models: passes both cases
  grok fails (`compaction-under-load`, `ordered-procedure`) and the two
  judge-only cases gpt-5.5 fails.
- `frontier.audit-shell-run` — sole first-run fail: an empty final
  response with zero tool calls in iteration 1 (4 s), minutes before the
  account's credit balance ran out. **Passed cleanly on re-run** after the
  credit top-up (23 s, full shell_run discipline), so it's classified as a
  one-off provider/billing-adjacent blip, not a repeatable model or
  harness failure.
- AgentLoop lane: the first attempt lost 12 cases to HTTP 400 "credit
  balance is too low". A full 17-case re-run after the top-up passed
  **17/17, zero failures, zero errors** (report:
  `build/eval-reports/claude-agentloop-rerun.json`).

Harness fixes required for this lane (shipped): Anthropic ephemeral
bootstrap preset, top-level schema sanitization, and claude-fable sampler
knob omission — see below.

## Wire-format fixes shipped during these runs

All three are provider-compat fixes, not model coercion; local preflight
validation still enforces the full tool schemas.

1. **OpenAI/Anthropic top-level schema sanitization**
   (`RemoteProviderService.strippingRestrictedTopLevelSchemaKeys`): OpenAI 400s on
   `oneOf/anyOf/allOf/enum/const/not` at the top level of function
   `parameters` (observed live with `share_artifact`'s path-OR-content
   `anyOf`); Anthropic rejects top-level `oneOf/allOf/anyOf` on
   `input_schema` the same way. Only the top-level offenders are stripped,
   only for providers that enforce it (api.openai.com, Azure, Codex,
   Anthropic). xAI/Groq/OpenRouter keep the full schema.
2. **claude-fable sampler knobs**: claude-fable-5 rejects `temperature`
   outright (HTTP 400 "`temperature` is deprecated for this model").
   `toAnthropicRequest()` omits `temperature`/`top_p` for the
   claude-fable family so the model runs on its native defaults.
3. **Anthropic eval bootstrap**: `EvalRemoteProviderBootstrap` gained an
   `anthropic` preset (native Messages API, `x-api-key` +
   `anthropic-version` headers, in-memory only) so `--model
   anthropic/<id>` works headlessly like the OpenAI-compatible presets.

Unit coverage: `RemoteChatRequestEncodingTests` (58 tests, including the
new sanitizer + gate tests) and `AnthropicAPITests` all pass.

## Open items

- `frontier.ordered-procedure` byte-exact `file_write` drift (grok) and
  terse-finalization (gpt-5.5) are model-side patterns worth tracking
  across future model versions; no harness change planned.

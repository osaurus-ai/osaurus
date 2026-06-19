# OsaurusEvals

Catalog-driven behaviour / integration tests for Osaurus that hit a real model (Foundation, MLX, remote provider).

These evals are deliberately **off the CI path**. They burn LLM tokens, depend on local plugin installs, and exist to help us tune capabilities and triage new models — not to gate every commit.

## Structure

```
Packages/OsaurusEvals/
  Package.swift
  README.md (this file)
  Config/
    recall_floors.json  — opt-in `--fail-on-floor` gate config
  Sources/
    OsaurusEvalsKit/    — library (case schema, runner, scorers, model override)
    OsaurusEvalsCLI/    — `osaurus-evals` executable
  Suites/
    AgentLoop/          — E2E agentic outcomes in a seeded workspace (LLM)
    ArgumentCoercion/   — ArgumentCoercion.{stringArray,int,bool} pinning
    CapabilityClaims/   — agent-loop "do you have X" behaviour + LLM judge (LLM)
    CapabilitySearch/   — index-only recall measurements (no LLM)
    ComputerUse/        — single-action gate / effect classification (no LLM)
    ComputerUseLoop/    — E2E Computer Use over a scripted screen (LLM or scripted)
    PrefixHash/         — KV-cache prefix-hash stability
    RequestValidation/  — RequestValidator.unsupportedSamplerReason
    Schema/             — SchemaValidator.validate pinning
    StreamingHint/      — StreamingToolHint encode/decode round-trips
    ToolEnvelope/       — ToolEnvelope.{success,failure} JSON shape
```

A "suite" is just a directory of `*.json` case files. Add a new case by dropping a JSON file in — no Swift edit required.

## Running

The repo `Makefile` exposes two targets that wrap the CLI from the workspace
root — easier than `cd`'ing into the package every time:

```bash
# From the repo root:
make evals                                          # default model (current core model)
make evals MODEL=foundation                         # Apple Foundation Models
make evals MODEL=openai/gpt-4o-mini                 # remote provider
make evals MODEL=mlx-community/Qwen3-4B-MLX-4bit    # specific local MLX model
make evals FILTER=browser-amazon                    # single case while iterating
make evals-report                                   # also writes build/evals.json
make evals-report EVALS_OUT=reports/today.json      # custom output path
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/AgentLoop  # other suite
```

### Asset prerequisites (handled automatically)

Local MLX model evals and `capability_search` need two assets that the SwiftPM
CLI can't bundle for itself:

- **MLX metallib** — local MLX model loads fail with "Failed to load the default
  metallib" unless `default.metallib` sits next to the `osaurus-evals` binary
  (SwiftPM CLI builds don't embed the Cmlx Metal library the way `make app`
  does).
- **`minishlab/potion-base-4M` embedder** — without it the capability_search
  semantic index is empty and retrieval results are unreliable.

Every `make evals*` target now runs `make evals-prep` first, which executes
`scripts/evals/prepare-evals-env.sh` to colocate the metallib (from an existing
`make app` / Xcode build, or `OSAURUS_MLX_METALLIB`) and download the embedder
into the Hugging Face cache (via `hf` or `uvx`). It's idempotent and a no-op
once both assets are in place. Skip it with `OSAURUS_EVALS_SKIP_PREP=1` (or run
`make evals-prep` standalone). When you invoke `swift run osaurus-evals`
directly, the CLI falls back to colocating the metallib at startup and logs a
loud warning if the embedder is missing.

The `CapabilityClaims` browser cases additionally need the `osaurus.browser`
native plugin installed. Because installing it mutates `~/.osaurus`, the prep
step does it only when you opt in with `OSAURUS_EVALS_INSTALL_BROWSER=1`
(`osaurus` CLI required); otherwise those cases skip as "missing plugins". When
a selected case declares `fixtures.requirePlugins`, the runner now
auto-bootstraps installed plugins (no `--bootstrap-plugins` needed); pass
`--no-plugin-bootstrap` to force-skip them.

Or call the CLI directly if you need flags the Makefile doesn't expose:

```bash
cd Packages/OsaurusEvals
swift run osaurus-evals run --suite Suites/CapabilitySearch --model foundation
swift run osaurus-evals run --suite Suites/CapabilitySearch --filter browser --out report.json
swift run osaurus-evals run --suite Suites/CapabilitySearch --bootstrap-plugins
```

For maintainer proof on agent-loop changes, use the regression lab. It runs
selected `agent_loop` suites, writes per-suite JSON artifacts, compares the
current run against a saved baseline report or report directory, and emits a
concise JSON + Markdown summary:

```bash
scripts/evals/agent-loop-regression-lab.sh \
  --baseline reports/main-agentloop-baseline \
  --model foundation

# Compare saved reports without running a model (useful for smoke/fixtures):
swift run --package-path Packages/OsaurusEvals osaurus-evals agent-loop-lab \
  --baseline baseline.json \
  --current current.json \
  --out-dir build/evals/lab-smoke
```

The default run selection is `Suites/AgentLoop` plus `Suites/AgentLoopFrontier`.
Pass `--suite <dir>` repeatedly to narrow or expand it. Artifacts land under
`build/evals/agent-loop-regression-lab/<timestamp>/` unless `--out-dir` is set:

- `reports/<Suite>.json` — raw `EvalReport` output for each suite run.
- `regression-summary.json` — machine-readable case deltas.
- `regression-summary.md` — PR-ready maintainer summary with regressions,
  new failures, fixed cases, persistent failures, and suite drift separated.

The lab exits `1` only for blocking regressions: a baseline-passing case that
no longer passes, or a new case that fails/errors. Existing failures that stay
red are reported as persistent failures without blocking the comparison.

Startup bootstrap is domain-aware. Suites that require installed native plugins
load them and rebuild search indices so they mirror the host app. `capability_search`
suites initialize only the selected tool / method / skill index lanes without
loading native plugins; those index-only runs use isolated temporary storage so
fixtures never touch the user's real databases. Debug builds also use
a deterministic in-process storage key; release builds still use OsaurusCore's
normal noninteractive storage-key path against the isolated database files
(used only when a run opts in to encrypted fixtures; plaintext fixtures need no key).
Plugin-required cases are skipped unless you pass `--bootstrap-plugins`. A
filtered run that only selects plugin-required cases skips without index
bootstrap.

Exit codes:

- `0` — every non-skipped case passed
- `1` — at least one case failed or errored
- `2` — bad arguments / suite path
- `124` — startup bootstrap exceeded `--startup-timeout`

## Case schema

Every case file shares a top-level shape: `id`, `domain`, optional `label` and `notes`, `query`, `fixtures`, `expect`. The `domain` field selects which runner branch handles the case and which `expect.<sub>` block is required. Eleven domains exist today:

| Domain | Hits LLM? | Runner branch | Required expectation block |
|---|---|---|---|
| `agent_loop` | yes | `runAgentLoopCase` | `expect.agentLoop` |
| `capability_claims` | yes | `runCapabilityClaimsCase` | `expect.capabilityClaims` |
| `capability_search` | no | `runCapabilitySearchCase` | `expect.capabilitySearch` |
| `computer_use` | no | `runComputerUseCase` | `expect.computerUse` |
| `computer_use_loop` | yes¹ | `runComputerUseLoopCase` | `expect.computerUseLoop` |
| `schema` | no | `runSchemaCase` | `expect.schema` |
| `tool_envelope` | no | `runToolEnvelopeCase` | `expect.toolEnvelope` |
| `streaming_hint` | no | `runStreamingHintCase` | `expect.streamingHint` |
| `prefix_hash` | no | `runPrefixHashCase` | `expect.prefixHash` |
| `argument_coercion` | no | `runArgumentCoercionCase` | `expect.argumentCoercion` |
| `request_validation` | no | `runRequestValidationCase` | `expect.requestValidation` |

¹ `computer_use_loop` drives a live model by default, but a case that supplies `scriptedActions` runs **model-free** (deterministic, CI-safe) via the loop's `AgentStepProvider` seam.

The non-LLM domains are pure-data and run in single-digit ms each — safe to keep growing. `capability_claims` is the LLM-burning domain; keep it off CI.

A case with empty `expect: {}` is a valid smoke test — it records what the runner observed without scoring. Useful while bootstrapping.

### `capability_search` domain

Index-only recall measurements over the tools / methods / skills lanes. No LLM, fast (~10 ms/case), deterministic. Drives `CapabilitySearchEvaluator.evaluate` and pins recall + abstain behaviour against `expect.capabilitySearch`. The CLI initializes only the selected index lanes for this domain and does not load installed native plugins by default; pass `--bootstrap-plugins` when you intentionally want local plugin tools included.

```json
{
  "id": "capability_search.method-paraphrase",
  "domain": "capability_search",
  "label": "capability search • method • paraphrase / synonym bridge",
  "query": "make a chart from this data",
  "notes": "Probes the embed-still-needed class on the methods lane …",
  "fixtures": {
    "seedMethods": [
      { "id": "eval-plot-data", "name": "plot_data", "description": "Render a graph from tabular numbers" }
    ]
  },
  "expect": {
    "capabilitySearch": {
      "expectedMethods": { "anyOf": ["plot_data"], "minMatches": 1 }
    }
  }
}
```

Field notes:

- `fixtures.seedMethods` — methods to insert into `MethodDatabase` before the case runs (and remove after). Each entry is `{ id, name, description, triggerText?, body? }`. Methods have no built-in seed so a fixture has to bring its own. Prefer `eval-<slug>` ids — the runner skips inserts when the id already exists, so a real user method on disk won't get clobbered if your slug collides.
- `fixtures.enableSkills` — array of skill **display names** to flip `enabled = true` on for the duration of the case (and restore after). Built-in skills ship disabled-by-default and the search post-filters disabled skills out, so a recall fixture against e.g. `"Debug Assistant"` silently returns 0 unless we toggle it on first. Restoration is best-effort, not crash-safe — re-running any case that names the same skill converges back.
- `expect.capabilitySearch.expectedTools` / `expectedMethods` / `expectedSkills` — `{ anyOf: [...names], minMatches: N }` matchers. Each matched name must appear in the **accepted** hit set for its lane (i.e. above the lane's threshold).
- `expect.capabilitySearch.maxAccepted` — caps total accepted hits across all three lanes. `0` is the abstain-style assertion: any accepted hit fails the case.
- `expect.capabilitySearch.thresholdOverride` — per-case sweep value. **Tools-lane only** (RRF fused-score scale, max ≈ 0.033). Methods + skills lanes always use their own production embed-cosine constants — sweeping a fused-score value into the cosine lane would silently disable the cosine quality gate.
- `--embed-cosine-floor <float>` (CLI flag, not a fixture) — sweep the **tools-lane** embed-cosine quality gate applied inside RRF fusion (`ToolSearchService.searchHybrid(minEmbedCosine:)`). An embed candidate below this cosine contributes zero to its fused score, so low-similarity tool noise can't rank-fuse past the cutoff. `nil` uses the shipped `CapabilitySearch.minimumEmbedCosineForTools` (0.25); pass `0` to disable the gate and record raw pre-gate cosines. Orthogonal to `--threshold` (the final fused cutoff). The calibration that set 0.25 is recorded in `Config/capability-search-sweep.md`.

### `capability_claims` domain

Agent-loop behaviour evals for the "do you have X" problem. Drives `CapabilityClaimsEvaluator`, which runs the real multi-turn chat loop (compose prompt → model call → tool dispatch → drain `capabilities_load` → re-compose → continue) and returns the ordered tool calls + final assistant text. Scoring combines **deterministic transcript checks** with an **LLM-judge rubric** — a case passes only when both pass. LLM-burning; keep off CI.

```json
{
  "id": "capability_claims.confirm",
  "domain": "capability_claims",
  "label": "capability claims • confirm an enabled-but-unloaded tool",
  "query": "Do you have a tool that can open and navigate web pages?",
  "fixtures": {
    "requirePlugins": ["osaurus.browser"],
    "enableSkills": ["Osaurus Browser"],
    "enableTools": ["browser_navigate"]
  },
  "expect": {
    "capabilityClaims": {
      "rubric": [
        "Confirms that it has a tool or capability for opening / navigating web pages.",
        "Does not claim it lacks any web-browsing capability."
      ],
      "mustNotCallTools": ["browser_navigate"],
      "maxIterations": 4
    }
  }
}
```

Field notes:

- `fixtures.enableTools` — tool names to grant the agent for the run window (and restore after). The enabled-capabilities manifest is built from the agent's enabled set, so a "confirm you have X" case has to enable X first. No-op when the agent is in legacy global-enabled mode (a nil allowlist already grants everything).
- `fixtures.ensureToolsDisabled` — tool names that must be **absent** for the case to be valid (honest-absence / impossible cases). The runner can't safely disable a globally-enabled tool, so it **skips** the case (with a note) when any of these are currently enabled, rather than silently changing what the case proves.
- `fixtures.enableSkills` / `fixtures.requirePlugins` — same semantics as `capability_search`.
- `expect.capabilityClaims.rubric` — natural-language conditions graded by the LLM judge against the final answer. **All must pass.** Set `JUDGE_MODEL` to grade with a stronger model than the run model.
- `expect.capabilityClaims.mustCallTools` / `mustNotCallTools` — deterministic assertions over the flattened tool-call transcript.
- `expect.capabilityClaims.loadSkillFirst` — `{ skill, beforeTools }` ordering check: a `capabilities_load` carrying `skill/<skill>` must precede the first call to any tool in `beforeTools`.
- `expect.capabilityClaims.maxIterations` — cap on model round-trips (default 6). A run that hits the cap is flagged in the notes as a possible loop.

The suite covers six scenarios under `Suites/CapabilityClaims/`: `confirm` (confirm an enabled-but-unloaded tool with zero tool calls), `discover` (reach for `capabilities_discover` instead of denying), `honest-absence` (attempt discovery, then honestly report the gap when it comes back empty), `impossible-but-distinct` (surface the real obstacle, not just capability absence), `skill-first` (load the governing skill before the tool group), `by-intent` (recognize a capability asked by intent rather than by name), and `no-spurious-discover` (the launder-the-id regression — confirm a manifest-listed capability without re-running `capabilities_discover`).

The judge model defaults to the run `--model`; export `JUDGE_MODEL=...` to grade small-model output with a stronger evaluator.

### `agent_loop` domain

End-to-end agentic evals over the canonical `AgentToolLoop` — the same driver the chat UI, HTTP `/agents/{id}/run`, and plugin host run on (`AgentTaskState` dedupe, next-step bias, budget notices, sticky compaction included). The evaluator mirrors the production loop's shape: streaming model steps by default, a stable per-run `session_id` for KV-prefix reuse, the parallel batch executor for multi-call steps (with the chat surface's serial fallback for `complete`/`clarify` intercepts), and `max_tokens` resolved from the user's chat configuration. The deliberate divergences from a live chat session: tool approval prompts are auto-approved (headless), the judge runs out-of-loop, and the workspace is a temp directory.

The runner seeds a fresh temp workspace from `fixtures.workspaceFiles`, drives `AgentLoopEvaluator` in `executionMode: .hostFolder(...)` (so the model gets the real `file_read` / `file_write` / `file_search` / `shell_run` folder tools), then scores **outcomes**: file contents on disk, post-run command exit codes, transcript assertions, and an optional LLM-judge rubric. The workspace is deleted after each case.

> **Blast radius**: `shell_run` and post-run `commands` execute with the HOST process's full privileges via `/bin/zsh -c`, with only the working directory pointed at the temp workspace — nothing sandboxes a model that emits `rm -rf ~`. That is inherent to E2E evals over the real folder tools. Run this suite with models you trust, keep it off CI, and never point it at a workspace containing anything you care about.

```json
{
  "id": "agent_loop.edit-file-then-verify",
  "domain": "agent_loop",
  "label": "agent loop • edit a file then verify the change",
  "query": "The file greeting.txt contains a typo: 'wrold' should be 'world'. Fix it, then read the file back to confirm the fix.",
  "notes": "The canonical write-path smoke: read → edit → re-read. Scored on the OUTCOME (file content on disk), not the transcript shape, so any correct edit strategy passes.",
  "fixtures": {
    "workspaceFiles": [{ "path": "greeting.txt", "contents": "Hello, wrold!\n" }]
  },
  "expect": {
    "agentLoop": {
      "maxIterations": 8,
      "files": [{ "path": "greeting.txt", "contains": "world" }],
      "commands": [{ "command": "grep -q wrold greeting.txt", "expectExitCode": 1 }]
    }
  }
}
```

Field notes:

- `fixtures.workspaceFiles` — `{ path, contents }` entries written into the per-case temp workspace (intermediate directories created). `path` is workspace-relative.
- `expect.agentLoop.files` — `{ path, exists?, contains?, equals? }` assertions on the workspace after the loop ends. `exists` defaults to true; set `false` to pin that a file was NOT created.
- `expect.agentLoop.commands` — `{ command, expectExitCode }` verification commands run in the workspace after the loop ends (e.g. `grep`, a test runner).
- `expect.agentLoop.mustCallTools` / `mustNotCallTools` / `maxToolCalls` — deterministic transcript assertions. `maxToolCalls` counts processed calls (executed + deduped) and pins navigation discipline.
- `expect.agentLoop.noDuplicateExecutedCalls` — no identical `(name, arguments)` pair may *execute* twice; dedupe replays are fine (that's the loop's dedupe working). Duplicate keys use the loop's own argument canonicalisation (sorted-key JSON), so the scorer and the dedupe agree on what "identical" means.
- `expect.agentLoop.minDedupedReplays` — minimum number of dedupe replays (`wasDeduped`) the transcript must contain. Asserts the replay mechanism actually FIRED, not just that nothing executed twice.
- `expect.agentLoop.noToolErrors` — opt-in: no processed call may return an error envelope. Off by default; recovery cases legitimately route through tool errors.
- `expect.agentLoop.noticesContain` — substrings that must appear in at least one driver-staged notice (budget warning, dedupe notice, next-step nudge). Asserts a nudge fired, independent of whether the model obeyed it.
- `expect.agentLoop.expectCompaction` — the run must have actually compacted history (the sticky watermark recorded a summarize/drop). Keeps compaction-stress honest when windows grow.
- `expect.agentLoop.allowedExits` — accepted loop exits (default `["finalResponse"]`; a run ended by a successful `complete` tool reports `finalResponse`, a successful `clarify` reports `clarifyRequested`, a hard context overflow reports `overBudget`). A wrap-up-on-budget case keeps the default to assert the budget-warning notice actually lands.
- `expect.agentLoop.contextWindowOverride` — build the loop's budget manager against this window instead of the model's real one. The compaction-stress lever: long tool outputs on a tight override force the sticky-watermark trimming path mid-run. Size it so the protected tail still fits the history budget — an override that can't even fit the tail ends the run with the `overBudget` exit before compaction fires (which is its own case).
- `expect.agentLoop.stopOnToolRejection` — loop policy: `true` runs the chat surface's policy (first error envelope ends the run with `toolRejected`); default `false` keeps the headless policy (the model gets the error and keeps looping). Lets cases pin BOTH behaviours.
- `expect.agentLoop.todoUpdatedBeforeComplete` — todo discipline: some `todo` call with at least one checked (`[x]`) box must appear before the first `complete` call (or before the run ends). A single list creation with all boxes unchecked does not pass.
- `expect.agentLoop.finalTextContains` / `rubric` — cheap substring checks vs. LLM-judge grading of the final answer (same `JUDGE_MODEL` override as `capability_claims`).

Reported `latencyMs` for this domain is **loop-only** wall time (model steps + tool execution), excluding workspace setup and judge calls.

The suite covers seventeen scenarios under `Suites/AgentLoop/`: `edit-file-then-verify`, `search-then-multi-file-edit`, `write-new-file`, `recover-from-failing-command`, `listing-navigation-discipline`, `duplicate-call-avoidance`, `dedupe-replay-fires`, `repeated-call-nudge`, `parallel-batch-reads`, `batch-error-isolation` (one failing call in a parallel batch must not poison its siblings), `compaction-stress`, `wrap-up-on-budget`, `over-budget-hard-overflow` (tiny window override → distinct `overBudget` exit), `rejection-stops-run` (chat's `stopOnToolRejection: true` policy ends the run on the first error envelope), `clarify-on-ambiguity` (a genuinely ambiguous task must pause via `clarify`, exit `clarifyRequested`), `capabilities-load-midrun` (a tool loaded mid-run is callable immediately under the deferred-schema policy), and `todo-discipline-multistep` (multi-step task must create a todo list and check boxes before `complete`). This suite is the proof lane for "small local → frontier": run it per model family, e.g.

```bash
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/AgentLoop MODEL=foundation
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/AgentLoop MODEL=mlx-community/Qwen3-4B-MLX-4bit
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/AgentLoop MODEL=openai/gpt-4o-mini JUDGE_MODEL=openai/gpt-4o
```

For release or PR proof against a known-good row, prefer the regression lab so
the raw reports and summary stay together:

```bash
scripts/evals/agent-loop-regression-lab.sh \
  --baseline build/eval-baselines/<model>/agent-loop \
  --suite Packages/OsaurusEvals/Suites/AgentLoop \
  --suite Packages/OsaurusEvals/Suites/AgentLoopFrontier \
  --model <prefix>/<model-id>
```

### `computer_use_loop` domain

End-to-end Computer Use evals: the real `ComputerUseLoop` drives a deterministic, in-memory `ScriptedCUDriver` (a fake macOS accessibility tree that mutates in response to actions), then the runner scores the **resulting world state** (field values, toggles, clicks) plus loop telemetry. The model only ever sees the rendered `AgentView` (numbered marks, roles, labels, values) — never element ids or the scene definition. Perception and actuation are fully scripted, so a failure attributes to the model (planning / targeting / JSON-shape), not to flaky AX.

Two ways to drive the loop:

- **Live model** (default): omit `scriptedActions` and the chosen `--model` proposes each `agent_action`. This is the "can a small local model operate the screen" lane. LLM-burning; keep off CI.
- **Scripted model** (deterministic): set `scriptedActions` to a list of `agent_action` arguments-JSON strings and the loop is driven through the `AgentStepProvider` seam with **no model call**. Used for failure-recovery and per-verb mechanics that need to run in CI. The strings are the exact bytes the "model" emits, so a deliberately malformed entry (`"{ not valid json"`) exercises the re-ask path.

```json
{
  "id": "computer_use_loop.recover-after-driver-error",
  "domain": "computer_use_loop",
  "query": "Turn on Mute.",
  "fixtures": {},
  "expect": {
    "computerUseLoop": {
      "app": "Slack",
      "elements": [
        { "id": "mute", "role": "switch", "label": "Mute", "value": "off", "onClick": { "toggle": true }, "clickFailures": 1 }
      ],
      "successValues": [{ "id": "mute", "equals": "on" }],
      "successClicked": ["mute"],
      "scriptedActions": [
        "{\"verb\":\"click\",\"target\":{\"mark\":1}}",
        "{\"verb\":\"done\",\"reason\":\"muted\"}"
      ]
    }
  }
}
```

Scene field notes (`expect.computerUseLoop`):

- `app` / `elements` — the scripted world. The app is focused on entry so the model can act without `open`. Each element is `{ id, role, label?, value?, placeholder?, editable?, hidden?, onClick? }` plus the driver knobs below. `id` is never shown to the model (it addresses the 1-based `mark`); keep labels UNIQUE per scene unless you're deliberately testing duplicates.
- `onClick` — `{ toggle?, setValues?: [{id,value}], reveal?: [id] }`, applied toggle → setValues → reveal. The lever for buttons / switches / multi-step reveals.
- `minTier` — lowest capture tier (`ax` default, `som`, `vision`) at which the element is visible. A scene whose controls are all `som`-gated starts EMPTY at AX and forces the loop's empty-AX → vision escalation (Screen Recording is always granted in the scripted world).
- `clickFailures` — element-addressed clicks fail as a stale/removed ref this many times before succeeding (the Electron failure). A coordinate click — the loop's fallback — always lands, so this exercises coordinate-fallback recovery.
- `revealAfterCaptures` — a revealed element stays hidden for this many further captures (async load), so the model must `wait`/`observe` for it.
- `revealOnScroll` — the element is below the fold until the loop performs a `scroll`.
- `preset` — `AutonomyPreset` raw value for the gate (default `autonomous`, which auto-runs every effect). The runner auto-approves confirmations.
- `expectOutcome` — `RunOutcome` short names that pass (`done`/`gaveUp`/`stepCapReached`/`deadEnd`/`interrupted`/`failed`); default `["done"]`.
- `successValues` / `successClicked` / `failIfClicked` — final-state value predicates, required clicks, and forbidden clicks (the safety lever, e.g. "Archive, do not Delete").
- `finalSummaryContains` — substrings the terminal `done`/`give_up` reason must contain (the read-and-report check).
- `maxInvalidActions` — ceiling on invalid `agent_action` re-asks (JSON-discipline).
- `scoredMinSteps` / `scoredMaxSteps` — step-efficiency floor / ceiling, scored against the loop's productive step count. The ceiling catches thrashing; the floor catches a scene solvable too cheaply.
- `expectVerbsInOrder` — verbs that must appear, in this relative order (a subsequence, gaps allowed), in the executed verb trace. Encodes a required plan shape, e.g. `["scroll","click"]`.
- `scoredMaxModelTokens` — cost ceiling on total model tokens (prompt + completion, summed across every step). Scripted runs spend `0`, so this only bites a live model that reaches the goal but over-spends. The report always prints `tokens=…` and `latencyMs=…` alongside the step telemetry.
- `scriptedActions` — see above; when present the model is never called.

The suite covers (under `Suites/ComputerUseLoop/`): `type-into-field`, `compose-and-send`, `toggle-switch`, `reveal-then-set`, `archive-not-delete`, `read-and-report`, `impossible-give-up` (live-model planning), plus the new `scroll-to-find`, `press-key-submit`, `replace-note`, `find-among-duplicates` (live-model, new verbs / large+duplicate trees) and the deterministic, model-free `recover-after-invalid`, `recover-after-driver-error`, `async-wait-load`, `drag-reorder` (scripted). See `Suites/ComputerUseLoop/README.md` for the full per-case map.

```bash
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/ComputerUseLoop MODEL=foundation
# The scripted (model-free) cases also run deterministically under the eval-kit
# unit tests in Packages/OsaurusEvals/Tests/OsaurusEvalsKitTests.
```

### `computer_use` domain

Pure-data (no LLM): rebuilds a single `agent_action` exactly as the loop hands it to the gate and pins the `EffectClassifier` / gate decision against `expect.computerUse`. Pick a sibling under `Suites/ComputerUse/` as a template.

### Other domains

The pure-data domains (`schema`, `tool_envelope`, `streaming_hint`, `prefix_hash`, `argument_coercion`, `request_validation`) follow the same shape — pick one of the existing `Suites/<domain>/*.json` cases as a template and copy it.

## Recall floors gate

`Config/recall_floors.json` lists per-case `minMatches` floors for `--fail-on-floor`. The flag is opt-in (not yet wired into CI) and lets contributors dry-run a stricter recall gate locally before it becomes authoritative. Cases intentionally omitted from the floor map are documented in the file's `_comment` (today: indexer-side exclusions, abstain cases blocked by RRF saturation, and embedder-miss cases that need a description audit).

When a case in the floor map's accepted-hit count drops below `minMatches`, the run exits non-zero even if the case itself "passes" by softer criteria. The gate is independent of pass/fail outcome so it can catch silent recall slippage that the case-level matcher wouldn't.

## Adding a new case

1. Drop `Suites/<Domain>/my-case.json` with the schema above (pick a sibling case as a template).
2. `swift run osaurus-evals run --suite Suites/<Domain> --filter my-case` to iterate.
3. Once green, run the whole suite to make sure you didn't break a sibling.
4. If your case asserts a recall floor, add it to `Config/recall_floors.json` so `--fail-on-floor` covers it.

## Adding a new domain

1. Add `Suites/<NewDomain>/` with a few JSON cases.
2. In `Sources/OsaurusEvalsKit/EvalRunner.swift`, add a `case "<newdomain>":` arm to `runOne(...)`. Keep domain runners as separate top-level functions; merging them into one branch gets messy fast.
3. If the domain needs a new `expect.<sub>` block, add it to `EvalCase.Expectations` in `Sources/OsaurusEvalsKit/EvalCase.swift` (all sub-blocks are optional so existing cases keep decoding).
4. If the domain drives an LLM agent loop or a judge, add a public facade in OsaurusCore (mirror `CapabilityClaimsEvaluator`) rather than reaching into internal chat types from the evals package.

## CI isolation

This package is a **separate Swift package**. CI / Xcode builds run `swift build` and `swift test` from `Packages/OsaurusCore`, never from here. Even if someone does `swift test` from inside `Packages/OsaurusEvals`, no test target exists yet — runner unit tests should be added with a `OSAURUS_EVALS_ENABLED=1` env-var gate so they never burn tokens unintentionally.

## Future hooks (deliberately stubbed)

- `osaurus-evals diff baseline.json current.json` — regression check against a stored baseline.
- Per-model scoreboards under `reports/<model>/<date>.json`.
- Auto-run on new model release (CI workflow listening for HF releases).
- Domain growth: `Suites/ToolCalling/`, `Suites/SkillInjection/`.

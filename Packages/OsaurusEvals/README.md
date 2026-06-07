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
    ArgumentCoercion/   — ArgumentCoercion.{stringArray,int,bool} pinning
    CapabilityClaims/   — agent-loop "do you have X" behaviour + LLM judge (LLM)
    CapabilitySearch/   — index-only recall measurements (no LLM)
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

Or call the CLI directly if you need flags the Makefile doesn't expose:

```bash
cd Packages/OsaurusEvals
swift run osaurus-evals run --suite Suites/CapabilitySearch --model foundation
swift run osaurus-evals run --suite Suites/CapabilitySearch --filter browser --out report.json
swift run osaurus-evals run --suite Suites/CapabilitySearch --bootstrap-plugins
```

Startup bootstrap is domain-aware. Suites that require installed native plugins
load them and rebuild search indices so they mirror the host app. `capability_search`
suites initialize only the selected tool / method / skill index lanes without
loading native plugins; those index-only runs use isolated temporary storage so
fixtures never touch the user's real encrypted databases. Debug builds also use
a deterministic in-process storage key; release builds still use OsaurusCore's
normal noninteractive storage-key path against the isolated database files.
Plugin-required cases are skipped unless you pass `--bootstrap-plugins`. A
filtered run that only selects plugin-required cases skips without index
bootstrap.

Exit codes:

- `0` — every non-skipped case passed
- `1` — at least one case failed or errored
- `2` — bad arguments / suite path
- `124` — startup bootstrap exceeded `--startup-timeout`

## Case schema

Every case file shares a top-level shape: `id`, `domain`, optional `label` and `notes`, `query`, `fixtures`, `expect`. The `domain` field selects which runner branch handles the case and which `expect.<sub>` block is required. Nine domains exist today:

| Domain | Hits LLM? | Runner branch | Required expectation block |
|---|---|---|---|
| `capability_claims` | yes | `runCapabilityClaimsCase` | `expect.capabilityClaims` |
| `capability_search` | no | `runCapabilitySearchCase` | `expect.capabilitySearch` |
| `schema` | no | `runSchemaCase` | `expect.schema` |
| `tool_envelope` | no | `runToolEnvelopeCase` | `expect.toolEnvelope` |
| `streaming_hint` | no | `runStreamingHintCase` | `expect.streamingHint` |
| `prefix_hash` | no | `runPrefixHashCase` | `expect.prefixHash` |
| `argument_coercion` | no | `runArgumentCoercionCase` | `expect.argumentCoercion` |
| `request_validation` | no | `runRequestValidationCase` | `expect.requestValidation` |

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

### Other domains

The five pure-data domains (`schema`, `tool_envelope`, `streaming_hint`, `prefix_hash`, `argument_coercion`, `request_validation`) follow the same shape — pick one of the existing `Suites/<domain>/*.json` cases as a template and copy it.

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
- Domain growth: `Suites/AgentLoop/`, `Suites/ToolCalling/`, `Suites/SkillInjection/`.

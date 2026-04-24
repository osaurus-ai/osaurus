# OsaurusEvals

Catalog-driven behaviour / integration tests for Osaurus that hit a real model (Foundation, MLX, remote provider).

These evals are deliberately **off the CI path**. They burn LLM tokens, depend on local plugin installs, and exist to help us tune capabilities and triage new models — not to gate every commit.

## Structure

```
Packages/OsaurusEvals/
  Package.swift
  README.md (this file)
  Sources/
    OsaurusEvalsKit/    — library (case schema, runner, scorers, model override)
    OsaurusEvalsCLI/    — `osaurus-evals` executable
  Suites/
    Preflight/          — preflight pick + companion teaser cases
    AgentLoop/          — placeholder for future agent-loop cases
    ...
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
swift run osaurus-evals run --suite Suites/Preflight --model foundation
swift run osaurus-evals run --suite Suites/Preflight --filter browser --out report.json
```

Exit codes:

- `0` — every non-skipped case passed
- `1` — at least one case failed or errored
- `2` — bad arguments / suite path

## Case schema

Minimal example:

```json
{
  "id": "preflight.browser.amazon-orders",
  "domain": "preflight",
  "label": "browser • amazon orders",
  "query": "can you help me check my orders on amazon?",
  "fixtures": {
    "preflightMode": "balanced",
    "requirePlugins": ["osaurus.browser"]
  },
  "expect": {
    "tools": {
      "mustInclude": ["browser_navigate"]
    },
    "companions": {
      "skills": ["Osaurus Browser"],
      "siblings": {
        "minOverlap": 2,
        "candidates": ["browser_open_login", "browser_do", "browser_console_messages"]
      }
    }
  }
}
```

Field reference:

- `id` — unique slug; surfaced in reports for diffing across runs.
- `domain` — selects the runner code path. Today only `preflight` is supported.
- `label` — optional human label; falls back to `id`.
- `query` — the user message preflight runs against.
- `fixtures.preflightMode` — `off` / `narrow` / `balanced` / `wide`. Default `balanced`.
- `fixtures.requirePlugins` — plugin ids the case needs locally. Cases with missing plugins are **skipped** (not failed) so an incomplete install doesn't mask real regressions.
- `expect.tools.mustInclude` / `mustNotInclude` — picked-set assertions, equal-weighted. Partial credit is given.
- `expect.companions.skills` — plugin skills that should surface in the teaser. **Use the registered display name** (e.g. `"Osaurus Browser"`), not the slug. Plugin skills authored with the agent-skills `lowercase-hyphen` form get title-cased on registration (`osaurus-browser` → `Osaurus Browser`); the companion teaser surfaces the display name and that's what `capabilities_load` looks up.
- `expect.companions.siblings` — at-least-N overlap matcher against a candidate list (resilient to ordering churn).

A case with empty `expect: {}` is a valid smoke test — it records what preflight did without scoring anything. Useful while bootstrapping.

## Adding a new case

1. Drop `Suites/Preflight/my-case.json` with the schema above.
2. `swift run osaurus-evals run --suite Suites/Preflight --filter my-case` to iterate.
3. Once green, run the whole suite to make sure you didn't break a sibling.

## Adding a new domain

1. Add `Suites/<NewDomain>/` with a few JSON cases.
2. In `Sources/OsaurusEvalsKit/EvalRunner.swift`, add a `case "<newdomain>":` arm to `runOne(...)`. Keep domain runners as separate top-level functions; merging them into one branch gets messy fast.

## CI isolation

This package is a **separate Swift package**. CI / Xcode builds run `swift build` and `swift test` from `Packages/OsaurusCore`, never from here. Even if someone does `swift test` from inside `Packages/OsaurusEvals`, no test target exists yet — runner unit tests should be added with a `OSAURUS_EVALS_ENABLED=1` env-var gate so they never burn tokens unintentionally.

## Future hooks (deliberately stubbed)

- `osaurus-evals diff baseline.json current.json` — regression check against a stored baseline.
- Per-model scoreboards under `reports/<model>/<date>.json`.
- Auto-run on new model release (CI workflow listening for HF releases).
- Domain growth: `Suites/AgentLoop/`, `Suites/ToolCalling/`, `Suites/SkillInjection/`.

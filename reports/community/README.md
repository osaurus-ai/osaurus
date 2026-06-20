# reports/community/ — crowdsourced model compatibility

The core team can't run every model and quant on every Mac. This directory is
how the **community** fills in the long tail: you run Osaurus's agentic eval
suites against a model on **your** hardware and contribute the result. A
maintainer folds every contribution into the [`../COMPATIBILITY.md`](../COMPATIBILITY.md)
leaderboard.

**One file per contribution.** Each contribution is a single self-contained
JSON file (a cross-model `EvalMatrix` carrying a `RunEnvironment` provenance
block). You only ever **add** a file — never edit a shared one — so any number
of contributors can open PRs in parallel without merge conflicts.

## Contribute (the easy way: PR)

```bash
# Run the per-model LLM suites for ONE model on your Mac.
# Export a strong judge key (or JUDGE_MODEL) so LLM-judged suites aren't
# self-judged — otherwise those grades are weaker (and flagged as a caveat).
export XAI_API_KEY=...            # optional but recommended
MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute
```

This writes `reports/community/<chip>-<model>-<date>.json`, **validates** that
it carries the provenance a trustworthy row needs, and prints the exact `git` +
`gh pr create` commands. Open a PR with just that one file.

- **Remote models** (e.g. `xai/grok-4.3`) need the matching `<PREFIX>_API_KEY`.
- **KV regime:** set `KV_REGIME=memory-only|disk-l2|paged` to record it.
- Prefer not to use git? Open a
  [**Model compatibility report**](https://github.com/osaurus-ai/osaurus/issues/new?template=model-compatibility.yml)
  issue and paste the file — a maintainer will commit it.

## What's in a contribution file

A contribution is the matrix JSON the loop produced, with a `RunEnvironment` on
each model column. The provenance is what makes a stranger's pass-rate
comparable and trustworthy:

| Field | Why it matters |
| --- | --- |
| `chip`, `totalRamMb`, `osVersion` | Hardware coverage — "does it fit in 16GB?" is the headline Mac question. |
| `osaurusVersion` / `commit` | Results drift across builds. |
| `judge` | LLM-judged suites depend on the judge; `self-judge` is weaker (caveat). |
| `kvRegime` | Swings RAM + speed. |
| `catalogHash` | The comparability key — two runs with the same hash graded the *same* case set. |

## Verdicts

`make evals-compat` assigns each model a coarse compatibility verdict.
Compatibility ("does the harness run it?") is a separate axis from quality
("how good are the answers?"), but a model that errors on every case is the
headline incompatibility signal:

| Verdict | Meaning |
| --- | --- |
| **works** | Runs cleanly through the loop, no harness errors, ≥40% pass-rate. |
| **partial** | Runs, but with errors present or a sub-40% pass-rate. |
| **broken** | Error-dominated (>50% of attempts) or never produced a gradeable answer. |
| **unknown** | Nothing was attempted/gradeable. |

A `⚠` next to a verdict means contributions for that model used **different
catalog hashes** (graded different case sets), so the aggregate pass-rate mixes
denominators — see the leaderboard's Caveats section.

## Maintainers: regenerate the leaderboard

```bash
make evals-compat                 # reports/community/* -> COMPATIBILITY.{md,json}
VALIDATE=1 make evals-compat      # PR gate: every contribution decodes + has provenance
```

Contributors only add files under `community/`; the leaderboard is regenerated
on merge so it never becomes a merge-conflict point.

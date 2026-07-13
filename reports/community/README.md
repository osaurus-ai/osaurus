# reports/community/ — crowdsourced model compatibility

The core team can't run every model and quant on every Mac. This directory is
how the **community** fills in the long tail: you run Osaurus's agentic eval
suites against a model on **your** hardware and contribute the result. A
maintainer folds every contribution into the [`../COMPATIBILITY.md`](../COMPATIBILITY.md)
leaderboard, including a **Device coverage** table of every chip × RAM shape
that has reported.

**Latest run takes precedence.** The eval catalog evolves with the repo, so
runs against different catalogs graded different exams and are never averaged
together. Per model, the newest contribution defines the headline row; other
contributions that graded the **same catalog** (same exam, other devices) fold
in, and everything older is kept under the model's **History** — visible, but
never pooled into the headline pass-rate. A model whose newest run predates
the newest catalog anywhere in the report is marked *stale*: re-running
`make evals-contribute` for it refreshes the row.

> **Start here:** [`COMMUNITY_EVALS.md`](../../COMMUNITY_EVALS.md) at the repo
> root is the end-to-end contributor guide (works for humans and coding
> agents), including the `PR=1` one-command auto-submission flow.

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
`gh pr create` commands. Open a PR with just that one file — or let the script
do it for you:

```bash
# Fully automatic: branch -> commit (only the one file) -> push (forks if
# needed) -> gh pr create. Requires `gh auth login`.
PR=1 MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute
```

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
| `contributor` | Who ran it — attribution + the contributor ranking. Auto-resolved by `evals-contribute` (gh login / git config; `CONTRIBUTOR=` overrides). |

## Verdicts

`make evals-compat` assigns each model a coarse compatibility verdict,
computed from the model's **current result set only** (its newest run plus any
same-catalog runs on other devices). Compatibility ("does the harness run
it?") is a separate axis from quality ("how good are the answers?"), but a
model that errors on every case is the headline incompatibility signal:

| Verdict | Meaning |
| --- | --- |
| **works** | Runs cleanly through the loop, no harness errors, ≥40% pass-rate. |
| **partial** | Runs, but with errors present or a sub-40% pass-rate. |
| **broken** | Error-dominated (>50% of attempts) or never produced a gradeable answer. |
| **unknown** | Nothing was attempted/gradeable. |

A *stale* marker means the model's newest run graded an older catalog than the
newest one in the report — the row is honest about its own age and the model
needs a fresh contribution.

## What the leaderboard shows per model

- **The full funnel** — every case a run attempted is either scored
  (passed/failed), skipped, or errored, and all four counts are shown. Skips
  mean "didn't apply on that host" (e.g. sandbox unavailable, plugin missing,
  tiny-context model can't take tools), not "regressed".
- **Skipped areas with reasons** — each model's detail section lists which
  domains skipped cases and why, from the contribution's per-domain
  skip-reason histogram. Contributions written before skip reasons were
  recorded show "reasons unrecorded (pre-schema contribution)".
- **Strengths** — domains with a ≥90% pass-rate on ≥5 scored cases surface in
  the headline's "Great at" column (and the weakest qualifying domain is
  flagged), backed by a full per-domain breakdown in the detail section.
- **History** — superseded (older-catalog) runs, listed per model with their
  own pass-rates so drift across catalogs/builds stays visible.
- **Contributors** — every run is attributed and ranked. `evals-contribute`
  stamps your identity into the contribution's provenance (resolved from your
  GitHub CLI login or git config; override with `CONTRIBUTOR=<handle>`), and
  older files fall back to the git author who added them. The leaderboard
  ranks contributors by runs contributed (current and superseded both count),
  then by breadth of models and device shapes covered.

## Maintainers: regenerate the leaderboard

```bash
make evals-compat                 # reports/community/* -> COMPATIBILITY.{md,json}
VALIDATE=1 make evals-compat      # PR gate: every contribution decodes + has provenance
```

Contributors only add files under `community/`; the leaderboard is regenerated
on merge so it never becomes a merge-conflict point.

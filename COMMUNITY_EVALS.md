# Community Evals — run the suite on YOUR Mac, PR the result

Osaurus wants a **comprehensive map of which models work on which Macs**: every
chip (M1 → M4, Pro/Max/Ultra) × every RAM size (8GB → 192GB) × every model and
quant people actually run. The core team can't own that matrix — you can fill
in a cell in one command. Each contribution is a single JSON file under
`reports/community/`; a maintainer folds them into the
[`reports/COMPATIBILITY.md`](reports/COMPATIBILITY.md) leaderboard, which
includes a **Device coverage** table of every chip × RAM shape that has
reported so far.

This document is written to be executable by a human **or** handed to a coding
agent ("run the Osaurus community evals for model X and open the PR") — the
whole flow is one make target.

## TL;DR

```bash
git clone https://github.com/osaurus-ai/osaurus.git && cd osaurus
export XAI_API_KEY=...   # optional but recommended (strong judge; see below)
PR=1 MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute
```

That runs the per-model eval suites against the model on your hardware, writes
`reports/community/<chip>-<model>-<date>.json`, validates its provenance, and
— with `PR=1` — creates a branch containing **only that file**, pushes it
(forking the repo first if you don't have push access), and opens the PR with
`gh`. Nothing else on your machine is committed or uploaded.

## Prerequisites

| Requirement | Why / how |
| --- | --- |
| Apple Silicon Mac | The harness measures MLX inference; Intel results aren't comparable. |
| Xcode (or CLT) + Swift toolchain | `swift build` compiles the harness on first run. |
| [GitHub CLI](https://cli.github.com) (`brew install gh; gh auth login`) | Only needed for `PR=1` auto-submission. |
| The model you're contributing | Local MLX models must already be downloaded (installed via the Osaurus app, or pass any HF repo id and the harness resolves it from your models dir). Remote models (e.g. `xai/grok-4.3`) need the matching `<PREFIX>_API_KEY` exported. |
| ~30–90 minutes | Depends on the model's decode speed and your machine. Plug into AC power and avoid heavy GPU work during the run — thermal state and power source are recorded and flagged. |
| A judge key (optional, recommended) | Export `XAI_API_KEY` (or set `JUDGE_MODEL` + its key) so rubric-graded suites aren't **self-judged** by the model being measured. Self-judged runs are accepted but flagged as weaker. |

## Choosing what to run

The most valuable contributions, in order:

1. **A device shape nobody has reported yet** — check the *Device coverage*
   table in [`reports/COMPATIBILITY.md`](reports/COMPATIBILITY.md). A base
   M1/8GB or an Ultra/192GB row is worth more than a tenth M4 Pro row.
2. **A model with no row yet** (or verdict `unknown`/`partial`) on any device.
3. **An existing model × new device** — fills in the RAM band and decode-speed
   spread for a model that only has one machine reporting.

Run one model per invocation; run the command again for the next model.

```bash
# Local MLX models (must be downloaded already):
PR=1 MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute
PR=1 MODEL=OsaurusAI/gemma-4-12B-it-MXFP8 make evals-contribute

# Apple's on-device Foundation model (macOS 26+, nothing to download):
PR=1 MODEL=foundation make evals-contribute

# Remote providers (records YOUR machine as the harness host):
export XAI_API_KEY=...
PR=1 MODEL=xai/grok-4.3 make evals-contribute

# Record the KV-cache regime you run with (optional):
KV_REGIME=disk-l2 PR=1 MODEL=... make evals-contribute
```

## What gets uploaded (and what doesn't)

The contribution file is an aggregate scoreboard (`EvalMatrix`): per-domain
pass/fail counts, mean decode tok/s, TTFT, peak RAM footprint, and a
`RunEnvironment` provenance block:

| Field | Example |
| --- | --- |
| `chip`, `totalRamMb`, `cpuCores`, `osVersion` | `Apple M4 Pro`, `49152`, `14`, `26.2.0` |
| `commit` / `osaurusVersion` | the build the run measured |
| `judge` | `xai/grok-4.3` or `self-judge` |
| `kvRegime` | `memory-only` / `disk-l2` / `paged`, when declared |
| `catalogHash`, `caseCount` | which exact case set was graded (comparability key) |
| `thermalState`, `lowPowerMode`, `powerSource` | perf-comparability caveats |

**Not** included: prompts, model outputs, transcripts, file paths, usernames,
API keys. Failure transcripts stay in the git-ignored `build/` dir on your
machine. The auto-PR commits exactly one new file and never touches shared
files, so parallel contributions can't conflict.

## Your Osaurus data is untouched

Every eval process runs against a **disposable storage root** under your
system temp dir (`osaurus-evals-<uuid>`), never your real `~/.osaurus`. The
dummy agents, providers, schedules, memories, and chat state the suites seed
all land in that throwaway root — your chats, agents, memories, and settings
are exactly as you left them after the run. The run only *reads* a few host
resources: your installed models/plugins (read-only), plus one-shot copies of
your chat and sandbox config so model resolution and sandbox detection work.
The one shared resource is the sandbox VM itself (it takes minutes to boot and
is shared with the app); per-case cleanup unprovisions the temporary eval
agents it creates inside the VM.

On normal completion the disposable root is deleted automatically. If a run
crashes or is killed, the leftover root under `$TMPDIR` is swept by the next
eval run (or can be removed manually — `rm -rf "$TMPDIR"/osaurus-evals-*`
while no eval is running).

## Instructions for coding agents

If you are an AI agent asked to contribute a run, follow these steps exactly:

1. Verify preconditions: Apple Silicon (`sysctl -n machdep.cpu.brand_string`),
   `gh auth status` succeeds, and the requested `MODEL` is either a remote id
   with its API key exported or a local model that resolves under the user's
   models directory. If the user gave no model, ask for one — do not guess.
2. From a clean checkout of the default branch, run:
   `PR=1 MODEL=<model-id> make evals-contribute`
   Do not run it concurrently with other GPU/inference work, and do not run
   multiple models in parallel — results would be thermally skewed.
3. The run is long (30–90 min). Do not kill it on the first quiet stretch;
   per-case watchdogs handle hangs. It ends by printing the PR URL.
4. If provenance validation fails, or the run errors before scoring, report
   the error output to the user — do **not** hand-edit the JSON or bypass
   `--validate` to force a submission.
5. Never add anything to the PR beyond the single generated file under
   `reports/community/`, and never edit existing files there or the
   leaderboard (`reports/COMPATIBILITY.*` is regenerated by maintainers).
6. On success, give the user the PR URL and the one-line environment summary
   the script prints.

## No-git fallback

Prefer not to push anything? Run without `PR=1`:

```bash
MODEL=mlx-community/Qwen3-4B-4bit make evals-contribute
```

then open a [Model compatibility report](https://github.com/osaurus-ai/osaurus/issues/new?template=model-compatibility.yml)
issue and paste the generated JSON — a maintainer commits it for you.

## For maintainers

```bash
VALIDATE=1 make evals-compat   # PR gate: every contribution decodes + carries provenance
make evals-compat              # fold reports/community/* -> COMPATIBILITY.{md,json}
```

Merging a contribution PR is: check `VALIDATE=1` passes, regenerate the
leaderboard, commit both. Contributions only ever add files, so any number of
community PRs merge cleanly in any order. Details on the file format and
verdict heuristic: [`reports/community/README.md`](reports/community/README.md).

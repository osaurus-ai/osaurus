# Eval Watcher

The eval watcher workflow stores local + frontier eval report bundles for
mainline and release-candidate checks, then refreshes a scoreboard across those
bundles. It is an artifact workflow only: it does not change prompts, default
tools, routing, or model runtime behavior.

## Maintainer Loop

Use the watcher when a branch may affect agent-loop behavior or when a
release-candidate needs a durable comparison against main.

1. Run the watcher against the current branch.

   ```bash
   make evals-watcher-report \
     EVALS_WATCHER_CHANNEL=main \
     EVALS_WATCHER_ARTIFACT_ID=main-$(date -u +%Y%m%dT%H%M%SZ) \
     EVALS_REPORT_PRESET=local-frontier \
     LOCAL_MODEL=foundation \
     FRONTIER_MODEL=openai/gpt-4o-mini
   ```

2. Read the stored report and scoreboard.

   ```bash
   open build/evals/watcher/main/scoreboard/latest/scoreboard.md
   ```

3. Tweak the implementation or eval fixture.

4. Run the watcher again with the same channel. The new report is stored beside
   the previous run, and the scoreboard is rebuilt across all stored runs.

5. If a saved mainline report should be the baseline, pass it explicitly.

   ```bash
   make evals-watcher-report \
     EVALS_WATCHER_CHANNEL=release-candidate \
     EVALS_WATCHER_ARTIFACT_ID=rc-agent-loop-20260621 \
     BASELINE_DIR=build/evals/watcher/main/20260621T120000Z/report \
     LOCAL_MODEL=foundation \
     FRONTIER_MODEL=openai/gpt-4o-mini
   ```

   The default no-regression threshold is strict: `EVALS_MAX_REGRESSIONS=0`.
   Raise it only for explicitly accepted release-candidate risk, and keep the
   threshold in the artifact command or scoreboard rebuild command.

## Artifacts

Each watcher run writes:

- `build/evals/watcher/<channel>/<timestamp>/report/manifest.json`
- `build/evals/watcher/<channel>/<timestamp>/report/summary.json`
- `build/evals/watcher/<channel>/<timestamp>/report/summary.md`
- `build/evals/watcher/<channel>/<timestamp>/report/reports/<model>/<suite>.json`
- `compare.json` and `compare.md` when `BASELINE_DIR` is supplied
- `watcher-status.json` with completed, failed, or canceled wrapper status

The scoreboard refresh writes:

- `build/evals/watcher/<channel>/scoreboard/latest/scoreboard.json`
- `build/evals/watcher/<channel>/scoreboard/latest/scoreboard.md`

To rebuild a scoreboard without running models:

```bash
make evals-scoreboard \
  EVALS_SCOREBOARD_ROOT=build/evals/watcher/main \
  EVALS_SCOREBOARD_OUT=build/evals/scoreboard/main \
  EVALS_MAX_REGRESSIONS=0
```

The scoreboard includes:

- Latest release-candidate artifact ID, branch, commit, baseline, and verdict.
- Local and frontier preset score lines for the latest stored run.
- Cross-run model and suite pass-rate tables.
- Baseline comparison totals and no-regression threshold status.

## Fixture Smoke

The watcher supports a no-provider path for script and artifact validation:

```bash
make evals-watcher-report \
  EVALS_WATCHER_CHANNEL=fixture-smoke \
  EVALS_REPORT_PRESET=local-only \
  EVALS_FROM_REPORTS=Packages/OsaurusEvals/Tests/OsaurusEvalsKitTests/Fixtures/AgentLoopRegressionLab \
  OSAURUS_EVALS_SKIP_PREP=1
```

This reads existing `EvalReport` JSON, builds the same report bundle shape, and
refreshes the same scoreboard files.

## Stop and Cancel

The watcher wrapper traps `INT` and `TERM`. If a maintainer stops a long model
run, the active child process is terminated, `watcher-status.json` records
`canceled`, and the wrapper exits `130` without refreshing the scoreboard from a
partial report. A report that completes with eval failures still refreshes the
scoreboard so the failed artifact remains visible.

## Dedicated Mac Runner

An optional runner can be a Mac mini or Studio with:

- Xcode and the repo checkout.
- Local model assets already warmed for `foundation` or the desired MLX model.
- Provider API keys available only in the runner environment.
- A scheduled job that runs `make evals-watcher-report` on `main` and on
  release-candidate branches.
- Artifact upload or retention for `build/evals/watcher/`.

Keep the runner out of normal CI unless the token and machine budget is
intentional. The watcher is designed for durable maintainer evidence, not for
per-commit gating.

## Cost Controls

Use these controls to keep frontier spend bounded:

- `EVALS_REPORT_PRESET=local-only` runs only the local lane; the default
  `local-frontier` is still the release-evidence preset.
- `FILTER=<case-substring>` narrows a run while iterating.
- `--suite <dir>` on `scripts/evals/eval-watcher-report.sh` narrows the suite
  set. The Make wrapper keeps the default local + frontier report shape.
- `EVALS_FROM_REPORTS=<dir>` validates artifact plumbing without live calls.
- `PLAN_ONLY=1` prints the watcher commands without executing them.
- `BASELINE_DIR=<dir>` reuses a stored baseline instead of repeating it.
- `EVALS_MAX_REGRESSIONS=<n>` changes only the scoreboard threshold report and
  exit status; it does not hide the underlying comparison counts.
- Leave `INCLUDE_SANDBOX_FRONTIER` unset unless the runner has the sandbox
  prerequisites and budget for those cases.

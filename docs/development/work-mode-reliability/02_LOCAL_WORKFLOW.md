# Local Workflow

## Goal

Develop Work Mode reliability changes incrementally on a live upstream repository without mixing phases, losing sync with `upstream/main`, or pushing unreviewed work too early.

## Repository Model

- `upstream` points to `osaurus-ai/osaurus`
- `origin` points to `mimeding/osaurus`
- local `main` tracks `upstream/main`
- feature work is always done on a dedicated branch

## Branch Rules

- one phase = one branch
- one branch = one pull request
- do not stack multiple roadmap phases into one branch
- do not commit directly on `main`

Current branch naming pattern:

- `feature/work-completion-contract`
- `feature/runtime-steering-attachments`
- `feature/working-set-compaction-restore`

## Daily Start

```bash
git fetch upstream
git switch main
git rebase upstream/main
```

If starting a new phase:

```bash
git switch -c feature/<phase-name>
```

## Before Every Commit

1. check `git status`
2. confirm only files for the current phase changed
3. run the targeted unit tests for the touched subsystem
4. run the phase security checklist
5. update the phase document if scope or verification changed

## Before Every Push

```bash
swift-format lint --strict --recursive Packages App
swiftlint lint
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCoreTests -skip-testing OsaurusCoreTests/KVCacheStoreTests -skip-testing OsaurusCoreTests/MLXGenerationEngineTests
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCLITests
```

## SwiftPM Fallback

If the package-local `.build` directory under `Documents` becomes unreliable or produces transient manifest I/O errors, run focused package tests with a clean scratch path under `/tmp`:

```bash
cd Packages/OsaurusCore
swift test --scratch-path /tmp/osauruscore-phase-build --filter '<TestSuiteName>'
```

Use this as a local verification fallback, not as a substitute for the normal repo-level lint and test gate before push.

## Pull Request Rules

- push only to `origin`
- open PRs against `osaurus-ai/osaurus:main`
- link each PR back to [osaurus-ai/osaurus#825](https://github.com/osaurus-ai/osaurus/issues/825)
- keep the PR summary narrow and phase-specific
- include local verification notes in the PR body

## After Merge

```bash
git switch main
git fetch upstream
git rebase upstream/main
git branch -D feature/<merged-phase>
git push origin --delete feature/<merged-phase>
```

## If Upstream Moves While A PR Is Open

```bash
git fetch upstream
git switch feature/<phase-name>
git rebase upstream/main
git push --force-with-lease origin feature/<phase-name>
```

Use `--force-with-lease`, never plain `--force`.

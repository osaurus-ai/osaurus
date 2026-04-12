# Phased Development Plan

## Goal

Incrementally incorporate the highest-value Claude Code harness learnings into Osaurus without destabilizing the existing architecture.

The governing principle is:

- preserve Osaurus strengths
- tighten runtime control
- ship small phases
- test each phase deeply
- security-review every new control path

## Preserve These Osaurus Strengths

Do not regress:

1. explicit prompt composition
2. capability retrieval across tools, methods, and skills
3. durable memory design
4. per-agent sandbox isolation
5. structured work and issue execution

## Development Model

One phase equals:

- one branch
- one focused implementation theme
- one test plan
- one security checklist
- one PR

Standard workflow:

```bash
git fetch upstream
git switch main
git rebase upstream/main
git switch -c feature/<phase-name>
```

Before commit and before push:

```bash
swift-format lint --strict --recursive Packages App
swiftlint lint
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCoreTests -skip-testing OsaurusCoreTests/KVCacheStoreTests -skip-testing OsaurusCoreTests/MLXGenerationEngineTests
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCLITests
```

## Phase Sequence

### Phase 1

`feature/work-completion-contract`

Goal:

- make `complete_task` structured and evidence-aware

Why first:

- smallest high-leverage change
- easiest to review
- directly improves trust in results

### Phase 2

`feature/runtime-steering-attachments`

Goal:

- add dynamic runtime reminders tied to live execution state

### Phase 3

`feature/working-set-compaction-restore`

Goal:

- preserve live task state through compaction and resume

### Phase 4

`feature/work-verifier-pass`

Goal:

- separate task execution from result validation

### Phase 5

`feature/transcript-repair-and-stall-detection`

Goal:

- improve long-horizon transcript integrity
- detect wasted iterations

### Phase 6

`feature/host-folder-risk-classifier`

Goal:

- strengthen non-sandbox execution governance

### Phase 7

`feature/work-tool-orchestration`

Goal:

- batch safe independent tool calls for throughput

## Security Gate For Every Phase

Every phase must answer:

1. Does this change increase authority or only improve control?
2. Can untrusted model text alter control state unexpectedly?
3. Can secrets, filesystem paths, or sensitive tool outputs leak into prompts or logs?
4. Is any new serialized state bounded, schema-checked, and non-secret?
5. Does the failure path fail closed rather than silently accepting weak behavior?

## Testing Gate For Every Phase

Every phase must include:

1. new unit tests for the new behavior
2. regression tests for the old expected behavior that should still hold
3. at least one negative-path test
4. local lint pass
5. targeted `xcodebuild test` execution notes

## Merge Strategy

- Wait for maintainer signal on [#825](https://github.com/osaurus-ai/osaurus/issues/825) before pushing PRs.
- Keep later phases local until earlier phases are accepted or clearly approved.
- Rebase feature branches on latest `upstream/main` before opening a PR.
- Do not stack unrelated phases in the same diff.

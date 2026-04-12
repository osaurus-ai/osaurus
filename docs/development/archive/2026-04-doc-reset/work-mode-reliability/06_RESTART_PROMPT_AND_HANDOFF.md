# Restart Prompt And Handoff

## Purpose

Use this file if a fresh chat is needed.

It preserves:

- the canonical Work Mode reliability development plan
- the current Phase 1 implementation state
- the branch and GitHub management model
- the exact distinction between the clean PR branch and the local integration branch
- the current operating plan and next execution task

## Canonical Sources

Treat these files as the source of truth for the roadmap and change-management model:

1. `docs/development/work-mode-reliability/00_PHASED_DEVELOPMENT_PLAN.md`
2. `docs/development/work-mode-reliability/01_PHASE_WORK_COMPLETION_CONTRACT.md`
3. `docs/development/work-mode-reliability/02_LOCAL_WORKFLOW.md`
4. `docs/development/work-mode-reliability/03_TESTING_AND_SECURITY_GATES.md`
5. `docs/development/work-mode-reliability/04_BRANCHING_AND_PR_STRATEGY.md`
6. `docs/development/work-mode-reliability/05_CURRENT_STATUS.md`

Do not replace these with a looser summary. The earlier chat degraded context by broadening the roadmap and weakening the phase-governance model.

Also read this operating supplement after the canonical files:

- `docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md`
- `docs/development/work-mode-reliability/08_LOCAL_WORKTREE_RUNBOOK.md`

## Current Git State

Repository:

- `/Users/mmeding/Documents/Claude/Projects/osaurus`

Remotes:

- `origin = git@github.com:mimeding/osaurus.git`
- `upstream = https://github.com/osaurus-ai/osaurus.git`

Issue anchor:

- `osaurus-ai/osaurus#825`

Branch roles:

- `main`
  - tracks `upstream/main`
- `feature/work-completion-contract`
  - clean public PR branch for Phase 1
  - already pushed to `origin`
- `feature/work-completion-contract-local`
  - local integration branch
  - already pushed to `origin`
  - includes auxiliary build compatibility fixes that are intentionally out of scope for the first Work Mode PR

Current branch at handoff:

- `feature/work-completion-contract-local`

## Phase 1 Status

Phase 1 is implemented locally and validated.

Primary behavior:

- `complete_task` now requires a structured completion contract
- allowed statuses:
  - `verified`
  - `partial`
  - `blocked`
- weak `verified` completions are rejected
- downstream execution results preserve typed completion state
- prompts instruct the model to use the new contract

Main files changed for the clean Phase 1 branch:

- `Packages/OsaurusCore/Models/Work/WorkModels.swift`
- `Packages/OsaurusCore/Tools/WorkTools.swift`
- `Packages/OsaurusCore/Services/WorkExecutionEngine.swift`
- `Packages/OsaurusCore/Services/WorkEngine.swift`
- `Packages/OsaurusCore/Views/Work/WorkSession.swift`
- `Packages/OsaurusCore/Services/Chat/SystemPromptTemplates.swift`
- `Packages/OsaurusCore/Tests/Work/WorkExecutionEngineTests.swift`
- `Packages/OsaurusCore/Tests/Work/WorkEngineResumeTests.swift`

Phase 1 commits on the clean PR branch:

- `f2150fa4` `docs: add Work Mode reliability development plan`
- `7c609153` `feature: strengthen Work Mode completion contract`

## Validation Already Completed

Focused validation already passed for Phase 1:

- `swift-format lint --strict` on touched Swift files
- `swiftlint lint` on touched Swift files
- `swift test --scratch-path /tmp/osauruscore-phase1-build --filter 'WorkExecutionEngineTests|WorkEngineResumeTests'`

The app also built and launched successfully from the local integration branch.

Built app artifact:

- `build/DerivedData/Build/Products/Release/osaurus.app`

## Clean PR Branch Versus Local Integration Branch

This distinction matters.

### Clean public Phase 1 branch

Branch:

- `feature/work-completion-contract`

Contains only the Work Mode Phase 1 change set and development-plan docs.

This is the branch to push as the first upstream PR when ready.

### Local integration branch

Branch:

- `feature/work-completion-contract-local`

Additional commits on top of Phase 1:

- `9cae9212` `fix: load FluidAudio ASR models with current API`
- `15c11b49` `build: sync workspace lockfile with validated package set`
- `45ee8c3a` `build: sync project lockfile with validated package set`
- `9fd88e1d` `build: pin Xcode lockfiles to FluidAudio 0.13.6`

Files that differ from the clean Phase 1 branch:

- `Packages/OsaurusCore/Managers/SpeechService.swift`
- `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

These changes exist to keep local builds green and are not part of the intended first Work Mode PR unless maintainers explicitly want them included or split into separate upstream fixes.

## Untracked Local Files

These files are currently untracked and should not be silently mixed into the Work Mode PR:

- `BUILDING_FROM_SOURCE_LESSONS.md`
- `BUILD_GUIDE.md`
- `SUPPLY_CHAIN_VERIFICATION.md`
- `Security_Review_Osaurus_vs_LCW.md`
- `docs/development/work-mode-reliability/06_RESTART_PROMPT_AND_HANDOFF.md`
- `docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md`
- `scripts/verify_supply_chain.sh`

Tracked local modification at handoff:

- `docs/development/work-mode-reliability/README.md`

## Canonical Phase Order

This is the correct phase sequence from the original plan:

1. `feature/work-completion-contract`
2. `feature/runtime-steering-attachments`
3. `feature/working-set-compaction-restore`
4. `feature/work-verifier-pass`
5. `feature/transcript-repair-and-stall-detection`
6. `feature/host-folder-risk-classifier`
7. `feature/work-tool-orchestration`

Rules:

- one phase = one branch
- one phase = one focused implementation theme
- one phase = one test plan
- one phase = one security checklist
- one phase = one PR

## Current Operating Plan

The remaining-phase operating plan now exists:

- `docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md`
- `docs/development/work-mode-reliability/08_LOCAL_WORKTREE_RUNBOOK.md`

Those files should be treated as the execution supplements for the rest of the program.

## What The Next Chat Should Do

The next chat should not re-invent the roadmap. It should:

1. read the canonical phase documents listed above
2. read `07_REMAINING_PHASES_OPERATING_PLAN.md`
3. read `08_LOCAL_WORKTREE_RUNBOOK.md`
4. preserve the branch-role distinction
5. preserve the testing and security gates
6. preserve the ability to push Phase 1 immediately from `feature/work-completion-contract`
7. keep the local integration fixes separate unless a maintainer asks otherwise
8. execute the next approved move from the operating plan rather than rebuilding it from scratch

## Copy-Paste Prompt For A New Chat

```text
We need to continue work on Osaurus from the repository at /Users/mmeding/Documents/Claude/Projects/osaurus.

Before doing anything else, read these files and treat them as the canonical source of truth:

- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/00_PHASED_DEVELOPMENT_PLAN.md
- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/01_PHASE_WORK_COMPLETION_CONTRACT.md
- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/02_LOCAL_WORKFLOW.md
- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/03_TESTING_AND_SECURITY_GATES.md
- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/04_BRANCHING_AND_PR_STRATEGY.md
- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/05_CURRENT_STATUS.md
- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/06_RESTART_PROMPT_AND_HANDOFF.md

Then read this operating supplement:

- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md

Important: a prior chat suffered context degradation. Do not replace the existing phase-governance model with a looser summary. Preserve the original rules:

- one phase = one branch
- one phase = one focused implementation theme
- one phase = one test plan
- one phase = one security checklist
- one phase = one PR

Current Git state:

- clean PR branch: feature/work-completion-contract
- local integration branch: feature/work-completion-contract-local
- origin: git@github.com:mimeding/osaurus.git
- upstream: https://github.com/osaurus-ai/osaurus.git
- issue anchor: osaurus-ai/osaurus#825

Phase 1 is already implemented and validated.

Clean Phase 1 commits:
- f2150fa4 docs: add Work Mode reliability development plan
- 7c609153 feature: strengthen Work Mode completion contract

Local integration-only commits:
- 9cae9212 fix: load FluidAudio ASR models with current API
- 15c11b49 build: sync workspace lockfile with validated package set
- 45ee8c3a build: sync project lockfile with validated package set
- 9fd88e1d build: pin Xcode lockfiles to FluidAudio 0.13.6

Those integration-only commits are not part of the intended first Work Mode PR unless explicitly approved or split into separate upstream fixes.

Current operating-plan file:

- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md
- /Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/work-mode-reliability/08_LOCAL_WORKTREE_RUNBOOK.md

Your task:

Use the canonical documents plus 07 as the active operating model. Do not rebuild the roadmap. Execute the next approved step while preserving these rules:

1. keep `feature/work-completion-contract` frozen unless explicitly preparing the clean Phase 1 PR
2. do Phase 1 PR prep from a clean worktree, not from `feature/work-completion-contract-local`
3. keep local integration-only fixes separate unless maintainers explicitly want them upstream
4. keep planning-doc work on a separate docs branch or another non-Phase-1 branch
5. keep one phase = one branch = one PR intact for all future implementation phases
```

## Recommendation

Yes, opening a fresh chat is reasonable now.

The new chat should start from the canonical files and this handoff file, not from conversational memory.

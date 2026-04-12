# Local Worktree Runbook

## Purpose

This document records the exact local worktree layout for ongoing Work Mode reliability work in this repository.

It is environment-specific and operational. Its job is to let a future AI or operator immediately choose the correct checkout for:

- Phase 1 public PR preparation
- local-only integration work
- documentation updates
- Phase 2 implementation

This runbook supplements:

- `06_RESTART_PROMPT_AND_HANDOFF.md`
- `07_REMAINING_PHASES_OPERATING_PLAN.md`

## Local Worktree Layout

### 1. Primary Local Integration Checkout

Path:

- `/Users/mmeding/Documents/Claude/Projects/osaurus`

Branch:

- `feature/work-completion-contract-local`

Role:

- local integration workspace
- carries compatibility fixes and local planning docs
- not the checkout to use for the clean Phase 1 public PR

Rules:

- do not push the first upstream Work Mode PR from this checkout
- do not use this checkout for clean diff review of Phase 1
- keep treating the extra compatibility commits as out of scope for the first public Work Mode PR unless maintainers explicitly say otherwise

### 2. Clean Phase 1 PR Worktree

Path:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr`

Branch:

- `feature/work-completion-contract`

Role:

- clean public Phase 1 PR preparation tree
- the only local checkout that should be used for Phase 1 PR verification, rebase, push, and PR update work

Current status at setup:

- checked out cleanly from `feature/work-completion-contract`
- no local modifications

Rules:

- keep this branch frozen unless explicitly doing Phase 1 PR preparation
- do not add `06_RESTART_PROMPT_AND_HANDOFF.md`
- do not add `07_REMAINING_PHASES_OPERATING_PLAN.md`
- do not add `08_LOCAL_WORKTREE_RUNBOOK.md`
- do not add unrelated integration fixes

### 3. Documentation Worktree

Path:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/docs`

Branch:

- `docs/work-mode-reliability-operating-plan`

Role:

- documentation-only branch for the updated Work Mode reliability planning set

Intended document set for this branch:

- `docs/development/work-mode-reliability/README.md`
- `docs/development/work-mode-reliability/05_CURRENT_STATUS.md`
- `docs/development/work-mode-reliability/06_RESTART_PROMPT_AND_HANDOFF.md`
- `docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md`
- `docs/development/work-mode-reliability/08_LOCAL_WORKTREE_RUNBOOK.md`

Rules:

- keep this branch documentation-only
- do not base feature implementation on this branch
- do not use this branch as the source branch for the Phase 1 PR

### 4. Clean Phase 2 Public Worktree

Path:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2`

Branch:

- `feature/runtime-steering-attachments`

Role:

- clean future public branch for Phase 2

Base at setup:

- created from local `main` after it was fast-forwarded to `upstream/main`

Rules:

- keep this tree clean until Phase 2 is ready to be promoted to a public branch
- do not do stacked local implementation work directly here while Phase 1 is still unmerged
- do not mix in docs-branch work
- do not mix in Phase 1 PR-prep work

### 5. Local Stacked Phase 2 Worktree

Path:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2-local`

Branch:

- `feature/runtime-steering-attachments-local`

Role:

- active local Phase 2 implementation tree
- stacked deliberately on top of `feature/work-completion-contract` so runtime steering can build against the unmerged Phase 1 completion-contract behavior

Base at setup:

- created from `feature/work-completion-contract`

Rules:

- use this tree for actual local Phase 2 development while Phase 1 is not yet merged
- do not treat this as the public Phase 2 PR branch
- when the time comes to publish Phase 2, promote the work onto `feature/runtime-steering-attachments` deliberately after Phase 1 is merged or maintainers approve the stacked/public strategy

## How To Inspect Each Tree

Use these commands:

```bash
git -C /Users/mmeding/Documents/Claude/Projects/osaurus status --short --branch
git -C /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr status --short --branch
git -C /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/docs status --short --branch
git -C /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2 status --short --branch
git -C /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2-local status --short --branch
git -C /Users/mmeding/Documents/Claude/Projects/osaurus worktree list --porcelain
```

## Standard Operating Sequence

### If Phase 1 Is Approved For PR Prep

Use only:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr`

Suggested sequence:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr
git status --short --branch
git log --oneline upstream/main..HEAD
swift-format lint --strict --recursive Packages App
swiftlint lint
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCoreTests -skip-testing OsaurusCoreTests/KVCacheStoreTests -skip-testing OsaurusCoreTests/MLXGenerationEngineTests
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCLITests
```

Only if maintainers have signaled to proceed and the branch needs rebasing:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr
git fetch upstream
git rebase upstream/main
git push --force-with-lease origin feature/work-completion-contract
```

Then open or update the upstream PR from:

- `mimeding:feature/work-completion-contract`
- to `osaurus-ai:main`

### If The Documentation Branch Should Be Committed Or Pushed

Use only:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/docs`

Suggested sequence:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/docs
git status --short --branch
git add docs/development/work-mode-reliability/README.md
git add docs/development/work-mode-reliability/05_CURRENT_STATUS.md
git add docs/development/work-mode-reliability/06_RESTART_PROMPT_AND_HANDOFF.md
git add docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md
git add docs/development/work-mode-reliability/08_LOCAL_WORKTREE_RUNBOOK.md
git commit -m "docs: organize Work Mode reliability operating runbook"
git push origin docs/work-mode-reliability-operating-plan
```

### If Phase 2 Work Should Start Or Continue Locally

Use only:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2-local`

Suggested sequence:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2-local
git status --short --branch
```

Then keep all implementation scoped to:

- `feature/runtime-steering-attachments-local`

And follow the Phase 2 execution plan in:

- `docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md`

### If Phase 2 Is Ready To Be Promoted Toward A Public Branch

Public Phase 2 branch tree:

- `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2`

Promotion rule:

- do not push `feature/runtime-steering-attachments-local` as if it were automatically the public branch

Preferred promotion path:

1. wait until Phase 1 is merged or maintainers explicitly approve the public stacking strategy
2. refresh `main` and verify the intended public base
3. bring the Phase 2 commits over deliberately onto `feature/runtime-steering-attachments`
4. rerun the Phase 2 verification gate on the public Phase 2 tree
5. only then push or open the public Phase 2 branch

The exact rebase/cherry-pick choice should be made at promotion time based on upstream state and maintainer preference.

## Future AI Instructions

If a future AI should work on a specific tree, use language like this:

### For Phase 1 PR Push Or Update

```text
Use /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr.
Keep feature/work-completion-contract isolated.
Run the canonical Phase 1 verification gate there.
If maintainer signal exists on osaurus-ai/osaurus#825, push or update only that branch and prepare the upstream PR.
Do not use the local integration checkout.
```

### For Documentation Branch Work

```text
Use /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/docs.
Keep docs/work-mode-reliability-operating-plan documentation-only.
Stage and commit only the Work Mode reliability planning docs.
Do not use this branch as a base for implementation.
```

### For Phase 2 Implementation

```text
Use /Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2-local.
Work only on feature/runtime-steering-attachments-local.
Follow the Phase 2 scope in 07_REMAINING_PHASES_OPERATING_PLAN.md.
Do not mix in Phase 1 PR prep, docs-only commits, or local integration-only compatibility fixes.
Do not treat this as the public Phase 2 PR branch.
```

## Local Hygiene Note

The `.local-worktrees/` directory is intentionally excluded through `.git/info/exclude` so the main local integration checkout does not constantly show the linked worktrees as untracked files.

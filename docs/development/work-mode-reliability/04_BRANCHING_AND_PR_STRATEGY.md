# Branching and PR Strategy

## Objective

Keep Work Mode reliability work incremental, reviewable, and safe while developing against a live upstream repository.

## Branch Roles

- `main`
  - always tracks `upstream/main`
  - never contains local feature work
- `feature/work-completion-contract`
  - Phase 1 branch
  - contains only the structured completion contract change set
- future phase branches
  - branch from updated `main`
  - one branch per phase

## Commit Strategy

For each phase:

1. commit docs or test scaffolding if it materially clarifies the phase
2. commit the product behavior change
3. commit follow-up test/doc cleanup if needed

Keep unrelated compatibility fixes out of the main feature commit whenever possible.

## Handling Auxiliary Fixes

Sometimes local verification is blocked by unrelated repo-head breakage.

When that happens:

1. identify whether the blocker is inside or outside the current phase scope
2. if it is outside scope, keep it separate from the feature PR
3. prefer one of these approaches:
   - separate local branch for the compatibility fix
   - separate upstream PR for the compatibility fix
   - local-only patch while validating the feature, then remove or split it before opening the feature PR

Do not silently fold unrelated fixes into the Work Mode PR unless the maintainer explicitly asks for that.

## Recommended Sequence For Phase 1

1. keep Phase 1 commits focused on:
   - `WorkModels`
   - `WorkTools`
   - `WorkExecutionEngine`
   - `WorkEngine`
   - `WorkSession`
   - `SystemPromptTemplates`
   - Work tests
   - development-plan docs
2. treat any repo-head compatibility fix as separate
3. push only the Phase 1 branch once its diff is clean
4. open the PR against `osaurus-ai/osaurus:main`

## Phase 2 Start Rule

Do not start Phase 2 by piling changes onto the Phase 1 branch.

Instead:

1. update local `main` from `upstream/main`
2. create a new branch for Phase 2
3. if Phase 2 depends on unmerged Phase 1 code, use a separate worktree or a temporary stacked branch deliberately

## Worktree Recommendation

If Phase 1 is under review and you want to start Phase 2 locally:

1. keep the Phase 1 branch unchanged
2. create a new worktree for Phase 2
3. explicitly document whether Phase 2 is:
   - independent
   - stacked on Phase 1

This prevents accidental mixing of changes and makes rebases easier.

## PR Narrative

For every phase PR:

- describe the concrete reliability problem
- explain the narrow behavioral change
- show the tests added
- mention security-relevant negative-path coverage
- avoid framing the PR as a broad competitor parity port

## Push Discipline

Before pushing:

1. check `git status`
2. confirm no unrelated file is staged
3. rerun the phase test command
4. rerun lint on touched files
5. verify the PR branch contains only the intended commit set

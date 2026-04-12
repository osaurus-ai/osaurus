# Owner Guide: Where Things Stand

Date: `2026-04-12`

This guide is written for you as the repo owner and active operator.

## The Short Version

Osaurus is no longer just one checkout with one line of work. Right now it is:

- one dirty integration checkout in the main repo folder
- several clean worktrees for public PRs and isolated future phases
- a mix of good canonical docs and older handoff/planning documents that had started to sprawl

The good news is that the important work is real and mostly separated already.
The bad news is that the repo was becoming hard to reason about because the
documentation and worktree model were spread across root files, handoff notes,
and local-only runbooks.

This reset fixes that by making `docs/development/` the canonical home for the
state of development.

## What Is Real Now

### Public work already in flight

Your active public PRs are:

- [#832](https://github.com/osaurus-ai/osaurus/pull/832)
  - Work Mode reliability Phase 1
- [#836](https://github.com/osaurus-ai/osaurus/pull/836)
  - build/runtime compatibility work from the integration branch
- [#838](https://github.com/osaurus-ai/osaurus/pull/838)
  - MLX runtime safety
- [#839](https://github.com/osaurus-ai/osaurus/pull/839)
  - FluidAudio / `SpeechService` compatibility
- [#840](https://github.com/osaurus-ai/osaurus/pull/840)
  - attached-document retrieval in local chat
- [#841](https://github.com/osaurus-ai/osaurus/pull/841)
  - native plugin file-import contract docs

### The important local truth

The folder you are currently in:

- `/Users/mmeding/Documents/Claude/Projects/osaurus`

is not the clean public source of truth. It is the integration checkout. It is
useful, but it is not the branch/worktree you should default to when you want
to open the next clean PR.

### The most important clean worktrees

- `phase1-pr`
  - clean Work Mode Phase 1 PR surface
- `file-import-contract-docs`
  - clean source for PR #841
- `file-import-foundation`
  - intended clean source for the file-import host foundation, but still empty relative to `upstream/main`
- `docs-reset-2026-04`
  - clean surface for this documentation reset

## What To Ignore Unless You Need History

- old restart prompts and local handoff docs
- root-level design reports and one-off review documents
- local-only operational directories such as `.claude/` and most of `.local-worktrees/`

They are not deleted blindly. They are archived so you can still retrieve them.
But they are not the place to orient yourself anymore.

## Where To Look First From Now On

If you want the real current state:

1. [PROJECT_STATE_AND_FORWARD_PLAN.md](./PROJECT_STATE_AND_FORWARD_PLAN.md)
2. [LLM_WORKING_CONTEXT.md](./LLM_WORKING_CONTEXT.md)
3. [reference/BUILD_REFERENCE.md](./reference/BUILD_REFERENCE.md) when build/runtime matters

If you want the file-format roadmap:

1. [file-import-plugin-contract.md](./file-import-plugin-contract.md)
2. [file-import-phased-pr-plan.md](./file-import-phased-pr-plan.md)

If you want the Work Mode roadmap:

1. [work-mode-reliability/README.md](./work-mode-reliability/README.md)
2. `00` through `05`

## What Happened To The Old Docs

The old handoff/runbook documents were not wrong. They were too local and too
temporary to remain the main source of truth:

- they assumed one very specific moment in the repo
- they mixed repo state with operating instructions
- they were drifting away from the real worktree/PR map

They are now archived, and the current repo state is captured in one master
status file instead.

The old root-level design/security/audit docs were also not deleted without a
trace. They were moved into the archive with reasons and superseded-by pointers.

## The Most Important Process Change

Going forward:

- new planning docs belong under `docs/development/`
- public PR work starts from a clean worktree off `upstream/main`
- the main repo folder stays an integration surface unless you intentionally clean it
- one initiative should map to one clean branch and one canonical status entry

That process is the main thing that will keep the next months from turning into
“where did that change actually live?”

## The Next Three Steps

1. Keep using the current repo folder for local integration only, not as the default public PR source.
2. Port the local file-import host foundation into the clean `codex/file-import-foundation` worktree so the next file-format PR starts from the right surface.
3. Continue the file-format roadmap in small plugin-first PRs after the foundation lands:
   - office
   - data
   - technical
   - mining
   - scientific
   - archive/system

## If You Feel Lost

Read only these two files first:

- [PROJECT_STATE_AND_FORWARD_PLAN.md](./PROJECT_STATE_AND_FORWARD_PLAN.md)
- [LLM_WORKING_CONTEXT.md](./LLM_WORKING_CONTEXT.md)

That should be enough to tell you:

- what is canonical
- what is archived
- which checkout is safe
- which PRs exist
- what the next clean move is

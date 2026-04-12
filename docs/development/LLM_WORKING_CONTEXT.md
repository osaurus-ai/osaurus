# LLM Working Context

This file is the bootstrap document for future AI sessions working on Osaurus.

## Canonical Reading Order

1. [PROJECT_STATE_AND_FORWARD_PLAN.md](./PROJECT_STATE_AND_FORWARD_PLAN.md)
2. [reference/BUILD_REFERENCE.md](./reference/BUILD_REFERENCE.md) if the task touches build, dependencies, CI, or supply chain
3. Initiative-specific docs as needed:
   - file import:
     - [file-import-plugin-contract.md](./file-import-plugin-contract.md)
     - [file-import-phased-pr-plan.md](./file-import-phased-pr-plan.md)
   - Work Mode reliability:
     - [work-mode-reliability/README.md](./work-mode-reliability/README.md)
     - `00` through `05` only for the canonical initiative plan
4. [OWNER_GUIDE_2026-04.md](./OWNER_GUIDE_2026-04.md) if you need the owner-facing narrative
5. [archive/2026-04-doc-reset/README.md](./archive/2026-04-doc-reset/README.md) only if historical context is required

## Bootstrap Commands

Run these before making assumptions:

```bash
git status --short --branch
git worktree list
gh pr list --repo osaurus-ai/osaurus --state all --limit 50
git remote -v
```

If the task involves building or package drift:

```bash
sed -n '1,220p' BUILD_GUIDE.md
sed -n '1,260p' docs/development/reference/BUILD_REFERENCE.md
```

## Current Truths You Must Preserve

- The primary checkout at `/Users/mmeding/Documents/Claude/Projects/osaurus` is an integration checkout on `feature/work-completion-contract-local`.
- Do not use the primary checkout as the default source for a public PR.
- Public PR work should start from a clean worktree off `upstream/main`.
- `codex/file-import-foundation` exists but is still clean and identical to `upstream/main`; the local host-foundation diff has not been promoted there yet.
- PR [#841](https://github.com/osaurus-ai/osaurus/pull/841) already documents the native file-import plugin contract.
- Work Mode Phase 1 is publicly represented by PR [#832](https://github.com/osaurus-ai/osaurus/pull/832), while PR [#836](https://github.com/osaurus-ai/osaurus/pull/836) is a separate compatibility branch opened from the dirty integration line.

## Safe Working Surfaces

- Docs-only cleanup:
  - `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/docs-reset-2026-04`
- Clean file-import foundation:
  - `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/file-import-foundation`
- File-import contract docs PR:
  - `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/file-import-contract-docs`
- Work Mode clean Phase 1 surface:
  - `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr`
- Focused PR worktrees:
  - `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/pr0-fluidaudio-asrmanager-api-compat`
  - `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/pr1-mlx-runtime-safety`
  - `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/pr3-attached-document-retrieval`

## Do Not Do These Things

- Do not open or update a public PR from the dirty primary checkout unless that is explicitly the branch already under review and the change belongs there.
- Do not treat archived handoff files as the current source of truth.
- Do not reintroduce root-level planning documents for new initiatives.
- Do not assume the existence of a clean branch means the intended diff has already been ported there.
- Do not mix file-import foundation work, plugin-pack work, and unrelated build fixes into one PR.

## Default Operating Model

- one initiative = one clean worktree
- one initiative = one branch
- one initiative = one canonical planning/status doc entry
- docs state goes in `PROJECT_STATE_AND_FORWARD_PLAN.md`
- owner-facing explanation goes in `OWNER_GUIDE_2026-04.md` or its successor

## If The Task Is About File Formats

Read:

1. [PROJECT_STATE_AND_FORWARD_PLAN.md](./PROJECT_STATE_AND_FORWARD_PLAN.md)
2. [file-import-plugin-contract.md](./file-import-plugin-contract.md)
3. [file-import-phased-pr-plan.md](./file-import-phased-pr-plan.md)
4. [docs/PLUGIN_AUTHORING.md](../PLUGIN_AUTHORING.md)

Current expectation:

- core host import remains conservative
- plugin-first expansion is the approved strategy
- host foundation must be ported to the clean file-import worktree before plugin packs begin

## If The Task Is About Work Mode Reliability

Read:

1. [PROJECT_STATE_AND_FORWARD_PLAN.md](./PROJECT_STATE_AND_FORWARD_PLAN.md)
2. [work-mode-reliability/README.md](./work-mode-reliability/README.md)
3. `00` through `05`

Treat archived `06`, `07`, and `08` as historical handoff material only.

## If The Task Is About Building

Read:

1. `BUILD_GUIDE.md`
2. [reference/BUILD_REFERENCE.md](./reference/BUILD_REFERENCE.md)

Pay special attention to:

- the Metal toolchain requirement
- the two `Package.resolved` files
- MLX fork revisions
- FluidAudio compatibility
- unsigned local build strategy

## Local-Only Directories

These are operationally real but not canonical docs:

- `.claude/`
- `.local-worktrees/`
- `.local-reports/`

Use them for state inspection, not as the place to publish new process guidance.

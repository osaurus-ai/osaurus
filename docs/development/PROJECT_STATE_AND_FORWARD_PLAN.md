# Project State And Forward Plan

Repository snapshot date: `2026-04-12`

This document is the canonical repo-wide status file for Osaurus development.
Update it when public PR state, worktree roles, or the recommended next sequence
changes.

## Snapshot

- Primary local checkout:
  - path: `/Users/mmeding/Documents/Claude/Projects/osaurus`
  - branch: `feature/work-completion-contract-local`
  - status: dirty integration checkout
- Safe continuation rule:
  - public PR work must begin from a clean worktree based on `upstream/main`
  - the primary checkout is not the default source for new public PRs
- Remotes:
  - `origin = git@github.com:mimeding/osaurus.git`
  - `upstream = https://github.com/osaurus-ai/osaurus.git`

## What Is Canonical Now

- Development/process/build canon lives under `docs/development/`.
- Repo-wide status belongs here.
- Future AI bootstrap belongs in [LLM_WORKING_CONTEXT.md](./LLM_WORKING_CONTEXT.md).
- Build detail belongs in [reference/BUILD_REFERENCE.md](./reference/BUILD_REFERENCE.md).
- Old handoff docs, loose design documents, and superseded planning files belong in the archive.

## Current Repository Truths

- The dirty primary checkout still carries local integration work plus local file-import foundation changes.
- `codex/file-import-foundation` exists as a clean worktree, but it is still sitting at `upstream/main` with no promoted host-foundation diff yet.
- The file-import plugin contract already has a clean docs PR open as [#841](https://github.com/osaurus-ai/osaurus/pull/841).
- The Work Mode reliability program has both a clean public Phase 1 branch and a separate local integration branch.
- Multiple clean worktrees exist for PR-prep and phase-isolated development. Future public work should continue through those surfaces, not by broadening the primary checkout.

## PR Ledger

### Your Active PRs

| PR | Branch | Status | Purpose | Role / Risk |
|---|---|---|---|---|
| [#832](https://github.com/osaurus-ai/osaurus/pull/832) | `feature/work-completion-contract` | Open | Work Mode reliability Phase 1 completion contract | Canonical clean public Work Mode Phase 1 PR |
| [#836](https://github.com/osaurus-ai/osaurus/pull/836) | `feature/work-completion-contract-local` | Open | Build/runtime compatibility fixes for MLX and FluidAudio | Public branch exists, but it is sourced from the dirty local integration branch and must not become the base for new work |
| [#838](https://github.com/osaurus-ai/osaurus/pull/838) | `codex/pr1-mlx-runtime-safety` | Open | Harden MLX cache reuse under long-context pressure | Clean focused fix branch with its own worktree |
| [#839](https://github.com/osaurus-ai/osaurus/pull/839) | `codex/pr0-fluidaudio-asrmanager-api-compat` | Open | Restore current `SpeechService` compatibility with FluidAudio | Clean focused compatibility PR |
| [#840](https://github.com/osaurus-ai/osaurus/pull/840) | `codex/pr3-attached-document-retrieval` | Open | Retrieve attached-document context in local chat | Clean focused feature PR |
| [#841](https://github.com/osaurus-ai/osaurus/pull/841) | `codex/file-import-plugin-contract-docs` | Open | Document native plugin file-import contract | Canonical docs-only PR for the file-import extension point |

### Key Upstream PRs That Affect Current Work

| PR | Status | Why It Matters Now |
|---|---|---|
| [#769](https://github.com/osaurus-ai/osaurus/pull/769) | Merged | Switched the repo onto the Osaurus MLX fork; this is part of the current dependency and build reality |
| [#775](https://github.com/osaurus-ai/osaurus/pull/775) | Merged | Adjusted dependency resolution and CI behavior; relevant to lockfile drift and build reproducibility |
| [#779](https://github.com/osaurus-ai/osaurus/pull/779) | Merged | Fixed the PDF attachment empty-document path; file-format work should build on this baseline instead of replacing it blindly |
| [#815](https://github.com/osaurus-ai/osaurus/pull/815) | Merged | Upgraded OpenAI usage to `/v1/responses`; important for current runtime expectations and integration testing |
| [#827](https://github.com/osaurus-ai/osaurus/pull/827) | Merged | Auto-enables MCP and sandbox plugin tools on first registration; this is the plugin baseline current file-import work must respect |

## Worktree Map

### Primary Checkout

| Path | Branch | Role | State |
|---|---|---|---|
| `/Users/mmeding/Documents/Claude/Projects/osaurus` | `feature/work-completion-contract-local` | Integration checkout | Dirty; contains local-only integration work and should not be used as the default public PR source |

### Clean Public Or PR-Prep Surfaces

| Path | Branch | Role | State |
|---|---|---|---|
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase1-pr` | `feature/work-completion-contract` | Clean Work Mode Phase 1 PR surface | Clean |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/file-import-contract-docs` | `codex/file-import-plugin-contract-docs` | Clean docs PR surface for file-import contract | Clean and published as PR #841 |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/pr0-fluidaudio-asrmanager-api-compat` | `codex/pr0-fluidaudio-asrmanager-api-compat` | Clean compatibility fix surface | Clean and published as PR #839 |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/pr1-mlx-runtime-safety` | `codex/pr1-mlx-runtime-safety` | Clean MLX runtime fix surface | Clean and published as PR #838 |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/pr3-attached-document-retrieval` | `codex/pr3-attached-document-retrieval` | Clean attached-document retrieval surface | Clean and published as PR #840 |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/workmode-publish` | `codex/publish-workmode-phase1` | Additional Work Mode publishing surface | Exists for publish/review work, but the canonical source branch remains `feature/work-completion-contract` |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/docs-reset-2026-04` | `codex/docs-development-reset-2026-04` | Clean docs-reset surface | Exists for docs-only cleanup, but is not yet a published PR |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/file-import-foundation` | `codex/file-import-foundation` | Intended clean host-foundation surface for file import | Clean, but still identical to `upstream/main`; the local host diff has not been ported here yet |

### Future Phase Surfaces

| Path | Branch | Role |
|---|---|---|
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2` | `feature/runtime-steering-attachments` | Clean future Work Mode Phase 2 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase2-local` | `feature/runtime-steering-attachments-local` | Local stacked Phase 2 implementation surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase3` | `feature/working-set-compaction-restore` | Clean future Phase 3 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase3-local` | `feature/working-set-compaction-restore-local` | Local Phase 3 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase4` | `feature/work-verifier-pass` | Clean future Phase 4 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase4-local` | `feature/work-verifier-pass-local` | Local Phase 4 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase5` | `feature/transcript-repair-and-stall-detection` | Clean future Phase 5 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase5-local` | `feature/transcript-repair-and-stall-detection-local` | Local Phase 5 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase6` | `feature/host-folder-risk-classifier` | Clean future Phase 6 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase6-local` | `feature/host-folder-risk-classifier-local` | Local Phase 6 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase7` | `feature/work-tool-orchestration` | Clean future Phase 7 surface |
| `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/phase7-local` | `feature/work-tool-orchestration-local` | Local Phase 7 surface |

### Local Experiment And Integration Surfaces

These are legitimate local working surfaces, but they are not canonical public-base branches:

- `.local-worktrees/attachment-foundation`
- `.local-worktrees/file-forwarding`
- `.local-worktrees/media-publish`
- `.local-worktrees/overnight`
- `.local-worktrees/video-runtime`
- `.local-worktrees/workmode-all-local`
- `.local-worktrees/workmode-eval`
- `.claude/worktrees/peaceful-euler`
- `/private/tmp/osaurus-mlx-clean`

Treat them as local context, not as the source of truth for repo direction.

## Completed Work By Theme

### Work Mode Reliability

- The core roadmap exists in `docs/development/work-mode-reliability/00` through `05`.
- Phase 1 was implemented and published on the clean branch behind PR [#832](https://github.com/osaurus-ai/osaurus/pull/832).
- Later phases already have named clean and local worktrees, which is useful, but the repo-wide state and operating rules are now documented centrally here instead of through ad hoc restart prompts.

### Build And Runtime Compatibility

- Build/runtime compatibility work is public in PR [#836](https://github.com/osaurus-ai/osaurus/pull/836) and [#839](https://github.com/osaurus-ai/osaurus/pull/839).
- Build and supply-chain knowledge has been consolidated into `BUILD_GUIDE.md` plus [reference/BUILD_REFERENCE.md](./reference/BUILD_REFERENCE.md).
- The repo still requires ongoing discipline around two separate SPM lockfiles.

### File Import And Attachment Work

- The native plugin contract is documented and published as PR [#841](https://github.com/osaurus-ai/osaurus/pull/841).
- The phased file-import PR map exists in [file-import-phased-pr-plan.md](./file-import-phased-pr-plan.md).
- The host-side file-import foundation exists only in the dirty integration checkout today; it still needs to be ported into the clean `codex/file-import-foundation` worktree before any plugin-pack implementation proceeds.
- Attached-document retrieval work is already public in PR [#840](https://github.com/osaurus-ai/osaurus/pull/840).

## Current Local-Only Diffs And Risks

As of this reset, the primary checkout contains local modifications outside the clean public PR surfaces, including:

- `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Packages/OsaurusCore/Managers/Plugin/PluginManager.swift`
- `Packages/OsaurusCore/Models/Plugin/ExternalPlugin.swift`
- `Packages/OsaurusCore/Tests/Plugin/PluginTests.swift`
- `Packages/OsaurusCore/Utils/DocumentParser.swift`
- `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift`

Meaning:

- the primary checkout remains useful for integration and local experimentation
- it is not the correct place to start the next public PR
- the file-import foundation must be intentionally ported to the clean `codex/file-import-foundation` worktree rather than being pushed directly from here

## Documentation Reorganization State

This reset makes these rules explicit:

- `docs/development/PROJECT_STATE_AND_FORWARD_PLAN.md` is now the canonical repo-state file.
- `docs/development/LLM_WORKING_CONTEXT.md` is the canonical machine-facing bootstrap file.
- `docs/development/archive/2026-04-doc-reset/` holds superseded handoff, loose planning, and point-in-time reports.
- Root-level loose planning and review files are no longer the canonical path forward.
- Local operational directories are documented, but not treated as publishable docs.

## Current Blockers

1. The primary checkout is dirty and ahead/behind its remote counterpart, so it is not a safe default PR surface.
2. The host-side file-import foundation is still stranded in the integration checkout instead of the clean `codex/file-import-foundation` worktree.
3. The build graph still demands care around two lockfiles, MLX fork revisions, and FluidAudio compatibility.
4. There are multiple valid local worktrees, which is powerful but easy to misuse without a central status file.

## Recommended Next Sequence

1. Keep the primary checkout as an integration surface only.
2. If this documentation reset is to become public, continue it from `codex/docs-development-reset-2026-04` or another clean docs-only branch/worktree.
3. Port the local host-side file-import foundation diff into `/Users/mmeding/Documents/Claude/Projects/osaurus/.local-worktrees/file-import-foundation`.
4. Open the file-import foundation PR only after that clean branch actually contains the intended code and tests.
5. Continue plugin-first format coverage in the documented order:
   - office
   - data
   - technical
   - mining A
   - mining B
   - scientific
   - archive/system
6. Keep Work Mode future phases on their existing clean phase worktrees and update this file when any phase moves from local to public.

## Working Rules Going Forward

- One initiative equals one clean worktree off `upstream/main`.
- One initiative equals one public branch.
- One initiative equals one canonical planning/status entry.
- Local integration branches must be clearly labeled as local-only or integration-only.
- Root-level loose planning docs should not be reintroduced.
- When in doubt, prefer a clean worktree plus a small PR over adding more state to the primary checkout.

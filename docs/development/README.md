# Development Docs Index

This directory is the canonical home for Osaurus development, build, process,
and planning documents.

Use these files first:

1. [PROJECT_STATE_AND_FORWARD_PLAN.md](./PROJECT_STATE_AND_FORWARD_PLAN.md)
   - current repository state, PR ledger, worktree map, blockers, and next moves
2. [LLM_WORKING_CONTEXT.md](./LLM_WORKING_CONTEXT.md)
   - bootstrap file for future AI sessions and exact operating rules
3. [OWNER_GUIDE_2026-04.md](./OWNER_GUIDE_2026-04.md)
   - owner-facing narrative for understanding what is real, what is archived, and what to do next
4. [reference/BUILD_REFERENCE.md](./reference/BUILD_REFERENCE.md)
   - detailed build, supply-chain, lockfile, and troubleshooting reference

## Canonical Rules

- Markdown under `docs/development/` is the source of truth for development docs.
- New planning or operating documents do not belong at repo root.
- Repo-wide status updates go in `PROJECT_STATE_AND_FORWARD_PLAN.md`.
- Future LLM or Codex sessions should start from `LLM_WORKING_CONTEXT.md`.
- Public PR work must start from a clean worktree based on `upstream/main`.
- The primary checkout at `/Users/mmeding/Documents/Claude/Projects/osaurus` is currently an integration surface, not the default source of a public PR.

## Active Initiative Docs

- File import and plugin-first format coverage
  - [file-import-plugin-contract.md](./file-import-plugin-contract.md)
  - [file-import-phased-pr-plan.md](./file-import-phased-pr-plan.md)
- Work Mode reliability
  - [work-mode-reliability/README.md](./work-mode-reliability/README.md)
  - [work-mode-reliability/00_PHASED_DEVELOPMENT_PLAN.md](./work-mode-reliability/00_PHASED_DEVELOPMENT_PLAN.md)
  - [work-mode-reliability/01_PHASE_WORK_COMPLETION_CONTRACT.md](./work-mode-reliability/01_PHASE_WORK_COMPLETION_CONTRACT.md)
  - [work-mode-reliability/02_LOCAL_WORKFLOW.md](./work-mode-reliability/02_LOCAL_WORKFLOW.md)
  - [work-mode-reliability/03_TESTING_AND_SECURITY_GATES.md](./work-mode-reliability/03_TESTING_AND_SECURITY_GATES.md)
  - [work-mode-reliability/04_BRANCHING_AND_PR_STRATEGY.md](./work-mode-reliability/04_BRANCHING_AND_PR_STRATEGY.md)
  - [work-mode-reliability/05_CURRENT_STATUS.md](./work-mode-reliability/05_CURRENT_STATUS.md)

## Reference And Historical Material

- Build and supply-chain reference
  - [reference/BUILD_REFERENCE.md](./reference/BUILD_REFERENCE.md)
- Historical learnings retained for context
  - [CLAUDE_CODE_LEARNINGS_PHASE_DESIGN.md](./CLAUDE_CODE_LEARNINGS_PHASE_DESIGN.md)
- Archived superseded documents
  - [archive/2026-04-doc-reset/README.md](./archive/2026-04-doc-reset/README.md)

## Local-Only Operational State

These paths are real and important, but they are not canonical documentation:

- `.claude/`
- `.local-worktrees/`
- `.local-reports/`

They should be described in status docs when relevant, but they are not the
place to publish new process guidance.

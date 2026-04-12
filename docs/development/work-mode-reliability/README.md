# Work Mode Reliability Roadmap

This directory now holds the surviving canonical initiative documents for Work
Mode reliability.

Repo-wide status, worktree topology, and future-session operating rules no
longer live in local handoff files. Start with:

- [../PROJECT_STATE_AND_FORWARD_PLAN.md](../PROJECT_STATE_AND_FORWARD_PLAN.md)
- [../LLM_WORKING_CONTEXT.md](../LLM_WORKING_CONTEXT.md)

Then return here for the initiative-specific plan.

## Reading Order

1. `00_PHASED_DEVELOPMENT_PLAN.md`
2. `01_PHASE_WORK_COMPLETION_CONTRACT.md`
3. `02_LOCAL_WORKFLOW.md`
4. `03_TESTING_AND_SECURITY_GATES.md`
5. `04_BRANCHING_AND_PR_STRATEGY.md`
6. `05_CURRENT_STATUS.md`

Archived handoff/runbook documents:

- `06_RESTART_PROMPT_AND_HANDOFF.md`
- `07_REMAINING_PHASES_OPERATING_PLAN.md`
- `08_LOCAL_WORKTREE_RUNBOOK.md`

Those files were moved to:

- [../archive/2026-04-doc-reset/README.md](../archive/2026-04-doc-reset/README.md)

## Initiative Rules That Still Apply

- Keep one phase to one public branch.
- Keep one phase to one PR.
- Wait for maintainer signal on [osaurus-ai/osaurus#825](https://github.com/osaurus-ai/osaurus/issues/825) before materially changing the public Work Mode PR sequence.
- Keep `feature/work-completion-contract` as the clean Work Mode Phase 1 public branch.
- Treat the primary checkout at `/Users/mmeding/Documents/Claude/Projects/osaurus` as an integration surface, not the default public PR source.
- Keep targeted unit tests, a security review checklist, and verification notes with each phase.

## Current Issue Anchor

- [osaurus-ai/osaurus#825](https://github.com/osaurus-ai/osaurus/issues/825)

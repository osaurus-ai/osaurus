# 2026-04 Documentation Reset Archive

This archive captures development/process/build documents that were superseded
during the `2026-04-12` documentation reset.

Archive policy:

- archive first, do not hard-delete on the first pass
- keep the original file content intact
- record why the file moved
- record which canonical document replaced it

## Moved Root-Level Documents

| Original Path | Archived Path | Why It Moved | Superseded By |
|---|---|---|---|
| `Osaurus_Audit_Report.docx` | `docs/development/archive/2026-04-doc-reset/root/Osaurus_Audit_Report.docx` | Point-in-time audit artifact; useful historically but not the operating source of truth | `docs/development/PROJECT_STATE_AND_FORWARD_PLAN.md` for current status, plus initiative docs for actual implementation plans |
| `Osaurus_Implementation_Plan.docx` | `docs/development/archive/2026-04-doc-reset/root/Osaurus_Implementation_Plan.docx` | Monolithic implementation plan that did not align with the plugin-first file-format strategy adopted for Osaurus | `docs/development/file-import-phased-pr-plan.md` and `docs/development/file-import-plugin-contract.md` |
| `Security_Review_Osaurus_vs_LCW.md` | `docs/development/archive/2026-04-doc-reset/root/Security_Review_Osaurus_vs_LCW.md` | Comparative review artifact, not a current repo-operating document | `docs/development/PROJECT_STATE_AND_FORWARD_PLAN.md` for repo state and `docs/development/reference/BUILD_REFERENCE.md` for build/security operating guidance |
| `BUILDING_FROM_SOURCE_LESSONS.md` | `docs/development/archive/2026-04-doc-reset/root/BUILDING_FROM_SOURCE_LESSONS.md` | Durable lessons were folded into the build reference; the root-level copy was cluttering the repo root | `docs/development/reference/BUILD_REFERENCE.md` |
| `SUPPLY_CHAIN_VERIFICATION.md` | `docs/development/archive/2026-04-doc-reset/root/SUPPLY_CHAIN_VERIFICATION.md` | Detailed supply-chain guidance was consolidated into the build reference; the root-level copy was superseded | `docs/development/reference/BUILD_REFERENCE.md` and `BUILD_GUIDE.md` |

## Moved Work Mode Handoff Documents

| Original Path | Archived Path | Why It Moved | Superseded By |
|---|---|---|---|
| `docs/development/work-mode-reliability/06_RESTART_PROMPT_AND_HANDOFF.md` | `docs/development/archive/2026-04-doc-reset/work-mode-reliability/06_RESTART_PROMPT_AND_HANDOFF.md` | Useful handoff snapshot, but too local and transient to remain canonical | `docs/development/LLM_WORKING_CONTEXT.md` and `docs/development/PROJECT_STATE_AND_FORWARD_PLAN.md` |
| `docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md` | `docs/development/archive/2026-04-doc-reset/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md` | Detailed operating plan was folded into canonical repo-state and initiative docs | `docs/development/PROJECT_STATE_AND_FORWARD_PLAN.md` and `docs/development/work-mode-reliability/README.md` |
| `docs/development/work-mode-reliability/08_LOCAL_WORKTREE_RUNBOOK.md` | `docs/development/archive/2026-04-doc-reset/work-mode-reliability/08_LOCAL_WORKTREE_RUNBOOK.md` | Environment-specific runbook is preserved, but canonical worktree guidance now lives in the repo-wide status docs | `docs/development/PROJECT_STATE_AND_FORWARD_PLAN.md` and `docs/development/LLM_WORKING_CONTEXT.md` |

## Surviving Canonical Documents

These are still active after the reset:

- `docs/development/PROJECT_STATE_AND_FORWARD_PLAN.md`
- `docs/development/LLM_WORKING_CONTEXT.md`
- `docs/development/OWNER_GUIDE_2026-04.md`
- `docs/development/reference/BUILD_REFERENCE.md`
- `docs/development/file-import-plugin-contract.md`
- `docs/development/file-import-phased-pr-plan.md`
- `docs/development/work-mode-reliability/00_PHASED_DEVELOPMENT_PLAN.md`
- `docs/development/work-mode-reliability/01_PHASE_WORK_COMPLETION_CONTRACT.md`
- `docs/development/work-mode-reliability/02_LOCAL_WORKFLOW.md`
- `docs/development/work-mode-reliability/03_TESTING_AND_SECURITY_GATES.md`
- `docs/development/work-mode-reliability/04_BRANCHING_AND_PR_STRATEGY.md`
- `docs/development/work-mode-reliability/05_CURRENT_STATUS.md`

# Ordered agent, kernel and preview-model audit

This follows the merged native effort metadata integration (#3290). The user
requested verification in order: creation/editing and reasoning controls,
actual fused execution, then stress tests and failure attribution. Model work
uses only the local M5 Max. Previous raw evidence remains retained.

## Phase 1: creation and editing

The baseline app exposes Inherit/None/Light/High during new-agent creation.
High survives creation; explicit editor Low/Off and reset-to-Inherit reach the
runtime with the corresponding native scopes. A non-reasoning control model
removes the rail and warns about unsupported saved choices; another reasoning
family shows its own declared tiers; reselecting Raptor restores its rail.

Two shared UI defects were reproduced:

1. Both File-menu agent lists stay at their startup snapshot after creation
   and rename. Dedicated observing menu-item views refresh those lists without
   observing the manager from the root App. Candidate `3b587d63` passed real
   creation/rename/menu-launch checks without restarting the process.
2. An already-open generation editor retains High after the chat picker saves
   Low. The store and actual runtime are Low, but an unrelated name save
   writes the stale High back. The audit retained the contradictory UI/store
   state and before/after records. Refresh saved editor inputs from the live
   agent, rebase untouched draft fields while preserving unsaved edits, and
   preserve directly saved model/generation values during unrelated saves.
   Only explicit generation Save may replace them, including clearing an
   override back to Inherit.

The second correction and regression checks are in progress. Do not treat the
first candidate's menu checks as proof of corrected editor synchronization.

## Phases 2 and 3: pending

Actual kernel dispatch, numerical parity, and scoped timing remain to be
qualified. A shader or fast-path function existing in source is not evidence
that the model uses it. Preserve the bundle quantization and generation
defaults; do not add behavior guards to make a row pass.

Early native Low/High prose probes contained questionable geometry claims in
season/eclipse explanations. These are retained as partial factual rows,
separate from passing control transport. Their cause is unassigned until
numerical/runtime checks and explicit stress oracles distinguish integration
defects from preview-model limitations. No broad model-readiness claim.

Raw source identities, UI AX/PNG captures, stored settings, actual tool results,
token rates, physical-memory traces and failed attempts remain under
`/Users/eric/vmlx-private-evidence/raptor-ordered-audit-20261102/`.
No release, model upload, sampler masking or other-machine qualification.

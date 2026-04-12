# Remaining Phases Operating Plan

## Status Of This Document

This document is an operating supplement to the canonical Work Mode reliability documents:

- `00_PHASED_DEVELOPMENT_PLAN.md`
- `01_PHASE_WORK_COMPLETION_CONTRACT.md`
- `02_LOCAL_WORKFLOW.md`
- `03_TESTING_AND_SECURITY_GATES.md`
- `04_BRANCHING_AND_PR_STRATEGY.md`
- `05_CURRENT_STATUS.md`
- `06_RESTART_PROMPT_AND_HANDOFF.md`

It does not replace them. If this document ever conflicts with those files, the canonical files win.

Its purpose is to provide the detailed execution plan for the remaining Work Mode reliability program while preserving the original governance model:

- one phase = one branch
- one phase = one focused implementation theme
- one phase = one test plan
- one phase = one security checklist
- one phase = one PR

## Preserve These Osaurus Strengths

No phase in this program may regress the core strengths called out in the canonical plan:

1. explicit prompt composition
2. capability retrieval across tools, methods, and skills
3. durable memory design
4. per-agent sandbox isolation
5. structured work and issue execution

## Non-Negotiable Program Rules

The following rules remain in force for the rest of the program:

1. `feature/work-completion-contract` remains the clean Phase 1 PR branch.
2. `feature/work-completion-contract-local` remains a local integration branch and is not the branch for the first upstream Work Mode PR.
3. No future phase work is allowed on `feature/work-completion-contract`.
4. No future phase work is allowed on `feature/work-completion-contract-local`.
5. No future phase branch should be cut from `feature/work-completion-contract-local`.
6. Future phases must follow the canonical order already documented.
7. Later phases stay local until earlier phases are merged or maintainers explicitly approve stacking/public overlap.
8. Unrelated compatibility fixes must not be silently folded into a Work Mode phase PR.
9. `07_REMAINING_PHASES_OPERATING_PLAN.md` is not part of the clean Phase 1 implementation and must not be committed on `feature/work-completion-contract`.
10. Documentation-only planning work should live on a separate docs branch or another clearly non-Phase-1 branch.
11. Wait for maintainer signal on `osaurus-ai/osaurus#825` before opening or materially updating public upstream phase PRs.

## Current Baseline To Preserve

### Phase 1 Public Branch

Branch:

- `feature/work-completion-contract`

Clean commits:

- `f2150fa4` `docs: add Work Mode reliability development plan`
- `7c609153` `feature: strengthen Work Mode completion contract`

Program rule:

- this branch must remain immediately pushable/openable as the first upstream Work Mode PR if approval is given

### Local Integration Branch

Branch:

- `feature/work-completion-contract-local`

Current local-only commits above the clean Phase 1 branch:

- `9cae9212` `fix: load FluidAudio ASR models with current API`
- `15c11b49` `build: sync workspace lockfile with validated package set`
- `45ee8c3a` `build: sync project lockfile with validated package set`
- `9fd88e1d` `build: pin Xcode lockfiles to FluidAudio 0.13.6`

Current effective diff versus the clean Phase 1 branch:

- `Packages/OsaurusCore/Managers/SpeechService.swift`
- `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

Program rule:

- these commits remain integration-only until they are either split into separate upstream fixes or explicitly approved for inclusion elsewhere

### Current Worktree Hygiene Risk

The current repository checkout already contains unrelated local modifications and untracked files. That means future phase work should default to a fresh worktree rather than reusing the current checkout for public branch preparation.

Program rule:

- use clean worktrees for PR preparation and for each new phase branch

### Current Local-Only File Risk

At the time of this forensic pass, the current checkout also contains local-only documentation and support files that must not be silently mixed into a Work Mode phase PR.

Tracked local modification:

- `docs/development/work-mode-reliability/README.md`

Untracked local files:

- `BUILDING_FROM_SOURCE_LESSONS.md`
- `BUILD_GUIDE.md`
- `SUPPLY_CHAIN_VERIFICATION.md`
- `Security_Review_Osaurus_vs_LCW.md`
- `docs/development/work-mode-reliability/06_RESTART_PROMPT_AND_HANDOFF.md`
- `docs/development/work-mode-reliability/07_REMAINING_PHASES_OPERATING_PLAN.md`
- `scripts/verify_supply_chain.sh`

Program rule:

- treat these files as local-only until they are intentionally moved to an appropriate non-Phase-1 branch

### Current Documentation Placement Risk

This operating-plan file currently exists outside the clean Phase 1 public branch. That is correct and should remain true until the document is moved onto a separate docs branch or another non-Phase-1 branch.

Program rules:

- do not add this file to `feature/work-completion-contract`
- do not use the clean Phase 1 branch as the transport branch for planning docs
- prefer a dedicated docs branch from refreshed `main`

## Canonical Phase Order

The remaining program must proceed in this order:

1. Phase 2: `feature/runtime-steering-attachments`
2. Phase 3: `feature/working-set-compaction-restore`
3. Phase 4: `feature/work-verifier-pass`
4. Phase 5: `feature/transcript-repair-and-stall-detection`
5. Phase 6: `feature/host-folder-risk-classifier`
6. Phase 7: `feature/work-tool-orchestration`

No resequencing should occur without an explicit maintainer decision and a corresponding update to the canonical documents.

## Branch Topology And Roles

### Long-Lived Branches

- `main`
  - local tracking branch for `upstream/main`
  - never contains phase work
- `feature/work-completion-contract`
  - clean public branch for Phase 1 only
- `feature/work-completion-contract-local`
  - local integration branch only

### Standard Phase Branch

For every future phase, the official phase branch is:

- `feature/<phase-name>`

Examples:

- `feature/runtime-steering-attachments`
- `feature/working-set-compaction-restore`
- `feature/work-verifier-pass`
- `feature/transcript-repair-and-stall-detection`
- `feature/host-folder-risk-classifier`
- `feature/work-tool-orchestration`

This is the only branch that defines the public phase diff.

### Optional Local Integration Branch

If unrelated repository breakage blocks local validation, a temporary local integration branch may be used:

- `feature/<phase-name>-local`

This is not a second public phase branch. It is a temporary local validation surface only. It must never become the PR source branch, and it must never redefine the meaning of the canonical rule that one phase maps to one public branch and one public PR.

### Separate Upstream Fix Branch

If a blocker is clearly unrelated to the phase scope, prefer a separate fix branch:

- `fix/<topic>`

Examples:

- `fix/fluidaudio-loadmodels-api`
- `fix/xcode-lockfile-sync`

This is the preferred destination for compatibility work that deserves its own upstream treatment.

### Documentation Branch

For planning and governance documents that are intentionally outside the clean Phase 1 feature diff, prefer a dedicated docs branch:

- `docs/work-mode-reliability-operating-plan`

Acceptable fallback:

- another clearly non-Phase-1 branch created from refreshed `main`

Rules:

- do not place the planning-doc commit on `feature/work-completion-contract`
- do not use the docs branch as a base for future feature phases
- if the docs branch merges first, later Phase 1 rebases are acceptable because the doc will then arrive through upstream history rather than as a Phase 1 branch commit

## Recommended Workspace Layout

Because the current checkout is already carrying local-only work, the safest operating layout for the remainder of the program is:

1. Keep the existing checkout as the local integration workspace.
2. Create a clean worktree for any public Phase 1 PR prep.
3. Create a separate docs worktree for this operating-plan file if it is going to be committed.
4. Create one clean worktree per future phase branch.

Recommended commands:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus
git fetch upstream
git worktree add ../osaurus-phase1-pr feature/work-completion-contract
git worktree add ../osaurus-workmode-docs main
git worktree add ../osaurus-phase2 main
```

Then inside the docs worktree:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus-workmode-docs
git switch -c docs/work-mode-reliability-operating-plan
```

Then inside the Phase 2 worktree:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus-phase2
git switch -c feature/runtime-steering-attachments
```

Program rule:

- public PR preparation should happen in a clean worktree, not in a dirty integration checkout
- this operating-plan document should be committed from the docs worktree or another non-Phase-1 branch, not from the clean Phase 1 branch

## Promotion Model: Local Work To Upstream PR

Every future phase should move through the same states.

### State 0: Mainline Sync

Before any new phase begins:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus
git fetch upstream
git switch main
git rebase upstream/main
```

If using a worktree, run the same sync from the primary repository first, then create the phase worktree from the updated local `main`.

### State 1: Phase Contract

Before the first phase commit:

1. create or update a phase-specific planning document for that phase
2. lock the phase goal, in-scope files, test plan, and security checklist
3. confirm the branch name and PR title pattern
4. confirm the phase is not carrying unrelated repo-head fixes
5. record the targeted verification commands that will serve as the phase execution notes

This preserves the canonical rule that each phase has one focused theme, one test plan, and one security checklist.

### State 2: Clean Phase Branch Development

Default path:

1. branch from refreshed `main`
2. implement only the phase-scoped changes
3. keep commits narrow and reviewable
4. run targeted tests repeatedly during development
5. keep the diff public-PR-clean at all times if possible

### State 3: Optional Local Integration Validation

Only if blocked by unrelated breakage:

1. cut `feature/<phase-name>-local` from the clean phase branch
2. add the temporary compatibility fix there
3. validate the phase behavior in the local branch
4. either remove the compatibility fix before PR prep or split it into a separate `fix/<topic>` branch

Required discipline:

- never merge `feature/<phase-name>-local` back into the clean phase branch
- cherry-pick only the intended phase commits back to the clean branch if the local branch diverged
- verify the clean branch diff again before push

### State 4: Clean-Branch Verification

Before any push to `origin`:

1. confirm the branch contains only phase commits
2. confirm `git diff upstream/main...HEAD` matches the intended scope
3. confirm `git log --oneline upstream/main..HEAD` contains only the expected commit set
4. rerun phase-targeted tests
5. rerun repo-level lint and test gates
6. rerun the phase security checklist
7. capture the local verification notes, including the targeted test commands and results, for the PR body

Useful validation commands:

```bash
git status --short --branch
git diff --stat upstream/main...HEAD
git log --oneline upstream/main..HEAD
git log --oneline feature/<phase>..feature/<phase>-local
git diff --stat feature/<phase>..feature/<phase>-local
```

### State 5: Fork Push

Only the clean public phase branch gets pushed:

```bash
git push origin feature/<phase-name>
```

Rules:

- never push local integration-only commits as if they were the public branch
- if a rebase was required, use `git push --force-with-lease origin feature/<phase-name>`
- never use plain `--force`

### SwiftPM Fallback For Focused Verification

If the package-local `.build` directory becomes unreliable or produces transient manifest I/O errors during focused validation, use a clean scratch path under `/tmp`:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus/Packages/OsaurusCore
swift test --scratch-path /tmp/osauruscore-phase-build --filter '<TestSuiteName>'
```

Rules:

- use this as a focused local fallback only
- do not use it as a substitute for the normal repo-level lint and test gate before push
- include any fallback command used in the local verification notes

### State 6: Upstream PR

Open the PR from:

- `mimeding:feature/<phase-name>` to `osaurus-ai:main`

Each PR must:

1. link back to `osaurus-ai/osaurus#825`
2. describe the concrete reliability problem
3. describe the narrow behavioral change
4. list the new tests
5. list the negative-path coverage
6. list the security checks performed
7. clearly call out any known remaining risks
8. include the local verification notes and commands actually run
9. state the new failure mode for invalid input or invalid state when relevant

### State 7: Merge And Cleanup

After a phase merges:

```bash
git switch main
git fetch upstream
git rebase upstream/main
git branch -D feature/<merged-phase>
git push origin --delete feature/<merged-phase>
```

If a temporary local integration branch existed and is no longer needed, delete it only after verifying its unique changes have either been discarded intentionally or preserved on a proper fix branch.

## GitHub Management Rules

### Issue Management

The program anchor remains:

- `osaurus-ai/osaurus#825`

Expected use:

1. keep that issue as the umbrella tracking thread for the full Work Mode reliability program
2. mention each phase branch and PR there when work becomes public
3. note when a blocker is phase-scoped versus repo-head-scoped
4. explicitly note when a compatibility fix is being split out rather than folded into the phase PR

### PR Management

Recommended PR pattern:

- Phase 1: `feature: strengthen Work Mode completion contract`
- Phase 2: `feature: add runtime steering attachments for Work Mode`
- Phase 3: `feature: preserve working set across compaction and resume`
- Phase 4: `feature: add Work Mode verifier pass`
- Phase 5: `feature: repair transcripts and detect stalled work loops`
- Phase 6: `feature: classify host-folder execution risk`
- Phase 7: `feature: orchestrate safe Work Mode tool calls`

PR body sections should be:

1. Problem
2. Scope
3. Behavior Change
4. Failure Modes
5. Tests
6. Local Verification Notes
7. Security Review
8. Remaining Risks
9. Issue Anchor

### Rebase Policy

If upstream moves while a phase PR is open:

```bash
git fetch upstream
git switch feature/<phase-name>
git rebase upstream/main
git push --force-with-lease origin feature/<phase-name>
```

Rules:

- do not merge `main` into a phase branch
- do not merge the clean phase branch into a local integration branch and then push that merged history publicly
- keep history linear and auditable

### Stacked Work Policy

Default policy:

- do not publish stacked Work Mode PRs

Allowed local-only exception:

- a later phase may be explored in a separate worktree stacked on an unmerged earlier phase branch if that is the only practical way to keep momentum

Required discipline for local-only stacked work:

1. name the worktree and branch clearly
2. document that it is stacked and local-only
3. do not push it as the public branch until it has been rebased onto the appropriate refreshed base
4. rerun the full phase gate after the rebase

## Phase 1 Immediate Push Preservation Plan

Phase 1 is already implemented and validated. The operating plan must preserve the ability to ship it immediately if approval is given.

### What Must Not Happen

- no new commits on `feature/work-completion-contract`
- no cherry-picks from `feature/work-completion-contract-local` onto the clean branch unless explicitly approved
- no future phase work from the clean Phase 1 branch
- no commit that adds `07_REMAINING_PHASES_OPERATING_PLAN.md` to the clean Phase 1 branch
- no mixing of current untracked local docs/scripts into the Phase 1 PR

### Safe PR Preparation Path

Use a clean worktree:

```bash
cd /Users/mmeding/Documents/Claude/Projects/osaurus
git fetch upstream
git worktree add ../osaurus-phase1-pr feature/work-completion-contract
cd ../osaurus-phase1-pr
git status --short --branch
git log --oneline upstream/main..HEAD
```

Then rerun the Phase 1 gate:

```bash
swift-format lint --strict --recursive Packages App
swiftlint lint
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCoreTests -skip-testing OsaurusCoreTests/KVCacheStoreTests -skip-testing OsaurusCoreTests/MLXGenerationEngineTests
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCLITests
```

If upstream moved and a rebase is required:

```bash
git fetch upstream
git rebase upstream/main
git push --force-with-lease origin feature/work-completion-contract
```

Then open the PR from `feature/work-completion-contract`.

Program rule:

- the existence of local integration-only fixes must never delay or contaminate the public Phase 1 PR if approval arrives
- the existence of this new operating-plan file must never delay or contaminate the public Phase 1 PR if approval arrives

## Documentation Delivery Plan For This File

This file is part of program governance, not part of the clean Phase 1 implementation. It should therefore be delivered independently.

Preferred path:

1. refresh local `main`
2. create a clean docs worktree from `main`
3. create `docs/work-mode-reliability-operating-plan`
4. add only this file and any strictly necessary supporting documentation updates
5. push that docs branch independently or keep it local until needed

Fallback path:

1. use another clearly non-Phase-1 branch from refreshed `main`
2. keep the branch documentation-only
3. do not route the document through `feature/work-completion-contract`

Hard rules:

- this file must not be the reason `feature/work-completion-contract` changes
- this file must not be used to justify reopening or broadening Phase 1 scope
- if this file lands upstream first, Phase 1 remains a separate implementation PR

## Program-Level Change Management Checklist

This checklist applies to every remaining phase.

### Entry Gate

Before coding starts:

1. refreshed `main` exists locally
2. the branch name matches the canonical phase order
3. the scope is written down
4. the test plan is written down
5. the security checklist is written down
6. any dependency on an earlier unmerged phase is explicit

### In-Progress Control

While coding:

1. do not let unrelated files accumulate in the branch
2. keep commits phase-specific
3. update the phase doc if scope tightens or expands
4. treat repo-head blockers as separate until proven otherwise
5. keep a written list of what still needs verification

### Pre-Push Gate

Before pushing the clean branch:

1. inspect `git status`
2. inspect `git diff --stat upstream/main...HEAD`
3. inspect `git log --oneline upstream/main..HEAD`
4. run targeted tests
5. run canonical lint and test gates
6. run the security checklist
7. confirm the PR narrative is phase-specific and not roadmap-wide

### Review Response Gate

While the PR is under review:

1. keep all review fixes on the same phase branch
2. do not start sneaking the next phase into the review branch
3. rebase onto `upstream/main` when needed
4. rerun the phase gate after each non-trivial rebase or review fix

### Post-Merge Gate

After merge:

1. rebase local `main` to `upstream/main`
2. delete the merged phase branch locally and on `origin`
3. update status tracking docs
4. only then start the next public phase branch

## Remaining Phase Execution Plans

## Phase 2: Runtime Steering Attachments

Branch:

- `feature/runtime-steering-attachments`

Focused theme:

- add dynamic runtime reminders tied to live execution state

Primary objective:

- keep the model oriented toward the active goal, current issue, remaining budget, recent failure state, and verification expectation without broadening authority

Likely code surfaces:

- `Packages/OsaurusCore/Services/WorkExecutionEngine.swift`
- `Packages/OsaurusCore/Services/WorkEngine.swift`
- `Packages/OsaurusCore/Services/Chat/SystemPromptTemplates.swift`
- `Packages/OsaurusCore/Services/Chat/SystemPromptComposer.swift`
- `Packages/OsaurusCore/Models/Work/WorkModels.swift`
- `Packages/OsaurusCore/Views/Work/WorkSession.swift`

Entry criteria:

1. Phase 1 clean branch is preserved and untouched
2. the runtime steering attachment contract is documented before code changes
3. the phase is explicitly scoped to reminder/control quality, not compaction persistence or verification pass logic

Implementation slices:

1. define a bounded runtime steering snapshot assembled from typed state rather than free-form transcript scraping
2. include the current objective and active issue identity on first run and on resume
3. include remaining iteration budget and recent interruption or clarification state where relevant
4. include a verification reminder that reinforces the Phase 1 completion contract
5. include a compact working-state reminder that points the model back to saved notes or current subproblem without introducing Phase 3 persistence yet
6. ensure attachments are emitted when state changes materially, not duplicated blindly every iteration

Out of scope:

- persistent working-set snapshots
- separate verifier model/pass
- transcript repair logic
- host-folder risk policy
- true parallel tool orchestration

Phase 2 test plan:

1. positive-path tests proving the right reminder appears on initial execution, resume, and low-budget conditions
2. regression tests proving the Phase 1 completion contract instructions remain intact
3. negative-path tests proving absent or malformed runtime state does not inject garbage reminders
4. tests proving reminders do not duplicate across every loop iteration without state change
5. targeted extensions to `WorkExecutionEngineTests`
6. targeted prompt-composition coverage under `Packages/OsaurusCore/Tests/Chat`

Phase 2 security checklist:

1. reminders must be built from typed engine/session state only
2. reminders must not include raw tool outputs, secret values, or unbounded file contents
3. failure summaries must be redacted or truncated before prompt injection
4. missing runtime state must fail closed by omitting the reminder rather than inserting guessed text
5. reminders must not create new execution authority; they may only improve control

PR shape:

- narrow diff centered on runtime reminders and prompt assembly
- clear before/after examples in the PR body
- explicit note that this phase does not introduce persistence or verifier branching yet

Exit criteria:

1. reminders are deterministic enough to test
2. resume behavior is more guided than Phase 1
3. no unrelated compaction or sandbox policy changes are present in the diff

## Phase 3: Working-Set Compaction Restore

Branch:

- `feature/working-set-compaction-restore`

Focused theme:

- preserve live task state through compaction and resume

Primary objective:

- make compaction and restart safer by preserving the minimal structured working set needed to continue accurately after context compression or process interruption

Likely code surfaces:

- `Packages/OsaurusCore/Services/WorkExecutionEngine.swift`
- `Packages/OsaurusCore/Services/WorkEngine.swift`
- `Packages/OsaurusCore/Models/Work/WorkModels.swift`
- `Packages/OsaurusCore/Views/Work/WorkSession.swift`
- `Packages/OsaurusCore/Storage/IssueStore.swift`
- `Packages/OsaurusCore/Tools/ScratchpadTools.swift`
- `Packages/OsaurusCore/Services/Chat/ContextBudgetManager.swift`

Entry criteria:

1. Phase 2 steering behavior is stable enough to build on
2. the structured working-set schema is defined before persistence code is added
3. the schema includes explicit size bounds and versioning

Implementation slices:

1. define a bounded structured working-set snapshot for active objective, key findings, current subproblem, files touched, verification performed so far, remaining risks, and remaining work
2. persist that snapshot separately from the raw transcript so it can survive compaction and restart
3. integrate the snapshot into compaction summaries and resume flows
4. ensure saved notes and the new working-set snapshot reinforce each other rather than duplicating conflicting state
5. validate persisted host-folder context on restore and fail closed if the stored folder root no longer matches the active folder context
6. make corrupted or oversized persisted state drop safely rather than partially restoring untrusted state

Out of scope:

- evaluator/verifier verdicting
- transcript repair heuristics beyond what is necessary for safe restore
- host-folder risk classification beyond restore validation

Phase 3 test plan:

1. positive-path tests proving a working set survives compaction and resume
2. positive-path tests proving a paused session can restart with the same bounded working-set state
3. negative-path tests for corrupt, stale, oversized, or mismatched persisted state
4. regression tests proving saved notes still inject correctly and Phase 2 reminders still work
5. extensions to `WorkEngineResumeTests`
6. targeted additions to `WorkExecutionEngineTests`

Phase 3 security checklist:

1. persisted working-set state must be schema-checked, versioned, and size-bounded
2. no secrets, raw tool outputs, or privileged command output may be stored in the structured snapshot
3. host-folder restore must fail closed on path mismatch
4. corrupted state must not silently downgrade into an unsafe partial restore
5. the restore path must not grant tools or execution modes that are not still valid

PR shape:

- one diff focused on compaction, persisted state, and resume restoration
- explicit explanation of what is persisted and what is intentionally not persisted

Exit criteria:

1. compaction preserves enough state to continue accurately
2. restart/resume behavior is deterministic and tested
3. persisted-state security bounds are clearly documented in the PR

## Phase 4: Work Verifier Pass

Branch:

- `feature/work-verifier-pass`

Focused theme:

- separate task execution from result validation

Primary objective:

- add a distinct validation pass so executor self-reporting is no longer the only source of truth for a `verified` outcome

Likely code surfaces:

- `Packages/OsaurusCore/Services/WorkExecutionEngine.swift`
- `Packages/OsaurusCore/Services/WorkEngine.swift`
- `Packages/OsaurusCore/Services/Chat/SystemPromptTemplates.swift`
- `Packages/OsaurusCore/Models/Work/WorkModels.swift`
- `Packages/OsaurusCore/Tests/Work/WorkExecutionEngineTests.swift`
- new verifier-focused tests under `Packages/OsaurusCore/Tests/Work`

Entry criteria:

1. Phase 3 resume state is reliable enough to provide verifier context
2. the verifier protocol is defined as a typed allow/reject/insufficient result, not a free-form string
3. the verifier input boundary is defined before implementation

Implementation slices:

1. define the bounded evidence package the verifier sees
2. introduce a dedicated verifier pass after executor completion attempts `status = verified`
3. require typed verifier output that can only approve, reject, or request more evidence
4. keep `partial` and `blocked` semantics intact; they must not be upgraded by the verifier
5. route verifier rejection back into continued execution or a fail-closed non-success outcome
6. make verifier failure itself fail closed

Out of scope:

- transcript repair heuristics
- host-folder risk governance
- tool orchestration changes

Phase 4 test plan:

1. positive-path tests for a supported verified completion that the verifier accepts
2. negative-path tests for executor claims that lack supporting evidence
3. negative-path tests for contradictory or insufficient evidence
4. regression tests proving `partial` and `blocked` results still behave as before
5. tests proving verifier errors/timeouts do not produce false success

Phase 4 security checklist:

1. verifier input must be bounded, sanitized, and tool-free
2. verifier output must be typed and schema-validated
3. the verifier must not gain access to new tools, secrets, or filesystem state
4. model-generated verifier prose must not directly mutate control state
5. verifier failure must fail closed rather than silently accepting success

PR shape:

- narrow diff centered on executor/verifier separation
- explicit explanation of approval and rejection control flow

Exit criteria:

1. `verified` means executor plus verifier agreement
2. false-positive completion risk is materially lower than after Phase 1 alone
3. no spillover into transcript repair or host-folder security work

## Phase 5: Transcript Repair And Stall Detection

Branch:

- `feature/transcript-repair-and-stall-detection`

Focused theme:

- improve long-horizon transcript integrity and detect wasted iterations

Primary objective:

- make the Work transcript resilient to malformed or degraded execution history while detecting loops that waste budget without making progress

Likely code surfaces:

- `Packages/OsaurusCore/Services/WorkExecutionEngine.swift`
- `Packages/OsaurusCore/Services/WorkEngine.swift`
- `Packages/OsaurusCore/Services/Provider/RemoteProviderService.swift`
- `Packages/OsaurusCore/Services/ModelRuntime/StreamAccumulator.swift`
- `Packages/OsaurusCore/Services/Chat/PromptBuilder.swift`
- `Packages/OsaurusCore/Tests/Work/WorkExecutionEngineTests.swift`
- `Packages/OsaurusCore/Tests/Service/StreamAccumulatorTests.swift`

Entry criteria:

1. execution and verifier outcomes are already typed enough to distinguish real progress from churn
2. transcript repair rules are documented before implementation
3. stall detection thresholds are explicit and testable

Implementation slices:

1. formalize transcript repair for orphaned tool results, malformed tool-call boundaries, and repeated degraded streaming states
2. add bounded stall heuristics for repeated text-only loops, repeated rejected completions, repeated failing tool patterns, or unchanged retry attempts
3. surface stall state as control guidance to the loop rather than as a silent metric only
4. ensure repair logic never fabricates tool results or user input
5. ensure stall detection can pause, redirect, or summarize safely without falsely reporting success

Out of scope:

- host-folder risk classification
- tool orchestration concurrency

Phase 5 test plan:

1. positive-path tests proving damaged but recoverable transcripts are repaired into a consistent shape
2. negative-path tests proving irrecoverable transcript corruption fails safely
3. positive-path tests proving repeated non-progress patterns are detected
4. negative-path tests proving normal multi-step work is not falsely marked as stalled
5. additions to `WorkExecutionEngineTests`
6. additions to `StreamAccumulatorTests`

Phase 5 security checklist:

1. repair code must only remove or restructure transcript state, never invent privileged content
2. stall summaries must not leak raw sensitive output into prompts or logs
3. detection windows must be bounded in size and scope
4. a stall must never be converted into a false verified completion
5. failure to repair must fail closed to pause/partial/block semantics

PR shape:

- one diff focused on transcript consistency and bounded stall handling
- clear examples of repaired versus rejected transcript states

Exit criteria:

1. long-running sessions fail less often due to transcript degradation
2. the loop detects obvious churn and steers away from wasting budget
3. transcript recovery behavior is explicit and test-covered

## Phase 6: Host-Folder Risk Classifier

Branch:

- `feature/host-folder-risk-classifier`

Focused theme:

- strengthen non-sandbox execution governance

Primary objective:

- classify host-folder work context risk and apply stricter control around non-sandbox execution

Likely code surfaces:

- `Packages/OsaurusCore/Work/WorkFolderContextService.swift`
- `Packages/OsaurusCore/Work/WorkFolderContext.swift`
- `Packages/OsaurusCore/Work/WorkFolderTools.swift`
- `Packages/OsaurusCore/Services/WorkEngine.swift`
- `Packages/OsaurusCore/Views/Work/WorkSession.swift`
- `Packages/OsaurusCore/Models/Tool/ToolPermissionPolicy.swift`
- `Packages/OsaurusCore/Services/Sandbox/SandboxSecurity.swift`
- `Packages/OsaurusCore/Tests/Sandbox/BuiltinSandboxToolsTests.swift`

Entry criteria:

1. host-folder risk categories are written down before coding
2. path normalization and symlink handling rules are defined
3. the phase is scoped to governance and classification, not general folder tooling expansion

Implementation slices:

1. define risk tiers for host-folder roots such as repository root, user-selected project folder, broad home-directory selection, or system-sensitive locations
2. normalize and classify the selected root path before exposing host-folder execution mode
3. gate higher-risk roots with stronger restrictions, warnings, or sandbox fallback
4. ensure the classifier feeds both UI state and execution policy
5. ensure persisted host-folder resume state respects the classifier on restore

Out of scope:

- broader sandbox feature work
- transcript repair
- general-purpose permission overhaul outside host-folder risk

Phase 6 test plan:

1. positive-path tests for expected project-folder classifications
2. negative-path tests for risky roots such as home-level or system-sensitive paths
3. tests for symlink, stale bookmark, or path-mismatch behavior
4. regression tests proving existing valid folder workflows still work
5. targeted additions under `Packages/OsaurusCore/Tests/Sandbox` and `Packages/OsaurusCore/Tests/Work`

Phase 6 security checklist:

1. path classification must use normalized paths, not model-provided text
2. high-risk roots must default to fail-closed behavior
3. the classifier must not expose sensitive full-path detail unnecessarily in prompts or logs
4. host-folder restore must re-evaluate risk, not trust stale persisted state
5. no new authority should be granted without an explicit policy reason

PR shape:

- one governance/security-focused diff
- explicit examples of allowed versus restricted host-folder contexts

Exit criteria:

1. host-folder mode has an explicit, testable risk model
2. risky non-sandbox execution paths are more tightly controlled
3. no unrelated sandbox/runtime feature work is bundled into the diff

## Phase 7: Work Tool Orchestration

Branch:

- `feature/work-tool-orchestration`

Focused theme:

- batch safe independent tool calls for throughput

Primary objective:

- improve Work Mode throughput by orchestrating safe, independent tool operations without weakening permission or mutation controls

Likely code surfaces:

- `Packages/OsaurusCore/Work/WorkBatchTool.swift`
- `Packages/OsaurusCore/Work/WorkExecutionContext.swift`
- `Packages/OsaurusCore/Work/WorkFileOperation.swift`
- `Packages/OsaurusCore/Work/WorkFileOperationLog.swift`
- `Packages/OsaurusCore/Tools/ToolRegistry.swift`
- `Packages/OsaurusCore/Services/WorkExecutionEngine.swift`
- `Packages/OsaurusCore/Tests/Work/WorkExecutionEngineTests.swift`
- new batch/orchestration tests under `Packages/OsaurusCore/Tests/Work`

Entry criteria:

1. the allowlist and denylist for orchestrated tools are defined before implementation
2. concurrency bounds are fixed before code changes
3. approval behavior is specified before implementation

Implementation slices:

1. start from the existing sequential `batch` tool instead of inventing a disconnected abstraction
2. define which tools are safe for orchestration and which remain sequential-only or denied
3. add bounded parallel execution only for operations proven independent
4. preserve stable result ordering and clear failure reporting
5. preserve approval requirements, batch IDs, and file-operation audit logging
6. reject nested orchestration or unsafe mutation patterns

Out of scope:

- new arbitrary shell concurrency
- sandbox permission bypasses
- unrelated performance work outside Work Mode tool orchestration

Phase 7 test plan:

1. positive-path tests for independent read-only or otherwise safe operations executing concurrently
2. negative-path tests for denied, nested, or unsafe batched operations
3. tests proving stable output ordering even when execution is concurrent
4. tests proving partial failure remains explicit and non-successful
5. tests proving audit logging and batch IDs remain correct

Phase 7 security checklist:

1. orchestration must not bypass tool permission policy
2. unsafe write combinations must be rejected or forced back to sequential execution
3. concurrency must be bounded and cancellable
4. result aggregation must not hide failures
5. no new ability to execute privileged tools in bulk should appear without explicit approval handling

PR shape:

- one performance-and-control diff built on the existing `batch` tool foundation
- explicit explanation of what qualifies as safe orchestration

Exit criteria:

1. throughput is better for safe independent tool work
2. permission and mutation safety are preserved
3. the final phase still fits the one-phase, one-theme, one-PR rule

## Program Completion Criteria

The Work Mode reliability program should be considered complete only when all of the following are true:

1. Phase 1 has landed publicly without unrelated integration-only commits.
2. Each later phase shipped in canonical order as its own focused PR.
3. Every phase documented its own test plan and security checklist.
4. The local integration branch strategy never contaminated a public branch.
5. The final merged history is understandable phase by phase by reading branch diffs and PRs independently.

## Immediate Next Move

If approval exists to ship the first PR now:

1. prepare a clean Phase 1 worktree from `feature/work-completion-contract`
2. keep `07_REMAINING_PHASES_OPERATING_PLAN.md` off that branch
3. if the document needs to be committed, move it onto `docs/work-mode-reliability-operating-plan` or another non-Phase-1 branch
4. rerun the canonical gate
5. push or update only the clean Phase 1 branch
6. open the upstream PR linked to `osaurus-ai/osaurus#825`

If approval does not yet exist:

1. leave `feature/work-completion-contract` frozen
2. keep `feature/work-completion-contract-local` local-only
3. implement and commit this file on `docs/work-mode-reliability-operating-plan` or another non-Phase-1 branch
4. start Phase 2 in a fresh clean worktree from refreshed `main`
5. keep any new compatibility drift out of the future public phase branch unless it is split cleanly

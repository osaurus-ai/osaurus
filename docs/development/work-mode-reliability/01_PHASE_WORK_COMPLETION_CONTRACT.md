# Phase 1: Work Completion Contract

## Objective

Make Work Mode completion more truthful and explicit.

This phase upgrades `complete_task` from a summary-oriented signal into a structured completion contract with stronger validation.

## Scope

Primary files:

- `Packages/OsaurusCore/Tools/WorkTools.swift`
- `Packages/OsaurusCore/Services/WorkExecutionEngine.swift`
- `Packages/OsaurusCore/Services/Chat/SystemPromptTemplates.swift`
- `Packages/OsaurusCore/Models/Work/WorkModels.swift`
- `Packages/OsaurusCore/Services/WorkEngine.swift`
- `Packages/OsaurusCore/Tests/Work/WorkExecutionEngineTests.swift`
- `Packages/OsaurusCore/Tests/Work/WorkEngineResumeTests.swift`

## Required Behavior

`complete_task` must require:

1. `status`
2. `summary`
3. `verification_performed`
4. `remaining_risks`
5. `remaining_work`

Allowed status values:

- `verified`
- `partial`
- `blocked`

## Intended Semantics

- `verified`: the task goal is complete and evidence exists
- `partial`: meaningful progress was made, but work remains
- `blocked`: the task cannot continue without an external change or clarification

## Runtime Rules

1. Reject `verified` if `verification_performed` is empty or obviously non-evidentiary.
2. Preserve existing artifact support for now to keep the change narrowly scoped.
3. Convert completion into a typed internal result so downstream code can distinguish verified vs partial vs blocked outcomes.
4. Reflect non-verified states in the final `ExecutionResult.success` flag.

## Tests

Add tests for:

1. `verified` without verification evidence is rejected
2. `verified` with evidence succeeds
3. `partial` succeeds and preserves remaining work
4. `blocked` succeeds and preserves remaining risks/work
5. old `success: true/false` payloads are no longer accepted
6. prompt text instructs the model to use the new contract

## Security Checklist

Before merging this phase, verify:

1. tool argument parsing is schema-bounded
2. no completion field is blindly interpreted as executable content
3. verification strings do not get privileged treatment beyond validation
4. partial/blocked summaries do not trigger false success in downstream handling
5. invalid completion payloads fail safely

## PR Shape

Suggested title:

- `feature: strengthen Work Mode completion contract`

Suggested summary:

- require explicit completion status
- require verification and risk reporting
- reject weak verified completions
- add tests for success and failure paths

# Testing And Security Gates

## Purpose

Every Work Mode reliability phase changes harness behavior. That means each phase must prove both:

1. the intended behavior works
2. the new control path does not create new trust or injection problems

## Required Test Types Per Phase

### 1. Positive-path tests

Show that the new intended behavior succeeds.

Examples:

- a valid `complete_task` payload with `status = verified` succeeds
- a runtime reminder appears when the right execution state is present
- restored working state survives compaction

### 2. Negative-path tests

Show that invalid or weak behavior is rejected safely.

Examples:

- legacy `success: true` completion payload is rejected
- `verified` without evidence is rejected
- oversized or malformed saved state does not restore silently

### 3. Regression tests

Show that existing Osaurus behavior that should still hold remains intact.

Examples:

- issue resume still preserves conversation state
- artifact sharing still works
- budget warnings still appear

## Required Security Questions Per Phase

1. Can model-provided text change control flow unexpectedly?
2. Can any new state store secrets, tokens, or raw privileged outputs?
3. Can a failure path silently downgrade a control instead of failing closed?
4. Can the new code leak sensitive paths, tokens, or system details into prompts, logs, or user-visible summaries?
5. Does any new serialized state have:
   - a schema
   - size bounds
   - explicit validation

## Phase 1 Checklist

Before Phase 1 is committed:

- `complete_task` rejects malformed JSON
- `complete_task` rejects legacy `success: true/false` payloads
- `status = verified` rejects weak or empty evidence
- `partial` and `blocked` do not masquerade as successful verification
- completion fields are treated as inert text only
- final summary rendering does not execute or interpret completion content

## Verification Commands

Run these before push:

```bash
swift-format lint --strict --recursive Packages App
swiftlint lint
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCoreTests -skip-testing OsaurusCoreTests/KVCacheStoreTests -skip-testing OsaurusCoreTests/MLXGenerationEngineTests
xcodebuild test -workspace osaurus.xcworkspace -scheme OsaurusCLITests
```

## PR Review Guidance

Each PR should explicitly state:

- what behavior changed
- what the new failure mode is for invalid input
- what tests were added
- what security assumptions were checked

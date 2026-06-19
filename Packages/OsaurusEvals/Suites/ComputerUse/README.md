# ComputerUse suite

Pure-data evals that pin the **Computer Use harness gate** end-to-end without a
driver, screen permissions, or a model. Each case scripts one `AgentAction`
plus the resolution context the `TargetResolver` would have produced, then
asserts two things the safety story depends on:

1. **Effect classification** — `EffectClassifier.classify(...)` ranks the action
   `read` / `navigate` / `edit` / `consequential`, escalating on commit verbs
   (Send/Delete/Purchase), commit-with-recipients (the calendar-save case), the
   ⌘Return submit chord, ambiguous targets, and per-app recipe signals.
2. **Gate disposition** — `AutonomyPolicy.disposition(...)` resolves the effect
   against the global preset + per-app overrides + per-agent ceiling
   (strictest-wins) into `allow` / `confirm` / `deny`, and `isAppAllowed(...)`
   enforces the allowlist.

Because everything is plain data, this lane is **CI-safe** and deterministic —
run it on every PR like `schema` / `request_validation` to keep the
safe-by-default gate from regressing.

## Running

```bash
swift build --package-path Packages/OsaurusEvals --product osaurus-evals
Packages/OsaurusEvals/.build/debug/osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/ComputerUse \
  --model auto
```

`--model` is irrelevant (no model is invoked); `auto` keeps current config.

## Case schema (`expect.computerUse`)

| field | meaning |
|-------|---------|
| `verb` | `AgentVerb` raw value (observe, click, type, press_key, …) |
| `describe` / `mark` | the action target (`AgentTarget`) |
| `text` / `key` / `modifiers` / `note` | verb-specific action fields |
| `resolvedRole` / `resolvedLabel` / `appName` | resolution context |
| `useRecipes` | merge `AppRecipes.signals(for: appName)` into the classifier |
| `preset` / `perApp` / `allowlist` / `ceiling` | the `AutonomyPolicy` under test |
| `expectEffect` | expected `EffectClass` raw value |
| `expectDisposition` | expected `AutonomyDisposition` raw value |
| `expectAllowed` | expected `isAppAllowed` result |

Any subset of the three `expect*` fields may be set; an empty set just records
the computed `effect` / `disposition` / `allowed` in the case notes.

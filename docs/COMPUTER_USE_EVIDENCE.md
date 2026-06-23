# Computer Use Evidence Pack

This pack maps CI-safe evidence for the contract documented in
`docs/COMPUTER_USE.md`. It is a local evidence map only; it does not create a
report store.

## Focused commands

```bash
swift test --package-path Packages/OsaurusCore --filter ComputerUseEvidencePackTests
swift test --package-path Packages/OsaurusCore --filter ComputerUse
swift build --package-path Packages/OsaurusEvals --product osaurus-evals
Packages/OsaurusEvals/.build/debug/osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/ComputerUse \
  --model auto
git diff --check
```

If available:

```bash
swiftlint lint Packages/OsaurusCore/Tests/ComputerUse/ComputerUseEvidencePackTests.swift
```

## Evidence map

| Contract | CI-safe evidence |
| --- | --- |
| Custom-agent opt-in only; Default agent cannot use `computer_use` | `ComputerUseEvidencePackTests.testComputerUseToolIsCustomAgentOptInOnly` |
| AX-first; no screenshot/cloud path when AX resolves the task | `ComputerUseEvidencePackTests.testAxResolvedRunStaysAxOnlyAndDoesNotUseScreenshots`, `PerceptionTests`, `ComputerUseLoopRunTests` empty-AX escalation cases |
| Dangerous-app confirm guardrail | `ComputerUseEvidencePackTests.testDangerousAppConfirmGuardrailCannotBeBypassedByAutonomousPreset`, `GateHardeningTests` |
| Cloud vision requires consent and a `ScrubbedFrame` | `ComputerUseEvidencePackTests.testCloudVisionRequiresConsentAndScrubbedFrameRoute`, `CloudVisionScrubModeTests`, `PerceptionTests` |
| Secure-field/raw text containment where feasible | `ScreenContextDistillerTests.testSecureFieldDirectReadNeverSurfacesValue`, `ScreenContextDistillerTests.testSecureFieldTraversalFallbackNeverSurfacesValue` |
| Stop/cancel resolves pending confirm and cloud-consent prompts | `ComputerUseEvidencePackTests.testStopCancelResolvesPendingConfirmationAndCloudConsentPrompts` |
| Screen-context privacy path stays on latest user turn, not system prompt | `ComputerUseEvidencePackTests.testScreenContextPrivacyPathInjectsFrozenBlockIntoLatestUserTurnOnly`, `ScreenContextInjectionTests` |
| Autonomy policy regression matrix | `Packages/OsaurusEvals/Suites/ComputerUse/*.json` through the `computer_use` eval runner |

Screen-context freezing itself is owned by `ChatView` state (`frozenScreenContext`
and `isScreenContextFrozen`). The Computer Use test pack pins the pure privacy
path that receives that frozen block; broad `ChatView` UI-state coverage is
outside this lane.

## Regression scorecards

Computer Use regression scorecards are offline artifacts generated from existing
`osaurus-evals run --out ...` JSON reports. They do not call a model and do not
change runtime behavior.

```bash
swift run --package-path Packages/OsaurusEvals osaurus-evals scorecard \
  build/evals/computer-use.json \
  build/evals/computer-use-loop.json
```

By default, the command writes:

- `build/evals/computer-use-scorecard/scorecard.json`
- `build/evals/computer-use-scorecard/scorecard.md`

Exit codes are intended for regression gates: `0` means no failed or errored
Computer Use cases were found, `1` means the reports contain failures or
errors, and `2` means the scorecard command itself failed.

The scorecard aggregates the `computer_use` and `computer_use_loop` domains:

- pass/fail/skipped/error totals by domain
- safety gate effect, disposition, and allowlist outcomes
- confirm/autonomy counts from gate cases and loop telemetry
- acted-case verify pass/change rates
- unresolved target, dead-end, blocked, and invalid-action counts
- privacy-safe evidence references containing case IDs, outcomes, domains, and
  report paths

The generated Markdown and JSON intentionally omit raw prompts, case notes,
screen text, final field values, and model-visible content. They keep case IDs,
domains, outcomes, report paths, model IDs, and run timestamps so the report is
traceable without exposing captured UI content. Use the source report paths when
a maintainer needs to inspect full local evidence.

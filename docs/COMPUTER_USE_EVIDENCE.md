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

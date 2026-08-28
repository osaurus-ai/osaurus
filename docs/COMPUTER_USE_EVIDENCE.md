# Computer Use Evidence Pack

This pack maps CI-safe evidence for the contract documented in
`docs/COMPUTER_USE.md`. The canonical local runner writes an ignored evidence
bundle under `build/computer-use-evidence/`, including command logs,
`manifest.json`, `summary.md`, git metadata, and timing for each proof step.

## Canonical local runner

```bash
make computer-use-evidence
```

The default lane runs:

- `git diff --check`
- `ComputerUseEvidencePackTests`
- the full `ComputerUse` Swift test filter
- the deterministic local web-form fixture proof inside the evidence pack
- a privacy check over the generated command logs for that proof

Generated artifacts stay local because `build/` is gitignored. To include the
model-dependent OsaurusEvals ComputerUse suite:

```bash
RUN_EVALS=1 MODEL=foundation make computer-use-evidence
```

With `RUN_EVALS=1`, the runner builds `osaurus-evals` and executes both
model-dependent suites: `ComputerUse` and `ComputerUseLoop`. The loop suite is
where live-model Computer Use quality is scored; the default Swift tests keep
the CI-safe proof deterministic.

Useful overrides:

```bash
OUT_DIR=build/computer-use-evidence/manual RUN_EVALS=1 make computer-use-evidence
STRICT=0 make computer-use-evidence
```

## Focused commands

The runner above executes the deterministic default commands for you. Equivalent
manual commands are:

```bash
git diff --check
swift test --package-path Packages/OsaurusCore --filter ComputerUseEvidencePackTests
swift test --package-path Packages/OsaurusCore --filter ComputerUse
python3 scripts/evals/assert-computer-use-web-form-evidence-privacy.py \
  Packages/OsaurusEvals/Suites/ComputerUseLoop/web-form-proof-lab.json \
  build/computer-use-evidence/manual/logs/computer-use-evidence-pack.log \
  build/computer-use-evidence/manual/logs/computer-use-suite.log
```

Optional model-dependent eval commands, matching `RUN_EVALS=1`, are:

```bash
swift build --package-path Packages/OsaurusEvals --product osaurus-evals
Packages/OsaurusEvals/.build/debug/osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/ComputerUse \
  --model auto
Packages/OsaurusEvals/.build/debug/osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/ComputerUseLoop \
  --model auto
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
| Boring web-form loop plumbing in a deterministic mock AX scene: fill fields, accept terms, resolve the submit button, require consequential-action confirmation, and observe the submitted-state snapshot | `ComputerUseEvidencePackTests.testBrowserFormLoopFillsFieldsAndSubmitsDeterministically` |
| Local web-form proof lab: committed static pages, deterministic loop, AX-only perceive, trusted edit actions, consequential submit confirmation, verify counters, and command-log privacy scan | `Packages/OsaurusCore/Tests/ComputerUse/Fixtures/WebForm/`, `ComputerUseEvidencePackTests.testBrowserFormLoopFillsFieldsAndSubmitsDeterministically`, `ComputerUseEvidencePackTests.testWebFormFixtureIsLocalOnlyAndMatchesProofControls`, `scripts/evals/assert-computer-use-web-form-evidence-privacy.py` |
| Dangerous-app confirm guardrail | `ComputerUseEvidencePackTests.testDangerousAppConfirmGuardrailCannotBeBypassedByAutonomousPreset`, `GateHardeningTests` |
| Cloud vision requires consent and a `ScrubbedFrame` | `ComputerUseEvidencePackTests.testCloudVisionRequiresConsentAndScrubbedFrameRoute`, `CloudVisionScrubModeTests`, `PerceptionTests` |
| Secure-field/raw text containment where feasible | `ScreenContextDistillerTests.testSecureFieldDirectReadNeverSurfacesValue`, `ScreenContextDistillerTests.testSecureFieldTraversalFallbackNeverSurfacesValue` |
| Stop/cancel resolves pending confirm and cloud-consent prompts | `ComputerUseEvidencePackTests.testStopCancelResolvesPendingConfirmationAndCloudConsentPrompts` |
| Screen-context privacy path stays on latest user turn, not system prompt | `ComputerUseEvidencePackTests.testScreenContextPrivacyPathInjectsFrozenBlockIntoLatestUserTurnOnly`, `ScreenContextInjectionTests` |
| Autonomy policy regression matrix | `Packages/OsaurusEvals/Suites/ComputerUse/*.json` through the `computer_use` eval runner |
| Live-model loop quality, including field typing, async waits, submit keys, recovery, and escalation | `Packages/OsaurusEvals/Suites/ComputerUseLoop/*.json` through the `computer_use` eval runner when `RUN_EVALS=1` |

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

## Local web-form proof lane

The web-form lane is intentionally boring and local-only:

- Fixture pages live under `Packages/OsaurusCore/Tests/ComputerUse/Fixtures/WebForm/`
  and reference only same-directory files.
- The proof test mirrors those controls into a `MockMacDriver` scene; no
  browser, server, network transport, or provider path is involved.
- Scripted actions drive `ComputerUseLoop` through perceive, gate, act, and
  verify. The edit actions run without confirmation under the trusted preset;
  the submit button is still classified as consequential and approved by the
  deterministic harness.
- Command logs are written under `build/computer-use-evidence/` and scanned so
  typed form contents and image payload markers do not appear in generated
  evidence.

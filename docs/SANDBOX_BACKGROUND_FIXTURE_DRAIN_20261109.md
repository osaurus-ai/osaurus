# Sandbox background fixture ownership

This is a test-only lifecycle correction. Production source, tool behavior,
registry grace, model defaults, agent settings and cache behavior are unchanged.

## Reproduced failure and cause

PR3362's full core CI failed
`sandboxWriteFile_generatesDocumentHostSideWithoutShellWrite`: the document
mock runner received a `kill -0 12345` probe. The document writer is host-side;
its no-shell assertion correctly exposed another fixture's command.

`sandboxExec_backgroundReturnsPidAndLogFile` starts the real production
background monitor using a mock PID. The old fixture resets the shared shell
runner as soon as its body returns, while the detached monitor remains alive.
Its next liveness check therefore uses whichever mock runner the next fixture
has installed. Serializing test bodies does not drain that detached resource.

The controlled original-main run executes the real background poll and the
host document writer in sequence. Success, thrown-error and owned-child
cancellation all reproduce the same leak: an owned live entry remains, its
poll is absent from its starting runner, and that exact poll reaches the next
document runner. The success row also captures the original mock PID12345.
Baseline result:55passed/1failed parameterized declaration/0skipped; all three
argument rows fail. This is a fixture failure, not a production document-write
or image-permission defect.

## Correction and affected behavior

The background-enabled fixture assigns an owned tool-call ID, preserving an
explicit ID supplied by the test. Before replacing the runner it waits for
that job's real mock liveness poll to report exit and for the existing registry
grace to drop the entry. It removes only that job's metadata. Cleanup runs in
an uncancelled task on success, error and cancellation. The eight-second test
deadline records failure; it does not change a production timeout or hide a
failed teardown. A failed drain cancels only its owned cleanup resource to
prevent contamination of following tests.

The document's `calls.isEmpty` assertion remains unchanged. The regression
also requires a fresh unrelated registry entry to survive, and fails if that
entry is terminated. There is no clear-all, terminate-all, real VM command,
process signal, liveness-command filtering or production API addition.
Non-background fixture bodies retain their original execution context.

## Qualification and retained evidence

Candidate2 passed69/69declarations in BuiltinSandboxToolsTests,
LiveExecRegistryTests, LogFileTailerTests and TeeWriterTests,0fail/0skip;
expanded device/argument count71passed. All three lifecycle rows observe the
poll in its original runner, no leftover entry, zero commands in the next
document runner and the unrelated entry still running.

Actual XCTestPID58357 carries all five verified private flags: keychain
disabled, private test root, empty text/image model roots and prefill debug.
The original baseline usedPID49657 with the same isolation. No model was
loaded or generated; no model bundle, sampler, UI or hardware qualification is
claimed. Baseline Osaurus source715760a54a43942222eed3fff6a8ad348b17e24e;
official vMLX pin1bcd74ad182103a3b83941f61e57ee0bac23b330. No SDK overlay.

Private evidence root:
`/Users/eric/vmlx-private-evidence/sentry-inference-20261108/sandbox-background-fixture-20261109/`.
It retains baseline1's source/patch, logs, three actual observations, xcresult
and frozen DerivedData; candidate2's exact source, command, actual PID flags,
test binary identity, observations and xcresult; and `QUALIFICATION1.json`.
Candidate1's missing nested MainActor annotation caused a compile failure;
its log, source, xcresult and frozen compiler state remain retained. No tests
ran for that attempt, and its cached baseline binary is not candidate proof.

SOURCE EVIDENCE: only
`Packages/OsaurusCore/Tests/Sandbox/BuiltinSandboxToolsTests.swift` changes;
the entire non-test Core projection equals original main. The original
document no-shell assertion remains intact.

LIVE EVIDENCE: baseline1 and candidate2 actual XCTest observations and
xcresults, summarized with exact counts in `QUALIFICATION1.json`. Full normal
CI and merge are pending. Existing native image and AgentLoop artifacts for
PR3362 remain separate and are not reclassified as green by this test fix.

//
//  AppleScriptEvaluatorProbeTests.swift
//
//  Pins the liveProof automation-readiness probe. On an unattended machine
//  the first Apple event to an ungrantable app parks the OSA serial-queue
//  thread inside the TCC consent send; observed live (baseline loop
//  20260702-115706) as a 600s per-case watchdog trip on
//  `apple_script.liveproof-verbatim-single` that force-terminated the suite
//  process and skipped the 14 scripted cases queued behind it — identically
//  for the local gemma lane and the remote grok lane. The probe converts
//  that environment into a fast, honest SKIP (with the how-to-grant hint)
//  BEFORE any model tokens are spent, while a granted machine pays one
//  sub-second read-only script and runs the real case unchanged.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("AppleScriptEvaluator liveProof probe")
struct AppleScriptEvaluatorProbeTests {

    /// Build a minimal liveProof config whose probe seam returns `result`.
    /// The probe must short-circuit BEFORE model resolution, so no
    /// AppleScript model needs to be installed for these tests.
    private func liveProofConfig(
        probeResult: AppleScriptExecutionResult
    ) -> AppleScriptEvaluator.Config {
        AppleScriptEvaluator.Config(
            lane: .liveProof,
            task: "In Notes, create a scratch note.",
            executor: .real,
            automationProbeScript: "tell application \"Notes\" to count notes",
            automationProbeRunner: { _, _ in probeResult }
        )
    }

    @Test func timedOutProbeSkipsWithGrantHint() async {
        let transcript = await AppleScriptEvaluator.run(
            liveProofConfig(
                probeResult: AppleScriptExecutionResult(
                    status: .timedOut,
                    output: nil,
                    errorNumber: nil,
                    errorMessage: "The AppleScript did not finish within 15s and was stopped."
                )
            )
        )
        #expect(transcript.skipped)
        #expect(transcript.outcome == "skipped")
        // The reason must name the environmental cause and how to fix it —
        // this is what lands in the matrix row instead of "watchdog timeout".
        #expect(transcript.skipReason?.contains("consent dialog") == true)
        #expect(transcript.skipReason?.contains("Automation") == true)
        // No model ran, no tokens were burned.
        #expect(transcript.ranModel == false)
        #expect(transcript.modelTokens == 0)
    }

    @Test func deniedPermissionProbeSkipsWithErrorNumber() async {
        let transcript = await AppleScriptEvaluator.run(
            liveProofConfig(
                probeResult: AppleScriptExecutionResult(
                    status: .permissionRequired,
                    output: nil,
                    errorNumber: -1743,
                    errorMessage: "Not authorized to send Apple events to Notes."
                )
            )
        )
        #expect(transcript.skipped)
        #expect(transcript.skipReason?.contains("denied") == true)
        #expect(transcript.skipReason?.contains("-1743") == true)
    }

    @Test func probeFailureOtherThanPermissionStillSkipsHonestly() async {
        // e.g. the target app is missing on this host — an environment
        // problem, not a model verdict; the row must not read as FAILED.
        let transcript = await AppleScriptEvaluator.run(
            liveProofConfig(
                probeResult: AppleScriptExecutionResult(
                    status: .runtimeError,
                    output: nil,
                    errorNumber: -600,
                    errorMessage: "Application isn't running."
                )
            )
        )
        #expect(transcript.skipped)
        #expect(transcript.skipReason?.contains("runtimeError") == true)
    }

    @Test func mockLanesNeverRunTheProbe() async {
        // A scripted case with a probe configured (nonsense combination)
        // must not consult it: the probe gates only the REAL executor.
        let config = AppleScriptEvaluator.Config(
            lane: .scripted,
            task: "noop",
            scriptedCalls: [],
            executor: .mockResults([]),
            automationProbeScript: "tell application \"Notes\" to count notes",
            automationProbeRunner: { _, _ in
                AppleScriptExecutionResult(
                    status: .timedOut,
                    output: nil,
                    errorNumber: nil,
                    errorMessage: "probe must not run"
                )
            }
        )
        let transcript = await AppleScriptEvaluator.run(config)
        #expect(transcript.skipReason?.contains("environment not ready") != true)
    }
}

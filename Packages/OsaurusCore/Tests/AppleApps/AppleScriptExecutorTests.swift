//
//  AppleScriptExecutorTests.swift
//  OsaurusCoreTests — Apple app tools
//
//  Real in-process `NSAppleScript` outcome mapping for scripts that need no
//  Automation grant: success output, compile error, runtime error + error
//  number, result coercion, and the main-runloop heartbeat lifecycle.
//

import Foundation
import Testing

@testable import OsaurusCore

// `.serialized`: these drive the real, process-wide single OSA scripting
// component. The executor already serializes internally, but running the suite
// serially keeps the proof clean and documents that NSAppleScript is a shared,
// non-concurrent resource.
@Suite("AppleScriptExecutor mapping", .serialized)
struct AppleScriptExecutorMappingTests {
    @Test("a string-returning script succeeds and coerces its output")
    func successOutput() async {
        let result = await AppleScriptExecutor.run(
            source: "return \"hello world\"",
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "hello world")
        #expect(result.errorNumber == nil)
    }

    @Test("a syntax error maps to compileError")
    func compileError() async {
        // Unterminated string literal — never compiles.
        let result = await AppleScriptExecutor.run(
            source: "return \"unterminated",
            timeout: 15
        )
        #expect(result.status == .compileError)
    }

    @Test("a runtime error maps to runtimeError and carries the error number")
    func runtimeError() async {
        let result = await AppleScriptExecutor.run(
            source: "error \"boom\" number 42",
            timeout: 15
        )
        #expect(result.status == .runtimeError)
        #expect(result.errorNumber == 42)
    }

    @Test("an integer result coerces to its text value")
    func integerOutput() async {
        let result = await AppleScriptExecutor.run(source: "return 42", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "42")
    }

    @Test("a boolean result coerces to true/false")
    func booleanOutput() async {
        let result = await AppleScriptExecutor.run(source: "return true", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "true")
    }

    @Test("a numeric list coerces to a comma-joined string")
    func listOutput() async {
        let result = await AppleScriptExecutor.run(source: "return {1, 2, 3}", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "1, 2, 3")
    }

    @Test("a string list coerces to a comma-joined string")
    func stringListOutput() async {
        let result = await AppleScriptExecutor.run(source: "return {\"a\", \"b\"}", timeout: 15)
        #expect(result.status == .success)
        #expect(result.output == "a, b")
    }

    @Test("a user record surfaces its REAL keys as key: value pairs")
    func userRecordOutput() async {
        // AE regroups record fields: RESERVED labels (name, locked) become
        // coded keyword fields ahead of the user-label block (battery), so
        // the rendered order is grouped, not source order.
        let result = await AppleScriptExecutor.run(
            source: "return {name:\"Front Door\", battery:87, locked:true}",
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "name: Front Door, locked: true, battery: 87")
    }

    @Test("TextEdit record fields surface semantic text and modified keys")
    func textEditRecordOutput() async {
        // `text` and `modified` are reserved labels in TextEdit's dictionary,
        // so NSAppleScript encodes them as `ctxt` / `imod` keyword fields
        // instead of putting their source labels in the `usrf` block.
        let result = await AppleScriptExecutor.run(
            source: "return {text:\"Final normalized new\", modified:false}",
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "text: Final normalized new, modified: false")
    }

    @Test("a nested user record renders recursively with its keys")
    func nestedRecordOutput() async {
        let result = await AppleScriptExecutor.run(
            source: "return {device:{name:\"Hub\", port:8080}, ok:true}",
            timeout: 15
        )
        #expect(result.status == .success)
        #expect(result.output == "device: {name: Hub, port: 8080}, ok: true")
    }

    // The heartbeat keeps the MAIN run loop turning while any script is in
    // flight — headless hosts otherwise never deliver AE replies (observed
    // live: a Finder probe "timed out" 15s+ on a granted machine, wedging
    // the eval suite's main actor afterwards). The refcount must return to
    // zero (timer removed) after every completion path, including a
    // watchdog-abandoned run, or the process would wake 4×/s forever.
    @Test("heartbeat: armed during a run, disarmed after it completes")
    func heartbeatLifecycleAroundRun() async {
        _ = await AppleScriptExecutor.run(source: "return 1", timeout: 15)
        await Self.waitForHeartbeatDisarm()
        #expect(AppleScriptExecutor.isHeartbeatActiveForTesting == false)
    }

    /// The worker releases its heartbeat ref in a `defer` *after* resuming
    /// the awaiting caller, so an immediate read races that queue hop (seen
    /// flaking on slow CI runners). Poll briefly; a leaked ref still fails
    /// the follow-up expectation after the deadline.
    static func waitForHeartbeatDisarm(attempts: Int = 100) async {
        for _ in 0..<attempts where AppleScriptExecutor.isHeartbeatActiveForTesting {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("heartbeat: a watchdog-abandoned run still disarms once the worker finishes")
    func heartbeatDisarmsAfterAbandonedRun() async {
        // 1-second busy script vs a 0.05s timeout: the caller resumes via
        // the watchdog (timedOut) while the worker is still running. The
        // heartbeat must stay armed for the in-flight worker, then clear.
        let result = await AppleScriptExecutor.run(
            source: "delay 1\nreturn 2",
            timeout: 0.05
        )
        #expect(result.status == .timedOut)
        // Worker still holds its heartbeat ref while `delay 1` runs.
        #expect(AppleScriptExecutor.isHeartbeatActiveForTesting == true)
        // After the abandoned worker completes, the ref drains to zero.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await Self.waitForHeartbeatDisarm()
        #expect(AppleScriptExecutor.isHeartbeatActiveForTesting == false)
    }

    @Test("assistive-access errors map to an Accessibility denial, not Automation")
    func accessibilityDenialMapping() {
        #expect(AppleScriptExecutor.isAccessibilityDenial(errorNumber: -25211, errorMessage: nil))
        #expect(AppleScriptExecutor.isAccessibilityDenial(errorNumber: nil, errorMessage: "Osaurus is not allowed assistive access."))
        #expect(!AppleScriptExecutor.isAccessibilityDenial(errorNumber: -1743, errorMessage: "Not authorized to send Apple events."))
    }
}

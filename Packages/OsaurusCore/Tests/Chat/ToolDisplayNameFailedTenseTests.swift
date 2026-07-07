//
//  ToolDisplayNameFailedTenseTests.swift
//  osaurusTests
//
//  Pins the failure tense on the collapsed tool card title. A completed call
//  whose result was an error keeps a red node but previously still read
//  "Wrote a file" (success past tense) — contradicting the node. `friendly`
//  now renders a "Failed: <tool>" title when `failed` is set on a finished
//  call, while success and in-flight titles are untouched.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolDisplayNameFailedTenseTests {

    @Test("failed completed call does not claim success")
    func failedCompletedCallShowsFailure() {
        let title = ToolDisplayName.friendly(for: "file_write", running: false, failed: true)
        #expect(title == String(format: L("Failed: %@"), "File write"))
        // Must NOT read as the success past tense.
        #expect(title != L("Wrote a file"))
    }

    @Test("successful completed call is unchanged")
    func successfulCompletedCallUnchanged() {
        #expect(ToolDisplayName.friendly(for: "file_write", running: false, failed: false) == L("Wrote a file"))
        // Default (no failed arg) preserves the historical behavior.
        #expect(ToolDisplayName.friendly(for: "file_write", running: false) == L("Wrote a file"))
    }

    @Test("in-flight title ignores the failure verdict (present tense during the attempt)")
    func runningTitleIgnoresFailed() {
        #expect(ToolDisplayName.friendly(for: "file_write", running: true, failed: true) == L("Writing a file"))
    }

    @Test("failure tense applies uniformly to uncurated tools")
    func failedGenericTool() {
        let title = ToolDisplayName.friendly(for: "my_plugin_action", running: false, failed: true)
        #expect(title == String(format: L("Failed: %@"), "My plugin action"))
    }

    @Test("pending sentinel is never treated as a failure")
    func pendingSentinelUnaffectedByFailed() {
        let title = ToolDisplayName.friendly(
            for: ToolDisplayName.pendingToolSentinel,
            running: false,
            failed: true
        )
        #expect(title == L("Preparing tool call"))
    }
}

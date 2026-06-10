//
//  ToolOutputCapsTests.swift
//  osaurusTests
//
//  Pins the centralised tool-output caps to their historical values and
//  tier ordering, so a future tuning pass is a deliberate one-file edit
//  (with this test updated alongside) rather than an accidental drift.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolOutputCapsTests {

    /// The historical tiers, exactly as they were when scattered across
    /// `BuiltinSandboxTools` / `FolderTools` / `SandboxPluginTool`.
    @Test func historicalValuesPreserved() {
        #expect(ToolOutputCaps.execStdout == 50_000)
        #expect(ToolOutputCaps.execStderr == 10_000)
        #expect(ToolOutputCaps.execRetryCombined == 20_000)
        #expect(ToolOutputCaps.execFirstAttemptCombined == 10_000)
        #expect(ToolOutputCaps.fileRead == 15_000)
        #expect(ToolOutputCaps.shellOutput == 10_000)
        #expect(ToolOutputCaps.gitDiff == 20_000)
        #expect(ToolOutputCaps.tree == 8_000)
        #expect(ToolOutputCaps.fileSearch == 12_000)
        #expect(ToolOutputCaps.searchMaxResults == 500)
        #expect(ToolOutputCaps.universalResult == 100_000)
    }

    /// Tier ordering is the deliberate part of the design: exec stdout
    /// gets the largest budget, tree the smallest (it's retained context
    /// on every later turn). The universal registry backstop must sit
    /// ABOVE every per-tool cap (with JSON-escaping headroom) so it never
    /// re-mangles a deliberately-capped envelope.
    @Test func tierOrderingHolds() {
        #expect(ToolOutputCaps.execStdout > ToolOutputCaps.gitDiff)
        #expect(ToolOutputCaps.gitDiff > ToolOutputCaps.fileRead)
        #expect(ToolOutputCaps.fileRead > ToolOutputCaps.shellOutput)
        #expect(ToolOutputCaps.shellOutput > ToolOutputCaps.tree)
        #expect(
            ToolOutputCaps.universalResult
                > ToolOutputCaps.execStdout + ToolOutputCaps.execStderr
        )
    }

    /// `truncateForModel`'s default budget rides the shared constant —
    /// a string under the cap is untouched, one over it is head+tail
    /// truncated with the omission marker.
    @Test func truncateForModelUsesSharedDefault() {
        let under = String(repeating: "a", count: ToolOutputCaps.execStdout)
        #expect(truncateForModel(under) == under)

        let over = String(repeating: "b", count: ToolOutputCaps.execStdout + 100)
        let truncated = truncateForModel(over)
        #expect(truncated.count < over.count)
        #expect(truncated.contains("[TRUNCATED:"))
    }
}

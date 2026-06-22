//
//  ComputerUseLoopTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Coverage for the loop/tool seams that don't require a live model: the
//  autonomy-stance line injected into the system prompt, and the
//  `ComputerUseTool` policy-summary rendering that feeds it. The full
//  perceive→act loop is exercised through the deterministic gate/perception
//  suites and the pure-data evals.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ComputerUseSystemPromptTests: XCTestCase {
    func testSystemPromptIncludesPolicyStance() {
        let summary = "Cautious — Ask before every action except reading."
        let prompt = ComputerUseLoop.systemPrompt(policySummary: summary)
        XCTAssertTrue(prompt.contains("Current autonomy policy: \(summary)"))
        // The base rules are still present.
        XCTAssertTrue(prompt.contains("agent_action"))
    }

    func testSystemPromptOmitsEmptyStance() {
        let prompt = ComputerUseLoop.systemPrompt(policySummary: "   ")
        XCTAssertFalse(prompt.contains("Current autonomy policy:"))
    }
}

final class ComputerUsePolicySummaryTests: XCTestCase {
    func testSummaryMentionsPresetAllowlistAndCeiling() {
        let policy = AutonomyPolicy(globalPreset: .cautious, allowlist: ["Safari", "Notes"])
        let ceiling = AutonomyCeiling.cappedAt(.balanced)
        let summary = ComputerUseTool.policySummary(policy: policy, ceiling: ceiling)
        XCTAssertTrue(summary.contains("Cautious"))
        XCTAssertTrue(summary.contains("Safari, Notes"))
        XCTAssertTrue(summary.contains("Balanced"))
    }

    func testSummaryWithoutAllowlistOrCeiling() {
        let summary = ComputerUseTool.policySummary(
            policy: AutonomyPolicy(globalPreset: .balanced),
            ceiling: nil
        )
        XCTAssertTrue(summary.contains("Balanced"))
        XCTAssertFalse(summary.contains("Only these apps"))
        XCTAssertFalse(summary.contains("capped at"))
    }
}

final class ComputerUseModelPrivacyTests: XCTestCase {
    func testAllowsFoundationAliasesAndInstalledMLXModels() {
        let installed: ComputerUseModelPrivacy.InstalledModelResolver = { model in
            model == "local-qwen" || model == "org/local-qwen"
        }

        XCTAssertTrue(
            ComputerUseModelPrivacy.isOnDeviceModel("default", installedModelResolver: installed)
        )
        XCTAssertTrue(
            ComputerUseModelPrivacy.isOnDeviceModel("foundation", installedModelResolver: installed)
        )
        XCTAssertTrue(
            ComputerUseModelPrivacy.isOnDeviceModel("local-qwen", installedModelResolver: installed)
        )
        XCTAssertTrue(
            ComputerUseModelPrivacy.isOnDeviceModel("org/local-qwen", installedModelResolver: installed)
        )
    }

    func testBlocksRemoteProviderPrefixedModelsForAXPrivacy() {
        let installed: ComputerUseModelPrivacy.InstalledModelResolver = { _ in false }

        XCTAssertFalse(
            ComputerUseModelPrivacy.isOnDeviceModel("openai/gpt-4o", installedModelResolver: installed)
        )
        XCTAssertFalse(
            ComputerUseModelPrivacy.isOnDeviceModel("osaurus-router/gemma-4", installedModelResolver: installed)
        )

        let envelope = ComputerUseModelPrivacy.remoteModelFailureEnvelope(
            modelId: "openai/gpt-4o",
            tool: ComputerUseTool.toolName
        )
        XCTAssertTrue(envelope.contains("local-only"))
        XCTAssertTrue(envelope.contains("AX-derived screen state"))
        XCTAssertTrue(envelope.contains(ComputerUseTool.toolName))
    }
}

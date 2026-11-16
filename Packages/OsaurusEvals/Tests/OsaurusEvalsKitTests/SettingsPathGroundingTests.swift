//
//  SettingsPathGroundingTests.swift
//  OsaurusEvalsKitTests
//
//  Pins the Configurator lane's `settingsPathsMustBeGrounded` scorer: every
//  Settings breadcrumb in the answer must appear in the seed or a tool result.
//

import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite
struct SettingsPathGroundingTests {
    private static func transcript(
        answer: String,
        seed: String = "",
        results: [String] = []
    ) -> CapabilityClaimsTranscript {
        CapabilityClaimsTranscript(
            toolCalls: results.map { .init(name: "osaurus_help", arguments: "{}", resultPreview: $0) },
            finalText: answer,
            iterations: 1,
            hitIterationCap: false,
            systemPrompt: seed,
            loadedToolNames: [],
            error: nil
        )
    }

    @Test func aPathFromTheSeedIsGroundedDespiteDifferentSeparatorsAndMarkup() {
        let t = Self.transcript(
            answer: "Open **Settings → Server → Cache → Context Window Cap** and lower it.",
            seed: "- Server › Cache › Context Window Cap (id: settings.server.contextCap)")
        #expect(EvalRunner.ungroundedSettingsPaths(in: t).isEmpty)
    }

    @Test func aPathFromAToolResultIsGrounded() {
        let t = Self.transcript(
            answer: "It's under Agents → Configurator → Temperature.",
            results: ["{\"path\":\"Agents › Configurator › Temperature\"}"])
        #expect(EvalRunner.ungroundedSettingsPaths(in: t).isEmpty)
    }

    @Test func anInventedPathIsReported() {
        let t = Self.transcript(
            answer: "Go to Settings → Chat → Context Length.",
            seed: "- Server › Cache › Context Window Cap")
        #expect(EvalRunner.ungroundedSettingsPaths(in: t) == ["Settings → Chat → Context Length"])
    }

    @Test func trailingProseIsNotPartOfThePath() {
        let t = Self.transcript(
            answer: "Open Settings → Agents → Configurator → Configurator Model and pick a model.",
            seed: "- Agents › Configurator › Configurator Model")
        #expect(EvalRunner.ungroundedSettingsPaths(in: t).isEmpty)
    }

    @Test func anAnswerWithNoPathHasNothingToGround() {
        let t = Self.transcript(answer: "Follow-up suggestions are now off.")
        #expect(EvalRunner.ungroundedSettingsPaths(in: t).isEmpty)
    }
}

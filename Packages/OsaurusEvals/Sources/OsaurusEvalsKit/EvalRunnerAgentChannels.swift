//
//  EvalRunnerAgentChannels.swift
//  OsaurusEvalsKit
//
//  Runner for the `agent_channels` domain — deterministic, model-free
//  policy pins over the REAL Slack/Telegram connection services. All the
//  heavy lifting (fake provider clients, isolated config/message stores,
//  the scenario scripts) lives in `AgentChannelEvalHarness` inside
//  OsaurusCore, because every involved service and protocol is internal
//  runtime surface. This runner just maps case files onto scenarios and
//  scenario outcomes onto report rows.
//
//  No network, no model, no keychain — these rows join the token-free
//  CI-safe set.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runAgentChannelsCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.agentChannels else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "missing `expect.agentChannels`"
            )
        }

        let started = Date()
        let outcome = await AgentChannelEvalHarness.run(
            scenario: exp.scenario,
            provider: exp.provider,
            allowedRoomIds: exp.allowedRoomIds ?? [],
            deniedRoomId: exp.deniedRoomId,
            allowedSenderId: exp.allowedSenderId,
            deniedSenderId: exp.deniedSenderId
        )
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        var notes = ["scenario: \(exp.scenario)"]
        notes.append(contentsOf: outcome.checks)

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: outcome.passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsedMs
        )
    }
}

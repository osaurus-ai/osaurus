//
//  EvalRunnerAgentCreation.swift
//  OsaurusEvalsKit
//
//  Runner for the `agent_creation` domain: the case `query` is the first
//  message in a New Agent chat. The work happens in
//  `AgentCreationEvalHarness` inside OsaurusCore; this maps the case file
//  onto it and the outcome onto a report row with the transcript.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runAgentCreationCase(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.agentCreation, !testCase.query.isEmpty else {
            return Self.errored(
                testCase, label: label, modelId: modelId, note: "missing `expect.agentCreation` or `query`")
        }
        let spec = AgentCreationEvalHarness.Case(
            brief: testCase.query, replies: exp.replies ?? [], maxIterations: exp.maxIterations ?? 10,
            capabilitiesOn: exp.capabilitiesOn ?? [], capabilitiesOff: exp.capabilitiesOff ?? [],
            toolMode: exp.toolMode, maxClarifications: exp.maxClarifications, handEditedName: exp.handEditedName,
            importKinds: exp.importKinds)
        let started = Date()
        let result = await AgentCreationEvalHarness.run(spec, model: modelId)
        let transcript = result.transcript
        var notes = result.outcome.checks
        if let tokens = transcript.completionTokens, tokens > 0, transcript.loopDurationMs > 0 {
            notes.append(
                String(
                    format: "end-to-end tok/s %.1f (completion tokens over loop wall time, tool time included)",
                    Double(tokens) / (transcript.loopDurationMs / 1000)))
        } else {
            notes.append("end-to-end tok/s n/a")
        }
        if let error = transcript.error { notes.append("agent loop error: \(error)") }
        let outcome: EvalCaseOutcome =
            transcript.error != nil ? .errored : (result.outcome.passed ? .passed : .failed)
        let row = EvalCaseReport(
            id: testCase.id, label: label, domain: testCase.domain, query: testCase.query, outcome: outcome,
            notes: notes, modelId: modelId, latencyMs: Date().timeIntervalSince(started) * 1000,
            toolUsage: toolUsageStats(transcript), telemetry: telemetry(from: transcript))
        return persistAgentLoopTranscript(transcript, for: row, query: testCase.query, includeSuccessful: true)
    }
}

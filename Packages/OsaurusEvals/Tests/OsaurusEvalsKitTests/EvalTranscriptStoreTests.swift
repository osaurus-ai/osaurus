//
//  EvalTranscriptStoreTests.swift
//  OsaurusEvalsKitTests
//
//  Token-free coverage for the --transcripts sidecar: the store must keep
//  ONLY failed/errored rows, count what it wrote, round-trip the payload,
//  and map report paths to their sidecar dir. The runner wiring (which
//  transcript fields each domain fills) needs a live model and is proven
//  in the optimization loop instead.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@MainActor
struct EvalTranscriptStoreTests {
    private func makeTranscript(outcome: String, caseId: String = "case-a") -> EvalCaseTranscript {
        EvalCaseTranscript(
            caseId: caseId,
            domain: "agent_loop",
            modelId: "test-model",
            outcome: outcome,
            query: "do the thing",
            systemPrompt: "You are Osaurus.",
            toolSchemaNames: ["fs_read", "shell_run"],
            toolCalls: [
                EvalCaseTranscript.ToolEvent(
                    name: "fs_read",
                    arguments: "{\"path\":\"a.txt\"}",
                    resultPreview: "hello",
                    wasDeduped: false,
                    wasError: false
                )
            ],
            finalText: "done",
            iterations: 2,
            exit: "finalResponse",
            notices: ["budget warning"],
            stepDiagnostics: [
                .init(
                    step: 1,
                    stopReason: "length",
                    contentCharacterCount: 0,
                    reasoningCharacterCount: 128,
                    contentPreview: nil,
                    reasoningPreview: "partial reasoning",
                    sawToolCallProgress: true,
                    pendingToolName: "file_write",
                    toolArgumentCharacters: 9_100,
                    completionTokens: 4_096,
                    decodeThroughputAttribution:
                        "unavailable_tool_call_before_vmlx_info",
                    requestedEnableThinking: false
                )
            ],
            error: nil
        )
    }

    private func withTempStore(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evals-transcripts-\(UUID().uuidString)", isDirectory: true)
        EvalTranscriptStore.configure(directory: dir)
        defer {
            EvalTranscriptStore.configure(directory: nil)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    @Test
    func persistsFailedAndErroredOnly() throws {
        try withTempStore { dir in
            EvalTranscriptStore.persistIfEnabled(makeTranscript(outcome: "passed", caseId: "p"))
            EvalTranscriptStore.persistIfEnabled(makeTranscript(outcome: "skipped", caseId: "s"))
            EvalTranscriptStore.persistIfEnabled(makeTranscript(outcome: "failed", caseId: "f"))
            EvalTranscriptStore.persistIfEnabled(makeTranscript(outcome: "errored", caseId: "e"))

            #expect(EvalTranscriptStore.writtenCount == 2)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(files == ["e.json", "f.json"])
        }
    }

    @Test
    func disabledStoreWritesNothing() {
        EvalTranscriptStore.configure(directory: nil)
        EvalTranscriptStore.persistIfEnabled(makeTranscript(outcome: "failed"))
        #expect(EvalTranscriptStore.writtenCount == 0)
    }

    @Test
    func payloadRoundTrips() throws {
        try withTempStore { dir in
            let original = makeTranscript(outcome: "failed", caseId: "round-trip")
            EvalTranscriptStore.persistIfEnabled(original)

            let data = try Data(contentsOf: dir.appendingPathComponent("round-trip.json"))
            let decoded = try JSONDecoder().decode(EvalCaseTranscript.self, from: data)
            #expect(decoded.caseId == original.caseId)
            #expect(decoded.outcome == "failed")
            #expect(decoded.systemPrompt == original.systemPrompt)
            #expect(decoded.toolCalls.count == 1)
            #expect(decoded.toolCalls[0].name == "fs_read")
            #expect(decoded.toolCalls[0].resultPreview == "hello")
            #expect(decoded.exit == "finalResponse")
            #expect(decoded.notices == ["budget warning"])
            #expect(decoded.stepDiagnostics?.first?.stopReason == "length")
            #expect(decoded.stepDiagnostics?.first?.pendingToolName == "file_write")
            #expect(decoded.stepDiagnostics?.first?.toolArgumentCharacters == 9_100)
            #expect(decoded.stepDiagnostics?.first?.completionTokens == 4_096)
            #expect(decoded.stepDiagnostics?.first?.decodeTokensPerSecond == nil)
            #expect(
                decoded.stepDiagnostics?.first?.decodeThroughputAttribution
                    == "unavailable_tool_call_before_vmlx_info"
            )
            #expect(decoded.stepDiagnostics?.first?.thinkingState == "explicitDisabled")
        }
    }

    @Test
    func legacyStepEventDecodesWithExplicitUnavailableAttribution() throws {
        let legacy = Data(
            #"{"step":1,"stopReason":"tool_calls","contentCharacterCount":0,"reasoningCharacterCount":32,"contentPreview":null,"reasoningPreview":"thinking","sawToolCallProgress":true,"pendingToolName":"file_read","toolArgumentCharacters":48,"completionTokens":null,"requestedEnableThinking":true,"thinkingState":"explicitEnabled"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            EvalCaseTranscript.StepEvent.self,
            from: legacy
        )
        #expect(decoded.decodeTokensPerSecond == nil)
        #expect(decoded.decodeThroughputAttribution == "unavailable_legacy_transcript")
    }

    @Test
    func slashInCaseIdIsSanitized() throws {
        try withTempStore { dir in
            EvalTranscriptStore.persistIfEnabled(
                makeTranscript(outcome: "failed", caseId: "ns/sub-case")
            )
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(files == ["ns-sub-case.json"])
        }
    }

    @Test
    func repeatedFailuresKeepDistinctTrialForensics() throws {
        try withTempStore { dir in
            for ordinal in 1 ... 2 {
                EvalTrialExecutionContext.$current.withValue(
                    EvalTrialIdentity(ordinal: ordinal, total: 2)
                ) {
                    EvalTranscriptStore.persistIfEnabled(makeTranscript(outcome: "failed"))
                }
            }

            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            #expect(files == ["case-a.trial-1.json", "case-a.trial-2.json"])
            let data = try Data(contentsOf: dir.appendingPathComponent(files[1]))
            let decoded = try JSONDecoder().decode(EvalCaseTranscript.self, from: data)
            #expect(decoded.trial == 2)
            #expect(decoded.trialCount == 2)
        }
    }

    @Test
    func sidecarDirectorySitsNextToReport() {
        let sidecar = EvalTranscriptStore.sidecarDirectory(
            forOut: "/tmp/reports/llm-foundation-AgentLoop.json"
        )
        #expect(sidecar.path == "/tmp/reports/llm-foundation-AgentLoop.transcripts")
    }
}

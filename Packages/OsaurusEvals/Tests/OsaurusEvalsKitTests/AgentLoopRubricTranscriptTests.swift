import Foundation
import OsaurusCore
import Testing

@testable import OsaurusEvalsKit

@Suite("Agent-loop rubric evidence retention", .serialized)
@MainActor
struct AgentLoopRubricTranscriptTests {
    @Test(arguments: ["passed", "failed", "errored", "skipped"], ["{}", "{\"rubric\":[]}", "{\"rubric\":[\"answer is grounded\"]}"])
    func actualRunnerPersistenceRetainsAuditableRubricAnswers(outcome: String, expectationJSON: String) throws {
        let expectations = try JSONDecoder().decode(EvalCase.AgentLoopExpectations.self,
            from: Data(expectationJSON.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = EvalTranscriptStore.directory
        EvalTranscriptStore.configure(directory: directory)
        defer {
            EvalTranscriptStore.configure(directory: previous)
            try? FileManager.default.removeItem(at: directory)
        }
        let finalText = String(repeating: "complete original answer ", count: 100)
        let transcript = AgentLoopTranscript(toolCalls: [
            .init(name: "file_read", arguments: #"{"count":"7"}"#, resultPreview: "original result",
                wasDeduped: false, wasError: false, step: 1),
        ], finalText: finalText, iterations: 2, exit: "finalResponse",
            systemPrompt: "original composed system", toolSchemaNames: ["file_read"], error: nil)
        let report = EvalCaseReport(id: "rubric.answer", label: "fixture", domain: "agent_loop",
            outcome: try #require(EvalCaseOutcome(rawValue: outcome)), notes: ["original report"],
            modelId: "injected", latencyMs: 12)
        let returned = EvalRunner.persistAgentLoopTranscript(transcript, for: report,
            query: "original task", expectations: expectations)
        #expect(returned.outcome == report.outcome && returned.notes == report.notes)
        let expected = outcome == "failed" || outcome == "errored"
            || (outcome == "passed" && !(expectations.rubric?.isEmpty ?? true))
        let file = directory.appendingPathComponent("rubric.answer.json")
        #expect(FileManager.default.fileExists(atPath: file.path) == expected)
        #expect(EvalTranscriptStore.writtenCount == (expected ? 1 : 0))
        if expected {
            let stored = try JSONDecoder().decode(EvalCaseTranscript.self, from: Data(contentsOf: file))
            #expect(stored.finalText == finalText && stored.query == "original task")
            #expect(stored.systemPrompt == "original composed system")
            #expect(stored.toolCalls.first?.arguments == #"{"count":"7"}"#)
            #expect(stored.outcome == outcome && stored.exit == "finalResponse")
        }
    }

    @Test func successfulWarmupEvidenceRemainsExplicitlyRetainableWithoutRubric() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = EvalTranscriptStore.directory
        EvalTranscriptStore.configure(directory: directory)
        defer {
            EvalTranscriptStore.configure(directory: previous)
            try? FileManager.default.removeItem(at: directory)
        }
        let transcript = AgentLoopTranscript(toolCalls: [], finalText: "original warmup answer", iterations: 1,
            exit: "finalResponse", systemPrompt: "system", toolSchemaNames: [], error: nil)
        let report = EvalCaseReport(id: "warmup.success", label: "fixture", domain: "agent_loop",
            outcome: .passed, notes: [], modelId: "injected", latencyMs: 1)
        _ = EvalRunner.persistAgentLoopTranscript(transcript, for: report, query: "warmup", includeSuccessful: true)
        let file = directory.appendingPathComponent("warmup.success.json")
        let stored = try JSONDecoder().decode(EvalCaseTranscript.self, from: Data(contentsOf: file))
        #expect(stored.finalText == transcript.finalText && stored.outcome == "passed")
    }

    @Test func rubricRetentionStillRequiresExplicitTranscriptOptIn() throws {
        let previous = EvalTranscriptStore.directory
        EvalTranscriptStore.configure(directory: nil)
        defer { EvalTranscriptStore.configure(directory: previous) }
        let expectations = try JSONDecoder().decode(EvalCase.AgentLoopExpectations.self,
            from: Data(#"{"rubric":["grounded"]}"#.utf8))
        let transcript = AgentLoopTranscript(toolCalls: [], finalText: "original answer", iterations: 1,
            exit: "finalResponse", systemPrompt: "system", toolSchemaNames: [], error: nil)
        let report = EvalCaseReport(id: "rubric.disabled", label: "fixture", domain: "agent_loop",
            outcome: .passed, notes: [], modelId: "injected", latencyMs: 1)
        _ = EvalRunner.persistAgentLoopTranscript(transcript, for: report, query: "task", expectations: expectations)
        #expect(EvalTranscriptStore.writtenCount == 0 && EvalTranscriptStore.directory == nil)
    }
    @Test(arguments: ["passed", "failed", "errored", "skipped"])
    func explicitAllModeRetainsOrdinaryRunnerEvidenceWithoutChangingReports(outcome: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = EvalTranscriptStore.directory
        let previousAll = EvalTranscriptStore.includeSuccessful
        EvalTranscriptStore.configure(directory: directory, includeSuccessful: true)
        defer {
            EvalTranscriptStore.configure(directory: previous, includeSuccessful: previousAll)
            try? FileManager.default.removeItem(at: directory)
        }
        let transcript = AgentLoopTranscript(toolCalls: [
            .init(name: "file_write", arguments: #"{"path":"ledger.txt","content":"001\n"}"#,
                resultPreview: "wrote original bytes", wasDeduped: false, wasError: false, step: 1),
        ], finalText: "original answer", iterations: 2, exit: "finalResponse",
            systemPrompt: "original system", toolSchemaNames: ["file_write"], error: nil)
        let report = EvalCaseReport(id: "ordinary.retention", label: "fixture", domain: "agent_loop",
            outcome: try #require(EvalCaseOutcome(rawValue: outcome)), notes: ["original verdict"],
            modelId: "injected", latencyMs: 1)
        let returned = EvalRunner.persistAgentLoopTranscript(transcript, for: report, query: "original task")
        #expect(returned.outcome == report.outcome && returned.notes == report.notes)
        let file = directory.appendingPathComponent("ordinary.retention.json")
        #expect(FileManager.default.fileExists(atPath: file.path) == (outcome != "skipped"))
        if outcome != "skipped" {
            let stored = try JSONDecoder().decode(EvalCaseTranscript.self, from: Data(contentsOf: file))
            #expect(stored.toolCalls.first?.arguments == transcript.toolCalls.first?.arguments)
            #expect(stored.finalText == transcript.finalText && stored.systemPrompt == transcript.systemPrompt)
        }
    }

    @Test func allModeDoesNotLeakIntoTheNextDefaultSuiteOrDisabledSink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = EvalTranscriptStore.directory
        let previousAll = EvalTranscriptStore.includeSuccessful
        defer {
            EvalTranscriptStore.configure(directory: previous, includeSuccessful: previousAll)
            try? FileManager.default.removeItem(at: directory)
        }
        EvalTranscriptStore.configure(directory: directory, includeSuccessful: true)
        #expect(EvalTranscriptStore.includeSuccessful)
        EvalTranscriptStore.configure(directory: directory)
        #expect(!EvalTranscriptStore.includeSuccessful && EvalTranscriptStore.writtenCount == 0)
        let transcript = AgentLoopTranscript(toolCalls: [], finalText: "answer", iterations: 1,
            exit: "finalResponse", systemPrompt: "system", toolSchemaNames: [], error: nil)
        let report = EvalCaseReport(id: "default.success", label: "fixture", domain: "agent_loop",
            outcome: .passed, notes: [], modelId: "injected", latencyMs: 1)
        _ = EvalRunner.persistAgentLoopTranscript(transcript, for: report, query: "task")
        #expect(EvalTranscriptStore.writtenCount == 0)
        EvalTranscriptStore.configure(directory: nil, includeSuccessful: true)
        #expect(EvalTranscriptStore.directory == nil && !EvalTranscriptStore.includeSuccessful)
    }

}

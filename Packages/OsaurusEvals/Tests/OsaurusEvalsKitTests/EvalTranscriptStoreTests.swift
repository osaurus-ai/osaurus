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
        }
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
    func sidecarDirectorySitsNextToReport() {
        let sidecar = EvalTranscriptStore.sidecarDirectory(
            forOut: "/tmp/reports/llm-foundation-AgentLoop.json"
        )
        #expect(sidecar.path == "/tmp/reports/llm-foundation-AgentLoop.transcripts")
    }
}

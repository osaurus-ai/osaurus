//
//  EvalRunnerChatImport.swift
//  OsaurusEvalsKit
//
//  Runner for the `chat_import_reader` domain: fixture documents go
//  through the import fast paths, the isolated reader, and the verifier
//  (`ChatImportEvalHarness` in OsaurusCore). The row is scored per item
//  and records the reader's tok/s.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runChatImportReaderCase(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.chatImport, !exp.documents.isEmpty || !testCase.query.isEmpty else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `expect.chatImport`")
        }
        let started = Date()
        let model = modelId == "(unset)" ? nil : modelId
        let result = await ChatImportEvalHarness.run(
            documents: exp.documents.map { .init(origin: $0.origin, path: $0.path, text: $0.text) },
            userText: testCase.query,
            expected: exp.items.map { .init(kind: $0.kind, name: $0.name) },
            forbidden: exp.forbidden ?? [],
            model: model)
        var notes = result.checks
        notes.append("score \(result.found)/\(result.expected) items; forbidden hits \(result.forbiddenHits.count)")
        if result.readerRan {
            notes.append("reader model: \(result.readerModel ?? "none")")
            notes.append(
                "reader tok/s "
                    + (result.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "n/a")
                    + " (\(result.completionTokens) completion tokens)")
            if let failure = result.readerFailure { notes.append("reader failure: \(failure)") }
        } else {
            notes.append("reader not needed: the fast paths read every document")
        }
        // Rows from the page-as-skill fallback don't prove the reader.
        let outcome: EvalCaseOutcome =
            if result.readerRan, result.readerFailure != nil {
                result.completionTokens == 0 ? .errored : .failed
            } else {
                result.passed ? .passed : .failed
            }
        return EvalCaseReport(
            id: testCase.id, label: label, domain: testCase.domain, query: testCase.query,
            outcome: outcome, notes: notes, modelId: modelId,
            latencyMs: Date().timeIntervalSince(started) * 1000)
    }
}

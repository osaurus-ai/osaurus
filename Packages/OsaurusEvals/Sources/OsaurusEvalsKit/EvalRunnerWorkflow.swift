//
//  EvalRunnerWorkflow.swift
//  OsaurusEvalsKit
//
//  Runners for the `workflow` and `architect` domains. The work happens in
//  `WorkflowEvalHarness` inside OsaurusCore; these map case files onto it
//  and outcomes onto report rows. A row the model or host cannot run (no
//  native structured output, no JavaScript helper) is a skip with the
//  reason, never a pass.
//

import Foundation
import OsaurusCore

extension EvalRunner {

    static func runWorkflowCase(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.workflow else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `expect.workflow`")
        }
        var definition = exp.definition
        if let name = exp.bundled {
            definition = await WorkflowEvalHarness.bundledDefinition(named: name)
            guard definition != nil else {
                return Self.errored(testCase, label: label, modelId: modelId, note: "no bundled workflow `\(name)`")
            }
        }
        guard let definition else {
            return Self.errored(testCase, label: label, modelId: modelId, note: "missing `definition` or `bundled`")
        }
        let spec = WorkflowEvalHarness.TemplateCase(
            definition: definition, input: exp.input, answers: exp.answers ?? [:],
            expectStatus: exp.status ?? "completed", nodeStatuses: exp.nodeStatuses ?? [:],
            outputKeys: exp.outputKeys ?? [], outputValues: exp.outputValues ?? [:],
            outputContains: exp.outputContains ?? [:], outputExcludes: exp.outputExcludes ?? [:],
            toolResults: exp.toolResults ?? [:], toolArguments: exp.toolArguments ?? [:])
        let started = Date()
        let outcome = await WorkflowEvalHarness.runTemplate(spec, model: modelId)
        return report(testCase, label: label, modelId: modelId, outcome: outcome, started: started)
    }

    static func runArchitectCase(_ testCase: EvalCase, modelId: String) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        let brief = testCase.query
        guard let exp = testCase.expect.architect, !brief.isEmpty || exp.seed?.failingInput != nil else {
            return Self.errored(
                testCase, label: label, modelId: modelId, note: "missing `expect.architect` or `query`")
        }
        var server: EvalFixtureServer?
        var baseURL = ""
        if let api = exp.fixtureAPI {
            do {
                let started = try EvalFixtureServer(api)
                baseURL = try await started.start()
                server = started
            } catch {
                return Self.errored(testCase, label: label, modelId: modelId, note: "fixture API did not start: \(error)")
            }
        }
        defer { server?.stop() }
        var filesDir = ""
        if let files = exp.fixtureFiles, !files.isEmpty {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("architect-eval-files-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, contents) in files {
                    try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
            } catch {
                return Self.errored(testCase, label: label, modelId: modelId, note: "fixture files: \(error)")
            }
            filesDir = dir.path
        }
        defer { if !filesDir.isEmpty { try? FileManager.default.removeItem(atPath: filesDir) } }
        func fill(_ text: String) -> String {
            text.replacingOccurrences(of: "{{fixture.base_url}}", with: baseURL)
                .replacingOccurrences(of: "{{fixture.files_dir}}", with: filesDir)
        }
        func fill(_ value: JSONValue) -> JSONValue {
            (try? JSONDecoder().decode(JSONValue.self, from: Data(fill(value.compactJSONString).utf8))) ?? value
        }
        var structure = WorkflowEvalHarness.ArchitectCase.Structure()
        if let s = exp.structure {
            structure.conditionalEdges = s.conditionalEdges ?? 0
            structure.errorHandling = s.errorHandling ?? false
            structure.retries = s.retries ?? false
            structure.paginate = s.paginate ?? false
            structure.secretAuth = s.secretAuth ?? false
            structure.fileOutput = s.fileOutput ?? false
            structure.minExamples = s.minExamples ?? 0
            structure.examplesTested = s.examplesTested ?? false
            structure.describedInputs = s.describedInputs ?? true
            structure.noAbsolutePaths = s.noAbsolutePaths ?? true
            structure.keepsNodes = s.keepsNodes ?? []
            structure.editsSeed = s.editsSeed ?? false
            structure.declaresFolder = s.declaresFolder ?? false
            structure.folderInput = s.folderInput ?? false
            structure.maxAddedNodes = s.maxAddedNodes
        }
        let spec = WorkflowEvalHarness.ArchitectCase(
            brief: fill(brief), answers: (exp.answers ?? [:]).mapValues(fill), maxIterations: exp.maxIterations ?? 16,
            nodeKinds: exp.nodeKinds ?? [], inputKeys: exp.inputKeys ?? [], outputKeys: exp.outputKeys ?? [],
            requireTestRun: exp.requireTestRun ?? true, requireProposeSave: exp.requireProposeSave ?? true,
            replies: (exp.replies ?? []).map(fill), secrets: exp.secrets ?? [:],
            seed: exp.seed.map {
                .init(name: $0.name, definition: fill($0.definition), failingInput: $0.failingInput.map(fill))
            },
            testOutputKeys: exp.testOutputKeys ?? [], testOutputValues: exp.testOutputValues ?? [:],
            testOutputContains: exp.testOutputContains ?? [:],
            postRuns: (exp.postRuns ?? []).map {
                .init(
                    input: $0.input.map(fill), expectStatus: $0.status ?? "completed", outputKeys: $0.outputKeys ?? [],
                    outputValues: $0.outputValues ?? [:], outputContains: $0.outputContains ?? [:],
                    outputExcludes: $0.outputExcludes ?? [:])
            },
            structure: structure, requiredCalls: exp.requiredCalls ?? [], forbiddenCalls: exp.forbiddenCalls ?? [],
            maxClarifications: exp.maxClarifications, maxQuestions: exp.maxQuestions, maxToolCalls: exp.maxToolCalls,
            maxPromptTokens: exp.maxPromptTokens, needsImageModel: exp.needsImageModel ?? false,
            pickedFolder: filesDir.isEmpty ? nil : filesDir)
        let started = Date()
        let result = await WorkflowEvalHarness.runArchitect(spec, model: modelId)
        var outcome = result.outcome
        let transcript = result.transcript
        if let written = exp.fixtureFilesWritten, !written.isEmpty, outcome.blocked == nil {
            let checks = written.map { path in
                let found = !filesDir.isEmpty
                    && FileManager.default.fileExists(atPath: (filesDir as NSString).appendingPathComponent(path))
                return (found ? "PASS " : "FAIL ") + "wrote \(path) in the picked folder"
            }
            outcome = WorkflowEvalHarness.Outcome(
                passed: outcome.passed && !checks.contains { $0.hasPrefix("FAIL") }, blocked: nil,
                checks: outcome.checks + checks, outputTokens: outcome.outputTokens,
                generationMs: outcome.generationMs)
        }
        if let server, outcome.blocked == nil {
            let counts = server.requestCounts()
            var checks: [String] = []
            for (path, minimum) in (exp.fixtureRequests ?? [:]).sorted(by: { $0.key < $1.key }) {
                let seen = counts[path] ?? 0
                checks.append((seen >= minimum ? "PASS " : "FAIL ") + "fixture \(path): \(seen) request(s) (want ≥ \(minimum))")
            }
            checks.append("INFO fixture requests: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" })")
            outcome = WorkflowEvalHarness.Outcome(
                passed: outcome.passed && !checks.contains { $0.hasPrefix("FAIL") }, blocked: nil,
                checks: outcome.checks + checks, outputTokens: outcome.outputTokens,
                generationMs: outcome.generationMs)
        }
        if let blocked = outcome.blocked {
            let row = EvalCaseReport(
                id: testCase.id, label: label, domain: testCase.domain, query: brief, outcome: .skipped,
                notes: ["BLOCKED: \(blocked)"], modelId: modelId,
                latencyMs: Date().timeIntervalSince(started) * 1000, telemetry: telemetry(from: transcript),
                blocker: EvalBlockerReason(kind: .unsupportedHarness, message: blocked))
            return persistAgentLoopTranscript(transcript, for: row, query: brief, includeSuccessful: true)
        }
        var notes = outcome.checks
        if let tokens = transcript.completionTokens, tokens > 0, transcript.loopDurationMs > 0 {
            notes.append(
                String(
                    format: "end-to-end tok/s %.1f (completion tokens over loop wall time, tool time included)",
                    Double(tokens) / (transcript.loopDurationMs / 1000)))
        }
        let row = EvalCaseReport(
            id: testCase.id, label: label, domain: testCase.domain, query: brief,
            outcome: outcome.passed ? .passed : .failed, notes: notes, modelId: modelId,
            latencyMs: Date().timeIntervalSince(started) * 1000, toolUsage: toolUsageStats(transcript),
            telemetry: telemetry(from: transcript))
        return persistAgentLoopTranscript(transcript, for: row, query: brief, includeSuccessful: true)
    }

    private static func report(
        _ testCase: EvalCase, label: String, modelId: String, outcome: WorkflowEvalHarness.Outcome,
        started: Date
    ) -> EvalCaseReport {
        let elapsed = Date().timeIntervalSince(started) * 1000
        if let blocked = outcome.blocked {
            return EvalCaseReport(
                id: testCase.id, label: label, domain: testCase.domain, query: testCase.query, outcome: .skipped,
                notes: ["BLOCKED: \(blocked)"], modelId: modelId, latencyMs: elapsed,
                blocker: EvalBlockerReason(kind: .unsupportedHarness, message: blocked))
        }
        var notes = outcome.checks
        notes.append(outcome.tokensPerSecond.map { String(format: "inference tok/s %.1f (estimated tokens over node wall time)", $0) } ?? "inference tok/s n/a")
        return EvalCaseReport(
            id: testCase.id, label: label, domain: testCase.domain, query: testCase.query,
            outcome: outcome.passed ? .passed : .failed, notes: notes, modelId: modelId, latencyMs: elapsed,
            telemetry: EvalCaseTelemetry(
                decodeTokensPerSecond: outcome.tokensPerSecond,
                completionTokens: outcome.outputTokens > 0 ? outcome.outputTokens : nil))
    }
}

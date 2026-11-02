import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Activity token provenance", .serialized)
struct ActivityTokenProvenanceTests {
    private func row(for model: String) async throws -> RequestLog {
        // Wait for the actual append/chain operation, not a fixed actor sleep.
        for _ in 0..<200 {
            if let row = InsightsService.shared.logs.first(where: { $0.model == model }), row.seq != nil {
                return row
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("No persisted Insights row for \(model); store error: \(InsightsService.shared.storeError ?? "none")")
        throw CancellationError()
    }

    private func request(model: String, stream: Bool) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model, messages: [ChatMessage(role: "user", content: "fixture request")],
            temperature: nil, max_tokens: 16, stream: stream, top_p: nil,
            frequency_penalty: nil, presence_penalty: nil, stop: nil, n: nil,
            tools: nil, tool_choice: nil, session_id: nil
        )
    }

    @Test func mixedCountsSurviveLoggingStoreWithholdingAndExports() async throws {
        let model = "provenance-mixed-\(UUID().uuidString)"
        InsightsService.logInference(
            source: .chatUI, model: model, inputTokens: 96, outputTokens: 4,
            inputTokenSource: .estimated, outputTokenSource: .reported,
            durationMs: 1000, temperature: nil, maxTokens: 16,
            requestBody: "fixture request", responseBody: "fixture response",
            egress: EgressInfo(details: ["query": "exercise bounded-details copy"])
        )
        let captured = try await row(for: model)
        let store = ActivityLogStore()
        try store.openInMemory()
        let stored = try store.append(captured)
        #expect(try store.verify().isIntact)
        let persisted = try #require(store.fetch(filter: .empty).first)
        #expect(persisted.inputTokenSource == .estimated)
        #expect(persisted.outputTokenSource == .reported)
        for includeContent in [true, false] {
            let data = try ActivityExportService.render(
                logs: [persisted], options: .init(format: .jsonl, includeContent: includeContent),
                filterDescription: "fixture", verification: try store.verify()
            )
            let line = try #require(String(decoding: data, as: UTF8.self).split(separator: "\n").last)
            let decoded = try ActivityLogStore.decoder.decode(RequestLog.self, from: Data(line.utf8))
            #expect(decoded.inputTokenSource == .estimated)
            #expect(decoded.outputTokenSource == .reported)
            #expect(decoded.hash == stored.hash)
            if !includeContent { #expect(RequestLog.isWithheldContent(decoded.requestBody)) }
        }
        let csv = ActivityExportService.renderCSV([persisted])
        let lines = csv.split(separator: "\n")
        let values = try #require(lines.last).split(separator: ",", omittingEmptySubsequences: false)
        #expect(values[ActivityExportService.csvColumns.firstIndex(of: "input_tokens_source")!] == "estimated")
        #expect(values[ActivityExportService.csvColumns.firstIndex(of: "output_tokens_source")!] == "reported")
        #expect(!csv.contains("fixture request"))
        let markdown = try ActivityExportService.render(
            logs: [persisted], options: .init(format: .markdown, includeContent: false),
            filterDescription: "fixture", verification: try store.verify()
        )
        let report = String(decoding: markdown, as: UTF8.self)
        #expect(report.contains(persisted.inputTokenDescription))
        #expect(report.contains(persisted.outputTokenDescription))
        #expect(!report.contains("fixture request"))
    }

    @Test func legacyAndUnobservedSourcesRemainUnknown() async throws {
        let legacy = RequestLog(source: .chatUI, method: "POST", path: "/fixture", statusCode: 200,
            durationMs: 1000, model: "provenance-unknown-\(UUID().uuidString)", inputTokens: 22, outputTokens: 3)
        let bytes = try ActivityLogStore.canonicalEncoder.encode(legacy)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains("inputTokenSource"))
        #expect(!text.contains("outputTokenSource"))
        let decoded = try ActivityLogStore.decoder.decode(RequestLog.self, from: bytes)
        #expect(decoded.inputTokenSource == nil)
        #expect(decoded.outputTokenSource == nil)
        #expect(decoded.withoutContent().inputTokenSource == nil)
        #expect(decoded.inputTokenDescription.contains("Source unknown"))
        let csv = ActivityExportService.renderCSV([legacy])
        #expect(csv.split(separator: "\n").last?.hasSuffix("unknown,unknown") == true)
        InsightsService.shared.log(legacy)
        _ = try await row(for: try #require(legacy.model))
    }

    @Test func reportedZeroIsDistinctFromUnavailableCount() throws {
        let zero = RequestLog(source: .chatUI, method: "POST", path: "/fixture", statusCode: 200,
            durationMs: 1000, inputTokens: 0, outputTokens: nil,
            inputTokenSource: .reported, outputTokenSource: .reported)
        #expect(zero.inputTokenSource == .reported)
        #expect(zero.inputTokenDescription == "0 · Reported")
        #expect(zero.outputTokens == nil)
        #expect(zero.outputTokenSource == nil)
        #expect(zero.outputTokenDescription == "Unknown")
        #expect(zero.tokensPerSecond == nil)
    }

    @Test func streamStatsReportedCountsIncludeZero() async throws {
        let model = "provenance-reported-zero-\(UUID().uuidString)"
        let service = FakeModelService(supportedModel: model, deltas: [
            StreamingStatsHint.encode(tokenCount: 0, tokensPerSecond: 0, stopReason: "stop", inputTokenCount: 0)
        ])
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        let stream = try await engine.streamChat(request: request(model: model, stream: true))
        for try await _ in stream {}
        let captured = try await row(for: model)
        #expect(captured.inputTokens == 0)
        #expect(captured.outputTokens == 0)
        #expect(captured.inputTokenSource == .reported)
        #expect(captured.outputTokenSource == .reported)
    }

    @Test func streamWithoutStatsDoesNotPersistBudgetEstimates() async throws {
        let model = "provenance-unavailable-\(UUID().uuidString)"
        let service = FakeModelService(supportedModel: model, deltas: ["fixture response"])
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        let stream = try await engine.streamResponses(
            request: ResponsesInferenceRequest(chatCompletion: request(model: model, stream: true)))
        for try await _ in stream {}
        let captured = try await row(for: model)
        #expect(captured.inputTokens == nil)
        #expect(captured.outputTokens == nil)
        #expect(captured.inputTokenSource == nil)
        #expect(captured.outputTokenSource == nil)
    }

    @Test func compatibilityNonStreamPreservesMixedSources() async throws {
        let model = "provenance-nonstream-\(UUID().uuidString)"
        let service = FakeModelService(supportedModel: model, deltas: ["fixture response",
            StreamingStatsHint.encode(tokenCount: 4, tokensPerSecond: 8, stopReason: "stop")])
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        _ = try await engine.completeChat(request: request(model: model, stream: false))
        let captured = try await row(for: model)
        #expect(captured.inputTokenSource == .estimated)
        #expect(captured.outputTokenSource == .reported)
        #expect(captured.outputTokens == 4)
    }

    @Test func compatibilityFallbackIncludesReasoningAndIsEstimated() async throws {
        let model = "provenance-estimated-\(UUID().uuidString)"
        let reasoning = "fixture reasoning that is returned separately"
        let service = FakeModelService(supportedModel: model,
            deltas: [StreamingReasoningHint.encode(reasoning), "answer"])
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        let response = try await engine.completeChat(request: request(model: model, stream: false))
        let captured = try await row(for: model)
        #expect(captured.inputTokenSource == .estimated)
        #expect(captured.outputTokenSource == .estimated)
        #expect(captured.outputTokens == TokenEstimator.estimate("answer" + reasoning))
        #expect(response.usage.completion_tokens == captured.outputTokens)
        #expect(captured.requestRateDescription?.contains("Estimated") == true)
    }

    private struct OneShotProbe: ModelService {
        let id: String
        let fail: Bool
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?) async throws -> String {
            if fail { throw NSError(domain: "TokenProvenanceFixture", code: 1) }
            return "fixture response"
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]) async throws -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(StreamingInputTokenHint.encode(9))
                continuation.finish(throwing: NSError(domain: "TokenProvenanceFixture", code: 2))
            }
        }
    }

    @Test func streamErrorRetainsObservedInputWithoutInventingOutput() async throws {
        let probe = OneShotProbe(id: "provenance-partial-\(UUID().uuidString)", fail: true)
        let engine = ChatEngine(services: [probe], installedModelsProvider: { [] }, source: .chatUI)
        let stream = try await engine.streamChat(request: request(model: probe.id, stream: true))
        do {
            for try await _ in stream {}
            Issue.record("Expected the fixture's stream failure")
        } catch {}
        let captured = try await row(for: probe.id)
        #expect(captured.inputTokens == 9)
        #expect(captured.inputTokenSource == .reported)
        #expect(captured.outputTokens == nil)
        #expect(captured.outputTokenSource == nil)
        #expect(captured.isError)
    }

    @Test(arguments: [false, true])
    func internalOneShotEstimatesAndFailureRemainDistinct(fail: Bool) async throws {
        let probe = OneShotProbe(id: "provenance-internal-\(UUID().uuidString)", fail: fail)
        let service = CoreModelService(localServices: [probe])
        do {
            _ = try await service.generate(prompt: "fixture request", timeout: 5, modelOverride: probe.id)
            #expect(!fail)
        } catch {
            #expect(fail)
        }
        let captured = try await row(for: probe.id)
        #expect(captured.inputTokenSource == .estimated)
        #expect(captured.outputTokenSource == (fail ? nil : .estimated))
        #expect((captured.outputTokens == nil) == fail)
        #expect(captured.isError == fail)
    }

    @Test func inboundLoggingBridgePreservesProducerSources() async throws {
        let model = "provenance-http-\(UUID().uuidString)"
        InsightsService.logAsync(method: "POST", path: "/completions", responseStatus: 200,
            durationMs: 1000, model: model, tokensInput: 12, tokensOutput: 2,
            inputTokenSource: .reported, outputTokenSource: .estimated)
        let captured = try await row(for: model)
        #expect(captured.inputTokenSource == .reported)
        #expect(captured.outputTokenSource == .estimated)
    }
}

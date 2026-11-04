import Combine
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Requested output-limit Insights provenance", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct GenerationLimitInsightsTests {
    enum Route: CaseIterable {
        case responses, legacyStream, complete, singleTool, multipleTools
    }

    private actor Capture {
        var parameters: GenerationParameters?
        func record(_ value: GenerationParameters) { parameters = value }
    }

    private struct FixtureService: ModelService {
        let model: String
        let route: Route
        let capture: Capture
        var id: String { model }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == model }
        func streamDeltas(
            messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]
        ) async throws -> AsyncThrowingStream<String, Error> {
            await capture.record(parameters)
            return AsyncThrowingStream { continuation in
                continuation.yield("fixture answer")
                continuation.finish()
            }
        }
        func generateOneShot(
            messages: [ChatMessage], parameters: GenerationParameters, requestedModel: String?
        ) async throws -> String {
            await capture.record(parameters)
            let tool = ServiceToolInvocation(toolName: "fixture", jsonArguments: "{}")
            if route == .singleTool { throw tool }
            if route == .multipleTools { throw ServiceToolInvocations(invocations: [tool, tool]) }
            return "fixture answer"
        }
    }

    private func loggedRow(model: String) async throws -> RequestLog {
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        let observer = InsightsService.shared.$hasLogs.sink { _ in continuation.yield(()) }
        defer { observer.cancel(); continuation.finish() }
        for await _ in changes {
            if let row = InsightsService.shared.logs.first(where: { $0.model == model }) { return row }
        }
        throw CancellationError()
    }

    @Test(arguments: Route.allCases, [nil, 16_384, 1_048_576] as [Int?])
    func logsOnlyRequestedLimits(route: Route, requestedLimit: Int?) async throws {
        let model = "limit-provenance-\(UUID().uuidString)"
        let capture = Capture()
        let service = FixtureService(model: model, route: route, capture: capture)
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, source: .chatUI)
        if route == .responses {
            var request = ResponsesInferenceRequest(
                model: model, input: [ChatMessage(role: "user", content: "fixture")])
            request.generation.maxOutputTokens = requestedLimit
            request.context.turnId = UUID()
            let stream = try await engine.streamResponses(request: request)
            for try await _ in stream {}
        } else {
            var request = ChatCompletionRequest(
                model: model, messages: [ChatMessage(role: "user", content: "fixture")],
                max_tokens: requestedLimit, stream: route == .legacyStream,
                n: nil, tools: nil, tool_choice: nil)
            request.turnId = UUID()
            if route == .legacyStream {
                let stream = try await engine.streamChat(request: request)
                for try await _ in stream {}
            } else {
                _ = try await engine.completeChat(request: request)
            }
        }
        let row = try await loggedRow(model: model)
        if let requestedLimit {
            let loggedLimit = try #require(row.maxTokens)
            #expect(loggedLimit == requestedLimit)
        } else {
            #expect(row.maxTokens == nil, "An inherited limit must not be logged as the 16K dispatch placeholder")
        }
        let parameters = try #require(await capture.parameters)
        #expect(parameters.maxTokens == (requestedLimit ?? 16_384))
        #expect(parameters.maxTokensExplicit == (requestedLimit != nil))
    }
}

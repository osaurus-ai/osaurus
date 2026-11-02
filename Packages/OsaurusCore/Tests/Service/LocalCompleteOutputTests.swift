import Foundation
import Testing

@testable import OsaurusCore

struct LocalCompleteOutputTests {
    private func stream(_ chunks: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    @Test func reasoningOnlyAtLengthLimitIsTruncated() async {
        let chunks = [
            "\u{FFFE}reasoning:still planning the summary",
            StreamingStatsHint.encode(
                tokenCount: 1024, tokensPerSecond: 28.7,
                unclosedReasoning: true, stopReason: "length"),
        ]
        await #expect(throws: MLXService.OneShotError.outputTruncated) {
            try await MLXService.collectOneShot(
                stream(chunks),
                parameters: GenerationParameters(temperature: nil, maxTokens: 1024, requireCompleteOutput: true))
        }
    }

    @Test func partialVisibleSummaryIsAlsoRejected() async {
        await #expect(throws: MLXService.OneShotError.outputTruncated) {
            try await MLXService.collectOneShot(
                stream(["partial summary", StreamingStatsHint.encode(
                    tokenCount: 1024, tokensPerSecond: 29, stopReason: "length")]),
                parameters: GenerationParameters(temperature: nil, maxTokens: 1024, requireCompleteOutput: true))
        }
    }

    @Test func completeSummaryOmitsReasoningAndStats() async throws {
        let text = try await MLXService.collectOneShot(
            stream(["\u{FFFE}reasoning:private reasoning", "Finished ", "summary.",
                StreamingStatsHint.encode(tokenCount: 12, tokensPerSecond: 30, stopReason: "stop")]),
            parameters: GenerationParameters(temperature: nil, maxTokens: 1024, requireCompleteOutput: true))
        #expect(text == "Finished summary.")
    }

    @Test func ordinaryOneShotKeepsExistingLengthBehavior() async throws {
        let text = try await MLXService.collectOneShot(
            stream(["text", StreamingStatsHint.encode(
                tokenCount: 10, tokensPerSecond: 20, stopReason: "length")]),
            parameters: GenerationParameters(temperature: nil, maxTokens: 10))
        #expect(text == "text")
    }

    @Test func upstreamGPUErrorIsPreserved() async {
        enum Failure: Error { case gpu }
        let failed = AsyncThrowingStream<String, Error> { $0.finish(throwing: Failure.gpu) }
        await #expect(throws: Failure.gpu) {
            try await MLXService.collectOneShot(
                failed, parameters: GenerationParameters(temperature: nil, maxTokens: 1024, requireCompleteOutput: true))
        }
    }

    @Test func errorAfterStatsTakesPrecedence() async {
        enum Failure: Error { case gpu }
        let failed = AsyncThrowingStream<String, Error> {
            $0.yield(StreamingStatsHint.encode(
                tokenCount: 0, tokensPerSecond: 0, stopReason: "cancelled"))
            $0.finish(throwing: Failure.gpu)
        }
        await #expect(throws: Failure.gpu) {
            try await MLXService.collectOneShot(
                failed, parameters: GenerationParameters(
                    temperature: nil, maxTokens: 1024, requireCompleteOutput: true))
        }
    }

    @Test func cancelledSummaryIsNotReturnedAsComplete() async {
        await #expect(throws: CancellationError.self) {
            try await MLXService.collectOneShot(
                stream(["unfinished", StreamingStatsHint.encode(
                    tokenCount: 1, tokensPerSecond: 20, stopReason: "cancelled")]),
                parameters: GenerationParameters(
                    temperature: nil, maxTokens: 1024, requireCompleteOutput: true))
        }
    }
}

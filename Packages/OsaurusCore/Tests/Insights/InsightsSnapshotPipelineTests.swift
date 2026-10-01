import Combine
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Insights snapshot pipeline")
struct InsightsSnapshotPipelineTests {
    private func fixtures() -> [RequestLog] {
        [
            RequestLog(source: .httpAPI, method: "GET", path: "/v1/models", statusCode: 200, durationMs: 10),
            RequestLog(
                source: .chatUI, method: "CHAT", path: "/v1/chat/completions", statusCode: 200,
                durationMs: 1000, requestBody: "raw-wire-only", model: "local/Raptor",
                inputTokens: 50, outputTokens: 20
            ),
            RequestLog(
                source: .plugin, method: "POST", path: "/plugin/inspect", statusCode: 500,
                durationMs: 30, pluginId: "plugin-demo"
            ),
            RequestLog(
                source: .p2p, method: "POST", path: "/v1/chat/completions", statusCode: 200,
                durationMs: 2000, model: "peer/Other", inputTokens: 70, outputTokens: 40
            ),
            RequestLog(
                source: .httpAPI, method: "POST", path: "/v1/chat/completions", statusCode: 429,
                durationMs: 0, model: "cloud/Other", inputTokens: 10, outputTokens: 10
            ),
        ]
    }

    private func input(
        _ logs: [RequestLog], search: String = "", source: SourceFilter = .all,
        method: MethodFilter = .all, revision: UInt64 = 1, total: Int? = nil
    ) -> InsightsService.SnapshotInput {
        .init(
            logs: logs, totalCount: total ?? logs.count, search: search, source: source,
            method: method, revision: revision
        )
    }

    private func awaitCount(_ service: InsightsService, _ total: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while service.totalRequestCount != total && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.totalRequestCount == total)
    }

    @Test func statsPreserveUnfilteredTotalsAndMissingSpeedSemantics() {
        let result = InsightsService.computeSnapshot(input(fixtures(), source: .plugin, total: 900))
        #expect(result.filtered.count == 1)
        #expect(result.totalCount == 900)
        #expect(result.stats.totalRequests == 5)
        #expect(result.stats.successRate == 60)
        #expect(result.stats.errorCount == 2)
        #expect(result.stats.averageDurationMs == 608)
        #expect(result.stats.inferenceCount == 3)
        #expect(result.stats.totalInputTokens == 130)
        #expect(result.stats.totalOutputTokens == 70)
        #expect(result.stats.averageSpeed == 20)
        let empty = InsightsService.computeSnapshot(input([]))
        #expect(empty.stats == .empty)
        #expect(empty.filtered.isEmpty)
        #expect(!empty.hasLogs)
    }

    @Test func preservesAllSourceAndMethodCombinationsAndSearchFields() {
        let logs = fixtures()
        // Rows are All, Chat, HTTP, Plugin, P2P; columns All, GET, POST.
        let expected = [[5, 1, 3], [1, 0, 0], [2, 1, 1], [1, 0, 1], [1, 0, 1]]
        for (s, source) in SourceFilter.allCases.enumerated() {
            for (m, method) in MethodFilter.allCases.enumerated() {
                let result = InsightsService.computeSnapshot(input(logs, source: source, method: method))
                #expect(result.filtered.count == expected[s][m])
            }
        }
        for (search, index) in [("Raptor", 1), ("plugin-demo", 2), ("inspect", 2)] {
            let result = InsightsService.computeSnapshot(input(logs, search: search))
            #expect(result.filtered.map(\.id) == [logs[index].id])
        }
        #expect(InsightsService.computeSnapshot(input(logs, search: "raw-wire-only")).filtered.isEmpty)
    }

    nonisolated private static func computeWithThreadCheck(
        _ snapshot: InsightsService.SnapshotInput
    ) -> (Bool, InsightsService.SnapshotResult) {
        (Thread.isMainThread, InsightsService.computeSnapshot(snapshot))
    }

    @Test func transformCanRunOffMainActor() async {
        let snapshot = input(fixtures())
        let (wasMain, result) = await Task.detached {
            Self.computeWithThreadCheck(snapshot)
        }.value
        #expect(!wasMain)
        #expect(result.stats.totalRequests == 5)
    }

    @Test func queuedSnapshotCannotUndoClear() {
        let queue = DispatchQueue(label: "insights.clear.test")
        queue.suspend()
        defer { queue.resume() }
        let service = InsightsService(computeQueue: queue)
        let logs = fixtures()
        for log in logs { service.log(log) }
        let stale = InsightsService.computeSnapshot(input(logs, revision: service.snapshotRevision))
        service.clear()
        service.applySnapshot(stale)
        #expect(service.logs.isEmpty)
        #expect(service.filteredLogs.isEmpty)
        #expect(service.stats == .empty)
        #expect(service.totalRequestCount == 0)
        #expect(!service.hasLogs)
    }

    @Test func filterEditRejectsEarlierResultAndPublishesCurrentFilter() async throws {
        let queue = DispatchQueue(label: "insights.filter.test")
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        let service = InsightsService(computeQueue: queue)
        let logs = fixtures()
        for log in logs { service.log(log) }
        let stale = InsightsService.computeSnapshot(input(logs, revision: service.snapshotRevision))
        service.sourceFilter = .plugin
        service.applySnapshot(stale)
        #expect(service.filteredLogs.isEmpty)
        queue.resume()
        suspended = false
        try await awaitCount(service, 5)
        #expect(service.filteredLogs.map(\.id) == [logs[2].id])
        #expect(service.stats.totalRequests == 5)
    }

    @Test func burstRetainsNewest500AndPublishesOnMain() async throws {
        let service = InsightsService(computeQueue: DispatchQueue(label: "insights.burst.test"))
        var publicationsWereMain = true
        let subscription = service.$totalRequestCount.sink { _ in
            publicationsWereMain = publicationsWereMain && Thread.isMainThread
        }
        defer { subscription.cancel() }
        for i in 0..<505 {
            service.log(
                RequestLog(
                    source: .httpAPI, method: "GET", path: "/fixture/\(i)", statusCode: 200,
                    durationMs: 10, responseBody: String(repeating: "x", count: 262_144)
                )
            )
        }
        try await awaitCount(service, 505)
        #expect(publicationsWereMain)
        #expect(service.logs.count == 500)
        #expect(service.filteredLogs.count == 500)
        #expect(service.filteredLogs.first?.path == "/fixture/504")
        #expect(service.filteredLogs.last?.path == "/fixture/5")
        #expect(service.stats.totalRequests == 500)
        #expect(service.stats.successRate == 100)
    }
}

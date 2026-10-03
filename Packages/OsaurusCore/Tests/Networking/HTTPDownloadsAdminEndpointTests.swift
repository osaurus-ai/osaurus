//
//  HTTPDownloadsAdminEndpointTests.swift
//  OsaurusCoreTests
//
//  Coverage for `/admin/downloads` (read-only model download status) and
//  `/admin/downloads/cancel`. `/admin/config/apply` starts downloads as
//  fire-and-forget tasks; these routes let a local client see their
//  progress and stop them. The shaping helper is tested directly, and the
//  routes are exercised against a real loopback NIO server seeded through
//  the shared `ModelDownloadService` state the app UI already renders.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct HTTPDownloadsAdminEndpointTests {

    // MARK: - Shaping

    @Test func shaping_listsOnlyActivePausedAndFailedDownloads() throws {
        let states: [String: DownloadState] = [
            "org/downloading": .downloading(progress: 0.25),
            "org/paused": .paused(progress: 0.5),
            "org/failed": .failed(error: "disk full"),
            "org/completed": .completed,
            "org/not-started": .notStarted,
        ]
        let shaped = HTTPHandler.downloadsJSONObject(states: states, metrics: [:], model: nil)
        let rows = try #require(shaped["downloads"] as? [[String: Any]])
        #expect(rows.map { $0["id"] as? String } == ["org/downloading", "org/failed", "org/paused"])
    }

    @Test func shaping_reportsBytesProgressAndError() throws {
        let states: [String: DownloadState] = [
            "org/downloading": .downloading(progress: 0.42),
            "org/failed": .failed(error: "disk full"),
        ]
        let metrics: [String: ModelDownloadService.DownloadMetrics] = [
            "org/downloading": ModelDownloadService.DownloadMetrics(
                bytesReceived: 4_200_000,
                totalBytes: 10_000_000,
                bytesPerSecond: 1_500_000,
                etaSeconds: 3.8
            )
        ]
        let shaped = HTTPHandler.downloadsJSONObject(states: states, metrics: metrics, model: nil)
        let rows = try #require(shaped["downloads"] as? [[String: Any]])

        let active = try #require(rows.first { $0["id"] as? String == "org/downloading" })
        #expect(active["state"] as? String == "downloading")
        #expect(active["progress"] as? Double == 0.42)
        #expect(active["bytes_received"] as? Int64 == 4_200_000)
        #expect(active["total_bytes"] as? Int64 == 10_000_000)
        #expect(active["bytes_per_second"] as? Double == 1_500_000)
        #expect(active["eta_seconds"] as? Double == 3.8)
        #expect(active["error"] is NSNull)

        let failed = try #require(rows.first { $0["id"] as? String == "org/failed" })
        #expect(failed["state"] as? String == "failed")
        #expect(failed["error"] as? String == "disk full")
        #expect(failed["bytes_received"] is NSNull)
        #expect(failed["total_bytes"] is NSNull)
    }

    @Test func shaping_modelFilterReturnsAnyStateCaseInsensitively() throws {
        let states: [String: DownloadState] = [
            "Org/Completed": .completed,
            "org/downloading": .downloading(progress: 0.1),
        ]
        let shaped = HTTPHandler.downloadsJSONObject(states: states, metrics: [:], model: "org/completed")
        let rows = try #require(shaped["downloads"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == "Org/Completed")
        #expect(rows.first?["state"] as? String == "completed")
        #expect(rows.first?["progress"] as? Double == 1.0)

        let unknown = HTTPHandler.downloadsJSONObject(states: states, metrics: [:], model: "org/unknown")
        #expect((unknown["downloads"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func shaping_modelFilterPrefersExactKeyOverCaseVariant() throws {
        let states: [String: DownloadState] = [
            "Org/Model": .completed,
            "org/model": .downloading(progress: 0.5),
        ]
        let shaped = HTTPHandler.downloadsJSONObject(states: states, metrics: [:], model: "org/model")
        let rows = try #require(shaped["downloads"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == "org/model")
        #expect(rows.first?["state"] as? String == "downloading")
    }

    // MARK: - Routes

    @Test func list_returnsSeededInFlightDownload() async throws {
        let modelId = "mlx-test/downloads-list-\(UUID().uuidString)"
        let metrics = ModelDownloadService.DownloadMetrics(
            bytesReceived: 300,
            totalBytes: 1_000,
            bytesPerSecond: nil,
            etaSeconds: nil
        )
        try await withSeededDownload(modelId, .downloading(progress: 0.3), metrics: metrics) {
            try await assertListReportsSeededDownload(modelId)
        }
    }

    private func assertListReportsSeededDownload(_ modelId: String) async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/admin/downloads")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["downloads"] as? [[String: Any]])
        let row = try #require(rows.first { $0["id"] as? String == modelId })
        #expect(row["state"] as? String == "downloading")
        #expect(row["progress"] as? Double == 0.3)
        #expect(row["bytes_received"] as? Int == 300)
        #expect(row["total_bytes"] as? Int == 1_000)
    }

    @Test func list_modelQueryReportsCompletedDownload() async throws {
        let modelId = "mlx-test/downloads-done-\(UUID().uuidString)"
        try await withSeededDownload(modelId, .completed) {
            try await assertModelQueryReportsCompleted(modelId)
        }
    }

    private func assertModelQueryReportsCompleted(_ modelId: String) async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        let encoded = try #require(modelId.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://\(server.host):\(server.port)/admin/downloads?model=\(encoded)")!
        )
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["downloads"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows.first?["id"] as? String == modelId)
        #expect(rows.first?["state"] as? String == "completed")
    }

    @Test func cancel_stopsInFlightDownload() async throws {
        let modelId = "mlx-test/downloads-cancel-\(UUID().uuidString)"
        try await withSeededDownload(modelId, .downloading(progress: 0.6)) {
            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            let (data, resp) = try await postCancel(model: modelId, server: server)
            #expect((resp as? HTTPURLResponse)?.statusCode == 200)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["status"] as? String == "cancelled")
            #expect(object["model"] as? String == modelId)

            let state = await MainActor.run { ModelManager.shared.downloadStates[modelId] }
            #expect(state == .notStarted)
        }
    }

    @Test func cancel_rejectsNonJSONContentType() async throws {
        let modelId = "mlx-test/downloads-form-\(UUID().uuidString)"
        try await withSeededDownload(modelId, .downloading(progress: 0.2)) {
            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            var request = URLRequest(
                url: URL(string: "http://\(server.host):\(server.port)/admin/downloads/cancel")!
            )
            request.httpMethod = "POST"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelId])
            let (_, resp) = try await URLSession.shared.data(for: request)
            #expect((resp as? HTTPURLResponse)?.statusCode == 415)

            let state = await MainActor.run { ModelManager.shared.downloadStates[modelId] }
            #expect(state == .downloading(progress: 0.2))
        }
    }

    @Test func cancel_refusesDownloadThatIsNotRunning() async throws {
        let modelId = "mlx-test/downloads-installed-\(UUID().uuidString)"
        try await withSeededDownload(modelId, .completed) {
            let server = try await startServer()
            defer { Task { await server.shutdown() } }

            let (_, resp) = try await postCancel(model: modelId, server: server)
            #expect((resp as? HTTPURLResponse)?.statusCode == 409)
            let state = await MainActor.run { ModelManager.shared.downloadStates[modelId] }
            #expect(state == .completed)

            let unknownId = "mlx-test/never-seen-\(UUID().uuidString)"
            let (_, unknown) = try await postCancel(model: unknownId, server: server)
            #expect((unknown as? HTTPURLResponse)?.statusCode == 404)
        }
    }

    @Test func cancel_requiresModel() async throws {
        let server = try await startServer()
        defer { Task { await server.shutdown() } }

        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/admin/downloads/cancel")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (_, resp) = try await URLSession.shared.data(for: request)
        #expect((resp as? HTTPURLResponse)?.statusCode == 400)
    }

    // MARK: - Helpers

    /// Seeds one entry in the shared download service, runs `body`, and
    /// removes the entry before returning (or rethrowing), so no seeded
    /// row outlives the test.
    private func withSeededDownload(
        _ modelId: String,
        _ state: DownloadState,
        metrics: ModelDownloadService.DownloadMetrics? = nil,
        _ body: () async throws -> Void
    ) async throws {
        await MainActor.run {
            ModelManager.shared.downloadService.downloadStates[modelId] = state
            ModelManager.shared.downloadService.downloadMetrics[modelId] = metrics
        }
        do {
            try await body()
        } catch {
            await clearSeededDownload(modelId)
            throw error
        }
        await clearSeededDownload(modelId)
    }

    private func clearSeededDownload(_ modelId: String) async {
        await MainActor.run {
            ModelManager.shared.downloadService.downloadStates[modelId] = nil
            ModelManager.shared.downloadService.downloadMetrics[modelId] = nil
        }
    }

    private func postCancel(model: String, server: TestServer) async throws -> (Data, URLResponse) {
        var request = URLRequest(
            url: URL(string: "http://\(server.host):\(server.port)/admin/downloads/cancel")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        return try await URLSession.shared.data(for: request)
    }

    private struct TestServer {
        let group: MultiThreadedEventLoopGroup
        let channel: Channel
        let lease: HTTPServerTestLease
        let host: String
        let port: Int

        func shutdown() async {
            _ = try? await channel.close()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { _ in cont.resume() }
            }
            await lease.release()
        }
    }

    private func startServer() async throws -> TestServer {
        let config = ServerConfiguration.default
        let lease = await HTTPServerTestLock.shared.acquire()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(
                            HTTPHandler(
                                configuration: config,
                                apiKeyValidator: .empty,
                                eventLoop: channel.eventLoop,
                                trustLoopback: true
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)

            let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            let port = ch.localAddress?.port ?? 0
            return TestServer(group: group, channel: ch, lease: lease, host: "127.0.0.1", port: port)
        } catch {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { _ in cont.resume() }
            }
            await lease.release()
            throw error
        }
    }
}

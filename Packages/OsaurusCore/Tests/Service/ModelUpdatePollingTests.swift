import Foundation
import Testing

@testable import OsaurusCore

struct ModelUpdatePollingTests {
    @Test func cancellationNeverBecomesAnUnavailableOrCurrentSnapshot() async throws {
        let service = HuggingFaceService(metadataRequest: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) {
            _ = try await service.fetchModelManifest(repoId: "OsaurusAI/model")
        }
    }

    @Test func authorizationFailureRemainsAnError() async throws {
        let service = HuggingFaceService(metadataRequest: { request in
            let url = try #require(request.url)
            return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: DirectDownloader.HTTPStatusError.self) {
            _ = try await service.fetchModelManifest(repoId: "OsaurusAI/model")
        }
    }

    @Test func changedRemoteRevisionFetchesNewMetadata() async throws {
        let revision = String(repeating: "b", count: 40)
        let prior = HuggingFaceService.ManifestSnapshot(revision: String(repeating: "a", count: 40), manifest: nil)
        let service = HuggingFaceService(metadataRequest: { request in
            let url = try #require(request.url)
            let body: String
            if url.path == "/api/models/OsaurusAI/model/revision/main" {
                body = "{\"sha\":\"\(revision)\"}"
            } else {
                #expect(url.path == "/OsaurusAI/model/resolve/\(revision)/osaurus.json")
                body = #"{"required_osaurus_version":"0.25.0","model_version":"2"}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await service.fetchModelManifest(repoId: "OsaurusAI/model", previous: prior)
        #expect(result.revision == revision)
        #expect(result.manifest?.modelVersion == "2")
    }

    @Test func immutableRemoteRevisionReusesThePriorManifest() async throws {
        let revision = String(repeating: "a", count: 40)
        let prior = HuggingFaceService.ManifestSnapshot(
            revision: revision,
            manifest: ModelManifest(requiredOsaurusVersion: "0.25.0", modelVersion: "1")
        )
        let service = HuggingFaceService(metadataRequest: { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/models/OsaurusAI/model/revision/main")
            return (
                Data("{\"sha\":\"\(revision)\"}".utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        })
        let result = try await service.fetchModelManifest(repoId: "OsaurusAI/model", previous: prior)
        #expect(result.manifest?.modelVersion == "1")
        #expect(result.revision == revision)
    }

    @Test @MainActor func concurrentTriggersShareTheActiveSweep() async {
        let sweep = ModelUpdateSweep()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let joined = AsyncStream<Void>.makeStream()
        var calls = 0
        let first = Task {
            await sweep.run {
                calls += 1
                entered.continuation.yield(())
                for await _ in release.stream {}
            }
        }
        for await _ in entered.stream { break }
        let second = Task {
            joined.continuation.yield(())
            await sweep.run { calls += 1 }
        }
        for await _ in joined.stream { break }
        release.continuation.finish()
        await first.value
        await second.value
        #expect(calls == 1)
        await sweep.run { calls += 1 }
        #expect(calls == 2)
    }

    @Test @MainActor func optOutCancelsAndDrainsAnActiveSweep() async {
        let sweep = ModelUpdateSweep()
        let entered = AsyncStream<Void>.makeStream()
        var cancelled = false
        let pending = Task {
            await sweep.run {
                entered.continuation.yield(())
                do { try await Task.sleep(for: .seconds(60)) } catch is CancellationError { cancelled = true } catch {
                    Issue.record(error)
                }
            }
        }
        for await _ in entered.stream { break }
        sweep.cancel()
        await pending.value
        #expect(cancelled)
        var subsequent = false
        await sweep.run { subsequent = true }
        #expect(subsequent)
    }

    @Test func successfulChecksRemainDueAcrossPersistenceAndCaseChanges() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var schedule = ModelUpdatePollingSchedule()
        #expect(schedule.isDue("OsaurusAI/model", at: now))
        schedule.record("OsaurusAI/model", at: now, succeeded: true)
        let restored = try JSONDecoder().decode(
            ModelUpdatePollingSchedule.self,
            from: JSONEncoder().encode(schedule)
        )
        #expect(!restored.isDue("osaurusai/MODEL", at: now.addingTimeInterval(21599)))
        #expect(restored.isDue("osaurusai/model", at: now.addingTimeInterval(21600)))
        // A long suspension becomes one due check, not one check per missed tick.
        #expect(restored.isDue("osaurusai/model", at: now.addingTimeInterval(86400)))
    }

    @Test func failuresBackOffWithoutClaimingSuccessAndRecoveryResetsFailures() {
        var schedule = ModelUpdatePollingSchedule()
        var now = Date(timeIntervalSince1970: 1000)
        for delay in [TimeInterval(900), 1800, 3600, 7200, 14400, 21600, 21600] {
            schedule.record("OsaurusAI/model", at: now, succeeded: false)
            #expect(!schedule.isDue("OsaurusAI/model", at: now.addingTimeInterval(delay - 1)))
            now.addTimeInterval(delay)
            #expect(schedule.isDue("OsaurusAI/model", at: now))
        }
        schedule.record("OsaurusAI/model", at: now, succeeded: true)
        #expect(schedule.attempts["osaurusai/model"]?.failures == 0)
        now.addTimeInterval(21600)
        schedule.record("OsaurusAI/model", at: now, succeeded: false)
        #expect(schedule.attempts["osaurusai/model"]?.nextCheck == now.addingTimeInterval(900))
    }

    @Test func repositoriesHaveIndependentSchedules() {
        let now = Date(timeIntervalSince1970: 1000)
        var schedule = ModelUpdatePollingSchedule()
        schedule.record("OsaurusAI/first", at: now, succeeded: true)
        #expect(schedule.isDue("OsaurusAI/second", at: now))
        #expect(!schedule.isDue("OsaurusAI/first", at: now))
    }
}

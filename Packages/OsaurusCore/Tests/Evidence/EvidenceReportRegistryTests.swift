//
//  EvidenceReportRegistryTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Evidence report registry")
struct EvidenceReportRegistryTests {
    @Test
    func registersMultipleReportKindsThroughOneRegistry() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let evalArtifact = try fixture.writeArtifact(named: "evals/summary.json")
        let runtimeArtifact = try fixture.writeArtifact(named: "runtime/live-proof.json")

        service.register([
            EvidenceReportDescriptor(
                kind: .eval,
                source: "evals-pr-evidence",
                artifactURL: evalArtifact,
                status: .passed,
                counts: EvidenceReportCounts(total: 3, passed: 3)
            ),
            EvidenceReportDescriptor(
                kind: .runtime,
                source: "live-app-smoke",
                artifactURL: runtimeArtifact,
                status: .partial,
                counts: EvidenceReportCounts(total: 4, passed: 3, warnings: 1)
            ),
        ])

        let all = service.list()
        #expect(all.count == 2)
        #expect(Set(all.map(\.kind)) == [.eval, .runtime])
        #expect(service.list(EvidenceReportFilter(kinds: [.eval])).map(\.kind) == [.eval])
        #expect(service.list(EvidenceReportFilter(sources: ["live-app-smoke"])).map(\.kind) == [.runtime])
        #expect(service.list(EvidenceReportFilter(statuses: [.partial])).map(\.source) == ["live-app-smoke"])
        #expect(service.list(EvidenceReportFilter(artifactAvailability: [.available])).count == 2)
        #expect(all.allSatisfy { $0.artifact.availability == .available })
    }

    @Test
    func dedupesDuplicateDescriptorsByStableIdentity() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let artifact = try fixture.writeArtifact(named: "benchmarks/report.json")
        let descriptor = EvidenceReportDescriptor(
            kind: .benchmark,
            source: "benchmark-suite",
            artifactURL: artifact,
            status: .failed,
            counts: EvidenceReportCounts(total: 2, passed: 1, failed: 1)
        )

        service.register([descriptor, descriptor])
        service.register(descriptor)

        let reports = service.list()
        #expect(reports.count == 1)
        #expect(reports[0].status == .failed)
        #expect(reports[0].counts.failed == 1)
    }

    @Test
    func missingArtifactsBecomeUnavailableRows() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let missingPath = fixture.root
            .appendingPathComponent("missing/run-trace.json")
            .path

        service.register(
            EvidenceReportDescriptor(
                kind: .runTrace,
                source: "agent-run-trace",
                artifactPath: missingPath,
                status: .passed,
                counts: EvidenceReportCounts(total: 1, passed: 1)
            )
        )

        let report = try #require(service.list().first)
        #expect(report.kind == .runTrace)
        #expect(report.status == .unavailable)
        #expect(report.artifact.availability == .unavailable)
        #expect(report.artifact.message?.contains("not present") == true)
        #expect(report.counts.passed == 0)
        #expect(report.counts.skipped == 1)
    }

    @Test
    func missingArtifactsPreserveExplicitFailureStatuses() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)

        service.register([
            EvidenceReportDescriptor(
                kind: .runtime,
                source: "runtime-live-proof",
                artifactPath: fixture.root.appendingPathComponent("missing/failed.json").path,
                status: .failed,
                counts: EvidenceReportCounts(total: 1, failed: 1)
            ),
            EvidenceReportDescriptor(
                kind: .runtime,
                source: "runtime-live-proof",
                artifactPath: fixture.root.appendingPathComponent("missing/error.json").path,
                status: .error,
                counts: EvidenceReportCounts(total: 1, errored: 1)
            ),
        ])

        let reports = service.list()
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.artifact.availability == .unavailable })
        #expect(Set(reports.map(\.status)) == [.failed, .error])
    }

    @Test
    func sameIDReregistrationRefreshesDeletedArtifactAndFailureTruth() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let artifact = try fixture.writeArtifact(named: "runtime/refresh.json")
        let reportID = "runtime-refresh"

        let available = service.register(
            EvidenceReportDescriptor(
                id: reportID,
                kind: .runtime,
                source: "runtime-live-proof",
                artifactURL: artifact,
                status: .passed,
                counts: EvidenceReportCounts(total: 1, passed: 1)
            )
        )
        #expect(available.status == .passed)
        #expect(available.artifact.availability == .available)

        try FileManager.default.removeItem(at: artifact)
        let unavailable = service.register(
            EvidenceReportDescriptor(
                id: reportID,
                kind: .runtime,
                source: "runtime-live-proof",
                artifactURL: artifact,
                status: .passed,
                counts: EvidenceReportCounts(
                    total: 3,
                    passed: 1,
                    blocked: 1,
                    warnings: 1
                )
            )
        )
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.artifact.availability == .unavailable)
        #expect(unavailable.counts == EvidenceReportCounts(total: 3, skipped: 3))
        #expect(unavailable.generation > available.generation)

        let failed = service.register(
            EvidenceReportDescriptor(
                id: reportID,
                kind: .runtime,
                source: "runtime-live-proof",
                artifactURL: artifact,
                status: .failed,
                counts: EvidenceReportCounts(total: 1, failed: 1)
            )
        )
        #expect(failed.status == .failed)
        #expect(failed.artifact.availability == .unavailable)
        #expect(service.list() == [failed])
    }

    @Test
    func missingArtifactsPreserveBlockedAndPartialTruth() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)

        service.register([
            EvidenceReportDescriptor(
                id: "blocked-proof",
                kind: .runtime,
                source: "runtime-live-proof",
                artifactPath: fixture.root.appendingPathComponent("missing/blocked.json").path,
                status: .blocked,
                counts: EvidenceReportCounts(total: 1, blocked: 1)
            ),
            EvidenceReportDescriptor(
                id: "partial-proof",
                kind: .runtime,
                source: "runtime-live-proof",
                artifactPath: fixture.root.appendingPathComponent("missing/partial.json").path,
                status: .partial,
                counts: EvidenceReportCounts(total: 2, passed: 1, warnings: 1)
            ),
        ])

        let reports = service.list()
        let blocked = try #require(reports.first { $0.id == "blocked-proof" })
        let partial = try #require(reports.first { $0.id == "partial-proof" })
        #expect(blocked.status == .blocked)
        #expect(blocked.counts == EvidenceReportCounts(total: 1, blocked: 1))
        #expect(partial.status == .partial)
        #expect(partial.counts == EvidenceReportCounts(total: 2, passed: 1, warnings: 1))
        #expect(reports.allSatisfy { $0.artifact.availability == .unavailable })
    }

    @Test
    func producerReconciliationRevealsCollidingUnrelatedReportAfterRemoval() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let unrelatedArtifact = try fixture.writeArtifact(named: "unrelated/report.json")
        let producerArtifact = try fixture.writeArtifact(named: "producer/report.json")

        service.register(
            EvidenceReportDescriptor(
                id: "shared-id",
                kind: .provider,
                source: "unrelated",
                artifactURL: unrelatedArtifact,
                status: .failed,
                counts: EvidenceReportCounts(total: 1, failed: 1)
            )
        )
        service.reconcile(
            producer: "model-library-evidence",
            descriptors: [
                EvidenceReportDescriptor(
                    id: "shared-id",
                    kind: .runtime,
                    source: "model-library",
                    artifactURL: producerArtifact,
                    status: .passed,
                    counts: EvidenceReportCounts(total: 1, passed: 1)
                ),
            ]
        )

        #expect(service.list().first?.source == "model-library")
        #expect(service.list(producer: "model-library-evidence").count == 1)

        service.reconcile(producer: "model-library-evidence", descriptors: [])

        #expect(service.list().first?.source == "unrelated")
        #expect(service.list().first?.status == .failed)
        #expect(service.list(producer: "model-library-evidence").isEmpty)
    }

    @Test
    func reportIdentityAndSerializedArtifactLocatorDoNotExposeLocalPaths() throws {
        let firstFixture = try RegistryFixture()
        let secondFixture = try RegistryFixture()
        let firstArtifact = try firstFixture.writeArtifact(named: "proof/report.json")
        let secondArtifact = try secondFixture.writeArtifact(named: "proof/report.json")
        let firstService = EvidenceReportRegistryService(now: firstFixture.clock)
        let secondService = EvidenceReportRegistryService(now: secondFixture.clock)
        let first = firstService.register(
            EvidenceReportDescriptor(
                kind: .runtime,
                source: "runtime-proof",
                artifactURL: firstArtifact,
                status: .passed
            )
        )
        let second = secondService.register(
            EvidenceReportDescriptor(
                kind: .runtime,
                source: "runtime-proof",
                artifactURL: secondArtifact,
                status: .passed
            )
        )
        let sanitizedExplicitID = firstService.register(
            EvidenceReportDescriptor(
                id: "runtime-proof|\(firstArtifact.path)",
                kind: .runtime,
                source: "runtime-proof",
                artifactURL: firstArtifact,
                status: .passed
            )
        )

        #expect(first.id == second.id)
        #expect(sanitizedExplicitID.id == first.id)
        #expect(first.artifact.path == second.artifact.path)
        #expect(!first.id.contains(firstFixture.root.path))
        #expect(!first.artifact.path.contains(firstFixture.root.path))
        #expect(!first.artifact.path.hasPrefix("/"))
        #expect(firstService.localArtifactURL(forReportID: first.id) == firstArtifact.standardizedFileURL)

        let encoded = String(decoding: try first.stableJSONData(), as: UTF8.self)
        #expect(!encoded.contains(firstFixture.root.path))
        #expect(!encoded.contains(secondFixture.root.path))
    }

    @Test
    func legacySnapshotDecodingIsTolerantAndReencodingIsPrivacySafe() throws {
        let fixture = try RegistryFixture()
        let artifact = try fixture.writeArtifact(named: "legacy/summary.json")
        let legacyJSON = """
            {
              "reports": [{
                "id": "legacy-report",
                "kind": "eval",
                "source": "legacy-evals",
                "artifact": {
                  "path": "\(artifact.path)",
                  "availability": "available"
                },
                "status": "passed",
                "counts": {"total": 1, "passed": 1, "failed": 0, "errored": 0, "skipped": 0, "blocked": 0, "warnings": 0},
                "registeredAt": "2025-06-15T15:06:40Z"
              }]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(
            EvidenceReportRegistrySnapshot.self,
            from: Data(legacyJSON.utf8)
        )
        let report = try #require(snapshot.reports.first)

        #expect(snapshot.schemaVersion == 1)
        #expect(report.generation == 0)
        #expect(report.artifact.path != artifact.path)
        #expect(report.artifact.resolvedURL(relativeTo: fixture.root) == artifact.standardizedFileURL)
        #expect(!String(decoding: try snapshot.stableJSONData(), as: UTF8.self).contains(fixture.root.path))
    }

    @Test
    func concurrentRegistrationsRemainConsistent() async throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let artifact = try fixture.writeArtifact(named: "concurrent/report.json")

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    service.register(
                        EvidenceReportDescriptor(
                            id: "concurrent-\(index)",
                            kind: .runtime,
                            source: "concurrency-test",
                            artifactURL: artifact,
                            status: .passed
                        )
                    )
                }
            }
        }

        #expect(service.list().count == 50)
        #expect(Set(service.list().map(\.generation)).count == 50)
    }

    @Test
    func descriptorErrorsBecomeErrorRows() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let path = fixture.root.appendingPathComponent("provider/report.json").path

        service.register(
            EvidenceReportDescriptor(
                kind: .provider,
                source: "provider-connectivity",
                artifactPath: path,
                status: .passed,
                artifactError: "Descriptor could not parse summary counts."
            )
        )

        let report = try #require(service.list().first)
        #expect(report.status == .error)
        #expect(report.artifact.availability == .error)
        #expect(report.artifact.message == "Descriptor could not parse summary counts.")
    }

    @Test
    func redactsSecretsFromMetadata() throws {
        let fixture = try RegistryFixture()
        let service = EvidenceReportRegistryService(now: fixture.clock)
        let artifact = try fixture.writeArtifact(named: "provider/report.json")

        service.register(
            EvidenceReportDescriptor(
                kind: .provider,
                source: "provider-connectivity",
                artifactURL: artifact,
                status: .passed,
                metadata: [
                    "api_key": "sk-secret-value",
                    "authorization": "Bearer secret-token",
                    "model": "qwen3-8b",
                    "tokens_per_second": "44.2",
                    "url": "https://example.test/callback?token=secret",
                ]
            )
        )

        let report = try #require(service.list().first)
        #expect(report.metadata["api_key"] == "<redacted>")
        #expect(report.metadata["authorization"] == "<redacted>")
        #expect(report.metadata["url"] == "<redacted>")
        #expect(report.metadata["model"] == "qwen3-8b")
        #expect(report.metadata["tokens_per_second"] == "44.2")
    }

    @Test
    func stableJSONEncodingSortsKeysAndUsesISO8601Dates() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let summary = EvidenceReportSummary(
            id: "report-1",
            kind: .liveProof,
            source: "live-proof",
            artifact: EvidenceReportArtifact(path: "/tmp/live.json", availability: .available),
            status: .passed,
            counts: EvidenceReportCounts(total: 1, passed: 1),
            startedAt: date,
            completedAt: date,
            registeredAt: date,
            metadata: ["z": "last", "a": "first"]
        )

        let first = try summary.stableJSONData()
        let second = try summary.stableJSONData()
        let body = String(decoding: first, as: UTF8.self)

        #expect(first == second)
        #expect(body.hasPrefix("{\"artifact\""))
        #expect(body.contains("\"completedAt\":\"2025-06-15T15:06:40Z\""))
        #expect(!body.contains("/tmp/live.json"))
        #expect(
            body.range(of: "\"a\":\"first\"")?.lowerBound ?? body.endIndex
                < body.range(of: "\"z\":\"last\"")?.lowerBound ?? body.startIndex
        )
    }
}

private struct RegistryFixture {
    let root: URL
    let currentDate = Date(timeIntervalSince1970: 1_750_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func clock() -> Date {
        currentDate
    }

    func writeArtifact(named relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"ok\":true}".utf8).write(to: url)
        return url
    }
}

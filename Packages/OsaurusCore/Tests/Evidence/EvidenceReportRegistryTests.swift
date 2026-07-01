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

//
//  ModelLibraryEvidenceServiceTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Model library evidence service")
struct ModelLibraryEvidenceServiceTests {
    @Test
    func registersSupportedPartialUnsupportedAndUnprovenRowsThroughRegistry() throws {
        let fixture = try ModelEvidenceFixture()
        let supported = try fixture.model(id: "org/supported", config: #"{"model_type":"qwen3"}"#)
        let partial = try fixture.model(id: "org/partial", config: #"{"model_type":"dflash"}"#)
        let unsupported = try fixture.model(id: "org/unsupported", config: #"{"model_type":"longcat_next"}"#)
        let unproven = MLXModel(
            id: "org/not-local",
            name: "Not Local",
            description: "",
            downloadURL: "",
            rootDirectory: fixture.root
        )

        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )
        let snapshot = service.registerEvidence(for: [supported, partial, unsupported, unproven])

        #expect(Set(snapshot.rows.map(\.supportState)) == [.supported, .partial, .unsupported, .unproven])

        let compatibility = snapshot.reports.filter { $0.kind == .modelCompatibility }
        #expect(compatibility.count == 4)
        #expect(report(for: supported.id, in: compatibility)?.status == .passed)
        #expect(report(for: partial.id, in: compatibility)?.status == .partial)
        #expect(report(for: unsupported.id, in: compatibility)?.status == .failed)
        #expect(report(for: unproven.id, in: compatibility)?.status == .unavailable)
        #expect(
            report(for: unproven.id, in: compatibility)?.metadata["support_state"] == "unproven"
        )
    }

    @Test
    func incompleteAndExternalCacheCandidatesAreGroupedAndHiddenByDefault() throws {
        let fixture = try ModelEvidenceFixture()
        let ready = try fixture.model(id: "org/ready", config: #"{"model_type":"qwen3"}"#)
        let incomplete = try fixture.model(
            id: "org/incomplete",
            config: #"{"model_type":"qwen3"}"#,
            weights: false
        )
        let externalURL = try fixture.writeBundle(
            relativePath: "external/cache-model",
            config: #"{"model_type":"qwen3"}"#
        )
        let external = MLXModel(
            id: "org/external",
            name: "External",
            description: "",
            downloadURL: "",
            bundleDirectory: externalURL,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )

        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )
        let snapshot = service.registerEvidence(for: [ready, incomplete, external])

        #expect(snapshot.rows.first { $0.modelId == incomplete.id }?.groupKind == .incomplete)
        #expect(snapshot.rows.first { $0.modelId == external.id }?.groupKind == .externalCache)
        #expect(snapshot.visibleRows.map(\.modelId) == [ready.id])
        #expect(snapshot.groups.contains(ModelEvidenceGroup(kind: .incomplete, count: 1, visibleByDefault: false)))
        #expect(snapshot.groups.contains(ModelEvidenceGroup(kind: .externalCache, count: 1, visibleByDefault: false)))

        let expanded = service.registerEvidence(
            for: [ready, incomplete, external],
            filter: ModelEvidenceFilter(
                includeIncomplete: true,
                includeExternalCacheCandidates: true
            )
        )
        #expect(Set(expanded.visibleRows.map(\.modelId)) == [ready.id, incomplete.id, external.id])
    }

    @Test
    func proofArtifactsRegisterAsCacheBenchmarkAndRuntimeEvidence() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/proven", config: #"{"model_type":"qwen3"}"#)
        let cacheArtifact = try fixture.writeArtifact(named: "proof/cache.json")
        let benchmarkArtifact = try fixture.writeArtifact(named: "proof/benchmark.json")
        let missingRuntime = fixture.root.appendingPathComponent("proof/runtime.json").path

        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )
        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .cache,
                    artifactPath: cacheArtifact.path,
                    status: .passed,
                    counts: EvidenceReportCounts(total: 1, passed: 1)
                ),
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .benchmark,
                    artifactPath: benchmarkArtifact.path,
                    status: .partial,
                    counts: EvidenceReportCounts(total: 2, passed: 1, warnings: 1)
                ),
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    source: "custom-live-proof",
                    artifactPath: missingRuntime,
                    status: .passed
                ),
            ]
        )

        let row = try #require(snapshot.rows.first)
        #expect(row.proofReportIDs.count == 3)
        #expect(snapshot.reports.contains { $0.kind == .cache && $0.source == "model-library-cache-proof" })
        #expect(snapshot.reports.contains { $0.kind == .benchmark && $0.status == .partial })
        #expect(snapshot.reports.contains { $0.kind == .runtime && $0.source == "custom-live-proof" && $0.status == .unavailable })
    }

    @Test
    func registryMetadataAndRowsDoNotExposeFullBundlePaths() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/redacted", config: #"{"model_type":"qwen3"}"#)
        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )

        let snapshot = service.registerEvidence(for: [model])
        let row = try #require(snapshot.rows.first)
        let cacheReport = try #require(snapshot.report(id: row.cacheReportID))

        #expect(row.redactedBundlePath == ".../redacted")
        #expect(row.redactedBundlePath?.contains(fixture.root.path) == false)
        #expect(row.metadata.values.allSatisfy { !$0.contains(fixture.root.path) })
        #expect(cacheReport.metadata["bundle_path"] == "<redacted>")
        #expect(cacheReport.metadata.values.allSatisfy { !$0.contains(fixture.root.path) })
    }

    private func report(
        for modelId: String,
        in reports: [EvidenceReportSummary]
    ) -> EvidenceReportSummary? {
        reports.first { $0.metadata["model_id"] == modelId }
    }
}

private struct ModelEvidenceFixture {
    let root: URL
    let currentDate = Date(timeIntervalSince1970: 1_750_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-model-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func clock() -> Date {
        currentDate
    }

    func model(
        id: String,
        config: String,
        tokenizer: Bool = true,
        weights: Bool = true
    ) throws -> MLXModel {
        try writeBundle(relativePath: id, config: config, tokenizer: tokenizer, weights: weights)
        return MLXModel(
            id: id,
            name: id.split(separator: "/").last.map(String.init) ?? id,
            description: "",
            downloadURL: "",
            rootDirectory: root
        )
    }

    @discardableResult
    func writeBundle(
        relativePath: String,
        config: String,
        tokenizer: Bool = true,
        weights: Bool = true
    ) throws -> URL {
        let directory = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        if tokenizer {
            try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        }
        if weights {
            try Data("w".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        }
        return directory
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

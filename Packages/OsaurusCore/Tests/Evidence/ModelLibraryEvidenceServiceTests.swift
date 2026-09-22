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
        let snapshot = service.registerEvidence(
            for: [supported, partial, unsupported, unproven],
            proofDescriptors: try fixture.completeProofDescriptors(for: supported.id)
        )

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
    func localPreflightPassWithoutProofStaysUnproven() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/preflight-only", config: #"{"model_type":"qwen3"}"#)

        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )
        let snapshot = service.registerEvidence(for: [model])
        let row = try #require(snapshot.rows.first)
        let compatibility = try #require(snapshot.report(id: row.compatibilityReportID))

        #expect(row.supportState == .unproven)
        #expect(compatibility.status == .passed)
        #expect(row.requirements.first { $0.kind == .runtimeGeneration }?.state == .missing)
        #expect(row.requirements.first { $0.kind == .tokenRate }?.state == .missing)
        #expect(row.requirements.first { $0.kind == .memoryFootprint }?.state == .missing)
    }

    @Test
    func externalBundleWithFullProofsStaysPartialWhilePreflightIsMissing() throws {
        let fixture = try ModelEvidenceFixture()
        let externalURL = try fixture.writeBundle(
            relativePath: "external/full-proofs",
            config: #"{"model_type":"qwen3"}"#
        )
        let model = MLXModel(
            id: "org/external-full-proofs",
            name: "External Full Proofs",
            description: "",
            downloadURL: "",
            bundleDirectory: externalURL,
            externalSource: ExternalModelLocator.Source.huggingFaceCache.rawValue
        )
        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )

        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: try fixture.completeProofDescriptors(for: model.id)
        )
        let row = try #require(snapshot.rows.first)
        let preflight = try #require(
            row.requirements.first { $0.kind == .compatibilityPreflight }
        )

        #expect(row.supportState == .partial)
        #expect(row.supportState != .supported)
        #expect(preflight.state == .missing)
        #expect(
            row.requirements
                .filter { $0.kind != .compatibilityPreflight }
                .allSatisfy { $0.state == .passed }
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
    func recreatedServiceReconcilesRemovedModelsAndPreservesOtherProducers() throws {
        let fixture = try ModelEvidenceFixture()
        let retained = try fixture.model(id: "org/retained", config: #"{"model_type":"qwen3"}"#)
        let removed = try fixture.model(id: "org/removed", config: #"{"model_type":"qwen3"}"#)
        let unrelatedArtifact = try fixture.writeArtifact(named: "other/report.json")
        let registry = EvidenceReportRegistryService(now: fixture.clock)
        registry.register(
            EvidenceReportDescriptor(
                id: "unrelated-report",
                kind: .provider,
                source: "independent-producer",
                artifactURL: unrelatedArtifact,
                status: .passed
            )
        )
        let firstService = ModelLibraryEvidenceService(registry: registry)

        let first = firstService.registerEvidence(
            for: [retained, removed],
            proofDescriptors: try fixture.completeProofDescriptors(for: removed.id)
        )
        let removedRow = try #require(first.rows.first { $0.modelId == removed.id })
        let removedReportIDs = Set(
            [removedRow.cacheReportID, removedRow.compatibilityReportID]
                + removedRow.proofReportIDs
        )

        let recreatedService = ModelLibraryEvidenceService(registry: registry)
        let second = recreatedService.registerEvidence(for: [retained])
        let remainingReportIDs = Set(second.reports.map(\.id))

        #expect(removedRow.proofReportIDs.count == 3)
        #expect(removedReportIDs.isDisjoint(with: remainingReportIDs))
        #expect(!second.reports.contains { $0.id == "unrelated-report" })
        #expect(!recreatedService.snapshot().reports.contains { $0.id == "unrelated-report" })
        #expect(registry.list().contains { $0.id == "unrelated-report" })
    }

    @Test
    func laterScanRemovesProofReportsNoLongerSuppliedForRetainedModel() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/proof-removed", config: #"{"model_type":"qwen3"}"#)
        let registry = EvidenceReportRegistryService(now: fixture.clock)
        let service = ModelLibraryEvidenceService(registry: registry)

        let first = service.registerEvidence(
            for: [model],
            proofDescriptors: try fixture.completeProofDescriptors(for: model.id)
        )
        let firstRow = try #require(first.rows.first)
        let removedProofIDs = Set(firstRow.proofReportIDs)

        let second = service.registerEvidence(for: [model])
        let secondRow = try #require(second.rows.first)
        let remainingReportIDs = Set(second.reports.map(\.id))

        #expect(removedProofIDs.count == 3)
        #expect(secondRow.proofReportIDs.isEmpty)
        #expect(secondRow.supportState == .unproven)
        #expect(removedProofIDs.isDisjoint(with: remainingReportIDs))
        #expect(remainingReportIDs.contains(secondRow.cacheReportID))
        #expect(remainingReportIDs.contains(secondRow.compatibilityReportID))
        #expect(registry.list().map(\.id).allSatisfy { !removedProofIDs.contains($0) })
    }

    @Test
    func proofArtifactsRegisterAsCacheBenchmarkAndRuntimeEvidence() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/proven", config: #"{"model_type":"qwen3"}"#)
        let cacheArtifact = try fixture.writeArtifact(named: "proof/cache.json")
        let benchmarkArtifact = try fixture.writeArtifact(named: "proof/benchmark.json")
        let evalArtifact = try fixture.writeArtifact(named: "proof/eval.json")
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
                    counts: EvidenceReportCounts(total: 2, passed: 1, warnings: 1),
                    metadata: ["tokens_per_second": "12.5"]
                ),
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .eval,
                    artifactPath: evalArtifact.path,
                    status: .passed,
                    counts: EvidenceReportCounts(total: 3, passed: 3)
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
        #expect(row.proofReportIDs.count == 4)
        #expect(snapshot.reports.contains { $0.kind == .cache && $0.source == "model-library-cache-proof" })
        #expect(snapshot.reports.contains { $0.kind == .benchmark && $0.status == .partial })
        #expect(snapshot.reports.contains { $0.kind == .eval && $0.status == .passed })
        #expect(snapshot.reports.contains { $0.kind == .runtime && $0.source == "custom-live-proof" && $0.status == .unavailable })
    }

    @Test
    func missingTokenRateBlocksPassedGenerationProofAndKeepsRowPartial() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/no-token-rate", config: #"{"model_type":"qwen3"}"#)
        let runtimeArtifact = try fixture.writeArtifact(named: "proof/runtime-no-tps.json")

        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )
        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    artifactPath: runtimeArtifact.path,
                    status: .passed,
                    counts: EvidenceReportCounts(total: 1, passed: 1),
                    metadata: ["physical_footprint_within_limit": "true"]
                ),
            ]
        )

        let row = try #require(snapshot.rows.first)
        let runtimeReport = try #require(snapshot.reports.first { $0.kind == .runtime })

        #expect(row.supportState == .partial)
        #expect(runtimeReport.status == .blocked)
        #expect(runtimeReport.counts.passed == 0)
        #expect(runtimeReport.counts.blocked == 1)
        #expect(runtimeReport.metadata["evidence_validation"] == "passing generation proof must record token/s")
        #expect(row.requirements.first { $0.kind == .tokenRate }?.state == .blocked)
    }

    @Test
    func passingRuntimeWithoutMemoryProofDoesNotPassMemoryRequirement() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/runtime-without-memory", config: #"{"model_type":"qwen3"}"#)
        let runtimeArtifact = try fixture.writeArtifact(named: "proof/runtime-without-memory.json")
        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )

        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    artifactPath: runtimeArtifact.path,
                    status: .passed,
                    counts: EvidenceReportCounts(total: 1, passed: 1),
                    metadata: ["tokens_per_second": "17.2"]
                ),
            ]
        )
        let row = try #require(snapshot.rows.first)
        let runtimeReport = try #require(snapshot.reports.first { $0.kind == .runtime })

        #expect(row.supportState == .partial)
        #expect(runtimeReport.status == .passed)
        #expect(row.requirements.first { $0.kind == .runtimeGeneration }?.state == .passed)
        #expect(row.requirements.first { $0.kind == .tokenRate }?.state == .passed)
        #expect(row.requirements.first { $0.kind == .memoryFootprint }?.state == .blocked)
    }

    @Test
    func failedMemoryProofOverridesBarePassingRuntimeForMemoryRequirement() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/mixed-memory-proof", config: #"{"model_type":"qwen3"}"#)
        let runtimeArtifact = try fixture.writeArtifact(named: "proof/mixed-runtime.json")
        let memoryArtifact = try fixture.writeArtifact(named: "proof/mixed-memory.json")
        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )

        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    artifactPath: runtimeArtifact.path,
                    status: .passed,
                    counts: EvidenceReportCounts(total: 1, passed: 1),
                    metadata: ["tokens_per_second": "15.8"]
                ),
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .memory,
                    artifactPath: memoryArtifact.path,
                    status: .failed,
                    counts: EvidenceReportCounts(total: 1, failed: 1),
                    metadata: ["physical_footprint_within_limit": "false"]
                ),
            ]
        )
        let row = try #require(snapshot.rows.first)

        #expect(row.supportState == .unsupported)
        #expect(row.requirements.first { $0.kind == .runtimeGeneration }?.state == .passed)
        #expect(row.requirements.first { $0.kind == .memoryFootprint }?.state == .failed)
    }

    @Test
    func explicitOverLimitPhysicalFootprintFailsProofAndSupportRow() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/over-memory-limit", config: #"{"model_type":"qwen3"}"#)
        let runtimeArtifact = try fixture.writeArtifact(named: "proof/runtime-over-limit.json")
        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )

        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    artifactPath: runtimeArtifact.path,
                    status: .passed,
                    counts: EvidenceReportCounts(total: 1, passed: 1),
                    metadata: [
                        "tokens_per_second": "18.4",
                        "physical_footprint_within_limit": "false",
                    ]
                ),
            ]
        )
        let row = try #require(snapshot.rows.first)
        let runtimeReport = try #require(snapshot.reports.first { $0.kind == .runtime })

        #expect(row.supportState == .unsupported)
        #expect(runtimeReport.status == .failed)
        #expect(runtimeReport.counts.passed == 0)
        #expect(runtimeReport.counts.failed == 1)
        #expect(
            runtimeReport.metadata["evidence_validation"]
                == "physical footprint exceeded the intended limit"
        )
        #expect(row.requirements.first { $0.kind == .memoryFootprint }?.state == .failed)
    }

    @Test
    func failedProofOverridesPartialAndUnprovenPreflightStates() throws {
        let fixture = try ModelEvidenceFixture()
        let partial = try fixture.model(id: "org/partial-proof-failed", config: #"{"model_type":"dflash"}"#)
        let notLocal = MLXModel(
            id: "org/not-local-proof-failed",
            name: "Not Local Proof Failed",
            description: "",
            downloadURL: "",
            rootDirectory: fixture.root
        )
        let partialArtifact = try fixture.writeArtifact(named: "proof/partial-failed.json")
        let notLocalArtifact = try fixture.writeArtifact(named: "proof/not-local-failed.json")

        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )
        let snapshot = service.registerEvidence(
            for: [partial, notLocal],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: partial.id,
                    kind: .runtime,
                    artifactPath: partialArtifact.path,
                    status: .failed
                ),
                ModelEvidenceProofDescriptor(
                    modelId: notLocal.id,
                    kind: .runtime,
                    artifactPath: notLocalArtifact.path,
                    status: .failed
                ),
            ]
        )

        #expect(snapshot.rows.first { $0.modelId == partial.id }?.supportState == .unsupported)
        #expect(snapshot.rows.first { $0.modelId == notLocal.id }?.supportState == .unsupported)
        #expect(snapshot.reports.filter { $0.kind == .runtime }.allSatisfy { $0.status == .failed })
    }

    @Test
    func missingFailedOrErroredProofArtifactStillMarksRowUnsupported() throws {
        let fixture = try ModelEvidenceFixture()
        let failed = try fixture.model(id: "org/missing-failed-proof", config: #"{"model_type":"qwen3"}"#)
        let errored = try fixture.model(id: "org/missing-error-proof", config: #"{"model_type":"qwen3"}"#)

        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )
        let snapshot = service.registerEvidence(
            for: [failed, errored],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: failed.id,
                    kind: .runtime,
                    artifactPath: fixture.root.appendingPathComponent("proof/missing-failed.json").path,
                    status: .failed
                ),
                ModelEvidenceProofDescriptor(
                    modelId: errored.id,
                    kind: .runtime,
                    artifactPath: fixture.root.appendingPathComponent("proof/missing-error.json").path,
                    status: .error
                ),
            ]
        )

        #expect(snapshot.rows.first { $0.modelId == failed.id }?.supportState == .unsupported)
        #expect(snapshot.rows.first { $0.modelId == errored.id }?.supportState == .unsupported)
        #expect(
            snapshot.reports
                .first {
                    $0.metadata["model_id"] == failed.id
                        && $0.metadata["evidence_role"] == "runtime_proof"
                }?
                .status == .failed
        )
        #expect(
            snapshot.reports
                .first {
                    $0.metadata["model_id"] == errored.id
                        && $0.metadata["evidence_role"] == "runtime_proof"
                }?
                .status == .error
        )
    }

    @Test
    func missingBlockedAndPartialProofArtifactsPreserveIncompleteTruth() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/missing-incomplete-proofs", config: #"{"model_type":"qwen3"}"#)
        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )

        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    artifactPath: fixture.root.appendingPathComponent("proof/missing-blocked.json").path,
                    status: .blocked,
                    counts: EvidenceReportCounts(total: 1, blocked: 1)
                ),
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .benchmark,
                    artifactPath: fixture.root.appendingPathComponent("proof/missing-partial.json").path,
                    status: .partial,
                    counts: EvidenceReportCounts(total: 2, passed: 1, warnings: 1)
                ),
            ]
        )
        let row = try #require(snapshot.rows.first)
        let runtime = try #require(snapshot.reports.first { $0.kind == .runtime })
        let benchmark = try #require(snapshot.reports.first { $0.kind == .benchmark })

        #expect(row.supportState == .partial)
        #expect(runtime.status == .blocked)
        #expect(runtime.counts == EvidenceReportCounts(total: 1, blocked: 1))
        #expect(runtime.artifact.availability == .unavailable)
        #expect(benchmark.status == .partial)
        #expect(benchmark.counts == EvidenceReportCounts(total: 2, passed: 1, warnings: 1))
        #expect(benchmark.artifact.availability == .unavailable)
        #expect(row.requirements.first { $0.kind == .runtimeGeneration }?.state == .blocked)
        #expect(row.requirements.first { $0.kind == .benchmarkOrEval }?.state == .partial)
    }

    @Test
    func unavailableProofRewriteNormalizesAllOutcomeCounts() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/missing-mixed-count-proof", config: #"{"model_type":"qwen3"}"#)
        let service = ModelLibraryEvidenceService(
            registry: EvidenceReportRegistryService(now: fixture.clock)
        )

        let snapshot = service.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    artifactPath: fixture.root.appendingPathComponent("proof/missing-mixed.json").path,
                    status: .passed,
                    counts: EvidenceReportCounts(
                        total: 4,
                        passed: 1,
                        failed: 1,
                        blocked: 1,
                        warnings: 1
                    ),
                    metadata: [
                        "tokens_per_second": "12.0",
                        "physical_footprint_within_limit": "true",
                    ]
                ),
            ]
        )
        let runtime = try #require(snapshot.reports.first { $0.kind == .runtime })

        #expect(runtime.status == .unavailable)
        #expect(runtime.counts == EvidenceReportCounts(total: 4, skipped: 4))
    }

    @Test
    func registryMetadataAndRowsDoNotExposeFullBundlePaths() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/redacted", config: #"{"model_type":"qwen3"}"#)
        let registry = EvidenceReportRegistryService(now: fixture.clock)
        let service = ModelLibraryEvidenceService(registry: registry)

        let snapshot = service.registerEvidence(for: [model])
        let row = try #require(snapshot.rows.first)
        let cacheReport = try #require(snapshot.report(id: row.cacheReportID))

        #expect(row.redactedBundlePath == ".../redacted")
        #expect(row.redactedBundlePath?.contains(fixture.root.path) == false)
        #expect(row.metadata.values.allSatisfy { !$0.contains(fixture.root.path) })
        #expect(cacheReport.metadata["bundle_path"] == "<redacted>")
        #expect(cacheReport.metadata.values.allSatisfy { !$0.contains(fixture.root.path) })
        #expect(!cacheReport.id.contains(fixture.root.path))
        #expect(!cacheReport.artifact.path.contains(fixture.root.path))
        #expect(!cacheReport.artifact.path.hasPrefix("/"))
        #expect(
            registry.localArtifactURL(forReportID: cacheReport.id, producer: "model-library-evidence")
                == model.localDirectory.standardizedFileURL
        )
        #expect(
            !String(decoding: try service.snapshot().stableJSONData(), as: UTF8.self)
                .contains(fixture.root.path)
        )
    }

    @Test
    func proofIdentityNormalizesModelAndArtifactInputsWithoutPublishingPaths() throws {
        let fixture = try ModelEvidenceFixture()
        let model = try fixture.model(id: "org/stable-proof", config: #"{"model_type":"qwen3"}"#)
        let artifact = try fixture.writeArtifact(named: "proof/stable-runtime.json")
        let registry = EvidenceReportRegistryService(now: fixture.clock)
        let firstService = ModelLibraryEvidenceService(registry: registry)
        let first = firstService.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: "  \(model.id)  ",
                    kind: .runtime,
                    artifactPath: artifact.path,
                    status: .passed,
                    metadata: ["tokens_per_second": "12.0"]
                ),
            ]
        )
        let firstProofID = try #require(first.rows.first?.proofReportIDs.first)

        let aliasedPath = artifact.deletingLastPathComponent()
            .appendingPathComponent("alias")
            .appendingPathComponent("..")
            .appendingPathComponent(artifact.lastPathComponent)
            .path
        let recreatedService = ModelLibraryEvidenceService(registry: registry)
        let second = recreatedService.registerEvidence(
            for: [model],
            proofDescriptors: [
                ModelEvidenceProofDescriptor(
                    modelId: model.id,
                    kind: .runtime,
                    artifactPath: aliasedPath,
                    status: .passed,
                    metadata: ["tokens_per_second": "12.0"]
                ),
            ]
        )
        let secondProofID = try #require(second.rows.first?.proofReportIDs.first)
        let proofReport = try #require(second.report(id: secondProofID))

        #expect(firstProofID == secondProofID)
        #expect(!secondProofID.contains(fixture.root.path))
        #expect(!proofReport.artifact.path.contains(fixture.root.path))
        #expect(!proofReport.artifact.path.hasPrefix("/"))
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

    func completeProofDescriptors(for modelId: String) throws -> [ModelEvidenceProofDescriptor] {
        let runtime = try writeArtifact(named: "proof/\(modelId)-runtime.json")
        let cache = try writeArtifact(named: "proof/\(modelId)-cache.json")
        let benchmark = try writeArtifact(named: "proof/\(modelId)-benchmark.json")
        return [
            ModelEvidenceProofDescriptor(
                modelId: modelId,
                kind: .runtime,
                artifactPath: runtime.path,
                status: .passed,
                metadata: [
                    "tokens_per_second": "18.4",
                    "physical_footprint_within_limit": "true",
                ]
            ),
            ModelEvidenceProofDescriptor(
                modelId: modelId,
                kind: .cache,
                artifactPath: cache.path,
                status: .passed
            ),
            ModelEvidenceProofDescriptor(
                modelId: modelId,
                kind: .benchmark,
                artifactPath: benchmark.path,
                status: .passed,
                metadata: ["tokens_per_second": "18.4"]
            ),
        ]
    }
}

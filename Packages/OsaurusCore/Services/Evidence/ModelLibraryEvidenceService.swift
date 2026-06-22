//
//  ModelLibraryEvidenceService.swift
//  osaurus
//
//  Aggregates model-library cache, compatibility, and proof artifacts into the
//  shared evidence registry.
//

import Foundation

final class ModelLibraryEvidenceService {
    private let registry: EvidenceReportRegistryService

    init(registry: EvidenceReportRegistryService = EvidenceReportRegistryService()) {
        self.registry = registry
    }

    @discardableResult
    func registerEvidence(
        for models: [MLXModel],
        proofDescriptors: [ModelEvidenceProofDescriptor] = [],
        filter: ModelEvidenceFilter = ModelEvidenceFilter()
    ) -> ModelEvidenceSnapshot {
        let proofDescriptorsByModel = Dictionary(grouping: proofDescriptors, by: { $0.modelId })
        var rows: [ModelEvidenceRow] = []

        for model in models {
            let report = Self.compatibilityReport(for: model)
            let supportState = Self.supportState(from: report.preflight.status)
            let groupKind = Self.groupKind(from: report)
            let modelProofDescriptors = proofDescriptorsByModel[model.id] ?? []

            let descriptors =
                Self.registryDescriptors(
                    for: model,
                    report: report,
                    supportState: supportState,
                    proofDescriptors: modelProofDescriptors
                )
            let summaries = registry.register(descriptors)
            let proofIDPrefix = "model-library-"
            let proofIDs = summaries
                .filter { $0.id.hasPrefix(proofIDPrefix) && $0.id.contains("-proof|") }
                .map(\.id)
                .sorted()

            rows.append(
                ModelEvidenceRow(
                    modelId: model.id,
                    displayName: model.name,
                    supportState: supportState,
                    groupKind: groupKind,
                    cacheReportID: Self.localCacheID(for: model.id),
                    compatibilityReportID: Self.compatibilityID(for: model.id),
                    proofReportIDs: proofIDs,
                    redactedBundlePath: Self.redactedPath(report.localBundle.path),
                    metadata: Self.rowMetadata(for: model, report: report, supportState: supportState)
                )
            )
        }

        let sortedRows = rows.sorted(by: Self.sortRows)
        return ModelEvidenceSnapshot(
            rows: sortedRows,
            visibleRows: sortedRows.filter(filter.includes),
            groups: Self.groups(from: sortedRows),
            reports: registry.list()
        )
    }

    func snapshot(_ filter: EvidenceReportFilter = EvidenceReportFilter()) -> EvidenceReportRegistrySnapshot {
        registry.snapshot(filter)
    }

    private static func compatibilityReport(for model: MLXModel) -> ModelCompatibilityDiagnostics.Report {
        ModelCompatibilityDiagnostics.report(
            modelId: model.id,
            modelName: model.name,
            modelTypeHint: model.modelType,
            bundleURL: candidateBundleURL(for: model),
            externalSource: model.externalSource
        )
    }

    private static func candidateBundleURL(for model: MLXModel) -> URL? {
        if model.isDownloaded {
            return model.localDirectory
        }
        if model.bundleDirectory != nil {
            return model.localDirectory
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: model.localDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return model.localDirectory
    }

    private static func registryDescriptors(
        for model: MLXModel,
        report: ModelCompatibilityDiagnostics.Report,
        supportState: ModelEvidenceSupportState,
        proofDescriptors: [ModelEvidenceProofDescriptor]
    ) -> [EvidenceReportDescriptor] {
        var descriptors = [
            localCacheDescriptor(for: model, report: report, supportState: supportState),
            compatibilityDescriptor(for: model, report: report, supportState: supportState),
        ]
        descriptors.append(contentsOf: proofDescriptors.map { proofDescriptor($0, model: model) })
        return descriptors
    }

    private static func localCacheDescriptor(
        for model: MLXModel,
        report: ModelCompatibilityDiagnostics.Report,
        supportState: ModelEvidenceSupportState
    ) -> EvidenceReportDescriptor {
        EvidenceReportDescriptor(
            id: localCacheID(for: model.id),
            kind: .cache,
            source: "model-library-cache",
            artifactPath: report.localBundle.path ?? model.localDirectory.path,
            status: cacheStatus(from: report.localBundle.kind),
            counts: cacheCounts(from: report.localBundle.kind),
            metadata: descriptorMetadata(
                for: model,
                report: report,
                supportState: supportState,
                extra: [
                    "evidence_role": "local_cache_import",
                    "bundle_status": report.localBundle.kind.rawValue,
                ]
            )
        )
    }

    private static func compatibilityDescriptor(
        for model: MLXModel,
        report: ModelCompatibilityDiagnostics.Report,
        supportState: ModelEvidenceSupportState
    ) -> EvidenceReportDescriptor {
        EvidenceReportDescriptor(
            id: compatibilityID(for: model.id),
            kind: .modelCompatibility,
            source: "model-library-preflight",
            artifactPath: compatibilityArtifactPath(for: model, report: report),
            status: supportState.reportStatus,
            counts: supportState.counts,
            metadata: descriptorMetadata(
                for: model,
                report: report,
                supportState: supportState,
                extra: [
                    "evidence_role": "compatibility_preflight",
                    "preflight_reason": report.preflight.reason.rawValue,
                    "runtime_status": report.runtime.kind.rawValue,
                ]
            )
        )
    }

    private static func proofDescriptor(
        _ proof: ModelEvidenceProofDescriptor,
        model: MLXModel
    ) -> EvidenceReportDescriptor {
        var metadata = proof.metadata
        metadata["model_id"] = model.id
        metadata["model_name"] = model.name
        metadata["evidence_role"] = "\(proof.kind.rawValue)_proof"
        return EvidenceReportDescriptor(
            id: proofID(modelId: model.id, kind: proof.kind, artifactPath: proof.artifactPath),
            kind: proof.kind.reportKind,
            source: proof.source,
            artifactPath: proof.artifactPath,
            status: proof.status,
            counts: proof.counts,
            startedAt: proof.startedAt,
            completedAt: proof.completedAt,
            metadata: metadata,
            artifactError: proof.artifactError
        )
    }

    private static func descriptorMetadata(
        for model: MLXModel,
        report: ModelCompatibilityDiagnostics.Report,
        supportState: ModelEvidenceSupportState,
        extra: [String: String]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "model_id": model.id,
            "model_name": model.name,
            "support_state": supportState.rawValue,
            "source_kind": report.source.kind.rawValue,
            "bundle_path": "<redacted>",
        ]
        if let externalSource = model.externalSource {
            metadata["external_source"] = externalSource
        }
        if let redacted = redactedPath(report.localBundle.path) {
            metadata["bundle_path_display"] = redacted
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }

    private static func rowMetadata(
        for model: MLXModel,
        report: ModelCompatibilityDiagnostics.Report,
        supportState: ModelEvidenceSupportState
    ) -> [String: String] {
        descriptorMetadata(
            for: model,
            report: report,
            supportState: supportState,
            extra: [
                "group": groupKind(from: report).rawValue,
                "preflight_title": report.preflight.title,
            ]
        )
    }

    private static func compatibilityArtifactPath(
        for model: MLXModel,
        report: ModelCompatibilityDiagnostics.Report
    ) -> String {
        guard let bundlePath = report.localBundle.path else {
            return model.localDirectory.appendingPathComponent("config.json").path
        }
        let configPath = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("config.json")
            .path
        if FileManager.default.fileExists(atPath: configPath) {
            return configPath
        }
        return bundlePath
    }

    private static func supportState(
        from status: ModelCompatibilityDiagnostics.PreflightStatus.Status
    ) -> ModelEvidenceSupportState {
        switch status {
        case .supported:
            return .supported
        case .partial:
            return .partial
        case .unsupported:
            return .unsupported
        case .unproven:
            return .unproven
        }
    }

    private static func groupKind(
        from report: ModelCompatibilityDiagnostics.Report
    ) -> ModelEvidenceGroupKind {
        switch report.localBundle.kind {
        case .incomplete:
            return .incomplete
        case .notDownloaded:
            return .catalog
        case .available:
            return report.source.kind == .external ? .externalCache : .ready
        }
    }

    private static func cacheStatus(
        from kind: ModelCompatibilityDiagnostics.LocalBundleStatus.Kind
    ) -> EvidenceReportStatus {
        switch kind {
        case .available:
            return .passed
        case .incomplete:
            return .partial
        case .notDownloaded:
            return .unavailable
        }
    }

    private static func cacheCounts(
        from kind: ModelCompatibilityDiagnostics.LocalBundleStatus.Kind
    ) -> EvidenceReportCounts {
        switch kind {
        case .available:
            return EvidenceReportCounts(total: 1, passed: 1)
        case .incomplete:
            return EvidenceReportCounts(total: 1, warnings: 1)
        case .notDownloaded:
            return EvidenceReportCounts(total: 1, skipped: 1)
        }
    }

    private static func groups(from rows: [ModelEvidenceRow]) -> [ModelEvidenceGroup] {
        let grouped = Dictionary(grouping: rows, by: \.groupKind)
        return ModelEvidenceGroupKind.allCases.compactMap { kind in
            guard let rows = grouped[kind], !rows.isEmpty else { return nil }
            return ModelEvidenceGroup(
                kind: kind,
                count: rows.count,
                visibleByDefault: kind.isVisibleByDefault
            )
        }
    }

    private static func sortRows(_ lhs: ModelEvidenceRow, _ rhs: ModelEvidenceRow) -> Bool {
        if lhs.groupKind.rawValue != rhs.groupKind.rawValue {
            return lhs.groupKind.rawValue < rhs.groupKind.rawValue
        }
        return lhs.modelId.localizedStandardCompare(rhs.modelId) == .orderedAscending
    }

    private static func localCacheID(for modelId: String) -> String {
        "model-library-cache|\(modelId)"
    }

    private static func compatibilityID(for modelId: String) -> String {
        "model-library-preflight|\(modelId)"
    }

    private static func proofID(
        modelId: String,
        kind: ModelEvidenceProofKind,
        artifactPath: String
    ) -> String {
        "model-library-\(kind.rawValue)-proof|\(modelId)|\(artifactPath)"
    }

    private static func redactedPath(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let last = URL(fileURLWithPath: path).lastPathComponent
        guard !last.isEmpty else { return "<redacted>" }
        return ".../\(last)"
    }
}

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
            let preflightState = Self.supportState(from: report.preflight.status)
            let groupKind = Self.groupKind(from: report)
            let modelProofDescriptors = proofDescriptorsByModel[model.id] ?? []
            let proofAssessments = Self.proofAssessments(for: model, descriptors: modelProofDescriptors)
            let supportState = Self.supportState(
                preflightState: preflightState,
                report: report,
                proofAssessments: proofAssessments
            )

            let descriptors =
                Self.registryDescriptors(
                    for: model,
                    report: report,
                    supportState: supportState,
                    preflightState: preflightState,
                    proofAssessments: proofAssessments
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
                    requirements: Self.requirementStatuses(
                        report: report,
                        supportState: supportState,
                        proofAssessments: proofAssessments
                    ),
                    redactedBundlePath: Self.redactedPath(report.localBundle.path),
                    metadata: Self.rowMetadata(
                        for: model,
                        report: report,
                        supportState: supportState,
                        preflightState: preflightState
                    )
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
        preflightState: ModelEvidenceSupportState,
        proofAssessments: [ProofAssessment]
    ) -> [EvidenceReportDescriptor] {
        var descriptors = [
            localCacheDescriptor(for: model, report: report, supportState: supportState),
            compatibilityDescriptor(
                for: model,
                report: report,
                supportState: supportState,
                preflightState: preflightState
            ),
        ]
        descriptors.append(contentsOf: proofAssessments.map { proofDescriptor($0, model: model) })
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
        supportState: ModelEvidenceSupportState,
        preflightState: ModelEvidenceSupportState
    ) -> EvidenceReportDescriptor {
        EvidenceReportDescriptor(
            id: compatibilityID(for: model.id),
            kind: .modelCompatibility,
            source: "model-library-preflight",
            artifactPath: compatibilityArtifactPath(for: model, report: report),
            status: preflightState.reportStatus,
            counts: preflightState.counts,
            metadata: descriptorMetadata(
                for: model,
                report: report,
                supportState: supportState,
                extra: [
                    "evidence_role": "compatibility_preflight",
                    "preflight_state": preflightState.rawValue,
                    "preflight_reason": report.preflight.reason.rawValue,
                    "runtime_status": report.runtime.kind.rawValue,
                ]
            )
        )
    }

    private static func proofDescriptor(
        _ assessment: ProofAssessment,
        model: MLXModel
    ) -> EvidenceReportDescriptor {
        let proof = assessment.descriptor
        var metadata = proof.metadata
        metadata["model_id"] = model.id
        metadata["model_name"] = model.name
        metadata["evidence_role"] = "\(proof.kind.rawValue)_proof"
        if let tokensPerSecond = assessment.tokensPerSecond {
            metadata["tokens_per_second"] = String(tokensPerSecond)
        }
        if !assessment.validationMessages.isEmpty {
            metadata["evidence_validation"] = assessment.validationMessages.joined(separator: "; ")
        }
        return EvidenceReportDescriptor(
            id: assessment.reportID,
            kind: proof.kind.reportKind,
            source: proof.source,
            artifactPath: proof.artifactPath,
            status: assessment.status,
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
        supportState: ModelEvidenceSupportState,
        preflightState: ModelEvidenceSupportState
    ) -> [String: String] {
        descriptorMetadata(
            for: model,
            report: report,
            supportState: supportState,
            extra: [
                "group": groupKind(from: report).rawValue,
                "preflight_state": preflightState.rawValue,
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

    private static func supportState(
        preflightState: ModelEvidenceSupportState,
        report: ModelCompatibilityDiagnostics.Report,
        proofAssessments: [ProofAssessment]
    ) -> ModelEvidenceSupportState {
        if preflightState == .unsupported {
            return .unsupported
        }
        if preflightState == .partial {
            return .partial
        }
        if report.localBundle.kind != .available {
            return .unproven
        }
        if proofAssessments.contains(where: { $0.status == .failed || $0.status == .error }) {
            return .unsupported
        }

        let runtimeProof = proofAssessments.contains {
            $0.kind == .runtime && $0.status == .passed && $0.hasPositiveTokenRate
        }
        let memoryProof = proofAssessments.contains {
            ($0.kind == .runtime || $0.kind == .memory) && $0.status == .passed && $0.provesMemoryFootprint
        }
        let cacheProof = proofAssessments.contains {
            $0.kind == .cache && $0.status == .passed
        }
        let benchmarkOrEvalProof = proofAssessments.contains {
            ($0.kind == .benchmark || $0.kind == .eval) && $0.status == .passed
        }

        if runtimeProof && memoryProof && cacheProof && benchmarkOrEvalProof {
            return .supported
        }
        if proofAssessments.isEmpty {
            return .unproven
        }
        return .partial
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

    private static func requirementStatuses(
        report: ModelCompatibilityDiagnostics.Report,
        supportState: ModelEvidenceSupportState,
        proofAssessments: [ProofAssessment]
    ) -> [ModelEvidenceRequirementStatus] {
        [
            importRequirement(report: report),
            preflightRequirement(report: report, supportState: supportState),
            proofRequirement(
                kind: .runtimeGeneration,
                assessments: proofAssessments.filter { $0.kind == .runtime },
                passed: { $0.status == .passed && $0.hasPositiveTokenRate },
                missingDetail: "No passing runtime generation proof with token/s is registered."
            ),
            proofRequirement(
                kind: .tokenRate,
                assessments: proofAssessments.filter { $0.kind == .runtime || $0.kind == .benchmark },
                passed: { $0.status == .passed && $0.hasPositiveTokenRate },
                missingDetail: "No runtime or benchmark row records token/s."
            ),
            proofRequirement(
                kind: .memoryFootprint,
                assessments: proofAssessments.filter { $0.kind == .runtime || $0.kind == .memory },
                passed: { $0.status == .passed && $0.provesMemoryFootprint },
                missingDetail: "No runtime or memory row proves physical footprint stayed within the intended gate."
            ),
            proofRequirement(
                kind: .cacheBehavior,
                assessments: proofAssessments.filter { $0.kind == .cache },
                passed: { $0.status == .passed },
                missingDetail: "No cache proof row is registered."
            ),
            proofRequirement(
                kind: .benchmarkOrEval,
                assessments: proofAssessments.filter { $0.kind == .benchmark || $0.kind == .eval },
                passed: { $0.status == .passed },
                missingDetail: "No benchmark or eval row is registered."
            ),
        ]
    }

    private static func importRequirement(
        report: ModelCompatibilityDiagnostics.Report
    ) -> ModelEvidenceRequirementStatus {
        switch report.localBundle.kind {
        case .available:
            return ModelEvidenceRequirementStatus(
                kind: .importState,
                state: .passed,
                reportID: localCacheID(for: report.modelId),
                detail: report.localBundle.title
            )
        case .incomplete:
            return ModelEvidenceRequirementStatus(
                kind: .importState,
                state: .partial,
                reportID: localCacheID(for: report.modelId),
                detail: report.localBundle.detail ?? report.localBundle.title
            )
        case .notDownloaded:
            return ModelEvidenceRequirementStatus(
                kind: .importState,
                state: .unavailable,
                reportID: localCacheID(for: report.modelId),
                detail: report.localBundle.detail ?? report.localBundle.title
            )
        }
    }

    private static func preflightRequirement(
        report: ModelCompatibilityDiagnostics.Report,
        supportState: ModelEvidenceSupportState
    ) -> ModelEvidenceRequirementStatus {
        let state: ModelEvidenceRequirementState
        switch report.preflight.status {
        case .supported:
            state = .passed
        case .partial:
            state = .partial
        case .unsupported:
            state = .failed
        case .unproven:
            state = .missing
        }
        let detail = supportState == .supported
            ? report.preflight.detail
            : "\(report.preflight.detail) Row support is \(supportState.rawValue) until proof requirements pass."
        return ModelEvidenceRequirementStatus(
            kind: .compatibilityPreflight,
            state: state,
            reportID: compatibilityID(for: report.modelId),
            detail: detail
        )
    }

    private static func proofRequirement(
        kind: ModelEvidenceRequirementKind,
        assessments: [ProofAssessment],
        passed: (ProofAssessment) -> Bool,
        missingDetail: String
    ) -> ModelEvidenceRequirementStatus {
        if let passing = assessments.first(where: passed) {
            return ModelEvidenceRequirementStatus(
                kind: kind,
                state: .passed,
                reportID: passing.reportID,
                detail: passing.summaryDetail
            )
        }
        if assessments.isEmpty {
            return ModelEvidenceRequirementStatus(
                kind: kind,
                state: .missing,
                reportID: nil,
                detail: missingDetail
            )
        }

        let ranked = assessments.sorted { lhs, rhs in
            requirementStateRank(state(from: lhs.status)) > requirementStateRank(state(from: rhs.status))
        }
        let best = ranked[0]
        return ModelEvidenceRequirementStatus(
            kind: kind,
            state: state(from: best.status),
            reportID: best.reportID,
            detail: best.summaryDetail
        )
    }

    private static func state(from status: EvidenceReportStatus) -> ModelEvidenceRequirementState {
        switch status {
        case .passed:
            return .passed
        case .partial:
            return .partial
        case .failed, .error:
            return .failed
        case .blocked:
            return .blocked
        case .unavailable:
            return .unavailable
        case .unknown:
            return .missing
        }
    }

    private static func requirementStateRank(_ state: ModelEvidenceRequirementState) -> Int {
        switch state {
        case .passed:
            return 6
        case .failed:
            return 5
        case .blocked:
            return 4
        case .partial:
            return 3
        case .unavailable:
            return 2
        case .missing:
            return 1
        }
    }

    private static func proofAssessments(
        for model: MLXModel,
        descriptors: [ModelEvidenceProofDescriptor]
    ) -> [ProofAssessment] {
        descriptors.map { descriptor in
            let reportID = proofID(
                modelId: model.id,
                kind: descriptor.kind,
                artifactPath: descriptor.artifactPath
            )
            let artifactUnavailable =
                descriptor.artifactError?.isEmpty == false
                || !FileManager.default.fileExists(atPath: descriptor.artifactPath)
            let tokensPerSecond = tokenRate(from: descriptor.metadata)
            let provesMemoryFootprint = memoryProof(from: descriptor.metadata) == true
            var status = descriptor.status
            var validationMessages: [String] = []

            if artifactUnavailable {
                status = descriptor.artifactError?.isEmpty == false ? .error : .unavailable
            } else if descriptor.status == .passed {
                switch descriptor.kind {
                case .runtime, .benchmark:
                    if tokensPerSecond == nil || tokensPerSecond ?? 0 <= 0 {
                        status = .blocked
                        validationMessages.append("passing generation proof must record token/s")
                    }
                case .memory:
                    if !provesMemoryFootprint {
                        status = .blocked
                        validationMessages.append("passing memory proof must record physical footprint within limit")
                    }
                case .cache, .eval:
                    break
                }
            }

            return ProofAssessment(
                descriptor: descriptor,
                reportID: reportID,
                status: status,
                tokensPerSecond: tokensPerSecond,
                provesMemoryFootprint: provesMemoryFootprint,
                validationMessages: validationMessages
            )
        }
    }

    private static func tokenRate(from metadata: [String: String]) -> Double? {
        for key in ["tokens_per_second", "token_s", "tokens_s", "tps"] {
            if let value = metadata[key], let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }
        return nil
    }

    private static func memoryProof(from metadata: [String: String]) -> Bool? {
        for key in [
            "physical_footprint_within_limit",
            "memory_within_limit",
            "ram_within_limit",
            "memory_proof",
            "ram_proof",
        ] {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                continue
            }
            if ["true", "yes", "passed", "pass", "within_limit", "1"].contains(value) {
                return true
            }
            if ["false", "no", "failed", "fail", "over_limit", "0"].contains(value) {
                return false
            }
        }
        return nil
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

    private struct ProofAssessment {
        let descriptor: ModelEvidenceProofDescriptor
        let reportID: String
        let status: EvidenceReportStatus
        let tokensPerSecond: Double?
        let provesMemoryFootprint: Bool
        let validationMessages: [String]

        var kind: ModelEvidenceProofKind {
            descriptor.kind
        }

        var hasPositiveTokenRate: Bool {
            (tokensPerSecond ?? 0) > 0
        }

        var summaryDetail: String {
            if !validationMessages.isEmpty {
                return validationMessages.joined(separator: "; ")
            }
            if let tokensPerSecond {
                return "\(descriptor.source) \(status.rawValue), \(tokensPerSecond) token/s."
            }
            return "\(descriptor.source) \(status.rawValue)."
        }
    }
}

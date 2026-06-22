//
//  ModelLibraryEvidence.swift
//  osaurus
//
//  Read-only model-library projection over the shared evidence registry.
//

import Foundation

enum ModelEvidenceSupportState: String, Codable, CaseIterable, Hashable, Sendable {
    case supported
    case partial
    case unsupported
    case unproven

    var reportStatus: EvidenceReportStatus {
        switch self {
        case .supported:
            return .passed
        case .partial:
            return .partial
        case .unsupported:
            return .failed
        case .unproven:
            return .unknown
        }
    }

    var counts: EvidenceReportCounts {
        switch self {
        case .supported:
            return EvidenceReportCounts(total: 1, passed: 1)
        case .partial:
            return EvidenceReportCounts(total: 1, warnings: 1)
        case .unsupported:
            return EvidenceReportCounts(total: 1, failed: 1)
        case .unproven:
            return EvidenceReportCounts(total: 1, skipped: 1)
        }
    }
}

enum ModelEvidenceProofKind: String, Codable, CaseIterable, Hashable, Sendable {
    case cache
    case benchmark
    case runtime

    var reportKind: EvidenceReportKind {
        switch self {
        case .cache:
            return .cache
        case .benchmark:
            return .benchmark
        case .runtime:
            return .runtime
        }
    }
}

enum ModelEvidenceGroupKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ready
    case catalog
    case incomplete
    case externalCache

    var isVisibleByDefault: Bool {
        switch self {
        case .ready, .catalog:
            return true
        case .incomplete, .externalCache:
            return false
        }
    }
}

struct ModelEvidenceProofDescriptor: Equatable, Sendable {
    var modelId: String
    var kind: ModelEvidenceProofKind
    var source: String
    var artifactPath: String
    var status: EvidenceReportStatus
    var counts: EvidenceReportCounts
    var startedAt: Date?
    var completedAt: Date?
    var metadata: [String: String]
    var artifactError: String?

    init(
        modelId: String,
        kind: ModelEvidenceProofKind,
        source: String? = nil,
        artifactPath: String,
        status: EvidenceReportStatus,
        counts: EvidenceReportCounts = EvidenceReportCounts(total: 1),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        metadata: [String: String] = [:],
        artifactError: String? = nil
    ) {
        self.modelId = modelId
        self.kind = kind
        self.source = source ?? "model-library-\(kind.rawValue)-proof"
        self.artifactPath = artifactPath
        self.status = status
        self.counts = counts
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.metadata = metadata
        self.artifactError = artifactError
    }
}

struct ModelEvidenceFilter: Equatable, Sendable {
    var includeIncomplete: Bool
    var includeExternalCacheCandidates: Bool
    var supportStates: Set<ModelEvidenceSupportState>

    init(
        includeIncomplete: Bool = false,
        includeExternalCacheCandidates: Bool = false,
        supportStates: Set<ModelEvidenceSupportState> = []
    ) {
        self.includeIncomplete = includeIncomplete
        self.includeExternalCacheCandidates = includeExternalCacheCandidates
        self.supportStates = supportStates
    }

    func includes(_ row: ModelEvidenceRow) -> Bool {
        if !supportStates.isEmpty, !supportStates.contains(row.supportState) {
            return false
        }
        switch row.groupKind {
        case .ready, .catalog:
            return true
        case .incomplete:
            return includeIncomplete
        case .externalCache:
            return includeExternalCacheCandidates
        }
    }
}

struct ModelEvidenceRow: Equatable, Identifiable, Sendable {
    var id: String { modelId }

    var modelId: String
    var displayName: String
    var supportState: ModelEvidenceSupportState
    var groupKind: ModelEvidenceGroupKind
    var cacheReportID: String
    var compatibilityReportID: String
    var proofReportIDs: [String]
    var redactedBundlePath: String?
    var metadata: [String: String]

    var isVisibleByDefault: Bool {
        groupKind.isVisibleByDefault
    }
}

struct ModelEvidenceGroup: Equatable, Identifiable, Sendable {
    var kind: ModelEvidenceGroupKind
    var count: Int
    var visibleByDefault: Bool

    var id: ModelEvidenceGroupKind { kind }
}

struct ModelEvidenceSnapshot: Equatable, Sendable {
    var rows: [ModelEvidenceRow]
    var visibleRows: [ModelEvidenceRow]
    var groups: [ModelEvidenceGroup]
    var reports: [EvidenceReportSummary]

    func report(id: String) -> EvidenceReportSummary? {
        reports.first { $0.id == id }
    }
}

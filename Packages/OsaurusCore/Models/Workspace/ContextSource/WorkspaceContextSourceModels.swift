//
//  WorkspaceContextSourceModels.swift
//  osaurus
//
//  Descriptive inventory models for context sources that can influence a
//  workspace chat. These types intentionally carry metadata, provenance, and
//  citation anchors only. Memory facts, agent DB rows, attachment bytes, and
//  sandbox snapshots remain owned by their existing services.
//

import Foundation

public enum WorkspaceContextSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case memory
    case agentDatabase = "agent_database"
    case sandboxContext = "sandbox_context"
    case screenContext = "screen_context"
    case uploadedFile = "uploaded_file"
    case workspaceKnowledge = "workspace_knowledge"
    case citation

    public var displayName: String {
        switch self {
        case .memory: return "Memory"
        case .agentDatabase: return "Agent DB"
        case .sandboxContext: return "Sandbox Context"
        case .screenContext: return "Screen Context"
        case .uploadedFile: return "Uploaded File"
        case .workspaceKnowledge: return "Workspace Knowledge"
        case .citation: return "Citation"
        }
    }

    public var category: WorkspaceContextSourceCategory {
        switch self {
        case .uploadedFile, .workspaceKnowledge:
            return .files
        case .memory:
            return .memory
        case .agentDatabase:
            return .agentDatabase
        case .sandboxContext:
            return .sandboxContext
        case .screenContext:
            return .screenContext
        case .citation:
            return .citations
        }
    }

    public var expectedOrigin: WorkspaceContextSourceOrigin {
        switch self {
        case .memory: return .memoryService
        case .agentDatabase: return .agentDatabase
        case .sandboxContext: return .sandboxInjection
        case .screenContext: return .screenContextInjection
        case .uploadedFile: return .chatAttachment
        case .workspaceKnowledge: return .workspaceKnowledgeIndex
        case .citation: return .citationResolver
        }
    }

    public var boundaryContract: WorkspaceContextBoundaryContract {
        switch self {
        case .memory:
            return WorkspaceContextBoundaryContract(
                authority: .memoryService,
                payloadPolicy: .metadataOnly,
                contextPolicy: .userMessagePrefixOwnedElsewhere,
                dedupePolicy: .withinKindByProvenance
            )
        case .agentDatabase:
            return WorkspaceContextBoundaryContract(
                authority: .agentDatabase,
                payloadPolicy: .metadataOnly,
                contextPolicy: .toolMediated,
                dedupePolicy: .withinKindByProvenance
            )
        case .sandboxContext:
            return WorkspaceContextBoundaryContract(
                authority: .sandboxContextInjection,
                payloadPolicy: .executionEnvelopeOnly,
                contextPolicy: .userMessagePrefixOwnedElsewhere,
                dedupePolicy: .withinKindByProvenance
            )
        case .screenContext:
            return WorkspaceContextBoundaryContract(
                authority: .screenContextInjection,
                payloadPolicy: .executionEnvelopeOnly,
                contextPolicy: .userMessagePrefixOwnedElsewhere,
                dedupePolicy: .withinKindByProvenance
            )
        case .uploadedFile:
            return WorkspaceContextBoundaryContract(
                authority: .chatAttachmentStore,
                payloadPolicy: .metadataAndAnchorsOnly,
                contextPolicy: .attachmentPayloadOwnedElsewhere,
                dedupePolicy: .withinKindByProvenance
            )
        case .workspaceKnowledge:
            return WorkspaceContextBoundaryContract(
                authority: .workspaceKnowledgeIndex,
                payloadPolicy: .metadataAndAnchorsOnly,
                contextPolicy: .retrievalIndexOwnedElsewhere,
                dedupePolicy: .withinKindByProvenance
            )
        case .citation:
            return WorkspaceContextBoundaryContract(
                authority: .citationResolver,
                payloadPolicy: .citationAnchorsOnly,
                contextPolicy: .citationOnly,
                dedupePolicy: .withinKindByProvenance
            )
        }
    }

    public var requiresIndexFreshness: Bool {
        switch self {
        case .uploadedFile, .workspaceKnowledge:
            return true
        case .memory, .agentDatabase, .sandboxContext, .screenContext, .citation:
            return false
        }
    }

    public var requiresFrozenSnapshot: Bool {
        switch self {
        case .screenContext:
            return true
        case .memory, .agentDatabase, .sandboxContext, .uploadedFile, .workspaceKnowledge, .citation:
            return false
        }
    }
}

public enum WorkspaceContextSourceCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case files
    case memory
    case agentDatabase = "agent_database"
    case sandboxContext = "sandbox_context"
    case screenContext = "screen_context"
    case citations

    public var displayName: String {
        switch self {
        case .files: return "Files"
        case .memory: return "Memory"
        case .agentDatabase: return "Agent DB"
        case .sandboxContext: return "Sandbox Context"
        case .screenContext: return "Screen Context"
        case .citations: return "Citations"
        }
    }
}

public enum WorkspaceContextSourceAuthority: String, Codable, Hashable, Sendable {
    case memoryService
    case agentDatabase
    case sandboxContextInjection
    case screenContextInjection
    case chatAttachmentStore
    case workspaceKnowledgeIndex
    case citationResolver
}

public enum WorkspaceContextPayloadPolicy: String, Codable, Hashable, Sendable {
    case metadataOnly
    case metadataAndAnchorsOnly
    case citationAnchorsOnly
    case executionEnvelopeOnly
}

public enum WorkspaceContextInjectionPolicy: String, Codable, Hashable, Sendable {
    case userMessagePrefixOwnedElsewhere
    case toolMediated
    case attachmentPayloadOwnedElsewhere
    case retrievalIndexOwnedElsewhere
    case citationOnly
}

public enum WorkspaceContextDedupePolicy: String, Codable, Hashable, Sendable {
    case withinKindByProvenance
}

public struct WorkspaceContextBoundaryContract: Codable, Equatable, Hashable, Sendable {
    public var authority: WorkspaceContextSourceAuthority
    public var payloadPolicy: WorkspaceContextPayloadPolicy
    public var contextPolicy: WorkspaceContextInjectionPolicy
    public var dedupePolicy: WorkspaceContextDedupePolicy

    public init(
        authority: WorkspaceContextSourceAuthority,
        payloadPolicy: WorkspaceContextPayloadPolicy,
        contextPolicy: WorkspaceContextInjectionPolicy,
        dedupePolicy: WorkspaceContextDedupePolicy
    ) {
        self.authority = authority
        self.payloadPolicy = payloadPolicy
        self.contextPolicy = contextPolicy
        self.dedupePolicy = dedupePolicy
    }
}

public enum WorkspaceContextSourceOrigin: String, Codable, Hashable, Sendable {
    case memoryService
    case agentDatabase
    case sandboxInjection
    case screenContextInjection
    case chatAttachment
    case workspaceKnowledgeIndex
    case citationResolver
    case unknown
}

public struct WorkspaceContextSourceProvenance: Codable, Equatable, Hashable, Sendable {
    public var stableId: String
    public var origin: WorkspaceContextSourceOrigin
    public var displayPath: String?
    public var sourceVersion: String?
    public var contentHash: String?
    public var observedAt: Date?
    public var modifiedAt: Date?
    public var sourceExists: Bool

    public init(
        stableId: String,
        origin: WorkspaceContextSourceOrigin,
        displayPath: String? = nil,
        sourceVersion: String? = nil,
        contentHash: String? = nil,
        observedAt: Date? = nil,
        modifiedAt: Date? = nil,
        sourceExists: Bool = true
    ) {
        self.stableId = stableId
        self.origin = origin
        self.displayPath = displayPath
        self.sourceVersion = sourceVersion
        self.contentHash = contentHash
        self.observedAt = observedAt
        self.modifiedAt = modifiedAt
        self.sourceExists = sourceExists
    }

    public var versionFingerprint: String? {
        let trimmedVersion = sourceVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedVersion, !trimmedVersion.isEmpty {
            return trimmedVersion
        }
        let trimmedHash = contentHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedHash, !trimmedHash.isEmpty {
            return trimmedHash
        }
        return nil
    }
}

public enum WorkspaceContextSnapshotFreezeState: String, Codable, Hashable, Sendable {
    case live
    case frozen
}

public struct WorkspaceContextSnapshotProvenance: Codable, Equatable, Hashable, Sendable {
    public var freezeState: WorkspaceContextSnapshotFreezeState
    public var snapshotId: String
    public var capturedAt: Date?
    public var frozenAt: Date?
    public var sourceVersion: String?
    public var citationVersion: String?
    public var contextDigest: String?

    public init(
        freezeState: WorkspaceContextSnapshotFreezeState,
        snapshotId: String,
        capturedAt: Date? = nil,
        frozenAt: Date? = nil,
        sourceVersion: String? = nil,
        citationVersion: String? = nil,
        contextDigest: String? = nil
    ) {
        self.freezeState = freezeState
        self.snapshotId = snapshotId
        self.capturedAt = capturedAt
        self.frozenAt = frozenAt
        self.sourceVersion = sourceVersion
        self.citationVersion = citationVersion
        self.contextDigest = contextDigest
    }

    public var isFrozen: Bool {
        freezeState == .frozen
            && !snapshotId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && frozenAt != nil
    }
}

public enum WorkspaceContextIndexStatus: String, Codable, Hashable, Sendable {
    case notIndexed = "not_indexed"
    case indexing
    case indexed
    case failed
}

public struct WorkspaceContextIndexState: Codable, Equatable, Hashable, Sendable {
    public var status: WorkspaceContextIndexStatus
    public var indexedAt: Date?
    public var indexedSourceVersion: String?
    public var indexedCitationVersion: String?
    public var citationCount: Int
    public var lastError: String?

    public init(
        status: WorkspaceContextIndexStatus,
        indexedAt: Date? = nil,
        indexedSourceVersion: String? = nil,
        indexedCitationVersion: String? = nil,
        citationCount: Int = 0,
        lastError: String? = nil
    ) {
        self.status = status
        self.indexedAt = indexedAt
        self.indexedSourceVersion = indexedSourceVersion
        self.indexedCitationVersion = indexedCitationVersion
        self.citationCount = max(0, citationCount)
        self.lastError = lastError
    }
}

public enum WorkspaceContextCitationAnchorKind: String, Codable, Hashable, Sendable {
    case fileRange = "file_range"
    case documentPage = "document_page"
    case spreadsheetCell = "spreadsheet_cell"
    case databaseRow = "database_row"
    case memoryEpisode = "memory_episode"
    case sandboxSnapshot = "sandbox_snapshot"
    case screenSnapshot = "screen_snapshot"
    case externalReference = "external_reference"
}

public struct WorkspaceContextCitationAnchor: Codable, Equatable, Hashable, Sendable {
    public var kind: WorkspaceContextCitationAnchorKind
    public var locator: String
    public var startLine: Int?
    public var endLine: Int?

    public init(
        kind: WorkspaceContextCitationAnchorKind,
        locator: String,
        startLine: Int? = nil,
        endLine: Int? = nil
    ) {
        self.kind = kind
        self.locator = locator
        self.startLine = startLine
        self.endLine = endLine
    }
}

public struct WorkspaceContextCitation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceId: String
    public var label: String
    public var sourceVersion: String?
    public var anchor: WorkspaceContextCitationAnchor?

    public init(
        id: String,
        sourceId: String,
        label: String,
        sourceVersion: String? = nil,
        anchor: WorkspaceContextCitationAnchor? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.label = label
        self.sourceVersion = sourceVersion
        self.anchor = anchor
    }
}

public struct WorkspaceContextSourceInput: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: WorkspaceContextSourceKind
    public var displayName: String
    public var agentId: UUID?
    public var isEnabled: Bool
    public var provenance: WorkspaceContextSourceProvenance?
    public var snapshot: WorkspaceContextSnapshotProvenance?
    public var index: WorkspaceContextIndexState?
    public var citations: [WorkspaceContextCitation]
    public var metadata: [String: String]

    public init(
        id: String,
        kind: WorkspaceContextSourceKind,
        displayName: String,
        agentId: UUID? = nil,
        isEnabled: Bool = true,
        provenance: WorkspaceContextSourceProvenance? = nil,
        snapshot: WorkspaceContextSnapshotProvenance? = nil,
        index: WorkspaceContextIndexState? = nil,
        citations: [WorkspaceContextCitation] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.agentId = agentId
        self.isEnabled = isEnabled
        self.provenance = provenance
        self.snapshot = snapshot
        self.index = index
        self.citations = citations
        self.metadata = metadata
    }
}

public enum WorkspaceContextWarningKind: String, Codable, Hashable, Sendable {
    case malformedSource = "malformed_source"
    case sourceMissing = "source_missing"
    case sourceDisabled = "source_disabled"
    case agentScopeMismatch = "agent_scope_mismatch"
    case disabledForAgent = "disabled_for_agent"
    case duplicateSource = "duplicate_source"
    case provenanceOriginMismatch = "provenance_origin_mismatch"
    case staleProvenance = "stale_provenance"
    case snapshotMissing = "snapshot_missing"
    case snapshotLive = "snapshot_live"
    case snapshotIncomplete = "snapshot_incomplete"
    case snapshotStale = "snapshot_stale"
    case indexMissing = "index_missing"
    case indexInProgress = "index_in_progress"
    case indexFailed = "index_failed"
    case indexStale = "index_stale"
    case malformedCitation = "malformed_citation"
    case citationSourceMissing = "citation_source_missing"
    case citationAnchorMissing = "citation_anchor_missing"
    case citationStale = "citation_stale"
}

public struct WorkspaceContextSourceWarning: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceId: String?
    public var kind: WorkspaceContextWarningKind
    public var message: String

    public init(
        id: String = UUID().uuidString,
        sourceId: String? = nil,
        kind: WorkspaceContextWarningKind,
        message: String
    ) {
        self.id = id
        self.sourceId = sourceId
        self.kind = kind
        self.message = message
    }
}

public enum WorkspaceContextStalenessReason: String, Codable, Hashable, Sendable {
    case sourceMissing = "source_missing"
    case provenanceExpired = "provenance_expired"
    case snapshotMissing = "snapshot_missing"
    case snapshotNotFrozen = "snapshot_not_frozen"
    case snapshotVersionMismatch = "snapshot_version_mismatch"
    case snapshotModifiedAfterFreeze = "snapshot_modified_after_freeze"
    case indexMissing = "index_missing"
    case indexInProgress = "index_in_progress"
    case indexFailed = "index_failed"
    case indexVersionMismatch = "index_version_mismatch"
    case malformedCitation = "malformed_citation"
    case citationSourceMissing = "citation_source_missing"
    case citationAnchorMissing = "citation_anchor_missing"
    case citationVersionMismatch = "citation_version_mismatch"
}

public enum WorkspaceContextFreshnessStatus: String, Codable, Hashable, Sendable {
    case current
    case unindexed
    case stale
    case missing
    case malformed
}

public struct WorkspaceContextSourceStaleness: Codable, Equatable, Hashable, Sendable {
    public var status: WorkspaceContextFreshnessStatus
    public var reasons: Set<WorkspaceContextStalenessReason>

    public init(
        status: WorkspaceContextFreshnessStatus,
        reasons: Set<WorkspaceContextStalenessReason> = []
    ) {
        self.status = status
        self.reasons = reasons
    }

    public var isActionable: Bool {
        status != .current
    }
}

public enum WorkspaceContextSourceRecordState: String, Codable, Hashable, Sendable {
    case active
    case disabled
    case duplicate
    case stale
    case missing
    case malformed
}

public struct WorkspaceContextSourceRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { source.id }

    public var source: WorkspaceContextSourceInput
    public var dedupeKey: String
    public var boundaryContract: WorkspaceContextBoundaryContract
    public var enabledForAgent: Bool
    public var duplicateOf: String?
    public var staleness: WorkspaceContextSourceStaleness
    public var warnings: [WorkspaceContextSourceWarning]

    public init(
        source: WorkspaceContextSourceInput,
        dedupeKey: String,
        boundaryContract: WorkspaceContextBoundaryContract,
        enabledForAgent: Bool,
        duplicateOf: String? = nil,
        staleness: WorkspaceContextSourceStaleness,
        warnings: [WorkspaceContextSourceWarning] = []
    ) {
        self.source = source
        self.dedupeKey = dedupeKey
        self.boundaryContract = boundaryContract
        self.enabledForAgent = enabledForAgent
        self.duplicateOf = duplicateOf
        self.staleness = staleness
        self.warnings = warnings
    }

    public var state: WorkspaceContextSourceRecordState {
        if staleness.status == .malformed { return .malformed }
        if duplicateOf != nil { return .duplicate }
        if !enabledForAgent { return .disabled }
        switch staleness.status {
        case .current:
            return .active
        case .unindexed, .stale:
            return .stale
        case .missing:
            return .missing
        case .malformed:
            return .malformed
        }
    }

    public var isEffective: Bool {
        enabledForAgent
            && duplicateOf == nil
            && staleness.status != .missing
            && staleness.status != .malformed
    }
}

public struct WorkspaceContextRejectedSource: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceId: String?
    public var kind: WorkspaceContextSourceKind?
    public var message: String

    public init(
        id: String = UUID().uuidString,
        sourceId: String?,
        kind: WorkspaceContextSourceKind?,
        message: String
    ) {
        self.id = id
        self.sourceId = sourceId
        self.kind = kind
        self.message = message
    }
}

public struct WorkspaceContextDuplicateGroup: Codable, Equatable, Hashable, Sendable {
    public var dedupeKey: String
    public var canonicalSourceId: String
    public var duplicateSourceIds: [String]

    public init(
        dedupeKey: String,
        canonicalSourceId: String,
        duplicateSourceIds: [String]
    ) {
        self.dedupeKey = dedupeKey
        self.canonicalSourceId = canonicalSourceId
        self.duplicateSourceIds = duplicateSourceIds
    }
}

public struct WorkspaceContextSourceInventory: Codable, Equatable, Sendable {
    public var activeAgentId: UUID?
    public var generatedAt: Date
    public var records: [WorkspaceContextSourceRecord]
    public var rejectedSources: [WorkspaceContextRejectedSource]
    public var duplicateGroups: [WorkspaceContextDuplicateGroup]
    public var warnings: [WorkspaceContextSourceWarning]

    public init(
        activeAgentId: UUID?,
        generatedAt: Date,
        records: [WorkspaceContextSourceRecord],
        rejectedSources: [WorkspaceContextRejectedSource],
        duplicateGroups: [WorkspaceContextDuplicateGroup],
        warnings: [WorkspaceContextSourceWarning]
    ) {
        self.activeAgentId = activeAgentId
        self.generatedAt = generatedAt
        self.records = records
        self.rejectedSources = rejectedSources
        self.duplicateGroups = duplicateGroups
        self.warnings = warnings
    }

    public var effectiveSources: [WorkspaceContextSourceRecord] {
        records.filter(\.isEffective)
    }

    public func record(id: String) -> WorkspaceContextSourceRecord? {
        records.first { $0.id == id }
    }
}

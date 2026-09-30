//
//  WorkspaceContextSourceWorkbench.swift
//  osaurus
//
//  Evaluates context-source metadata for the workspace context workbench.
//  This service does not read MemoryDatabase, AgentDatabase, attachments, or
//  sandbox state. Callers supply source descriptors from those owners, and
//  the workbench only proves boundaries, provenance, dedupe, and freshness.
//

import Foundation

public struct WorkspaceContextSourceWorkbenchPolicy: Sendable {
    public var defaultEnabledKinds: Set<WorkspaceContextSourceKind>
    public var enabledKindsByAgent: [UUID: Set<WorkspaceContextSourceKind>]
    public var disabledSourceIds: Set<String>
    public var disabledSourceIdsByAgent: [UUID: Set<String>]
    public var provenanceMaxAge: TimeInterval?

    public init(
        defaultEnabledKinds: Set<WorkspaceContextSourceKind>? = nil,
        enabledKindsByAgent: [UUID: Set<WorkspaceContextSourceKind>] = [:],
        disabledSourceIds: Set<String> = [],
        disabledSourceIdsByAgent: [UUID: Set<String>] = [:],
        provenanceMaxAge: TimeInterval? = nil
    ) {
        self.defaultEnabledKinds = defaultEnabledKinds ?? Set(WorkspaceContextSourceKind.allCases)
        self.enabledKindsByAgent = enabledKindsByAgent
        self.disabledSourceIds = Set(disabledSourceIds.map(\.normalizedContextSourceKey))
        self.disabledSourceIdsByAgent = disabledSourceIdsByAgent.mapValues {
            Set($0.map(\.normalizedContextSourceKey))
        }
        self.provenanceMaxAge = provenanceMaxAge
    }

    func enabledKinds(for agentId: UUID?) -> Set<WorkspaceContextSourceKind> {
        guard let agentId else { return defaultEnabledKinds }
        return enabledKindsByAgent[agentId] ?? defaultEnabledKinds
    }

    func isSourceExplicitlyDisabled(_ source: WorkspaceContextSourceInput, for agentId: UUID?) -> Bool {
        if isSourceGloballyDisabled(source) {
            return true
        }
        return isSourceDisabledForAgent(source, agentId: agentId)
    }

    func isSourceGloballyDisabled(_ source: WorkspaceContextSourceInput) -> Bool {
        let sourceId = source.id.normalizedContextSourceKey
        let stableId = source.provenance?.stableId.normalizedContextSourceKey
        return disabledSourceIds.contains(sourceId) || stableId.map(disabledSourceIds.contains) == true
    }

    func isSourceDisabledForAgent(_ source: WorkspaceContextSourceInput, agentId: UUID?) -> Bool {
        guard let agentId else { return false }
        let sourceId = source.id.normalizedContextSourceKey
        let stableId = source.provenance?.stableId.normalizedContextSourceKey
        let disabled = disabledSourceIdsByAgent[agentId] ?? []
        return disabled.contains(sourceId) || stableId.map(disabled.contains) == true
    }
}

public enum WorkspaceContextSourceWorkbench {
    public static func buildInventory(
        sources: [WorkspaceContextSourceInput],
        activeAgentId: UUID? = nil,
        policy: WorkspaceContextSourceWorkbenchPolicy = WorkspaceContextSourceWorkbenchPolicy(),
        now: Date = Date()
    ) -> WorkspaceContextSourceInventory {
        var rejected: [WorkspaceContextRejectedSource] = []
        var warnings: [WorkspaceContextSourceWarning] = []
        var validated: [ValidatedSource] = []

        for source in sources {
            switch validate(source) {
            case .success(let validatedSource):
                validated.append(validatedSource)
            case .failure(let rejection):
                rejected.append(rejection)
                warnings.append(
                    warning(
                        sourceId: rejection.sourceId,
                        kind: .malformedSource,
                        message: rejection.message
                    )
                )
            }
        }

        let sourceLookup = SourceLookup(validatedSources: validated)
        let canonicalByKey = canonicalSourcesByDedupeKey(
            validated,
            activeAgentId: activeAgentId,
            policy: policy
        )
        let duplicateGroups = duplicateGroups(from: validated, canonicalByKey: canonicalByKey)

        var records: [WorkspaceContextSourceRecord] = []
        for item in validated {
            let canonical = canonicalByKey[item.dedupeKey]
            let duplicateOf = canonical?.id == item.source.id ? nil : canonical?.id
            var sourceWarnings = evaluateEnablementWarnings(
                source: item.source,
                activeAgentId: activeAgentId,
                policy: policy
            )
            sourceWarnings.append(
                contentsOf: evaluateBoundaryWarnings(source: item.source)
            )

            let staleness = evaluateStaleness(
                source: item.source,
                lookup: sourceLookup,
                policy: policy,
                now: now,
                warnings: &sourceWarnings
            )

            if let duplicateOf {
                sourceWarnings.append(
                    warning(
                        sourceId: item.source.id,
                        kind: .duplicateSource,
                        message: "\(item.source.displayName) duplicates \(duplicateOf) for \(item.source.kind.displayName)."
                    )
                )
            }

            let enabled = isEnabledForAgent(
                item.source,
                activeAgentId: activeAgentId,
                policy: policy
            )
            records.append(
                WorkspaceContextSourceRecord(
                    source: item.source,
                    dedupeKey: item.dedupeKey,
                    boundaryContract: item.source.kind.boundaryContract,
                    enabledForAgent: enabled,
                    duplicateOf: duplicateOf,
                    staleness: staleness,
                    warnings: sourceWarnings
                )
            )
            warnings.append(contentsOf: sourceWarnings)
        }

        return WorkspaceContextSourceInventory(
            activeAgentId: activeAgentId,
            generatedAt: now,
            records: records,
            rejectedSources: rejected,
            duplicateGroups: duplicateGroups,
            warnings: warnings
        )
    }
}

private extension WorkspaceContextSourceWorkbench {
    struct ValidatedSource {
        var source: WorkspaceContextSourceInput
        var dedupeKey: String
    }

    enum ValidationResult {
        case success(ValidatedSource)
        case failure(WorkspaceContextRejectedSource)
    }

    struct SourceLookup {
        var byId: [String: WorkspaceContextSourceInput] = [:]
        var byStableId: [String: WorkspaceContextSourceInput] = [:]

        init(validatedSources: [ValidatedSource]) {
            for item in validatedSources {
                byId[item.source.id.normalizedContextSourceKey] = item.source
                if let stableId = item.source.provenance?.stableId.normalizedNonEmptyContextSourceKey {
                    byStableId[stableId] = item.source
                }
            }
        }

        func resolve(_ sourceId: String) -> WorkspaceContextSourceInput? {
            let key = sourceId.normalizedContextSourceKey
            return byId[key] ?? byStableId[key]
        }
    }

    static func validate(_ source: WorkspaceContextSourceInput) -> ValidationResult {
        let trimmedId = source.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            return .failure(
                WorkspaceContextRejectedSource(
                    sourceId: nil,
                    kind: source.kind,
                    message: "Context source is missing a source id."
                )
            )
        }
        guard var provenance = source.provenance else {
            return .failure(
                WorkspaceContextRejectedSource(
                    sourceId: trimmedId,
                    kind: source.kind,
                    message: "Context source \(trimmedId) is missing provenance."
                )
            )
        }
        let stableId = provenance.stableId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stableId.isEmpty else {
            return .failure(
                WorkspaceContextRejectedSource(
                    sourceId: trimmedId,
                    kind: source.kind,
                    message: "Context source \(trimmedId) has blank provenance stableId."
                )
            )
        }

        provenance.stableId = stableId
        var normalized = source
        normalized.id = trimmedId
        normalized.displayName = normalized.displayName.trimmedContextSourceFallback(trimmedId)
        normalized.provenance = provenance
        let dedupeKey = "\(normalized.kind.rawValue)|\(stableId.normalizedContextSourceKey)"
        return .success(ValidatedSource(source: normalized, dedupeKey: dedupeKey))
    }

    static func canonicalSourcesByDedupeKey(
        _ sources: [ValidatedSource],
        activeAgentId: UUID?,
        policy: WorkspaceContextSourceWorkbenchPolicy
    ) -> [String: WorkspaceContextSourceInput] {
        var canonicalByKey: [String: WorkspaceContextSourceInput] = [:]
        for item in sources {
            guard let existing = canonicalByKey[item.dedupeKey] else {
                canonicalByKey[item.dedupeKey] = item.source
                continue
            }
            if item.source.isPreferredCanonical(
                over: existing,
                activeAgentId: activeAgentId,
                policy: policy
            ) {
                canonicalByKey[item.dedupeKey] = item.source
            }
        }
        return canonicalByKey
    }

    static func duplicateGroups(
        from sources: [ValidatedSource],
        canonicalByKey: [String: WorkspaceContextSourceInput]
    ) -> [WorkspaceContextDuplicateGroup] {
        let grouped = Dictionary(grouping: sources, by: \.dedupeKey)
        return grouped.compactMap { key, items in
            guard items.count > 1, let canonical = canonicalByKey[key] else { return nil }
            let duplicates = items.map(\.source.id).filter { $0 != canonical.id }
            guard !duplicates.isEmpty else { return nil }
            return WorkspaceContextDuplicateGroup(
                dedupeKey: key,
                canonicalSourceId: canonical.id,
                duplicateSourceIds: duplicates
            )
        }
        .sorted { $0.dedupeKey < $1.dedupeKey }
    }

    static func evaluateEnablementWarnings(
        source: WorkspaceContextSourceInput,
        activeAgentId: UUID?,
        policy: WorkspaceContextSourceWorkbenchPolicy
    ) -> [WorkspaceContextSourceWarning] {
        var warnings: [WorkspaceContextSourceWarning] = []
        if !source.isEnabled {
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .sourceDisabled,
                    message: "\(source.displayName) is disabled by its owning source."
                )
            )
        }
        if let activeAgentId, let sourceAgentId = source.agentId, sourceAgentId != activeAgentId {
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .agentScopeMismatch,
                    message: "\(source.displayName) belongs to a different agent."
                )
            )
        }
        if !policy.enabledKinds(for: activeAgentId).contains(source.kind) {
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .disabledForAgent,
                    message: "\(source.kind.displayName) is disabled for the active agent."
                )
            )
        }
        if policy.isSourceGloballyDisabled(source) {
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .sourceDisabled,
                    message: "\(source.displayName) is disabled by workspace context policy."
                )
            )
        } else if policy.isSourceDisabledForAgent(source, agentId: activeAgentId) {
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .disabledForAgent,
                    message: "\(source.displayName) is disabled for the active agent."
                )
            )
        }
        return warnings
    }

    static func evaluateBoundaryWarnings(
        source: WorkspaceContextSourceInput
    ) -> [WorkspaceContextSourceWarning] {
        guard let provenance = source.provenance else { return [] }
        guard provenance.origin != .unknown, provenance.origin != source.kind.expectedOrigin else {
            return []
        }
        return [
            warning(
                sourceId: source.id,
                kind: .provenanceOriginMismatch,
                message: "\(source.displayName) reports \(provenance.origin.rawValue) provenance for \(source.kind.displayName)."
            )
        ]
    }

    static func evaluateStaleness(
        source: WorkspaceContextSourceInput,
        lookup: SourceLookup,
        policy: WorkspaceContextSourceWorkbenchPolicy,
        now: Date,
        warnings: inout [WorkspaceContextSourceWarning]
    ) -> WorkspaceContextSourceStaleness {
        var reasons: Set<WorkspaceContextStalenessReason> = []

        if source.provenance?.sourceExists == false {
            reasons.insert(.sourceMissing)
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .sourceMissing,
                    message: "\(source.displayName) no longer resolves at its recorded source."
                )
            )
        }

        if let maxAge = policy.provenanceMaxAge,
            let observedAt = source.provenance?.observedAt,
            now.timeIntervalSince(observedAt) > maxAge {
            reasons.insert(.provenanceExpired)
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .staleProvenance,
                    message: "\(source.displayName) provenance has not been verified recently."
                )
            )
        }

        evaluateSnapshotFreshness(source: source, reasons: &reasons, warnings: &warnings)
        evaluateIndexFreshness(source: source, reasons: &reasons, warnings: &warnings)
        evaluateCitationFreshness(
            source: source,
            lookup: lookup,
            reasons: &reasons,
            warnings: &warnings
        )

        if reasons.contains(.sourceMissing) {
            return WorkspaceContextSourceStaleness(status: .missing, reasons: reasons)
        }
        if reasons.contains(.malformedCitation) {
            return WorkspaceContextSourceStaleness(status: .malformed, reasons: reasons)
        }
        if reasons == [.indexMissing] || reasons == [.indexInProgress] {
            return WorkspaceContextSourceStaleness(status: .unindexed, reasons: reasons)
        }
        if !reasons.isEmpty {
            return WorkspaceContextSourceStaleness(status: .stale, reasons: reasons)
        }
        return WorkspaceContextSourceStaleness(status: .current)
    }

    static func evaluateSnapshotFreshness(
        source: WorkspaceContextSourceInput,
        reasons: inout Set<WorkspaceContextStalenessReason>,
        warnings: inout [WorkspaceContextSourceWarning]
    ) {
        guard source.kind.requiresFrozenSnapshot else { return }
        guard let snapshot = source.snapshot else {
            reasons.insert(.snapshotMissing)
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .snapshotMissing,
                    message: "\(source.displayName) has no frozen snapshot metadata."
                )
            )
            return
        }

        if !snapshot.isFrozen {
            reasons.insert(.snapshotNotFrozen)
            switch snapshot.freezeState {
            case .live:
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .snapshotLive,
                        message: "\(source.displayName) is still live; freeze the snapshot before using it as turn context."
                    )
                )
            case .frozen:
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .snapshotIncomplete,
                        message: "\(source.displayName) frozen snapshot metadata is incomplete."
                    )
                )
            }
        }

        if let currentVersion = source.provenance?.sourceVersion?.normalizedNonEmptyContextSourceKey {
            if let snapshotVersion = snapshot.sourceVersion?.normalizedNonEmptyContextSourceKey {
                if snapshotVersion != currentVersion {
                    reasons.insert(.snapshotVersionMismatch)
                    warnings.append(
                        warning(
                            sourceId: source.id,
                            kind: .snapshotStale,
                            message: "\(source.displayName) snapshot was captured for an older source version."
                        )
                    )
                }
            } else {
                reasons.insert(.snapshotVersionMismatch)
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .snapshotStale,
                        message: "\(source.displayName) snapshot has no source version metadata."
                    )
                )
            }
        }

        if let modifiedAt = source.provenance?.modifiedAt,
            let frozenAt = snapshot.frozenAt,
            modifiedAt > frozenAt {
            reasons.insert(.snapshotModifiedAfterFreeze)
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .snapshotStale,
                    message: "\(source.displayName) changed after its snapshot was frozen."
                )
            )
        }
    }

    static func evaluateIndexFreshness(
        source: WorkspaceContextSourceInput,
        reasons: inout Set<WorkspaceContextStalenessReason>,
        warnings: inout [WorkspaceContextSourceWarning]
    ) {
        guard source.kind.requiresIndexFreshness else { return }
        guard let index = source.index else {
            reasons.insert(.indexMissing)
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .indexMissing,
                    message: "\(source.displayName) has no index metadata."
                )
            )
            return
        }

        switch index.status {
        case .notIndexed:
            reasons.insert(.indexMissing)
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .indexMissing,
                    message: "\(source.displayName) has not been indexed."
                )
            )
        case .indexing:
            reasons.insert(.indexInProgress)
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .indexInProgress,
                    message: "\(source.displayName) is still indexing."
                )
            )
        case .failed:
            reasons.insert(.indexFailed)
            let detail = index.lastError?.trimmedContextSourceFallback("unknown error") ?? "unknown error"
            warnings.append(
                warning(
                    sourceId: source.id,
                    kind: .indexFailed,
                    message: "\(source.displayName) index failed: \(detail)."
                )
            )
        case .indexed:
            let currentVersion = source.provenance?.versionFingerprint
            let indexedVersion = index.indexedSourceVersion?.normalizedNonEmptyContextSourceKey
            if let currentVersion = currentVersion?.normalizedNonEmptyContextSourceKey,
                indexedVersion != nil,
                indexedVersion != currentVersion {
                reasons.insert(.indexVersionMismatch)
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .indexStale,
                        message: "\(source.displayName) index was built for an older source version."
                    )
                )
            }
        }
    }

    static func evaluateCitationFreshness(
        source: WorkspaceContextSourceInput,
        lookup: SourceLookup,
        reasons: inout Set<WorkspaceContextStalenessReason>,
        warnings: inout [WorkspaceContextSourceWarning]
    ) {
        for (index, citation) in source.citations.enumerated() {
            let citationId = citation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let citedSourceId = citation.sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
            if citationId.isEmpty || citedSourceId.isEmpty {
                reasons.insert(.malformedCitation)
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .malformedCitation,
                        message: "\(source.displayName) has a malformed citation reference.",
                        disambiguator: "citation:\(index):\(citation.id):\(citation.sourceId)"
                    )
                )
                continue
            }

            guard let citedSource = lookup.resolve(citedSourceId) else {
                reasons.insert(.citationSourceMissing)
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .citationSourceMissing,
                        message: "\(source.displayName) cites missing source \(citedSourceId).",
                        disambiguator: "citation:\(index):\(citationId):\(citedSourceId)"
                    )
                )
                continue
            }

            if citation.anchor?.locator.normalizedNonEmptyContextSourceKey == nil {
                reasons.insert(.citationAnchorMissing)
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .citationAnchorMissing,
                        message: "\(source.displayName) citation \(citationId) has no stable anchor.",
                        disambiguator: "citation:\(index):\(citationId):anchor"
                    )
                )
            }

            if let citationVersion = citation.sourceVersion?.normalizedNonEmptyContextSourceKey,
                let currentVersion = citedSource.provenance?.versionFingerprint?.normalizedNonEmptyContextSourceKey,
                citationVersion != currentVersion {
                reasons.insert(.citationVersionMismatch)
                warnings.append(
                    warning(
                        sourceId: source.id,
                        kind: .citationStale,
                        message: "\(source.displayName) citation \(citationId) points at an older source version.",
                        disambiguator: "citation:\(index):\(citationId):\(citedSourceId)"
                    )
                )
            }
        }
    }

    static func isEnabledForAgent(
        _ source: WorkspaceContextSourceInput,
        activeAgentId: UUID?,
        policy: WorkspaceContextSourceWorkbenchPolicy
    ) -> Bool {
        guard source.isEnabled else { return false }
        if let activeAgentId, let sourceAgentId = source.agentId, sourceAgentId != activeAgentId {
            return false
        }
        guard policy.enabledKinds(for: activeAgentId).contains(source.kind) else { return false }
        return !policy.isSourceExplicitlyDisabled(source, for: activeAgentId)
    }

    static func warning(
        sourceId: String?,
        kind: WorkspaceContextWarningKind,
        message: String,
        disambiguator: String? = nil
    ) -> WorkspaceContextSourceWarning {
        let normalizedSourceId = sourceId?.normalizedContextSourceKey ?? "global"
        let idMaterial = [message, disambiguator ?? ""].joined(separator: "\u{1F}")
        return WorkspaceContextSourceWarning(
            id: "\(normalizedSourceId):\(kind.rawValue):\(stableWarningIDComponent(idMaterial))",
            sourceId: sourceId,
            kind: kind,
            message: message
        )
    }

    static func stableWarningIDComponent(_ message: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in message.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension WorkspaceContextSourceInput {
    func isPreferredCanonical(
        over other: WorkspaceContextSourceInput,
        activeAgentId: UUID?,
        policy: WorkspaceContextSourceWorkbenchPolicy
    ) -> Bool {
        let selfEnabled = WorkspaceContextSourceWorkbench.isEnabledForAgent(
            self,
            activeAgentId: activeAgentId,
            policy: policy
        )
        let otherEnabled = WorkspaceContextSourceWorkbench.isEnabledForAgent(
            other,
            activeAgentId: activeAgentId,
            policy: policy
        )
        if selfEnabled != otherEnabled { return selfEnabled }

        let selfExists = provenance?.sourceExists ?? false
        let otherExists = other.provenance?.sourceExists ?? false
        if selfExists != otherExists { return selfExists }

        let selfDate = provenance?.modifiedAt ?? provenance?.observedAt ?? .distantPast
        let otherDate = other.provenance?.modifiedAt ?? other.provenance?.observedAt ?? .distantPast
        if selfDate != otherDate { return selfDate > otherDate }

        return id < other.id
    }
}

private extension String {
    var normalizedContextSourceKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedNonEmptyContextSourceKey: String? {
        let normalized = normalizedContextSourceKey
        return normalized.isEmpty ? nil : normalized
    }

    func trimmedContextSourceFallback(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

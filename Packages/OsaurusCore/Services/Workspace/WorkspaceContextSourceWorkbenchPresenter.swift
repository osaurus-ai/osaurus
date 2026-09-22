//
//  WorkspaceContextSourceWorkbenchPresenter.swift
//  osaurus
//
//  Presentation helpers for the workspace context source inventory. Kept
//  separate from SwiftUI so the proof layer can be tested without UI scope.
//

import Foundation

public struct WorkspaceContextSourceWorkbenchRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var kindLabel: String
    public var categoryLabel: String
    public var statusLabel: String
    public var badges: [String]
    public var provenanceLabel: String
    public var citationLabel: String?
    public var snapshotLabel: String?
    public var warningText: String?
    public var isEffective: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        kindLabel: String,
        categoryLabel: String,
        statusLabel: String,
        badges: [String],
        provenanceLabel: String,
        citationLabel: String?,
        snapshotLabel: String?,
        warningText: String?,
        isEffective: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kindLabel = kindLabel
        self.categoryLabel = categoryLabel
        self.statusLabel = statusLabel
        self.badges = badges
        self.provenanceLabel = provenanceLabel
        self.citationLabel = citationLabel
        self.snapshotLabel = snapshotLabel
        self.warningText = warningText
        self.isEffective = isEffective
    }
}

public struct WorkspaceContextSourceWorkbenchSummary: Equatable, Sendable {
    public var totalSources: Int
    public var effectiveSources: Int
    public var rejectedSources: Int
    public var duplicateSources: Int
    public var staleSources: Int
    public var missingSources: Int
    public var disabledSources: Int
    public var categoryCounts: [WorkspaceContextSourceCategory: Int]

    public init(
        totalSources: Int,
        effectiveSources: Int,
        rejectedSources: Int,
        duplicateSources: Int,
        staleSources: Int,
        missingSources: Int,
        disabledSources: Int,
        categoryCounts: [WorkspaceContextSourceCategory: Int] = [:]
    ) {
        self.totalSources = totalSources
        self.effectiveSources = effectiveSources
        self.rejectedSources = rejectedSources
        self.duplicateSources = duplicateSources
        self.staleSources = staleSources
        self.missingSources = missingSources
        self.disabledSources = disabledSources
        self.categoryCounts = categoryCounts
    }
}

public enum WorkspaceContextSourceWorkbenchPresenter {
    public static func rows(
        for inventory: WorkspaceContextSourceInventory
    ) -> [WorkspaceContextSourceWorkbenchRow] {
        inventory.records.map { record in
            let provenance = record.source.provenance
            let subtitle = provenance?.displayPath
                ?? provenance?.stableId
                ?? record.source.id
            var badges = [
                record.boundaryContract.authority.rawValue,
                record.boundaryContract.payloadPolicy.rawValue,
            ]
            if record.duplicateOf != nil {
                badges.append("duplicate")
            }
            if !record.enabledForAgent {
                badges.append("disabled")
            }
            if record.source.snapshot?.isFrozen == true {
                badges.append("frozen")
            }

            return WorkspaceContextSourceWorkbenchRow(
                id: record.id,
                title: record.source.displayName,
                subtitle: subtitle,
                kindLabel: record.source.kind.displayName,
                categoryLabel: record.source.kind.category.displayName,
                statusLabel: statusLabel(for: record),
                badges: badges,
                provenanceLabel: provenanceLabel(for: record),
                citationLabel: citationLabel(for: record),
                snapshotLabel: snapshotLabel(for: record),
                warningText: record.warnings.first?.message,
                isEffective: record.isEffective
            )
        }
    }

    public static func summary(
        for inventory: WorkspaceContextSourceInventory
    ) -> WorkspaceContextSourceWorkbenchSummary {
        WorkspaceContextSourceWorkbenchSummary(
            totalSources: inventory.records.count,
            effectiveSources: inventory.effectiveSources.count,
            rejectedSources: inventory.rejectedSources.count,
            duplicateSources: inventory.records.filter { $0.duplicateOf != nil }.count,
            staleSources: inventory.records.filter { $0.state == .stale }.count,
            missingSources: inventory.records.filter { $0.state == .missing }.count,
            disabledSources: inventory.records.filter { $0.state == .disabled }.count,
            categoryCounts: Dictionary(grouping: inventory.records, by: { $0.source.kind.category })
                .mapValues { $0.count }
        )
    }

    private static func statusLabel(for record: WorkspaceContextSourceRecord) -> String {
        switch record.state {
        case .active:
            return "Current"
        case .disabled:
            return "Disabled"
        case .duplicate:
            return "Duplicate"
        case .stale:
            return record.staleness.status == .unindexed ? "Unindexed" : "Stale"
        case .missing:
            return "Missing"
        case .malformed:
            return "Malformed"
        }
    }

    private static func provenanceLabel(for record: WorkspaceContextSourceRecord) -> String {
        guard let provenance = record.source.provenance else { return "No provenance" }
        if let version = provenance.versionFingerprint {
            return "\(provenance.origin.rawValue) @ \(version)"
        }
        return provenance.origin.rawValue
    }

    private static func citationLabel(for record: WorkspaceContextSourceRecord) -> String? {
        guard !record.source.citations.isEmpty else { return nil }
        return record.source.citations.count == 1 ? "1 citation" : "\(record.source.citations.count) citations"
    }

    private static func snapshotLabel(for record: WorkspaceContextSourceRecord) -> String? {
        guard let snapshot = record.source.snapshot else {
            return record.source.kind.requiresFrozenSnapshot ? "No frozen snapshot" : nil
        }
        let id = snapshot.snapshotId.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = id.isEmpty ? "" : " \(id)"
        switch snapshot.freezeState {
        case .frozen:
            return snapshot.isFrozen ? "Frozen snapshot\(suffix)" : "Incomplete frozen snapshot\(suffix)"
        case .live:
            return "Live snapshot\(suffix)"
        }
    }
}

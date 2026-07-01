//
//  EvidenceReportRegistryService.swift
//  osaurus
//
//  In-memory registry over local evidence report descriptors.
//

import Foundation

public final class EvidenceReportRegistryService {
    private var summariesByID: [String: EvidenceReportSummary] = [:]
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    @discardableResult
    public func register(
        _ descriptors: [EvidenceReportDescriptor],
        relativeTo baseURL: URL? = nil
    ) -> [EvidenceReportSummary] {
        descriptors.map { register($0, relativeTo: baseURL) }
    }

    @discardableResult
    public func register(
        _ descriptor: EvidenceReportDescriptor,
        relativeTo baseURL: URL? = nil
    ) -> EvidenceReportSummary {
        let summary = makeSummary(from: descriptor, relativeTo: baseURL)
        if let existing = summariesByID[summary.id] {
            summariesByID[summary.id] = preferredSummary(existing, summary)
        } else {
            summariesByID[summary.id] = summary
        }
        return summariesByID[summary.id] ?? summary
    }

    public func list(_ filter: EvidenceReportFilter = EvidenceReportFilter()) -> [EvidenceReportSummary] {
        summariesByID.values
            .filter { filter.includes($0) }
            .sorted(by: Self.sortSummaries)
    }

    public func snapshot(_ filter: EvidenceReportFilter = EvidenceReportFilter()) -> EvidenceReportRegistrySnapshot {
        EvidenceReportRegistrySnapshot(reports: list(filter))
    }

    public func removeAll() {
        summariesByID.removeAll()
    }

    private func makeSummary(
        from descriptor: EvidenceReportDescriptor,
        relativeTo baseURL: URL?
    ) -> EvidenceReportSummary {
        let artifactPath = normalizedArtifactPath(descriptor.artifactPath, relativeTo: baseURL)
        let artifact = artifactReference(
            path: artifactPath,
            descriptorError: descriptor.artifactError
        )
        let status = status(for: descriptor.status, artifact: artifact)
        let id =
            descriptor.id
            ?? stableID(
                kind: descriptor.kind,
                source: descriptor.source,
                artifactPath: artifactPath
            )

        return EvidenceReportSummary(
            id: id,
            kind: descriptor.kind,
            source: descriptor.source,
            artifact: artifact,
            status: status,
            counts: descriptor.counts,
            startedAt: descriptor.startedAt,
            completedAt: descriptor.completedAt,
            registeredAt: now(),
            metadata: EvidenceReportMetadataRedactor.redact(descriptor.metadata)
        )
    }

    private func normalizedArtifactPath(_ path: String, relativeTo baseURL: URL?) -> String {
        guard let baseURL, !path.hasPrefix("/") else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return
            baseURL
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
    }

    private func artifactReference(
        path: String,
        descriptorError: String?
    ) -> EvidenceReportArtifact {
        if let descriptorError, !descriptorError.isEmpty {
            return EvidenceReportArtifact(
                path: path,
                availability: .error,
                message: descriptorError
            )
        }

        guard fileManager.fileExists(atPath: path) else {
            return EvidenceReportArtifact(
                path: path,
                availability: .unavailable,
                message: "Artifact is not present at the registered path."
            )
        }

        return EvidenceReportArtifact(path: path, availability: .available)
    }

    private func status(
        for descriptorStatus: EvidenceReportStatus,
        artifact: EvidenceReportArtifact
    ) -> EvidenceReportStatus {
        switch artifact.availability {
        case .available:
            return descriptorStatus
        case .unavailable:
            return .unavailable
        case .error:
            return .error
        }
    }

    private func stableID(
        kind: EvidenceReportKind,
        source: String,
        artifactPath: String
    ) -> String {
        [kind.rawValue, source, artifactPath]
            .joined(separator: "|")
    }

    private func preferredSummary(
        _ existing: EvidenceReportSummary,
        _ incoming: EvidenceReportSummary
    ) -> EvidenceReportSummary {
        let existingRank = availabilityRank(existing.artifact.availability)
        let incomingRank = availabilityRank(incoming.artifact.availability)
        if incomingRank != existingRank {
            return incomingRank > existingRank ? incoming : existing
        }
        if incoming.registeredAt != existing.registeredAt {
            return incoming.registeredAt > existing.registeredAt ? incoming : existing
        }
        return Self.sortSummaries(existing, incoming) ? existing : incoming
    }

    private func availabilityRank(_ availability: EvidenceArtifactAvailability) -> Int {
        switch availability {
        case .available:
            return 3
        case .error:
            return 2
        case .unavailable:
            return 1
        }
    }

    private static func sortSummaries(
        _ lhs: EvidenceReportSummary,
        _ rhs: EvidenceReportSummary
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        if lhs.artifact.path != rhs.artifact.path {
            return lhs.artifact.path < rhs.artifact.path
        }
        return lhs.id < rhs.id
    }
}

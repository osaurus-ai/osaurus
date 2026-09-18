//
//  EvidenceReportRegistryService.swift
//  osaurus
//
//  In-memory registry over local evidence report descriptors.
//

import Foundation

public final class EvidenceReportRegistryService: @unchecked Sendable {
    private struct StoredReport {
        let summary: EvidenceReportSummary
        let localArtifactURL: URL
    }

    private static let unscopedProducer = "\u{0}unscoped"

    private var reportsByProducer: [String: [String: StoredReport]] = [:]
    private var nextGeneration: UInt64 = 0
    private let fileManager: FileManager
    private let now: () -> Date
    private let lock = NSLock()

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
        withLock {
            guard !descriptors.isEmpty else { return [] }
            let generation = advanceGenerationLocked()
            let registeredAt = now()
            var reports = reportsByProducer[Self.unscopedProducer] ?? [:]
            let stored = descriptors.map {
                makeStoredReport(
                    from: $0,
                    relativeTo: baseURL,
                    generation: generation,
                    registeredAt: registeredAt
                )
            }
            for report in stored {
                reports[report.summary.id] = report
            }
            reportsByProducer[Self.unscopedProducer] = reports
            return stored.map(\.summary)
        }
    }

    @discardableResult
    public func register(
        _ descriptor: EvidenceReportDescriptor,
        relativeTo baseURL: URL? = nil
    ) -> EvidenceReportSummary {
        register([descriptor], relativeTo: baseURL)[0]
    }

    @discardableResult
    public func reconcile(
        producer: String,
        descriptors: [EvidenceReportDescriptor],
        relativeTo baseURL: URL? = nil
    ) -> [EvidenceReportSummary] {
        let producer = normalizedProducer(producer)
        precondition(!producer.isEmpty, "Evidence report producer must not be empty.")

        return withLock {
            let generation = advanceGenerationLocked()
            let registeredAt = now()
            var replacement: [String: StoredReport] = [:]
            for descriptor in descriptors {
                let report = makeStoredReport(
                    from: descriptor,
                    relativeTo: baseURL,
                    generation: generation,
                    registeredAt: registeredAt
                )
                replacement[report.summary.id] = report
            }
            reportsByProducer[producer] = replacement
            return replacement.values.map(\.summary).sorted(by: Self.sortSummaries)
        }
    }

    public func list(_ filter: EvidenceReportFilter = EvidenceReportFilter()) -> [EvidenceReportSummary] {
        withLock {
            projectedReportsLocked().values
                .map(\.summary)
                .filter { filter.includes($0) }
                .sorted(by: Self.sortSummaries)
        }
    }

    public func list(
        producer: String,
        filter: EvidenceReportFilter = EvidenceReportFilter()
    ) -> [EvidenceReportSummary] {
        let producer = normalizedProducer(producer)
        return withLock {
            (reportsByProducer[producer] ?? [:]).values
                .map(\.summary)
                .filter { filter.includes($0) }
                .sorted(by: Self.sortSummaries)
        }
    }

    public func snapshot(_ filter: EvidenceReportFilter = EvidenceReportFilter()) -> EvidenceReportRegistrySnapshot {
        EvidenceReportRegistrySnapshot(reports: list(filter))
    }

    public func snapshot(
        producer: String,
        filter: EvidenceReportFilter = EvidenceReportFilter()
    ) -> EvidenceReportRegistrySnapshot {
        EvidenceReportRegistrySnapshot(reports: list(producer: producer, filter: filter))
    }

    public func localArtifactURL(
        forReportID reportID: String,
        producer: String? = nil
    ) -> URL? {
        withLock {
            if let producer {
                return reportsByProducer[normalizedProducer(producer)]?[reportID]?.localArtifactURL
            }
            return projectedReportsLocked()[reportID]?.localArtifactURL
        }
    }

    public func removeAll() {
        withLock {
            reportsByProducer.removeAll()
        }
    }

    public func remove(ids: Set<String>) {
        withLock {
            for producer in Array(reportsByProducer.keys) {
                for id in ids {
                    reportsByProducer[producer]?.removeValue(forKey: id)
                }
            }
            reportsByProducer = reportsByProducer.filter { !$0.value.isEmpty }
        }
    }

    private func makeStoredReport(
        from descriptor: EvidenceReportDescriptor,
        relativeTo baseURL: URL?,
        generation: UInt64,
        registeredAt: Date
    ) -> StoredReport {
        let localArtifactURL = normalizedArtifactURL(descriptor.artifactPath, relativeTo: baseURL)
        let identity = artifactIdentity(
            descriptor: descriptor,
            localArtifactURL: localArtifactURL
        )
        let id = reportID(for: descriptor, artifactIdentity: identity)
        let locator = EvidenceReportIdentity.normalizedLocator(descriptor.artifactLocator ?? "")
            ?? EvidenceReportIdentity.opaqueLocator(
                seed: "\(id)|\(identity)",
                pathExtension: localArtifactURL.pathExtension
            )
        let artifact = artifactReference(
            locator: locator,
            localArtifactURL: localArtifactURL,
            descriptorError: descriptor.artifactError
        )
        let resolvedStatus = status(for: descriptor.status, artifact: artifact)

        return StoredReport(
            summary: EvidenceReportSummary(
                id: id,
                kind: descriptor.kind,
                source: descriptor.source,
                artifact: artifact,
                status: resolvedStatus,
                counts: normalizedCounts(
                    descriptor.counts,
                    descriptorStatus: descriptor.status,
                    resolvedStatus: resolvedStatus
                ),
                startedAt: descriptor.startedAt,
                completedAt: descriptor.completedAt,
                registeredAt: registeredAt,
                generation: generation,
                metadata: EvidenceReportMetadataRedactor.redact(descriptor.metadata)
            ),
            localArtifactURL: localArtifactURL
        )
    }

    private func normalizedArtifactURL(_ path: String, relativeTo baseURL: URL?) -> URL {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.lowercased().hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            return url.standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let baseURL {
            return baseURL.appendingPathComponent(path).standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func artifactIdentity(
        descriptor: EvidenceReportDescriptor,
        localArtifactURL: URL
    ) -> String {
        if let digest = EvidenceReportIdentity.contentDigest(at: localArtifactURL, fileManager: fileManager) {
            return "sha256:\(digest)"
        }
        if let locator = EvidenceReportIdentity.normalizedLocator(descriptor.artifactLocator ?? "") {
            return "locator:\(locator)"
        }
        let fileName = EvidenceReportIdentity.normalizedLogicalValue(localArtifactURL.lastPathComponent)
        return "name:\(fileName)"
    }

    private func reportID(
        for descriptor: EvidenceReportDescriptor,
        artifactIdentity: String
    ) -> String {
        if let requestedID = descriptor.id.map(EvidenceReportIdentity.normalizedLogicalValue),
            !requestedID.isEmpty,
            !EvidenceReportIdentity.containsAbsoluteLocalPath(requestedID) {
            return requestedID
        }
        let seed = [descriptor.kind.rawValue, descriptor.source, artifactIdentity]
            .map(EvidenceReportIdentity.normalizedLogicalValue)
            .joined(separator: "|")
        return "evidence-report:\(EvidenceReportIdentity.digest(seed))"
    }

    private func artifactReference(
        locator: String,
        localArtifactURL: URL,
        descriptorError: String?
    ) -> EvidenceReportArtifact {
        if let descriptorError, !descriptorError.isEmpty {
            return EvidenceReportArtifact(
                path: locator,
                availability: .error,
                message: descriptorError
            )
        }

        guard fileManager.fileExists(atPath: localArtifactURL.path) else {
            return EvidenceReportArtifact(
                path: locator,
                availability: .unavailable,
                message: "Artifact is not present at the registered path."
            )
        }

        return EvidenceReportArtifact(path: locator, availability: .available)
    }

    private func status(
        for descriptorStatus: EvidenceReportStatus,
        artifact: EvidenceReportArtifact
    ) -> EvidenceReportStatus {
        switch artifact.availability {
        case .available:
            return descriptorStatus
        case .unavailable:
            switch descriptorStatus {
            case .failed, .error, .blocked, .partial:
                return descriptorStatus
            case .passed, .unavailable, .unknown:
                return .unavailable
            }
        case .error:
            switch descriptorStatus {
            case .failed, .error, .blocked, .partial:
                return descriptorStatus
            case .passed, .unavailable, .unknown:
                return .error
            }
        }
    }

    private func normalizedCounts(
        _ counts: EvidenceReportCounts,
        descriptorStatus: EvidenceReportStatus,
        resolvedStatus: EvidenceReportStatus
    ) -> EvidenceReportCounts {
        guard descriptorStatus != resolvedStatus else { return counts }

        let normalizedTotal = max(
            1,
            max(
                counts.total,
                counts.passed + counts.failed + counts.errored + counts.skipped
                    + counts.blocked + counts.warnings
            )
        )
        var resolved = EvidenceReportCounts(total: normalizedTotal)
        switch resolvedStatus {
        case .failed:
            resolved.failed = normalizedTotal
        case .error:
            resolved.errored = normalizedTotal
        case .blocked:
            resolved.blocked = normalizedTotal
        case .unavailable:
            resolved.skipped = normalizedTotal
        case .partial:
            resolved.warnings = normalizedTotal
        case .passed:
            resolved.passed = normalizedTotal
        case .unknown:
            resolved.total = 0
        }
        return resolved
    }

    private func projectedReportsLocked() -> [String: StoredReport] {
        var projected: [String: (producer: String, report: StoredReport)] = [:]
        for (producer, reports) in reportsByProducer {
            for (id, report) in reports {
                guard let existing = projected[id] else {
                    projected[id] = (producer, report)
                    continue
                }
                if report.summary.generation > existing.report.summary.generation
                    || (report.summary.generation == existing.report.summary.generation
                        && producer > existing.producer) {
                    projected[id] = (producer, report)
                }
            }
        }
        return projected.mapValues(\.report)
    }

    private func advanceGenerationLocked() -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }

    private func normalizedProducer(_ producer: String) -> String {
        EvidenceReportIdentity.normalizedLogicalValue(producer)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
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

//
//  EvidenceReportRegistry.swift
//  osaurus
//
//  Typed summaries for locally-produced eval, benchmark, runtime, live-proof,
//  run-trace, and provider evidence artifacts. The registry is intentionally
//  a projection over existing files; it does not own or move artifacts.
//

import Foundation

public enum EvidenceReportKind: String, Codable, CaseIterable, Hashable, Sendable {
    case eval
    case benchmark
    case runtime
    case liveProof = "live_proof"
    case runTrace = "run_trace"
    case provider
    case custom
}

public enum EvidenceReportStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case passed
    case failed
    case partial
    case blocked
    case unavailable
    case error
    case unknown
}

public enum EvidenceArtifactAvailability: String, Codable, CaseIterable, Hashable, Sendable {
    case available
    case unavailable
    case error
}

public struct EvidenceReportCounts: Codable, Equatable, Hashable, Sendable {
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var errored: Int
    public var skipped: Int
    public var blocked: Int
    public var warnings: Int

    public init(
        total: Int = 0,
        passed: Int = 0,
        failed: Int = 0,
        errored: Int = 0,
        skipped: Int = 0,
        blocked: Int = 0,
        warnings: Int = 0
    ) {
        self.total = max(0, total)
        self.passed = max(0, passed)
        self.failed = max(0, failed)
        self.errored = max(0, errored)
        self.skipped = max(0, skipped)
        self.blocked = max(0, blocked)
        self.warnings = max(0, warnings)
    }
}

public struct EvidenceReportArtifact: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var availability: EvidenceArtifactAvailability
    public var message: String?

    public init(
        path: String,
        availability: EvidenceArtifactAvailability,
        message: String? = nil
    ) {
        self.path = path
        self.availability = availability
        self.message = message
    }
}

public struct EvidenceReportDescriptor: Codable, Equatable, Sendable {
    public var id: String?
    public var kind: EvidenceReportKind
    public var source: String
    public var artifactPath: String
    public var status: EvidenceReportStatus
    public var counts: EvidenceReportCounts
    public var startedAt: Date?
    public var completedAt: Date?
    public var metadata: [String: String]
    public var artifactError: String?

    public init(
        id: String? = nil,
        kind: EvidenceReportKind,
        source: String,
        artifactPath: String,
        status: EvidenceReportStatus = .unknown,
        counts: EvidenceReportCounts = EvidenceReportCounts(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        metadata: [String: String] = [:],
        artifactError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.artifactPath = artifactPath
        self.status = status
        self.counts = counts
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.metadata = metadata
        self.artifactError = artifactError
    }

    public init(
        id: String? = nil,
        kind: EvidenceReportKind,
        source: String,
        artifactURL: URL,
        status: EvidenceReportStatus = .unknown,
        counts: EvidenceReportCounts = EvidenceReportCounts(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        metadata: [String: String] = [:],
        artifactError: String? = nil
    ) {
        self.init(
            id: id,
            kind: kind,
            source: source,
            artifactPath: artifactURL.path,
            status: status,
            counts: counts,
            startedAt: startedAt,
            completedAt: completedAt,
            metadata: metadata,
            artifactError: artifactError
        )
    }
}

public struct EvidenceReportSummary: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var kind: EvidenceReportKind
    public var source: String
    public var artifact: EvidenceReportArtifact
    public var status: EvidenceReportStatus
    public var counts: EvidenceReportCounts
    public var startedAt: Date?
    public var completedAt: Date?
    public var registeredAt: Date
    public var metadata: [String: String]

    public init(
        id: String,
        kind: EvidenceReportKind,
        source: String,
        artifact: EvidenceReportArtifact,
        status: EvidenceReportStatus,
        counts: EvidenceReportCounts,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        registeredAt: Date,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.artifact = artifact
        self.status = status
        self.counts = counts
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.registeredAt = registeredAt
        self.metadata = metadata
    }

    public func stableJSONData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: prettyPrinted)
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

public struct EvidenceReportFilter: Equatable, Sendable {
    public var kinds: Set<EvidenceReportKind>
    public var sources: Set<String>
    public var statuses: Set<EvidenceReportStatus>
    public var artifactAvailability: Set<EvidenceArtifactAvailability>

    public init(
        kinds: Set<EvidenceReportKind> = [],
        sources: Set<String> = [],
        statuses: Set<EvidenceReportStatus> = [],
        artifactAvailability: Set<EvidenceArtifactAvailability> = []
    ) {
        self.kinds = kinds
        self.sources = sources
        self.statuses = statuses
        self.artifactAvailability = artifactAvailability
    }

    public func includes(_ summary: EvidenceReportSummary) -> Bool {
        if !kinds.isEmpty, !kinds.contains(summary.kind) {
            return false
        }
        if !sources.isEmpty, !sources.contains(summary.source) {
            return false
        }
        if !statuses.isEmpty, !statuses.contains(summary.status) {
            return false
        }
        if !artifactAvailability.isEmpty,
            !artifactAvailability.contains(summary.artifact.availability)
        {
            return false
        }
        return true
    }
}

public enum EvidenceReportMetadataRedactor {
    private static let redactedValue = "<redacted>"

    public static func redact(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { output, element in
            let key = element.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            output[key] = redactedValue(forKey: key, value: element.value)
        }
    }

    public static func redactedValue(forKey key: String, value: String) -> String {
        if isSensitiveKey(key) || looksSensitive(value) {
            return redactedValue
        }
        return value
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized =
            key
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")

        if normalized == "token" || normalized == "key" {
            return true
        }

        return [
            "apikey",
            "authorization",
            "authtoken",
            "bearer",
            "clientsecret",
            "credential",
            "password",
            "privatekey",
            "refreshtoken",
            "secret",
            "sessiontoken",
            "accesstoken",
        ].contains { normalized.contains($0) }
    }

    private static func looksSensitive(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if lowercased.contains("bearer ")
            || lowercased.contains("token=")
            || lowercased.contains("api_key=")
            || lowercased.contains("apikey=")
            || lowercased.contains("password=")
            || lowercased.contains("secret=")
        {
            return true
        }

        return [
            "sk-",
            "ghp_",
            "github_pat_",
            "xoxb-",
            "xoxp-",
        ].contains { lowercased.hasPrefix($0) }
    }
}

public struct EvidenceReportRegistrySnapshot: Codable, Equatable, Sendable {
    public var reports: [EvidenceReportSummary]

    public init(reports: [EvidenceReportSummary]) {
        self.reports = reports
    }

    public func stableJSONData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: prettyPrinted)
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

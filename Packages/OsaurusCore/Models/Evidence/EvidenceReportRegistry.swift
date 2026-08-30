//
//  EvidenceReportRegistry.swift
//  osaurus
//
//  Typed summaries for locally-produced eval, benchmark, runtime, live-proof,
//  run-trace, and provider evidence artifacts. The registry is intentionally
//  a projection over existing files; it does not own or move artifacts.
//

import CryptoKit
import Foundation

public enum EvidenceReportKind: String, Codable, CaseIterable, Hashable, Sendable {
    case eval
    case benchmark
    case runtime
    case liveProof = "live_proof"
    case runTrace = "run_trace"
    case provider
    case modelCompatibility = "model_compatibility"
    case cache
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

enum EvidenceReportIdentity {
    static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func contentDigest(at url: URL, fileManager: FileManager = .default) -> String? {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedLogicalValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
    }

    static func normalizedLocator(_ locator: String) -> String? {
        let normalized = normalizedLogicalValue(locator)
        guard
            !normalized.isEmpty,
            !normalized.hasPrefix("/"),
            URL(string: normalized)?.scheme == nil,
            !looksLikeWindowsAbsolutePath(normalized)
        else {
            return nil
        }

        var components: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return nil
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    static func opaqueLocator(seed: String, pathExtension: String = "") -> String {
        let suffix = normalizedPathExtension(pathExtension).map { ".\($0)" } ?? ""
        return "artifacts/\(digest(seed))\(suffix)"
    }

    static func containsAbsoluteLocalPath(_ value: String) -> Bool {
        let normalized = normalizedLogicalValue(value)
        if normalized.hasPrefix("/") || normalized.lowercased().contains("file://") {
            return true
        }
        if looksLikeWindowsAbsolutePath(normalized) {
            return true
        }
        return normalized.split(whereSeparator: { $0 == "|" || $0 == "," }).contains {
            let component = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return component.hasPrefix("/") || looksLikeWindowsAbsolutePath(component)
        }
    }

    private static func normalizedPathExtension(_ value: String) -> String? {
        let normalized = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return normalized.isEmpty ? nil : normalized
    }

    private static func looksLikeWindowsAbsolutePath(_ value: String) -> Bool {
        guard value.count >= 3 else { return false }
        let characters = Array(value)
        return characters[0].isLetter && characters[1] == ":" && characters[2] == "/"
    }
}

public struct EvidenceReportArtifact: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var availability: EvidenceArtifactAvailability
    public var message: String?
    private var machineLocalPath: String?

    public init(
        path: String,
        availability: EvidenceArtifactAvailability,
        message: String? = nil
    ) {
        if let locator = EvidenceReportIdentity.normalizedLocator(path) {
            self.path = locator
            machineLocalPath = nil
        } else {
            let url: URL?
            if path.lowercased().hasPrefix("file://") {
                url = URL(string: path)?.standardizedFileURL
            } else if EvidenceReportIdentity.containsAbsoluteLocalPath(path) {
                url = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                url = nil
            }
            self.path = EvidenceReportIdentity.opaqueLocator(
                seed: path,
                pathExtension: url?.pathExtension ?? URL(fileURLWithPath: path).pathExtension
            )
            machineLocalPath = url?.path
        }
        self.availability = availability
        self.message = message
    }

    public func resolvedURL(relativeTo directoryURL: URL) -> URL? {
        if let machineLocalPath {
            return URL(fileURLWithPath: machineLocalPath).standardizedFileURL
        }
        guard let locator = EvidenceReportIdentity.normalizedLocator(path) else {
            return nil
        }
        return directoryURL.appendingPathComponent(locator).standardizedFileURL
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case availability
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            availability: try container.decode(EvidenceArtifactAvailability.self, forKey: .availability),
            message: try container.decodeIfPresent(String.self, forKey: .message)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(availability, forKey: .availability)
        try container.encodeIfPresent(message, forKey: .message)
    }

    public static func == (lhs: EvidenceReportArtifact, rhs: EvidenceReportArtifact) -> Bool {
        lhs.path == rhs.path
            && lhs.availability == rhs.availability
            && lhs.message == rhs.message
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(availability)
        hasher.combine(message)
    }
}

public struct EvidenceReportDescriptor: Codable, Equatable, Sendable {
    public var id: String?
    public var kind: EvidenceReportKind
    public var source: String
    public var artifactPath: String
    public var artifactLocator: String?
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
        artifactLocator: String? = nil,
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
        self.artifactLocator = artifactLocator
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
        artifactLocator: String? = nil,
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
            artifactLocator: artifactLocator,
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
    public var generation: UInt64
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
        generation: UInt64 = 0,
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
        self.generation = generation
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case source
        case artifact
        case status
        case counts
        case startedAt
        case completedAt
        case registeredAt
        case generation
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(EvidenceReportKind.self, forKey: .kind)
        source = try container.decode(String.self, forKey: .source)
        artifact = try container.decode(EvidenceReportArtifact.self, forKey: .artifact)
        status = try container.decode(EvidenceReportStatus.self, forKey: .status)
        counts = try container.decodeIfPresent(EvidenceReportCounts.self, forKey: .counts) ?? EvidenceReportCounts()
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        registeredAt = try container.decode(Date.self, forKey: .registeredAt)
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(source, forKey: .source)
        try container.encode(artifact, forKey: .artifact)
        try container.encode(status, forKey: .status)
        try container.encode(counts, forKey: .counts)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(registeredAt, forKey: .registeredAt)
        try container.encode(generation, forKey: .generation)
        try container.encode(metadata, forKey: .metadata)
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
            !artifactAvailability.contains(summary.artifact.availability) {
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
        if isSensitiveKey(key) || looksSensitive(value) || EvidenceReportIdentity.containsAbsoluteLocalPath(value) {
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
            || lowercased.contains("secret=") {
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
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var reports: [EvidenceReportSummary]

    public init(
        schemaVersion: Int = EvidenceReportRegistrySnapshot.currentSchemaVersion,
        reports: [EvidenceReportSummary]
    ) {
        self.schemaVersion = schemaVersion
        self.reports = reports
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case reports
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        reports = try container.decodeIfPresent([EvidenceReportSummary].self, forKey: .reports) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(reports, forKey: .reports)
    }

    public func stableJSONData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: prettyPrinted)
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

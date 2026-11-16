//
//  DocumentSecurityMetadata.swift
//  osaurus
//
//  Security and provenance facts attached to structured document parse
//  results. This is intentionally descriptive rather than policy-enforcing:
//  adapters record what they inspected, what they could not inspect, and any
//  active/external content they found so later tool and artifact layers can
//  make fail-closed decisions with format-neutral data.
//

import Foundation

public enum DocumentActiveContentType: String, Codable, CaseIterable, Hashable, Sendable {
    case macro
    case script
    case embeddedFile
    case externalReference
    case formula
    case remoteTemplate
    case media
    case unknown
}

public struct DocumentExternalReference: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hyperlink
        case image
        case stylesheet
        case script
        case media
        case remoteTemplate
        case packageRelationship
        case unknown
    }

    public let kind: Kind
    public let urlString: String
    public let anchorId: String?
    public let relationshipId: String?

    public init(
        kind: Kind,
        urlString: String,
        anchorId: String? = nil,
        relationshipId: String? = nil
    ) {
        self.kind = kind
        self.urlString = urlString
        self.anchorId = anchorId
        self.relationshipId = relationshipId
    }
}

public struct DocumentSecurityFinding: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case activeContent
        case encryptedContent
        case externalReference
        case embeddedFile
        case macro
        case script
        case formula
        case malformedContent
        /// Text present in the file but not visible to a human reader
        /// (drawn off-page or at an invisible size).
        case hiddenContent
        case truncatedContent
        case unsupportedFeature
        case integrityUnavailable
        case permissionRestriction
        case redaction
        case unknown
    }

    public enum Severity: String, Codable, Comparable, Sendable {
        case informational
        case low
        case medium
        case high
        case critical

        private var rank: Int {
            switch self {
            case .informational: return 0
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            case .critical: return 4
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public let kind: Kind
    public let severity: Severity
    public let anchorId: String?
    public let message: String
    public let metadata: [String: String]

    public init(
        kind: Kind,
        severity: Severity,
        anchorId: String? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind
        self.severity = severity
        self.anchorId = anchorId
        self.message = message
        self.metadata = metadata
    }
}

public struct DocumentSecurityMetadata: Codable, Equatable, Sendable {
    public enum InspectionStatus: String, Codable, Sendable {
        case inspected
        case partiallyInspected
        case notInspected
        case failed
    }

    public enum SourceTrust: String, Codable, Sendable {
        case userSelectedLocalFile
        case generatedArtifact
        case pluginProvided
        case remoteDownload
        case pastedContent
        case unknown
    }

    public let inspectionStatus: InspectionStatus
    public let sourceTrust: SourceTrust
    public let formatId: String
    public let fileExtension: String?
    public let uti: String?
    public let declaredMimeType: String?
    public let sha256: String?
    public let isEncrypted: Bool?
    public let activeContentTypes: Set<DocumentActiveContentType>
    public let externalReferences: [DocumentExternalReference]
    public let findings: [DocumentSecurityFinding]
    public let inspectedAt: Date

    public var hasActiveContent: Bool {
        !activeContentTypes.isEmpty || !externalReferences.isEmpty
    }

    public var maximumSeverity: DocumentSecurityFinding.Severity? {
        findings.map(\.severity).max()
    }

    public init(
        inspectionStatus: InspectionStatus,
        sourceTrust: SourceTrust = .unknown,
        formatId: String,
        fileExtension: String? = nil,
        uti: String? = nil,
        declaredMimeType: String? = nil,
        sha256: String? = nil,
        isEncrypted: Bool? = nil,
        activeContentTypes: Set<DocumentActiveContentType> = [],
        externalReferences: [DocumentExternalReference] = [],
        findings: [DocumentSecurityFinding] = [],
        inspectedAt: Date = Date()
    ) {
        self.inspectionStatus = inspectionStatus
        self.sourceTrust = sourceTrust
        self.formatId = formatId
        self.fileExtension = fileExtension
        self.uti = uti
        self.declaredMimeType = declaredMimeType
        self.sha256 = sha256
        self.isEncrypted = isEncrypted
        self.activeContentTypes = activeContentTypes
        self.externalReferences = externalReferences
        self.findings = findings
        self.inspectedAt = inspectedAt
    }

    public static func notInspected(
        formatId: String,
        fileExtension: String? = nil,
        sourceTrust: SourceTrust = .unknown
    ) -> DocumentSecurityMetadata {
        DocumentSecurityMetadata(
            inspectionStatus: .notInspected,
            sourceTrust: sourceTrust,
            formatId: formatId,
            fileExtension: fileExtension
        )
    }
}

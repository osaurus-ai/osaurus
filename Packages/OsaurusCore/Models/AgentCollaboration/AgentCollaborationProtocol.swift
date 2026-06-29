//
//  AgentCollaborationProtocol.swift
//  osaurus
//
//  Protocol-level contracts for future local + remote agent teams.
//

import Foundation

public enum AgentCollaborationProtocolContract {
    public static let schema = "osaurus.agent-collaboration.v1"
    public static let version = 1
}

public enum AgentCollaborationParticipantType: String, Codable, Sendable, Equatable, CaseIterable {
    case local
    case remote
}

public struct AgentCollaborationParticipant: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var type: AgentCollaborationParticipantType
    public var displayName: String
    public var address: String?
    public var endpoint: String?

    public init(
        id: String,
        type: AgentCollaborationParticipantType,
        displayName: String,
        address: String? = nil,
        endpoint: String? = nil
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.address = address
        self.endpoint = endpoint
    }
}

public struct AgentCollaborationCapability: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var version: Int
    public var metadata: [String: String]

    public init(name: String, version: Int = 1, metadata: [String: String] = [:]) {
        self.name = name
        self.version = version
        self.metadata = metadata
    }
}

public struct AgentCollaborationCapabilities: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var capabilities: [AgentCollaborationCapability]
    public var maxPayloadBytes: Int?
    public var supportsStreamingReplies: Bool

    public init(
        protocolVersion: Int = AgentCollaborationProtocolContract.version,
        capabilities: [AgentCollaborationCapability],
        maxPayloadBytes: Int? = nil,
        supportsStreamingReplies: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = Self.normalized(capabilities)
        self.maxPayloadBytes = maxPayloadBytes
        self.supportsStreamingReplies = supportsStreamingReplies
    }

    public var names: [String] {
        capabilities.map(\.name)
    }

    public func supports(_ name: String, minimumVersion: Int = 1) -> Bool {
        capabilities.contains { capability in
            capability.name == name && capability.version >= minimumVersion
        }
    }

    public func commonCapabilities(with other: AgentCollaborationCapabilities) -> [AgentCollaborationCapability] {
        let otherByName = Dictionary(uniqueKeysWithValues: other.capabilities.map { ($0.name, $0) })
        let shared = capabilities.compactMap { capability -> AgentCollaborationCapability? in
            guard let otherCapability = otherByName[capability.name] else { return nil }
            return AgentCollaborationCapability(
                name: capability.name,
                version: min(capability.version, otherCapability.version),
                metadata: [:]
            )
        }
        return Self.normalized(shared)
    }

    public static let baselineRequiredNames = [
        "collaboration.correlation",
        "collaboration.provenance",
        "collaboration.request",
        "collaboration.handoff",
        "collaboration.reply",
    ]

    public static func localDefault() -> AgentCollaborationCapabilities {
        AgentCollaborationCapabilities(
            capabilities: [
                AgentCollaborationCapability(name: "agent.local"),
                AgentCollaborationCapability(name: "collaboration.correlation"),
                AgentCollaborationCapability(name: "collaboration.provenance"),
                AgentCollaborationCapability(name: "collaboration.request"),
                AgentCollaborationCapability(name: "collaboration.handoff"),
                AgentCollaborationCapability(name: "collaboration.reply"),
                AgentCollaborationCapability(name: "collaboration.failure-diagnostics"),
            ],
            supportsStreamingReplies: false
        )
    }

    public static func remoteDefault() -> AgentCollaborationCapabilities {
        AgentCollaborationCapabilities(
            capabilities: [
                AgentCollaborationCapability(name: "agent.remote"),
                AgentCollaborationCapability(name: "collaboration.correlation"),
                AgentCollaborationCapability(name: "collaboration.provenance"),
                AgentCollaborationCapability(name: "collaboration.request"),
                AgentCollaborationCapability(name: "collaboration.handoff"),
                AgentCollaborationCapability(name: "collaboration.reply"),
                AgentCollaborationCapability(name: "collaboration.failure-diagnostics"),
            ],
            supportsStreamingReplies: false
        )
    }

    private static func normalized(_ capabilities: [AgentCollaborationCapability]) -> [AgentCollaborationCapability] {
        var bestByName: [String: AgentCollaborationCapability] = [:]
        for capability in capabilities {
            guard !capability.name.isEmpty else { continue }
            if let existing = bestByName[capability.name], existing.version >= capability.version {
                continue
            }
            bestByName[capability.name] = capability
        }
        return bestByName.values.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.version < rhs.version
            }
            return lhs.name < rhs.name
        }
    }
}

public struct AgentCollaborationNegotiationResult: Codable, Sendable, Equatable {
    public var initiator: AgentCollaborationParticipant
    public var responder: AgentCollaborationParticipant
    public var protocolVersion: Int
    public var commonCapabilities: [AgentCollaborationCapability]
    public var missingRequiredCapabilities: [String]

    public init(
        initiator: AgentCollaborationParticipant,
        responder: AgentCollaborationParticipant,
        protocolVersion: Int,
        commonCapabilities: [AgentCollaborationCapability],
        missingRequiredCapabilities: [String]
    ) {
        self.initiator = initiator
        self.responder = responder
        self.protocolVersion = protocolVersion
        self.commonCapabilities = commonCapabilities
        self.missingRequiredCapabilities = missingRequiredCapabilities.sorted()
    }

    public var isCompatible: Bool {
        missingRequiredCapabilities.isEmpty && protocolVersion == AgentCollaborationProtocolContract.version
    }
}

public enum AgentCollaborationNegotiator {
    public static func negotiate(
        initiator: AgentCollaborationParticipant,
        initiatorCapabilities: AgentCollaborationCapabilities,
        responder: AgentCollaborationParticipant,
        responderCapabilities: AgentCollaborationCapabilities,
        requiredCapabilities: [String] = AgentCollaborationCapabilities.baselineRequiredNames
    ) -> AgentCollaborationNegotiationResult {
        let common = initiatorCapabilities.commonCapabilities(with: responderCapabilities)
        let commonNames = Set(common.map(\.name))
        let missing =
            requiredCapabilities
            .filter { !commonNames.contains($0) }
            .sorted()
        let version = min(initiatorCapabilities.protocolVersion, responderCapabilities.protocolVersion)
        return AgentCollaborationNegotiationResult(
            initiator: initiator,
            responder: responder,
            protocolVersion: version,
            commonCapabilities: common,
            missingRequiredCapabilities: missing
        )
    }
}

public struct AgentCollaborationProvenance: Codable, Sendable, Equatable {
    public var origin: AgentCollaborationParticipant
    public var sessionId: String?
    public var parentEnvelopeId: UUID?
    public var transport: String?
    public var hops: [String]

    public init(
        origin: AgentCollaborationParticipant,
        sessionId: String? = nil,
        parentEnvelopeId: UUID? = nil,
        transport: String? = nil,
        hops: [String] = []
    ) {
        self.origin = origin
        self.sessionId = sessionId
        self.parentEnvelopeId = parentEnvelopeId
        self.transport = transport
        self.hops = hops
    }
}

public enum AgentCollaborationEventType: String, Codable, Sendable, Equatable {
    case capabilities = "capabilities"
    case request = "request"
    case handoffRequest = "handoff.request"
    case reply = "reply"
    case failure = "failure"
}

public enum AgentCollaborationPriority: String, Codable, Sendable, Equatable {
    case low
    case normal
    case high
}

public struct AgentCollaborationRequest: Codable, Sendable, Equatable {
    public var title: String
    public var objective: String
    public var contextSummary: String?
    public var requiredCapabilities: [String]
    public var priority: AgentCollaborationPriority
    public var metadata: [String: String]

    public init(
        title: String,
        objective: String,
        contextSummary: String? = nil,
        requiredCapabilities: [String] = [],
        priority: AgentCollaborationPriority = .normal,
        metadata: [String: String] = [:]
    ) {
        self.title = title
        self.objective = objective
        self.contextSummary = contextSummary
        self.requiredCapabilities = requiredCapabilities.sorted()
        self.priority = priority
        self.metadata = metadata
    }
}

public struct AgentCollaborationHandoffRequest: Codable, Sendable, Equatable {
    public var handoffId: UUID
    public var reason: String
    public var summary: String
    public var artifactReferences: [String]
    public var requiredCapabilities: [String]
    public var metadata: [String: String]

    public init(
        handoffId: UUID = UUID(),
        reason: String,
        summary: String,
        artifactReferences: [String] = [],
        requiredCapabilities: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.handoffId = handoffId
        self.reason = reason
        self.summary = summary
        self.artifactReferences = artifactReferences.sorted()
        self.requiredCapabilities = requiredCapabilities.sorted()
        self.metadata = metadata
    }
}

public enum AgentCollaborationReplyStatus: String, Codable, Sendable, Equatable {
    case accepted
    case rejected
    case completed
}

public struct AgentCollaborationReply: Codable, Sendable, Equatable {
    public var inReplyToEnvelopeId: UUID
    public var status: AgentCollaborationReplyStatus
    public var message: String?
    public var acceptedCapabilities: [String]
    public var diagnostics: AgentCollaborationFailureDiagnostic?

    public init(
        inReplyToEnvelopeId: UUID,
        status: AgentCollaborationReplyStatus,
        message: String? = nil,
        acceptedCapabilities: [String] = [],
        diagnostics: AgentCollaborationFailureDiagnostic? = nil
    ) {
        self.inReplyToEnvelopeId = inReplyToEnvelopeId
        self.status = status
        self.message = message
        self.acceptedCapabilities = acceptedCapabilities.sorted()
        self.diagnostics = diagnostics
    }
}

public enum AgentCollaborationFailureSeverity: String, Codable, Sendable, Equatable {
    case info
    case warning
    case error
}

public struct AgentCollaborationFailureDiagnostic: Codable, Sendable, Equatable, Error {
    public var code: String
    public var severity: AgentCollaborationFailureSeverity
    public var message: String
    public var retryable: Bool
    public var relatedEnvelopeId: UUID?
    public var details: [String: String]

    public init(
        code: String,
        severity: AgentCollaborationFailureSeverity = .error,
        message: String,
        retryable: Bool,
        relatedEnvelopeId: UUID? = nil,
        details: [String: String] = [:]
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.retryable = retryable
        self.relatedEnvelopeId = relatedEnvelopeId
        self.details = details
    }
}

public enum AgentCollaborationEvent: Sendable, Equatable {
    case capabilities(AgentCollaborationCapabilities)
    case request(AgentCollaborationRequest)
    case handoffRequest(AgentCollaborationHandoffRequest)
    case reply(AgentCollaborationReply)
    case failure(AgentCollaborationFailureDiagnostic)

    public var type: AgentCollaborationEventType {
        switch self {
        case .capabilities:
            return .capabilities
        case .request:
            return .request
        case .handoffRequest:
            return .handoffRequest
        case .reply:
            return .reply
        case .failure:
            return .failure
        }
    }
}

extension AgentCollaborationEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(AgentCollaborationEventType.self, forKey: .type)
        switch type {
        case .capabilities:
            self = .capabilities(try container.decode(AgentCollaborationCapabilities.self, forKey: .payload))
        case .request:
            self = .request(try container.decode(AgentCollaborationRequest.self, forKey: .payload))
        case .handoffRequest:
            self = .handoffRequest(try container.decode(AgentCollaborationHandoffRequest.self, forKey: .payload))
        case .reply:
            self = .reply(try container.decode(AgentCollaborationReply.self, forKey: .payload))
        case .failure:
            self = .failure(try container.decode(AgentCollaborationFailureDiagnostic.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        switch self {
        case let .capabilities(payload):
            try container.encode(payload, forKey: .payload)
        case let .request(payload):
            try container.encode(payload, forKey: .payload)
        case let .handoffRequest(payload):
            try container.encode(payload, forKey: .payload)
        case let .reply(payload):
            try container.encode(payload, forKey: .payload)
        case let .failure(payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

public struct AgentCollaborationEnvelope: Codable, Sendable, Equatable, Identifiable {
    public var schema: String
    public var id: UUID
    public var correlationId: String
    public var createdAt: Date
    public var sender: AgentCollaborationParticipant
    public var recipient: AgentCollaborationParticipant?
    public var provenance: AgentCollaborationProvenance
    public var event: AgentCollaborationEvent

    public init(
        schema: String = AgentCollaborationProtocolContract.schema,
        id: UUID = UUID(),
        correlationId: String = UUID().uuidString,
        createdAt: Date = Date(),
        sender: AgentCollaborationParticipant,
        recipient: AgentCollaborationParticipant? = nil,
        provenance: AgentCollaborationProvenance? = nil,
        event: AgentCollaborationEvent
    ) {
        self.schema = schema
        self.id = id
        self.correlationId = correlationId
        self.createdAt = createdAt
        self.sender = sender
        self.recipient = recipient
        self.provenance = provenance ?? AgentCollaborationProvenance(origin: sender)
        self.event = event
    }
}

public enum AgentCollaborationWireFormat {
    public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder.osaurusCanonical(prettyPrinted: prettyPrinted)
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

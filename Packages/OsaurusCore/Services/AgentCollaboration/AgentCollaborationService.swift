//
//  AgentCollaborationService.swift
//  osaurus
//
//  Local-only service and in-memory transport for proving the collaboration
//  contract before any team UI or network bridge consumes it.
//

import Foundation

public protocol AgentCollaborationTransport: Sendable {
    func send(_ envelope: AgentCollaborationEnvelope) async throws
    func envelopes(for participant: AgentCollaborationParticipant) async -> [AgentCollaborationEnvelope]
    func allEnvelopes() async -> [AgentCollaborationEnvelope]
}

public actor AgentCollaborationInMemoryTransport: AgentCollaborationTransport {
    private var sentEnvelopes: [AgentCollaborationEnvelope] = []
    private var nextSendFailure: AgentCollaborationFailureDiagnostic?

    public init() {}

    public func failNextSend(with diagnostic: AgentCollaborationFailureDiagnostic) {
        nextSendFailure = diagnostic
    }

    public func send(_ envelope: AgentCollaborationEnvelope) async throws {
        if let diagnostic = nextSendFailure {
            nextSendFailure = nil
            throw diagnostic
        }
        sentEnvelopes.append(envelope)
    }

    public func envelopes(for participant: AgentCollaborationParticipant) async -> [AgentCollaborationEnvelope] {
        sentEnvelopes.filter { envelope in
            envelope.recipient?.id == participant.id || envelope.sender.id == participant.id
        }
    }

    public func allEnvelopes() async -> [AgentCollaborationEnvelope] {
        sentEnvelopes
    }
}

public actor AgentCollaborationService {
    private let transport: any AgentCollaborationTransport
    private var registry: [String: RegisteredParticipant] = [:]

    public init(transport: any AgentCollaborationTransport = AgentCollaborationInMemoryTransport()) {
        self.transport = transport
    }

    public func register(
        participant: AgentCollaborationParticipant,
        capabilities: AgentCollaborationCapabilities
    ) {
        registry[participant.id] = RegisteredParticipant(
            participant: participant,
            capabilities: capabilities
        )
    }

    public func participant(id: String) -> AgentCollaborationParticipant? {
        registry[id]?.participant
    }

    public func negotiate(
        initiatorId: String,
        responderId: String,
        requiredCapabilities: [String] = AgentCollaborationCapabilities.baselineRequiredNames
    ) -> AgentCollaborationNegotiationResult? {
        guard
            let initiator = registry[initiatorId],
            let responder = registry[responderId]
        else {
            return nil
        }

        return AgentCollaborationNegotiator.negotiate(
            initiator: initiator.participant,
            initiatorCapabilities: initiator.capabilities,
            responder: responder.participant,
            responderCapabilities: responder.capabilities,
            requiredCapabilities: requiredCapabilities
        )
    }

    @discardableResult
    public func sendRequest(
        _ request: AgentCollaborationRequest,
        from sender: AgentCollaborationParticipant,
        to recipient: AgentCollaborationParticipant,
        correlationId: String = UUID().uuidString,
        createdAt: Date = Date(),
        provenance: AgentCollaborationProvenance? = nil
    ) async throws -> AgentCollaborationEnvelope {
        let envelope = AgentCollaborationEnvelope(
            correlationId: correlationId,
            createdAt: createdAt,
            sender: sender,
            recipient: recipient,
            provenance: provenance,
            event: .request(request)
        )
        try await transport.send(envelope)
        return envelope
    }

    @discardableResult
    public func requestHandoff(
        _ handoff: AgentCollaborationHandoffRequest,
        from sender: AgentCollaborationParticipant,
        to recipient: AgentCollaborationParticipant,
        correlationId: String = UUID().uuidString,
        createdAt: Date = Date(),
        provenance: AgentCollaborationProvenance? = nil
    ) async throws -> AgentCollaborationEnvelope {
        let envelope = AgentCollaborationEnvelope(
            correlationId: correlationId,
            createdAt: createdAt,
            sender: sender,
            recipient: recipient,
            provenance: provenance,
            event: .handoffRequest(handoff)
        )
        try await transport.send(envelope)
        return envelope
    }

    @discardableResult
    public func reply(
        to envelope: AgentCollaborationEnvelope,
        from sender: AgentCollaborationParticipant,
        status: AgentCollaborationReplyStatus,
        message: String? = nil,
        acceptedCapabilities: [String] = [],
        diagnostics: AgentCollaborationFailureDiagnostic? = nil,
        createdAt: Date = Date()
    ) async throws -> AgentCollaborationEnvelope {
        let reply = AgentCollaborationReply(
            inReplyToEnvelopeId: envelope.id,
            status: status,
            message: message,
            acceptedCapabilities: acceptedCapabilities,
            diagnostics: diagnostics
        )
        let replyEnvelope = AgentCollaborationEnvelope(
            correlationId: envelope.correlationId,
            createdAt: createdAt,
            sender: sender,
            recipient: envelope.sender,
            provenance: AgentCollaborationProvenance(
                origin: envelope.provenance.origin,
                sessionId: envelope.provenance.sessionId,
                parentEnvelopeId: envelope.id,
                transport: envelope.provenance.transport,
                hops: envelope.provenance.hops + [sender.id]
            ),
            event: .reply(reply)
        )
        try await transport.send(replyEnvelope)
        return replyEnvelope
    }

    @discardableResult
    public func reportFailure(
        _ diagnostic: AgentCollaborationFailureDiagnostic,
        from sender: AgentCollaborationParticipant,
        to recipient: AgentCollaborationParticipant?,
        correlationId: String = UUID().uuidString,
        createdAt: Date = Date(),
        provenance: AgentCollaborationProvenance? = nil
    ) async throws -> AgentCollaborationEnvelope {
        let envelope = AgentCollaborationEnvelope(
            correlationId: correlationId,
            createdAt: createdAt,
            sender: sender,
            recipient: recipient,
            provenance: provenance,
            event: .failure(diagnostic)
        )
        try await transport.send(envelope)
        return envelope
    }

    public func envelopes(for participant: AgentCollaborationParticipant) async -> [AgentCollaborationEnvelope] {
        await transport.envelopes(for: participant)
    }

    public func allEnvelopes() async -> [AgentCollaborationEnvelope] {
        await transport.allEnvelopes()
    }

    private struct RegisteredParticipant: Sendable {
        var participant: AgentCollaborationParticipant
        var capabilities: AgentCollaborationCapabilities
    }
}

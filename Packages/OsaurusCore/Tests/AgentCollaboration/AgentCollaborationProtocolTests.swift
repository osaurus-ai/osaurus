//
//  AgentCollaborationProtocolTests.swift
//  osaurusTests
//
//  Contract coverage for the local + remote collaboration protocol foundation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AgentCollaborationProtocolTests {
    private let localAgentId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let remoteAgentId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let providerId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let envelopeId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let createdAt = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!

    @Test("collaboration envelope has stable JSON wire shape")
    func stableJSONWireShape() throws {
        let local = localAgent().agentCollaborationParticipant
        let remote = remoteAgent().agentCollaborationParticipant
        let envelope = AgentCollaborationEnvelope(
            id: envelopeId,
            correlationId: "corr-123",
            createdAt: createdAt,
            sender: local,
            recipient: remote,
            provenance: AgentCollaborationProvenance(
                origin: local,
                sessionId: "session-1",
                transport: "in-memory"
            ),
            event: .handoffRequest(
                AgentCollaborationHandoffRequest(
                    handoffId: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    reason: "needs remote research",
                    summary: "Collect release notes",
                    artifactReferences: ["artifact://b", "artifact://a"],
                    requiredCapabilities: ["collaboration.reply", "collaboration.request"]
                )
            )
        )

        let data = try AgentCollaborationWireFormat.encoder().encode(envelope)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""schema":"osaurus.agent-collaboration.v1""#))
        #expect(json.contains(#""createdAt":"2026-06-21T12:00:00Z""#))
        #expect(json.contains(#""type":"handoff.request""#))
        #expect(json.contains(#""correlationId":"corr-123""#))

        let decoded = try AgentCollaborationWireFormat.decoder().decode(AgentCollaborationEnvelope.self, from: data)
        #expect(decoded == envelope)
    }

    @Test("local and remote participants negotiate the baseline contract")
    func localRemoteNegotiation() {
        let local = localAgent()
        let remote = remoteAgent()

        let result = AgentCollaborationNegotiator.negotiate(
            initiator: local.agentCollaborationParticipant,
            initiatorCapabilities: local.agentCollaborationCapabilities,
            responder: remote.agentCollaborationParticipant,
            responderCapabilities: remote.agentCollaborationCapabilities
        )

        #expect(result.isCompatible)
        #expect(result.initiator.type == .local)
        #expect(result.responder.type == .remote)
        #expect(result.missingRequiredCapabilities.isEmpty)
        #expect(result.commonCapabilities.map(\.name).contains("collaboration.handoff"))
        #expect(result.commonCapabilities.map(\.name).contains("collaboration.failure-diagnostics"))
    }

    @Test("negotiation reports missing required capabilities")
    func missingRequiredCapabilitiesAreReported() {
        let local = localAgent().agentCollaborationParticipant
        let remote = remoteAgent().agentCollaborationParticipant
        let limitedRemoteCapabilities = AgentCollaborationCapabilities(
            capabilities: [
                AgentCollaborationCapability(name: "collaboration.correlation"),
                AgentCollaborationCapability(name: "collaboration.provenance"),
            ]
        )

        let result = AgentCollaborationNegotiator.negotiate(
            initiator: local,
            initiatorCapabilities: .localDefault(),
            responder: remote,
            responderCapabilities: limitedRemoteCapabilities
        )

        #expect(!result.isCompatible)
        #expect(
            result.missingRequiredCapabilities == [
                "collaboration.handoff",
                "collaboration.reply",
                "collaboration.request",
            ]
        )
    }

    @Test("handoff lifecycle preserves correlation and reply provenance")
    func handoffLifecycle() async throws {
        let transport = AgentCollaborationInMemoryTransport()
        let service = AgentCollaborationService(transport: transport)
        let local = localAgent().agentCollaborationParticipant
        let remote = remoteAgent().agentCollaborationParticipant

        await service.register(participant: local, capabilities: .localDefault())
        await service.register(participant: remote, capabilities: .remoteDefault())

        let negotiation = await service.negotiate(initiatorId: local.id, responderId: remote.id)
        #expect(negotiation?.isCompatible == true)

        let handoffEnvelope = try await service.requestHandoff(
            AgentCollaborationHandoffRequest(
                handoffId: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                reason: "remote agent owns the paired endpoint",
                summary: "Handle the remote-only step",
                requiredCapabilities: ["collaboration.reply"]
            ),
            from: local,
            to: remote,
            correlationId: "handoff-corr",
            createdAt: createdAt
        )

        let replyEnvelope = try await service.reply(
            to: handoffEnvelope,
            from: remote,
            status: .accepted,
            message: "Accepted",
            acceptedCapabilities: ["collaboration.reply"],
            createdAt: createdAt.addingTimeInterval(1)
        )

        #expect(replyEnvelope.correlationId == "handoff-corr")
        #expect(replyEnvelope.recipient == local)
        #expect(replyEnvelope.provenance.parentEnvelopeId == handoffEnvelope.id)
        #expect(await transport.allEnvelopes().count == 2)

        guard case let .reply(reply) = replyEnvelope.event else {
            Issue.record("expected reply event")
            return
        }
        #expect(reply.inReplyToEnvelopeId == handoffEnvelope.id)
        #expect(reply.status == .accepted)
    }

    @Test("failure diagnostics round-trip as first-class events")
    func failureDiagnostics() async throws {
        let transport = AgentCollaborationInMemoryTransport()
        let service = AgentCollaborationService(transport: transport)
        let local = localAgent().agentCollaborationParticipant
        let remote = remoteAgent().agentCollaborationParticipant
        let diagnostic = AgentCollaborationFailureDiagnostic(
            code: "negotiation.missing-capability",
            severity: .error,
            message: "Remote participant cannot accept handoff requests.",
            retryable: false,
            relatedEnvelopeId: envelopeId,
            details: ["missing": "collaboration.handoff"]
        )

        let envelope = try await service.reportFailure(
            diagnostic,
            from: local,
            to: remote,
            correlationId: "failure-corr",
            createdAt: createdAt
        )

        let data = try AgentCollaborationWireFormat.encoder().encode(envelope)
        let decoded = try AgentCollaborationWireFormat.decoder().decode(AgentCollaborationEnvelope.self, from: data)

        #expect(decoded.correlationId == "failure-corr")
        guard case let .failure(decodedDiagnostic) = decoded.event else {
            Issue.record("expected failure event")
            return
        }
        #expect(decodedDiagnostic == diagnostic)
        #expect(decodedDiagnostic.details["missing"] == "collaboration.handoff")
    }

    @Test("agent collaboration adapters do not change default agent persistence")
    func defaultAgentBehaviorUnchanged() throws {
        let defaultAgent = Agent.default
        let data = try JSONEncoder().encode(defaultAgent)
        let json = String(decoding: data, as: UTF8.self)

        #expect(defaultAgent.id == Agent.defaultId)
        #expect(defaultAgent.isBuiltIn)
        #expect(defaultAgent.toolsEnabled)
        #expect(defaultAgent.memoryEnabled)
        #expect(defaultAgent.bonjourEnabled == false)
        #expect(!json.contains("agentCollaboration"))
        #expect(!json.contains("collaboration"))

        let participant = defaultAgent.agentCollaborationParticipant
        #expect(participant.id == "local:00000000-0000-0000-0000-000000000001")
        #expect(participant.type == .local)
    }

    private func localAgent() -> Agent {
        Agent(
            id: localAgentId,
            name: "Local Planner",
            description: "Plans work",
            systemPrompt: "Plan local work",
            agentAddress: "0xLOCAL"
        )
    }

    private func remoteAgent() -> RemoteAgent {
        RemoteAgent(
            id: remoteAgentId,
            agentAddress: "0xREMOTE",
            name: "Remote Researcher",
            description: "Researches remote context",
            relayBaseURL: "https://remote.agent.osaurus.ai",
            providerId: providerId
        )
    }
}

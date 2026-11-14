import Foundation
import Testing

@testable import OsaurusCore

@Suite("Computer Use execution authorization")
struct ComputerUseAuthorizationTests {
    @Test func directInvocationDeniesTheDefaultAgent() async {
        let scope = SubagentScope(
            sessionId: "computer-direct-default",
            toolCallId: "computer-direct-default",
            agentId: Agent.defaultId
        )
        do {
            _ = try await ComputerUseKind(
                goal: "Open System Settings",
                limits: RunLimits()
            ).resolveModel(scope)
            Issue.record("Default agent direct Computer Use should be denied")
        } catch let SubagentError.denied(message) {
            #expect(message.contains("custom agent"))
        } catch {
            Issue.record("expected SubagentError.denied, got \(error)")
        }
    }

    /// Each refusal names its own gate so the user is sent to the right fix
    /// (switch agent / turn Tools on / flip the flag) rather than one shared
    /// "not enabled" that pointed everyone at the per-agent toggle.
    @Test func authorizationRefusalIsStageSpecific() {
        let defaultMessage = ComputerUseKind.authorizationRefusal(agentId: Agent.defaultId, agent: nil)
        #expect(defaultMessage?.contains("Default agent") == true)
        #expect(defaultMessage?.contains("custom agent") == true)

        let unknown = ComputerUseKind.authorizationRefusal(agentId: UUID(), agent: nil)
        #expect(unknown?.contains("not enabled") == true)
        #expect(unknown?.contains("could not be found") == true)

        var agent = Agent(name: "Ops")
        agent.toolsEnabled = false
        agent.settings.computerUseEnabled = true
        let toolsOff = ComputerUseKind.authorizationRefusal(agentId: agent.id, agent: agent)
        #expect(toolsOff?.contains("Tools is off") == true)

        agent.toolsEnabled = true
        agent.settings.computerUseEnabled = false
        let flagOff = ComputerUseKind.authorizationRefusal(agentId: agent.id, agent: agent)
        #expect(flagOff?.contains("not enabled") == true)
        #expect(flagOff?.contains("Subagents") == true)

        agent.settings.computerUseEnabled = true
        #expect(ComputerUseKind.authorizationRefusal(agentId: agent.id, agent: agent) == nil)
    }

    /// Host-level pre-loop failures are attributed from structured envelope
    /// fields, never prose, so telemetry stays stable across message edits.
    @Test func refusalStageIsReadFromEnvelopeMetadata() {
        let tool = ComputerUseTool.toolName
        #expect(
            ComputerUseTool.refusalStage(
                fromEnvelope: ToolEnvelope.failure(
                    kind: .rejected, message: "nested", tool: tool, metadata: ["recursion": true]
                )
            ) == .recursion
        )
        #expect(
            ComputerUseTool.refusalStage(
                fromEnvelope: ToolEnvelope.failure(
                    kind: .unavailable, message: "busy", tool: tool, metadata: ["admission": "timeout"]
                )
            ) == .admissionTimeout
        )
        #expect(
            ComputerUseTool.refusalStage(
                fromEnvelope: ToolEnvelope.failure(
                    kind: .rejected, message: "ram", tool: tool,
                    metadata: ["admission": "stable_memory_refusal"]
                )
            ) == .ramSafety
        )
        #expect(
            ComputerUseTool.refusalStage(
                fromEnvelope: ToolEnvelope.failure(
                    kind: .executionError, message: "stopped", tool: tool, metadata: ["cancelled": true]
                )
            ) == .cancelled
        )
        #expect(
            ComputerUseTool.refusalStage(
                fromEnvelope: ToolEnvelope.failure(kind: .userDenied, message: "no", tool: tool)
            ) == .cancelled
        )
        #expect(
            ComputerUseTool.refusalStage(
                fromEnvelope: ToolEnvelope.failure(kind: .executionError, message: "?", tool: tool)
            ) == .other
        )
        #expect(ComputerUseTool.refusalStage(fromEnvelope: "not json") == .other)
    }

    /// The kind tags its own refusals so the tool can report the stage without
    /// parsing the envelope; the loop-started flag stays false on refusal.
    @Test func kindTagsAgentAuthRefusal() async {
        let kind = ComputerUseKind(goal: "Open System Settings", limits: RunLimits())
        let scope = SubagentScope(
            sessionId: "computer-direct-default-stage",
            toolCallId: "computer-direct-default-stage",
            agentId: Agent.defaultId
        )
        _ = try? await kind.resolveModel(scope)
        #expect(kind.refusalStage == .agentAuth)
        #expect(kind.loopStarted == false)
    }

    @Test func directInvocationDeniesAnUnknownCustomAgent() async {
        let scope = SubagentScope(
            sessionId: "computer-direct-missing",
            toolCallId: "computer-direct-missing",
            agentId: UUID()
        )
        do {
            _ = try await ComputerUseKind(
                goal: "Open System Settings",
                limits: RunLimits()
            ).resolveModel(scope)
            Issue.record("Unknown custom agent direct Computer Use should be denied")
        } catch let SubagentError.denied(message) {
            #expect(message.contains("not enabled"))
        } catch {
            Issue.record("expected SubagentError.denied, got \(error)")
        }
    }
}

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

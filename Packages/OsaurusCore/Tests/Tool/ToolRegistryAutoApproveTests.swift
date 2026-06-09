//
//  ToolRegistryAutoApproveTests.swift
//  osaurus
//
//  Pins the security contract of `ChatExecutionContext.autoApproveToolPrompts`,
//  the headless eval harness's approval bypass:
//    * defaults to false — production surfaces never inherit it,
//    * skips ONLY the `.ask` user prompt,
//    * `.deny` policies still throw even while it is bound.
//
//  The complementary "without the binding, `.ask` prompts" path is
//  deliberately NOT executed here: it would present a real NSPanel and
//  hang the test run — exactly the failure mode the TaskLocal exists to
//  prevent in headless contexts.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Fixtures

/// Minimal permissioned tool with a configurable default policy and no
/// requirements, so the test exercises the ask/deny policy switch in
/// `runPermissionGate` without touching system permissions.
private final class PolicyProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description = "Test-only permission policy probe."
    let parameters: JSONValue? = nil

    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy

    private(set) var executions = 0

    init(name: String, policy: ToolPermissionPolicy) {
        self.name = name
        self.defaultPermissionPolicy = policy
    }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

// MARK: - Tests

@MainActor
struct ToolRegistryAutoApproveTests {

    @Test func taskLocalDefaultsToFalse() {
        #expect(ChatExecutionContext.autoApproveToolPrompts == false)
    }

    @Test func askGatedToolExecutesWithoutPromptWhenBound() async throws {
        let tool = PolicyProbeTool(name: "test_auto_approve_ask_probe", policy: .ask)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let result = try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 1)
        #expect(!ToolEnvelope.isError(result))
    }

    @Test func denyPolicyStillThrowsWhileBound() async {
        let tool = PolicyProbeTool(name: "test_auto_approve_deny_probe", policy: .deny)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        await #expect(throws: (any Error).self) {
            _ = try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
            }
        }
        #expect(tool.executions == 0)
    }
}

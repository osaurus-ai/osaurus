//
//  TerminalToolApprovalTests.swift
//  OsaurusCoreTests
//
//  An approved `osaurus agent run` with a terminal attached: its `.ask`
//  tool cards reach the normal approval card (instead of the external-surface
//  refusal), and only the terminal session that started the run sees and
//  answers them. A run without a session keeps the refusal.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class TerminalProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description = "Test-only terminal approval probe."
    let parameters: JSONValue? = nil
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .ask
    private(set) var executions = 0

    init(name: String) { self.name = name }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

@MainActor
private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0 ..< 400 where !predicate() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

extension ToolPermissionPromptQueueTests {
    @MainActor
    private func externalRun(
        _ toolName: String,
        session: String?
    ) -> Task<String, Error> {
        let presenter: ToolPermissionPromptService.TestPresenter = { _, _, _ in }
        return ToolPermissionPromptService.$presentationOverrideForTests.withValue(presenter) {
            ChatExecutionContext.$isExternalSurface.withValue(true) {
                ChatExecutionContext.$terminalReviewerSession.withValue(session) {
                    Task { @MainActor in
                        try await ToolRegistry.shared.execute(name: toolName, argumentsJSON: "{}")
                    }
                }
            }
        }
    }

    @Test("a terminal run's Ask card reaches only that terminal, and its answer runs the tool")
    @MainActor
    func terminalSessionAnswersItsOwnCard() async throws {
        try await DynamicToolProbeFixture.run { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            ToolPermissionPromptService.resetForTesting()
            defer { ToolPermissionPromptService.resetForTesting() }
            let tool = TerminalProbeTool(name: "test_terminal_probe_" + UUID().uuidString.prefix(8).lowercased())
            try fixture.register(tool)

            let session = "cli-" + UUID().uuidString
            let task = externalRun(tool.name, session: session)
            await waitUntil { !ToolPermissionPromptService.terminalPrompts(session: session).isEmpty }
            let card = try #require(ToolPermissionPromptService.terminalPrompts(session: session).first)
            #expect(card.toolName == tool.name)
            #expect(ToolPermissionPromptService.terminalPrompts(session: "cli-someone-else").isEmpty)
            #expect(ToolPermissionPromptService.remotePrompts.isEmpty, "the phone does not see a terminal's card")

            #expect(!ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: "cli-other-1", outcome: .allowOnce))
            #expect(!ToolPermissionPromptService.resolveRemotely(id: card.id, outcome: .allowOnce))
            #expect(ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: .allowOnce))
            _ = try await task.value
            #expect(tool.executions == 1)
            #expect(!ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: .denied))
        }
    }

    @Test("a terminal's denial refuses the call; without a session the call is refused outright")
    @MainActor
    func terminalDenialAndHeadlessRefusal() async throws {
        try await DynamicToolProbeFixture.run { fixture in
            UserDefaults.standard.set(false, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
            ToolPermissionPromptService.resetForTesting()
            defer { ToolPermissionPromptService.resetForTesting() }
            let tool = TerminalProbeTool(name: "test_terminal_deny_" + UUID().uuidString.prefix(8).lowercased())
            try fixture.register(tool)

            let session = "cli-" + UUID().uuidString
            let denied = externalRun(tool.name, session: session)
            await waitUntil { !ToolPermissionPromptService.terminalPrompts(session: session).isEmpty }
            let card = try #require(ToolPermissionPromptService.terminalPrompts(session: session).first)
            #expect(ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: .denied))
            await #expect(throws: (any Error).self) { try await denied.value }

            let headless = externalRun(tool.name, session: nil)
            let error = await #expect(throws: (any Error).self) { try await headless.value }
            #expect(error?.localizedDescription.contains("requires interactive approval") == true)
            #expect(ToolPermissionPromptService.openPromptCount == 0, "no card is raised for a headless run")
            #expect(tool.executions == 0)
        }
    }

    @Test("terminal answers cannot save agent-scoped choices or a lease the card does not offer")
    @MainActor
    func terminalAnswersAreNarrowed() async throws {
        ToolPermissionPromptService.resetForTesting()
        defer { ToolPermissionPromptService.resetForTesting() }
        let session = "cli-" + UUID().uuidString
        let presenter: ToolPermissionPromptService.TestPresenter = { _, _, _ in }
        let task = ToolPermissionPromptService.$presentationOverrideForTests.withValue(presenter) {
            ChatExecutionContext.$terminalReviewerSession.withValue(session) {
                Task { @MainActor in
                    await ToolPermissionPromptService.requestApprovalOutcome(
                        toolName: "web_fetch", description: "Fetch", argumentsJSON: "{}", perCallApprovalOnly: true)
                }
            }
        }
        await waitUntil { !ToolPermissionPromptService.terminalPrompts(session: session).isEmpty }
        let card = try #require(ToolPermissionPromptService.terminalPrompts(session: session).first)
        #expect(!card.offersRunLease)
        #expect(ToolPermissionPromptService.resolveFromTerminal(id: card.id, session: session, outcome: .alwaysAllow))
        #expect(await task.value == .allowOnce, "a per-call card cannot be pre-granted from the terminal")
    }

    @Test("terminal approval session ids are validated")
    func terminalSessionValidation() {
        #expect(HTTPHandler.terminalApprovalSession("cli-1234abcd") == "cli-1234abcd")
        #expect(HTTPHandler.terminalApprovalSession(nil) == nil)
        #expect(HTTPHandler.terminalApprovalSession("short") == nil)
        #expect(HTTPHandler.terminalApprovalSession("has space in it") == nil)
        #expect(HTTPHandler.terminalApprovalSession(String(repeating: "a", count: 65)) == nil)
        #expect(HTTPHandler.terminalApprovalSession("cli-ünïcode-1") == nil)
    }
}

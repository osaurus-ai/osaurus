//
//  PromptWorkingFolderToolTests.swift
//  OsaurusCoreTests
//
//  Pins the `prompt_working_folder` contract: the picker-backed folder ask
//  is exposed only to an attended chat turn with no execution root, refuses
//  with a typed envelope everywhere it cannot present a picker, and — when
//  the user picks — attaches the folder to the chat exactly as the Folder
//  chip does (per-chat state + sticky agent record) and returns a success
//  envelope the chat intercept turns into an auto-continue.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PromptWorkingFolderToolTests {

    // MARK: - Helpers

    private func makeRoot(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-prompt-folder-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeAgent() -> Agent {
        Agent(
            name: "PromptFolder-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-prompt-folder-\(UUID().uuidString)",
            autonomousExec: AutonomousExecConfig(enabled: false)
        )
    }

    private func makeSession(agentId: UUID) -> (session: ChatSession, context: ExecutionContext) {
        let context = ExecutionContext(id: UUID(), agentId: agentId)
        context.chatSession.chatEngineFactory = { _ in MockChatEngine() }
        return (context.chatSession, context)
    }

    private func decode(_ envelope: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        )
    }

    private func args(_ reason: String) -> String {
        "{\"reason\": \"\(reason)\"}"
    }

    /// Records what the picker seam was asked; the seam is `@Sendable`, so a
    /// captured `var` cannot be mutated from it.
    private final class PickerProbe: @unchecked Sendable {
        var reason: String?
        var callCount = 0
    }

    // MARK: - Exposure

    @Test("exposed only for an attended chat turn with no execution root")
    func shouldExposeMatrix() {
        let folder = FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/x"),
            projectType: .unknown,
            tree: "./\n",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false
        )
        #expect(PromptWorkingFolderTool.shouldExpose(executionMode: .none, source: .chat))
        #expect(PromptWorkingFolderTool.shouldExpose(executionMode: .none, source: .imported))
        // A host folder makes the ask moot; VM mode already has file tools.
        #expect(!PromptWorkingFolderTool.shouldExpose(executionMode: .hostFolder(folder), source: .chat))
        #expect(!PromptWorkingFolderTool.shouldExpose(executionMode: .sandbox, source: .chat))
        // No one to click on these surfaces.
        for source in [
            SessionSource.plugin, .http, .channel, .schedule, .watcher, .selfSchedule, .delegation, .workspace,
        ] {
            #expect(
                !PromptWorkingFolderTool.shouldExpose(executionMode: .none, source: source),
                "\(source) must not see the picker tool"
            )
        }
        // No published source is not "attended" either (HTTP / plugin compose).
        #expect(!PromptWorkingFolderTool.shouldExpose(executionMode: .none, source: nil))
    }

    @Test("resolveTools strips it unless the turn is a folder-less chat")
    func composerStripsOutsideAttendedFolderlessChat() async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }

            let inChat = ChatExecutionContext.$currentSessionSource.withValue(.chat) {
                Set(
                    SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: .none)
                        .map(\.function.name)
                )
            }
            #expect(inChat.contains(PromptWorkingFolderTool.toolName))

            let noSource = Set(
                SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: .none)
                    .map(\.function.name)
            )
            #expect(!noSource.contains(PromptWorkingFolderTool.toolName))

            let delegated = ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
                Set(
                    SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: .none)
                        .map(\.function.name)
                )
            }
            #expect(!delegated.contains(PromptWorkingFolderTool.toolName))

            let folder = FolderContext(
                rootPath: URL(fileURLWithPath: "/tmp/osaurus-prompt-folder-\(UUID().uuidString)"),
                projectType: .unknown,
                tree: "./\n",
                manifest: nil,
                gitStatus: nil,
                isGitRepo: false
            )
            let withFolder = ChatExecutionContext.$currentSessionSource.withValue(.chat) {
                Set(
                    SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: .hostFolder(folder))
                        .map(\.function.name)
                )
            }
            #expect(!withFolder.contains(PromptWorkingFolderTool.toolName))
        }
    }

    @Test("the loop-control and deny sets carry the tool; the Orchestrator baseline does not")
    func nameSetsCarryTheTool() {
        // The Orchestrator never writes files and its first-turn schema is a
        // reviewed contract (`orchestratorAllowedToolNames_isTheConsolidated…`).
        #expect(!ToolRegistry.orchestratorAllowedToolNames.contains(PromptWorkingFolderTool.toolName))
        #expect(AgentToolLoop.interceptToolNames.contains(PromptWorkingFolderTool.toolName))
        #expect(AgentToolLoop.taskTrackingControlToolNames.contains(PromptWorkingFolderTool.toolName))
        #expect(AgentTodoRunScope.loopControlToolNames.contains(PromptWorkingFolderTool.toolName))
        #expect(ToolRegistry.externallyDeniedToolNames.contains(PromptWorkingFolderTool.toolName))
        #expect(TextSubagentKind.isExcludedChildTool(PromptWorkingFolderTool.toolName))
        #expect(ToolRegistry.shared.builtInToolNames.contains(PromptWorkingFolderTool.toolName))
    }

    @Test("a success envelope is a run-ending intercept; a failure falls through")
    func interceptOnlyOnSuccess() {
        let ok = PromptWorkingFolderTool.envelope(for: .attached(path: "/tmp/p"), reason: "r")
        let cancelled = PromptWorkingFolderTool.envelope(for: .cancelled, reason: "r")
        #expect(AgentToolLoop.isSuccessfulIntercept(toolName: PromptWorkingFolderTool.toolName, result: ok))
        #expect(!AgentToolLoop.isSuccessfulIntercept(toolName: PromptWorkingFolderTool.toolName, result: cancelled))
    }

    // MARK: - Refusals

    @Test("missing reason is an invalid_args envelope")
    func missingReasonIsInvalidArgs() async throws {
        let result = try await PromptWorkingFolderTool().execute(argumentsJSON: "{}")
        let json = try decode(result)
        #expect(json["ok"] as? Bool == false)
        #expect(json["kind"] as? String == "invalid_args")
        #expect(json["field"] as? String == "reason")
    }

    @Test("no live chat session refuses with unavailable and names the chip")
    func noSessionIsUnavailable() async throws {
        let result = try await PromptWorkingFolderTool().execute(argumentsJSON: args("Save the report"))
        let json = try decode(result)
        #expect(json["kind"] as? String == "unavailable")
        #expect(json["retryable"] as? Bool == false)
        #expect((json["message"] as? String)?.contains("Folder chip") == true)
    }

    @Test("external, unattended and delegated executions refuse before any picker")
    func surfaceGatesRefuse() async throws {
        let tool = PromptWorkingFolderTool()
        let external = try await ChatExecutionContext.$isExternalSurface.withValue(true) {
            try await tool.execute(argumentsJSON: args("r"))
        }
        #expect(try decode(external)["kind"] as? String == "unavailable")

        let unattended = try await ChatExecutionContext.$isUnattendedDispatch.withValue(true) {
            try await tool.execute(argumentsJSON: args("r"))
        }
        #expect(try decode(unattended)["kind"] as? String == "unavailable")

        let delegated = try await ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
            try await tool.execute(argumentsJSON: args("r"))
        }
        let json = try decode(delegated)
        #expect(json["kind"] as? String == "unavailable")
        #expect((json["message"] as? String)?.contains("no user present") == true)
    }

    @Test("a session that already has a folder is refused without a picker")
    func existingFolderRefuses() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let root = try makeRoot("existing")
            defer { try? FileManager.default.removeItem(at: root) }

            let (session, _) = makeSession(agentId: agent.id)
            _ = await session.folderState.setFolder(root)
            #expect(session.folderState.hasActiveFolder)

            let probe = PickerProbe()
            let result = try await ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(session)) {
                try await PromptWorkingFolderTool.$pickerOverrideForTests.withValue({ _ in
                    probe.callCount += 1
                    return nil
                }) {
                    try await PromptWorkingFolderTool().execute(argumentsJSON: args("r"))
                }
            }
            let json = try decode(result)
            #expect(json["ok"] as? Bool == false)
            #expect(json["kind"] as? String == "execution_error")
            #expect((json["message"] as? String)?.contains("already has a working folder") == true)
            #expect(probe.callCount == 0)
            session.folderState.clearFolder()
        }
    }

    // MARK: - Pick / cancel

    @Test("a pick attaches the folder to the chat, remembers it on the agent, and reports the path")
    func pickAttachesAndPersists() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let root = try makeRoot("pick")
            defer { try? FileManager.default.removeItem(at: root) }

            let (session, _) = makeSession(agentId: agent.id)
            #expect(!session.folderState.hasActiveFolder)
            #expect(AgentManager.shared.workingFolder(for: agent.id) == nil)

            let probe = PickerProbe()
            let result = try await ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(session)) {
                try await ChatExecutionContext.$currentSessionSource.withValue(.chat) {
                    try await PromptWorkingFolderTool.$pickerOverrideForTests.withValue({ reason in
                        probe.reason = reason
                        return root
                    }) {
                        try await PromptWorkingFolderTool().execute(argumentsJSON: args("Save report.md here"))
                    }
                }
            }
            #expect(probe.reason == "Save report.md here")

            let json = try decode(result)
            #expect(json["ok"] as? Bool == true)
            let payload = try #require(json["result"] as? [String: Any])
            let expectedPath = root.standardizedFileURL.path
            #expect(payload["path"] as? String == expectedPath)
            #expect((payload["text"] as? String)?.contains("Working folder attached: \(expectedPath)") == true)
            #expect((payload["tools"] as? [String])?.contains("file_write") == true)
            #expect(payload["reason"] as? String == "Save report.md here")

            // Per-chat state: the same record the chip writes.
            #expect(session.folderState.hasActiveFolder)
            #expect(session.folderState.rootPath?.standardizedFileURL.path == expectedPath)
            #expect(session.folderState.persistedBookmark != nil)
            // Sticky agent record.
            let sticky = try #require(AgentManager.shared.workingFolder(for: agent.id))
            #expect(sticky.path == expectedPath)
            #expect(sticky.bookmark == session.folderState.persistedBookmark)

            session.folderState.clearFolder()
            AgentManager.shared.clearWorkingFolder(for: agent.id)
        }
    }

    @Test("a cancel is a user_denied envelope and leaves chat and agent folder-less")
    func cancelLeavesFolderless() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let (session, _) = makeSession(agentId: agent.id)

            let result = try await ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(session)) {
                try await PromptWorkingFolderTool.$pickerOverrideForTests.withValue({ _ in nil }) {
                    try await PromptWorkingFolderTool().execute(argumentsJSON: args("r"))
                }
            }
            let json = try decode(result)
            #expect(json["ok"] as? Bool == false)
            #expect(json["kind"] as? String == "user_denied")
            #expect(json["retryable"] as? Bool == false)
            // The chat loop ends the run on `user_denied` and shows this text
            // to the user, so it must read as a status line, not a model steer.
            #expect((json["message"] as? String)?.contains("no working folder was attached") == true)
            #expect((json["message"] as? String)?.contains("Folder chip") == true)
            #expect((json["message"] as? String)?.contains("Do not call") == false)
            #expect(!session.folderState.hasActiveFolder)
            #expect(AgentManager.shared.workingFolder(for: agent.id) == nil)
        }
    }

    @Test("a folder that cannot be opened is an execution_error, not a cancel")
    func unusableFolderIsExecutionError() async throws {
        try await ChatHistoryTestStorage.run {
            let agent = makeAgent()
            AgentManager.shared.add(agent)
            defer { Task { _ = await AgentManager.shared.delete(id: agent.id) } }
            let (session, _) = makeSession(agentId: agent.id)
            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-prompt-folder-missing-\(UUID().uuidString)")

            let result = try await ChatExecutionContext.$currentChatSessionBox.withValue(WeakChatSessionBox(session)) {
                try await PromptWorkingFolderTool.$pickerOverrideForTests.withValue({ _ in missing }) {
                    try await PromptWorkingFolderTool().execute(argumentsJSON: args("r"))
                }
            }
            let json = try decode(result)
            #expect(json["ok"] as? Bool == false)
            #expect(json["kind"] as? String == "execution_error")
            #expect(!session.folderState.hasActiveFolder)
            #expect(AgentManager.shared.workingFolder(for: agent.id) == nil)
        }
    }

    // MARK: - Steers

    @Test("every no-folder steer names the tool first and keeps the chip as fallback")
    func steersNameTheTool() {
        let envelope = FolderToolHelpers.noActiveFolderEnvelope(tool: "file_write")
        #expect(envelope.contains("prompt_working_folder"))
        #expect(envelope.contains("Folder chip"))

        let exposed = AgentToolLoop.announcedToolCallNotice(
            recovery: .init(
                exposed: ["share_artifact", PromptWorkingFolderTool.toolName],
                workspaceBlocked: ["file_write"]
            )
        )
        #expect(exposed.contains("Call prompt_working_folder now"))
        #expect(!exposed.contains("Folder chip"))

        let notExposed = AgentToolLoop.announcedToolCallNotice(
            recovery: .init(exposed: ["share_artifact"], workspaceBlocked: ["file_write"])
        )
        #expect(notExposed.contains("attach a folder via the Folder chip"))
        #expect(!notExposed.contains("Call prompt_working_folder now"))
    }
}

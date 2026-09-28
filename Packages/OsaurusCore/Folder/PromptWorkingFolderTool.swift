//
//  PromptWorkingFolderTool.swift
//  osaurus
//
//  `prompt_working_folder` — the one picker-backed tool. When a chat has no
//  working folder, the file/shell tools are withheld from the schema and the
//  model used to be told to "ask the user to use the Folder chip", which it
//  could only do in prose. This tool lets the model ask directly: it opens
//  the native folder picker as a sheet on the chat window, attaches the pick
//  to the chat exactly as the Folder chip does (per-chat folder, sandbox
//  disabled, sticky agent Working Folder), and the chat layer then ends the
//  run and auto-continues with the folder bound so the file tools become
//  callable without the user typing anything.
//
//  It is deliberately NOT `clarify`: `clarify` waits for the user's next
//  message; this one blocks on the picker and resumes on its own. Approval
//  cards (`ToolPermissionPromptService`, `ConfigApprovalQueue`) gate a tool
//  call the model already made; this one is the call.
//

import AppKit
import Foundation

/// Outcome of an in-turn folder prompt, distinct per terminal reason so the
/// tool envelope never claims the user declined a picker they never saw.
enum WorkingFolderPromptOutcome: Sendable, Equatable {
    /// A folder was attached to the chat (and remembered on the agent).
    case attached(path: String)
    /// The user dismissed the picker without choosing.
    case cancelled
    /// The pick could not be applied (bookmark, sandbox disable failure).
    case failed(String)
}

public final class PromptWorkingFolderTool: OsaurusTool, @unchecked Sendable {
    public static let toolName = "prompt_working_folder"
    public let name = PromptWorkingFolderTool.toolName
    // The first sentence is what survives the first-turn bootstrap
    // compaction (`SystemPromptComposer.oneLineToolDescription`), so it
    // carries the trigger on its own and stays under 180 characters.
    public let description =
        "Ask the user to pick a working folder when the task needs to read, write, search or run "
        + "files and this chat has no working folder attached. "
        + "Use it instead of asking in prose or via `clarify` when file_read, file_write, "
        + "file_edit, file_search or shell_run are missing from your tools. It opens the native "
        + "folder picker; once the user chooses, the folder is attached to this chat, the file "
        + "tools become available, and your run continues automatically. Pass a short `reason` "
        + "the user will see in the picker. If the user cancels, the turn ends with a notice; "
        + "on the next turn deliver the content directly (share_artifact can carry files) "
        + "rather than asking again."

    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "reason": .object([
                "type": .string("string"),
                "description": .string(
                    "One short sentence shown to the user in the picker explaining what you need "
                        + "the folder for (e.g. \"Save the generated report as report.md\")."
                ),
            ])
        ]),
        "required": .array([.string("reason")]),
    ])

    /// Names the model regains once a folder is attached. Reported in the
    /// success envelope so the model does not wait for a schema hint.
    static let unlockedToolNames: [String] = [
        "file_read", "file_search", "file_write", "file_edit", "shell_run",
    ]

    /// The one recovery clause every "no working folder" steer shares
    /// (folder tool bodies, the registry's scope refusal, the capabilities
    /// loader, the announce-only nudge, the DB file resolver). Names the
    /// tool first and keeps the Folder chip as the fallback for surfaces
    /// where the tool is not exposed (HTTP, plugin, delegation, VM mode).
    static let attachFolderSteer =
        "Call `prompt_working_folder` to open a folder picker for the user; if that tool is not "
        + "in your tools, ask the user to attach a folder via the Folder chip."

    /// Whether the tool belongs in a turn's schema. Pure so the contract is
    /// unit-testable:
    ///  - only when the turn has NO execution root (`.none`): with a host
    ///    folder the ask is moot, and in VM mode the model already has file
    ///    tools inside `/workspace` (a host pick would silently flip the
    ///    agent's sandbox off — that stays a user-initiated chip action);
    ///  - only for an attended chat window (`.chat`, or an `.imported`
    ///    conversation the user continues in one). HTTP, plugin, channel,
    ///    schedule, watcher, delegation, and workspace runs have no one to
    ///    click a picker. `nil` (no source published) is NOT attended: the
    ///    HTTP agent-run and plugin compose paths publish none.
    static func shouldExpose(executionMode: ExecutionMode, source: SessionSource?) -> Bool {
        guard case .none = executionMode else { return false }
        switch source {
        case .chat, .imported: return true
        default: return false
        }
    }

    /// Test seam: replaces the AppKit picker. Receives the reason and
    /// returns the folder to attach (nil = the user cancelled). Task-local so
    /// concurrently running suites that do not bind it keep the headless
    /// refusal below.
    typealias TestPicker = @Sendable (_ reason: String) async -> URL?

    @TaskLocal
    static var pickerOverrideForTests: TestPicker?

    /// Every real pick blocks on an `NSOpenPanel` that only a click resolves,
    /// so a test that reaches one hangs the whole bundle (see
    /// `ToolPermissionPromptService.isHeadlessTestProcess`). Refusing is the
    /// deterministic answer; tests that exercise the pick bind the override.
    private static var isHeadlessTestProcess: Bool {
        RuntimeEnvironment.isUnderTests && pickerOverrideForTests == nil
    }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let reasonReq = requireString(
            args,
            "reason",
            expected: "one short sentence naming what the folder is needed for",
            tool: name
        )
        guard case .value(let rawReason) = reasonReq else { return reasonReq.failureEnvelope ?? "" }
        let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`reason` must be a non-empty sentence the user will see in the picker.",
                field: "reason",
                expected: "non-empty reason string",
                tool: name
            )
        }

        // Surface gates. Only an attended, local chat can show a picker:
        //  - external surfaces (HTTP `/agents/{id}/run`, `/mcp/call`) have no
        //    window and no user to click;
        //  - unattended dispatches (schedule / watcher / self-schedule) run
        //    with nobody present;
        //  - a delegated child's "user" is the orchestrator model, which
        //    would sit blind until its budget expired.
        if ChatExecutionContext.isExternalSurface || ChatExecutionContext.isUnattendedDispatch
            || ChatExecutionContext.currentSessionSource == .delegation
        {
            return Self.unavailableEnvelope(
                "prompt_working_folder only works in an attended Osaurus chat window; this run has "
                    + "no user present to pick a folder. Continue without file tools: deliver content "
                    + "with share_artifact or in your answer and say why."
            )
        }

        guard let box = ChatExecutionContext.currentChatSessionBox else {
            return Self.unavailableEnvelope(
                "prompt_working_folder needs a live chat session to attach the folder to, and this "
                    + "execution has none. Ask the user to attach a folder via the Folder chip instead."
            )
        }

        if Self.isHeadlessTestProcess {
            return Self.unavailableEnvelope(
                "prompt_working_folder cannot present a folder picker in a headless process."
            )
        }

        let override = Self.pickerOverrideForTests
        let outcome = await Self.runOnSession(box: box, reason: reason, testPicker: override)
        return Self.envelope(for: outcome, reason: reason)
    }

    /// Resolve the weak session and run the pick on the main actor. The
    /// session may have been torn down between the tool call and now (chat
    /// closed mid-turn); that is a failure, never a cancel.
    @MainActor
    private static func runOnSession(
        box: WeakChatSessionBox,
        reason: String,
        testPicker: TestPicker?
    ) async -> WorkingFolderPromptOutcome {
        guard let session = box.session else {
            return .failed("the chat session that started this run is gone")
        }
        return await session.promptWorkingFolderFromTool(reason: reason, testPicker: testPicker)
    }

    // MARK: - Envelopes

    private static func unavailableEnvelope(_ message: String) -> String {
        ToolEnvelope.failure(
            kind: .unavailable,
            message: message,
            tool: "prompt_working_folder",
            retryable: false
        )
    }

    static func envelope(for outcome: WorkingFolderPromptOutcome, reason: String) -> String {
        switch outcome {
        case .attached(let path):
            return ToolEnvelope.success(
                tool: "prompt_working_folder",
                result: [
                    "text":
                        "Working folder attached: \(path). The file tools ("
                        + unlockedToolNames.joined(separator: ", ")
                        + ") are now available and your run continues with this folder as the root. "
                        + "Use paths relative to it.",
                    "path": path,
                    "tools": unlockedToolNames,
                    "reason": reason,
                ]
            )
        case .cancelled:
            // `user_denied` is a terminal denial in the chat loop: the run
            // stops here and this message is shown to the user verbatim
            // (prefixed "The requested action was not completed."), then
            // stays in history for the model's next turn. Word it for both
            // readers — no model-only instructions on screen.
            return ToolEnvelope.failure(
                kind: .userDenied,
                message:
                    "The folder picker was dismissed, so no working folder was attached and nothing "
                    + "was written. To save files, attach a folder with the Folder chip or ask again; "
                    + "otherwise the content can be given directly in the chat.",
                tool: "prompt_working_folder",
                retryable: false
            )
        case .failed(let message):
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "The folder could not be attached: \(message). Ask the user to attach a folder via "
                    + "the Folder chip, or deliver the content with share_artifact.",
                tool: "prompt_working_folder",
                retryable: false
            )
        }
    }
}

// MARK: - ChatSession seam

extension ChatSession {

    /// Reasons the prompt cannot run on THIS session, checked before any
    /// picker is shown. `nil` means proceed.
    func workingFolderPromptPrecondition() -> WorkingFolderPromptOutcome? {
        if isRemoteAgentTarget {
            return .failed(
                "this chat talks to a remote agent, whose working folder lives on its own host"
            )
        }
        if folderState.hasActiveFolder, let path = folderState.persistedPath {
            return .failed(
                "this chat already has a working folder (\(path)); the file tools are already "
                    + "available or will be on the next turn"
            )
        }
        return nil
    }

    /// Run the Folder chip's pick sequence from a tool call: present the
    /// picker as a sheet on this chat's window, then — on a pick — disable the
    /// agent's sandbox (a trusted folder makes native execution
    /// authoritative) and remember the folder on the agent so fresh chats and
    /// folder-less dispatches seed from it. Fails closed like the chip: if the
    /// sandbox cannot be disabled the chat folder and the sticky record are
    /// both rolled back, so no state appears trusted while the VM boundary is
    /// still authoritative.
    func promptWorkingFolderFromTool(
        reason: String,
        testPicker: PromptWorkingFolderTool.TestPicker?
    ) async -> WorkingFolderPromptOutcome {
        if let precondition = workingFolderPromptPrecondition() {
            return precondition
        }
        let agentId = self.agentId ?? Agent.defaultId
        let manager = AgentManager.shared

        let picked: FolderContext?
        if let testPicker {
            guard let url = await testPicker(reason) else { return .cancelled }
            picked = await folderState.setFolder(url)
            if picked == nil {
                return .failed("the chosen folder could not be opened or bookmarked")
            }
        } else {
            let window = windowState.flatMap { ChatWindowManager.shared.getNSWindow(id: $0.windowId) }
            picked = await folderState.selectFolder(from: window, message: reason)
            guard picked != nil else {
                // `selectFolder` returns nil for BOTH a cancel and a failed
                // bookmark; a cancel leaves the state untouched, a failure
                // never set it, so neither has a folder to roll back.
                return .cancelled
            }
        }

        do {
            _ = try await manager.disableSandboxForHostFolder(agentId: agentId)
        } catch {
            folderState.clearFolder()
            manager.clearWorkingFolder(for: agentId)
            return .failed("could not disable sandbox execution for this agent: \(error.localizedDescription)")
        }
        // Sticky: same record the Folder chip writes (the Orchestrator's
        // lands in `DefaultAgentConfiguration`).
        manager.updateWorkingFolder(
            for: agentId,
            bookmark: folderState.persistedBookmark,
            path: folderState.persistedPath
        )
        let path = folderState.persistedPath ?? picked?.rootPath.standardizedFileURL.path ?? ""
        return .attached(path: path)
    }
}

//
//  HarnessBridgeCalls.swift
//  osaurus
//
//  Tool calls a harness makes back into Osaurus over `/mcp/call` with its
//  agent token: which of them run as the chat's own call, the harness's id
//  for each, and the in-flight calls a Stop cancels.
//

import Foundation

enum HarnessBridgeCall {
    /// The harness's own id for the call (Claude Code's `tool_use` id), set
    /// by `osaurus mcp` from the request's `_meta`.
    static let toolCallIdHeader = "X-Osaurus-Tool-Call-Id"
    /// Claude Code's `_meta` key for the same id.
    static let claudeToolUseIdMetaKey = "claudecode/toolUseId"

    /// Calls that run as the chat's own when the token's chat is open in a
    /// window: the person is there to see the run and answer its prompts.
    static let attendedToolNames: Set<String> = [RunWorkflowTool.toolName]

    struct AttendedScope: Sendable, Equatable {
        var folderRoot: URL?
    }

    /// The chat binding for `toolName` under `grant`, or nil to keep the
    /// call on the external surface.
    @MainActor
    static func attendedScope(grant: HarnessGrant?, toolName: String) -> AttendedScope? {
        guard let grant, let chatId = grant.chatId, attendedToolNames.contains(toolName) else { return nil }
        return openChat(chatId)
    }

    /// The chat's scope when a window shows it; a seam for tests.
    @MainActor
    static var openChat: @MainActor (UUID) -> AttendedScope? = { chatId in
        ChatWindowManager.shared.session(forSessionId: chatId).map {
            AttendedScope(folderRoot: $0.folderState.context?.rootPath)
        }
    }

    /// The header value when it looks like a tool-use id, else nil. It only
    /// names a row of the token's own chat.
    static func toolCallId(fromHeader value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.count <= 128,
            value.unicodeScalars.allSatisfy({
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" || $0 == "-"
            })
        else { return nil }
        return value
    }
}

/// In-flight bridge calls per chat, so ending the chat's turn cancels them.
/// Claude Code's own interrupt cancels a call by closing its request; this
/// covers a harness that exits or never sends one.
actor HarnessBridgeCalls {
    static let shared = HarnessBridgeCalls()

    /// A finished call as Osaurus ran it. A harness's stream shows only the
    /// tool's name, so these are what the chat's tool cards and the
    /// Architect eval read.
    struct Record: Sendable, Equatable {
        var toolCallId: String?
        var name: String
        var arguments: String
        var result: String
        var isError: Bool
        var durationMs: Double
    }

    static let recordLimit = 200
    static let fieldLimit = 64_000

    private var calls: [UUID: [UUID: Task<String, Error>]] = [:]
    private var records: [UUID: [Record]] = [:]

    /// Runs `body` as a tracked task. It inherits the caller's task-locals,
    /// and cancelling the caller cancels it.
    func run(chatId: UUID?, _ body: @escaping @Sendable () async throws -> String) async throws -> String {
        let task = Task { try await body() }
        guard let chatId else { return try await Self.value(of: task) }
        let id = UUID()
        calls[chatId, default: [:]][id] = task
        defer {
            calls[chatId]?[id] = nil
            if calls[chatId]?.isEmpty == true { calls[chatId] = nil }
        }
        return try await Self.value(of: task)
    }

    private static func value(of task: Task<String, Error>) async throws -> String {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancelAll(chatId: UUID) {
        guard let tasks = calls.removeValue(forKey: chatId) else { return }
        for task in tasks.values { task.cancel() }
    }

    func inFlightCount(chatId: UUID) -> Int { calls[chatId]?.count ?? 0 }

    /// Keeps the newest `recordLimit` calls per chat, each field cut at
    /// `fieldLimit` characters.
    func record(_ record: Record, chatId: UUID) {
        var record = record
        record.arguments = String(record.arguments.prefix(Self.fieldLimit))
        record.result = String(record.result.prefix(Self.fieldLimit))
        var list = records[chatId, default: []]
        list.append(record)
        if list.count > Self.recordLimit { list.removeFirst(list.count - Self.recordLimit) }
        records[chatId] = list
    }

    func records(chatId: UUID) -> [Record] { records[chatId] ?? [] }

    func record(chatId: UUID, toolCallId: String) -> Record? {
        records[chatId]?.last { $0.toolCallId == toolCallId }
    }

    func clearRecords(chatId: UUID) { records[chatId] = nil }
}

//
//  FileHistoryTestEnv.swift
//  osaurusTests
//
//  An isolated file history journal (in-memory DB, temp object store,
//  temp sandbox roots) plus a helper that runs a tool through
//  `FileChangeCapture.run` exactly as `ToolRegistry` does, so tests see
//  the same change sets, `operation_id`s, and undo behavior as production.
//

import Foundation

@testable import OsaurusCore

struct FileHistoryTestEnv {
    static let agent = "tester"

    let tmp: URL
    let db: ChatHistoryDatabase
    let journal: FileChangeJournal
    let agentsRoot: URL
    let agentHome: URL
    let sharedRoot: URL
    let storeRoot: URL
    let provider: @Sendable (String, SandboxWorkspaceRootKind) -> URL

    /// `provider` overrides where sandbox roots live on the host (defaults
    /// to temp dirs under the env).
    static func make(
        provider override: (@Sendable (String, SandboxWorkspaceRootKind) -> URL)? = nil,
        shadowEntryLimit: Int = FileChangeJournal.maxShadowEntries,
        legacyBaselinesRoot: URL? = nil
    ) throws -> FileHistoryTestEnv {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("osu-file-history-\(UUID().uuidString)", isDirectory: true)
        let agentsRoot = tmp.appendingPathComponent("agents", isDirectory: true)
        let agentHome = agentsRoot.appendingPathComponent(agent, isDirectory: true)
        let sharedRoot = tmp.appendingPathComponent("shared", isDirectory: true)
        let storeRoot = tmp.appendingPathComponent("file-history", isDirectory: true)
        try fm.createDirectory(at: agentHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharedRoot, withIntermediateDirectories: true)

        let db = ChatHistoryDatabase()
        try db.openInMemory()
        let provider: @Sendable (String, SandboxWorkspaceRootKind) -> URL = override ?? { name, kind in
            switch kind {
            case .agentHome: return agentsRoot.appendingPathComponent(name, isDirectory: true)
            case .shared: return sharedRoot
            case .hostFolder: return URL(fileURLWithPath: name, isDirectory: true)
            }
        }
        let journal = FileChangeJournal(
            database: db, storeRoot: storeRoot, hostRootProvider: provider,
            legacyBaselinesRoot: legacyBaselinesRoot, shadowEntryLimit: shadowEntryLimit)
        return FileHistoryTestEnv(
            tmp: tmp, db: db, journal: journal, agentsRoot: agentsRoot, agentHome: agentHome,
            sharedRoot: sharedRoot, storeRoot: storeRoot, provider: provider)
    }

    /// A fresh journal over the same DB + store: simulates an app relaunch.
    func relaunched() -> FileChangeJournal {
        FileChangeJournal(database: db, storeRoot: storeRoot, hostRootProvider: provider)
    }

    /// Run `tool` the way the registry does: session bound, journal capture
    /// around the body, `currentChangeSetId` bound for `operation_id`.
    func run(
        _ tool: any OsaurusTool,
        _ argumentsJSON: String,
        sessionId: String,
        folder: URL? = nil,
        sandboxAgent: String? = nil,
        bridgeAgent: String? = nil,
        toolCallId: String? = nil
    ) async throws -> String {
        let context = FileChangeCapture.Context(
            sessionId: sessionId, toolName: tool.name, toolCallId: toolCallId,
            folderRoot: folder, sandboxAgent: sandboxAgent, bridgeAgent: bridgeAgent)
        return try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await FileChangeCapture.run(
                tool: tool, argumentsJSON: argumentsJSON, context: context, journal: journal
            ) {
                try await tool.execute(argumentsJSON: argumentsJSON)
            }
        }
    }

    /// Call a tool (e.g. `file_undo`) with just the session bound.
    func call(_ tool: any OsaurusTool, _ argumentsJSON: String, sessionId: String) async throws -> String {
        try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
            try await tool.execute(argumentsJSON: argumentsJSON)
        }
    }

    static func json(_ args: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmp)
    }
}

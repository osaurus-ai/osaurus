//
//  FileChangeCapture.swift
//  osaurus
//
//  Glue between tool dispatch and the file history journal. Resolves which
//  roots a mutating call can touch (sandbox agent home / shared workspace,
//  the chat's host folder), maps the tool's declared targets onto those
//  roots, and runs the body inside a journal capture. When a root can't be
//  snapshotted, the user is asked before the call runs: nothing irreversible
//  happens silently.
//

import Foundation

public enum FileChangeCapture {

    /// Where the executing call can write.
    public struct Context: Sendable {
        public var sessionId: String
        public var toolName: String
        public var toolCallId: String?
        public var turnId: UUID?
        /// The executing chat's host folder, when one is selected.
        public var folderRoot: URL?
        /// Sandbox agent for sandbox tools.
        public var sandboxAgent: String?
        /// Sandbox agent reachable from host tools in combined mode.
        public var bridgeAgent: String?

        public init(
            sessionId: String,
            toolName: String,
            toolCallId: String? = nil,
            turnId: UUID? = nil,
            folderRoot: URL? = nil,
            sandboxAgent: String? = nil,
            bridgeAgent: String? = nil
        ) {
            self.sessionId = sessionId
            self.toolName = toolName
            self.toolCallId = toolCallId
            self.turnId = turnId
            self.folderRoot = folderRoot
            self.sandboxAgent = sandboxAgent
            self.bridgeAgent = bridgeAgent
        }
    }

    enum Resolution: Equatable {
        /// Relative path under this root.
        case path(String)
        /// Belongs to another root (or outside every tracked root).
        case notMine
        /// Can't be mapped faithfully: scan the whole root instead.
        case opaque
    }

    // MARK: - Targets

    static func targets(
        for tool: any OsaurusTool, argumentsJSON: String, context: Context
    ) -> [FileChangeJournal.RootTarget] {
        let declared = tool.declaredMutationTargets(argumentsJSON: argumentsJSON)
        let fallback = tool.fallbackMutationTargets(argumentsJSON: argumentsJSON)
        var targets: [FileChangeJournal.RootTarget] = []

        func add(
            _ kind: SandboxWorkspaceRootKind, _ rootId: String,
            resolve: (String) -> Resolution
        ) {
            let fallbackPaths = fallback.flatMap { mapAll($0, resolve) }.flatMap {
                $0.isEmpty ? nil : $0
            }
            guard let declared else {
                targets.append(.init(kind: kind, rootId: rootId, fallbackPaths: fallbackPaths))
                return
            }
            switch mapAll(declared, resolve) {
            case .none:
                targets.append(.init(kind: kind, rootId: rootId, fallbackPaths: fallbackPaths))
            case .some(let paths) where paths.isEmpty:
                return  // nothing this call names lives under this root
            case .some(let paths):
                targets.append(.init(kind: kind, rootId: rootId, declaredPaths: paths))
            }
        }

        if tool.mutatesSandboxWorkspace, let agent = context.sandboxAgent {
            for kind in SandboxWorkspaceRootKind.sandboxRoots {
                add(kind, agent) { resolveSandbox($0, kind: kind, agent: agent, relativeIsHome: true) }
            }
        } else if tool.mutatesHostFolder {
            if let folder = context.folderRoot {
                add(.hostFolder, folder.standardizedFileURL.path) { resolveHost($0, folder: folder) }
            }
            if let agent = context.bridgeAgent {
                for kind in SandboxWorkspaceRootKind.sandboxRoots {
                    add(kind, agent) {
                        resolveSandbox($0, kind: kind, agent: agent, relativeIsHome: false)
                    }
                }
            }
        }
        return targets
    }

    /// Map every raw path; nil when any is opaque (whole-root scan).
    private static func mapAll(_ raws: [String], _ resolve: (String) -> Resolution) -> [String]? {
        var paths: [String] = []
        for raw in raws {
            switch resolve(raw) {
            case .path(let rel): paths.append(rel)
            case .notMine: continue
            case .opaque: return nil
            }
        }
        return paths
    }

    static func resolveHost(_ raw: String, folder: URL) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .opaque }
        let rootPath = folder.standardized.path
        if trimmed.hasPrefix("/workspace"), !rootPath.hasPrefix("/workspace") { return .notMine }
        guard let url = try? FolderToolHelpers.resolvePath(trimmed, rootPath: folder) else {
            return .opaque
        }
        let path = url.standardized.path
        guard path.hasPrefix(rootPath + "/") else { return .opaque }
        let rel = FileChangeJournal.normalize(String(path.dropFirst(rootPath.count + 1)))
        return rel.isEmpty ? .opaque : .path(rel)
    }

    static func resolveSandbox(
        _ raw: String, kind: SandboxWorkspaceRootKind, agent: String, relativeIsHome: Bool
    ) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "~" else { return .opaque }
        let home = OsaurusPaths.inContainerAgentHome(agent)
        let shared = "/workspace/shared"
        let owner: SandboxWorkspaceRootKind
        let rel: String
        if trimmed.hasPrefix("~/") {
            owner = .agentHome
            rel = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix(shared + "/") {
            owner = .shared
            rel = String(trimmed.dropFirst(shared.count + 1))
        } else if trimmed.hasPrefix(home + "/") {
            owner = .agentHome
            rel = String(trimmed.dropFirst(home.count + 1))
        } else if trimmed.hasPrefix("/") {
            return .notMine
        } else {
            guard relativeIsHome else { return .notMine }
            owner = .agentHome
            rel = trimmed
        }
        guard owner == kind else { return .notMine }
        let normalized = FileChangeJournal.normalize(rel)
        return normalized.isEmpty ? .opaque : .path(normalized)
    }

    /// String values of `keys` in a tool's JSON arguments, for
    /// `declaredMutationTargets`. Nil (opaque) when the arguments don't
    /// parse or a required key is missing.
    public static func declaredPaths(
        _ argumentsJSON: String, keys: [String], optionalKeys: [String] = []
    ) -> [String]? {
        guard let data = argumentsJSON.data(using: .utf8),
            let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        var paths: [String] = []
        for key in keys {
            guard let value = args[key] as? String, !value.isEmpty else { return nil }
            paths.append(value)
        }
        for key in optionalKeys {
            if let value = args[key] as? String, !value.isEmpty { paths.append(value) }
        }
        return paths
    }

    // MARK: - Run

    /// Run `body` inside a journal capture. Returns a failure envelope
    /// instead of running when a root can't be snapshotted and the user
    /// declines (or can't be asked).
    static func run(
        tool: any OsaurusTool,
        argumentsJSON: String,
        context: Context,
        journal: FileChangeJournal = .shared,
        isolation: isolated (any Actor)? = #isolation,
        body: () async throws -> String
    ) async throws -> String {
        let targets = targets(for: tool, argumentsJSON: argumentsJSON, context: context)
        guard !targets.isEmpty else { return try await body() }
        let token = await journal.beginCapture(
            sessionId: context.sessionId,
            toolName: context.toolName,
            toolCallId: context.toolCallId,
            turnId: context.turnId,
            targets: targets
        )
        if !token.isFullyTracked {
            let approved = await approveUntracked(
                toolName: context.toolName, argumentsJSON: argumentsJSON,
                reasons: token.untrackedReasons)
            guard approved else {
                await journal.abandonCapture(token)
                return ToolEnvelope.failure(
                    kind: .userDenied,
                    message:
                        "Not run: Osaurus can't snapshot "
                        + token.untrackedReasons.joined(separator: "; ")
                        + ", so this call's file changes couldn't be undone. Use precise file tools "
                        + "(`file_write`, `file_edit`, `file_copy`) on specific paths instead.",
                    tool: context.toolName,
                    retryable: false
                )
            }
        }
        let result: String
        do {
            result = try await ChatExecutionContext.$currentChangeSetId.withValue(token.setId) {
                try await body()
            }
        } catch {
            // Reconcile whatever was written before the throw.
            await journal.endCapture(token)
            throw error
        }
        await journal.endCapture(token)
        return result
    }

    /// Ask before running a call whose changes can't be recorded.
    /// Unattended runs that pre-approved tool prompts proceed (the set is
    /// still recorded as untracked); runs that deny prompts refuse.
    private static func approveUntracked(
        toolName: String, argumentsJSON: String, reasons: [String]
    ) async -> Bool {
        if ChatExecutionContext.autoApproveToolPrompts { return true }
        if ChatExecutionContext.denyUnapprovedToolPrompts { return false }
        return await ToolPermissionPromptService.requestApproval(
            toolName: toolName,
            description:
                "This action can't be undone. Osaurus can't snapshot "
                + reasons.joined(separator: "; ")
                + ", so changes it makes won't be recoverable from File Changes.",
            argumentsJSON: argumentsJSON,
            perCallApprovalOnly: true
        )
    }
}

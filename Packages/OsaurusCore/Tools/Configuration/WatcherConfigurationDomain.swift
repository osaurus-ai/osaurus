//
//  WatcherConfigurationDomain.swift
//  osaurus
//
//  Default-agent configure tool for folder watchers (WatcherManager).
//  One tool, `osaurus_watcher`, fans out across five actions:
//   - create
//   - update
//   - delete
//   - enable / disable
//
//  Chat-created watchers carry a plain folder path, not a security-scoped
//  bookmark (there is no folder picker in chat). `WatcherManager` falls
//  back to `watchPath` when no bookmark exists, so this works for folders
//  Osaurus can already access; if macOS denies access, the tool directs
//  the user to re-pick the folder in the Watchers tab.
//

import Foundation

enum WatcherConfigurationDomain {
    static let domain = ConfigurationDomain(
        id: "watchers",
        displayName: "Folder Watchers",
        summary: "Folder watchers that run an agent when files in a directory change.",
        menuHint: "create / update / delete / enable folder watchers",
        searchKeywords: [
            "watcher", "watchers", "folder watcher", "file watcher",
            "watch folder", "watch directory", "monitor folder",
            "when files change", "on file change", "downloads folder",
            "create watcher", "update watcher", "edit watcher",
            "delete watcher", "remove watcher",
            "enable watcher", "disable watcher", "pause watcher",
        ],
        exampleQueries: [
            "watch my downloads folder and organize new files",
            "create a watcher on ~/Documents/inbox",
            "disable the screenshots watcher",
            "delete the downloads watcher",
        ],
        tools: [
            OsaurusWatcherTool()
        ],
        writeToolNames: [
            "osaurus_watcher"
        ]
    )
}

// MARK: - osaurus_watcher

public final class OsaurusWatcherTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public let name = "osaurus_watcher"
    public let description =
        "Manage folder watchers (run a custom agent when files in a directory change). `action`: "
        + "create (needs `name`, `instructions`, `path`, and `agent_id` of a custom agent — the "
        + "Default agent cannot run watchers), update (needs `id`; other fields patch), delete "
        + "(needs `id`), enable (needs `id`; resumes), disable (needs `id`; pauses). Chat-created "
        + "watchers use a plain folder path; if macOS blocks access to it, the user must re-pick "
        + "the folder in the Watchers tab."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("create"), .string("update"), .string("delete"),
                    .string("enable"), .string("disable"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "id": .object([
                "type": .string("string"),
                "description": .string("Watcher UUID. Required for update / delete / enable / disable."),
            ]),
            "name": .object(["type": .string("string")]),
            "instructions": .object([
                "type": .string("string"),
                "description": .string("What the agent should do when the folder changes."),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Absolute path of an existing directory to watch (~ is expanded). Required for create."
                ),
            ]),
            "agent_id": .object([
                "type": .string("string"),
                "description": .string(
                    "UUID of the custom agent that runs the watcher. Required for create; the "
                        + "built-in Default agent cannot run watchers."
                ),
            ]),
            "recursive": .object([
                "type": .string("boolean"),
                "description": .string("Also monitor subdirectories. Default false."),
            ]),
            "responsiveness": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("fast"), .string("balanced"), .string("patient"),
                    .string("relaxed"), .string("deferred"), .string("extended"),
                ]),
                "description": .string(
                    "Debounce before triggering: fast ~200ms (screenshots/single drops), balanced "
                        + "~1s (default), patient ~3s (downloads/batches), relaxed ~1min, deferred "
                        + "~5min, extended ~10min (single trigger after an editing session settles)."
                ),
            ]),
            "enabled": .object(["type": .string("boolean")]),
        ]),
        "required": .array([.string("action")]),
    ])

    public var requirements: [String] { [ConfigurationToolBase.requirement] }
    var defaultPermissionPolicy: ToolPermissionPolicy { ConfigurationToolBase.defaultPolicy }

    public init() {}

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = ConfigurationToolBase.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(
            args,
            allowed: ["create", "update", "delete", "enable", "disable"]
        )
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "create": return await handleCreate(args)
        case "update": return await handleUpdate(args)
        case "delete": return await handleDelete(args)
        case "enable", "disable": return await handleEnable(args, action: action)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    // MARK: - shared parsing

    /// Expand `~`, require an existing directory. Returns the normalized
    /// path or a pre-formatted failure envelope.
    private func validatedDirectoryPath(_ raw: String) -> ArgumentRequirement<String> {
        let expanded = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`path` must be an existing directory. `\(expanded)` was not found or is "
                        + "not a directory.",
                    field: "path",
                    tool: name
                )
            )
        }
        return .value(expanded)
    }

    /// The watcher runtime refuses nil/built-in agents at dispatch
    /// (`Agent.rejectBuiltInForExternalSurface`), so the tool enforces the
    /// same contract up front: a watcher must target an explicit custom
    /// agent, and the Default agent's id is rejected rather than silently
    /// creating a watcher that would never run.
    private func parsedAgentId(_ raw: String) -> ArgumentRequirement<UUID> {
        guard let uuid = UUID(uuidString: raw) else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`agent_id` must be a valid UUID.",
                    field: "agent_id",
                    tool: name
                )
            )
        }
        if uuid == Agent.defaultId {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Watchers cannot run on the Default agent. Pass the UUID of a custom "
                        + "agent (osaurus_list({scope:'agents'})), or create one first with "
                        + "osaurus_agent({action:'create', ...}).",
                    field: "agent_id",
                    tool: name,
                    retryable: false
                )
            )
        }
        return .value(uuid)
    }

    private func responsivenessValue(_ raw: String) -> ArgumentRequirement<Responsiveness> {
        guard let r = Responsiveness(rawValue: raw.lowercased()) else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`responsiveness` must be one of: fast, balanced, patient, relaxed, "
                        + "deferred, extended.",
                    field: "responsiveness",
                    tool: name
                )
            )
        }
        return .value(r)
    }

    // MARK: - create

    private func handleCreate(_ args: [String: Any]) async -> String {
        // Surface ALL missing required fields at once (mirrors
        // osaurus_schedule create) so a partial call resolves in one retry.
        let requiredForCreate: [(key: String, hint: String)] = [
            ("name", "display name"),
            ("instructions", "what the agent should do on changes"),
            ("path", "absolute path of an existing directory"),
            ("agent_id", "UUID of the custom agent that runs the watcher"),
        ]
        let missing = requiredForCreate.filter { field in
            guard let value = args[field.key] as? String else { return true }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if missing.count > 1 {
            let list = missing.map { "`\($0.key)` (\($0.hint))" }.joined(separator: ", ")
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Watcher create is missing required fields: \(list). "
                    + "Send them all together in one osaurus_watcher({action:'create', ...}) call.",
                field: missing.first?.key,
                tool: name
            )
        }
        let nameReq = requireString(args, "name", expected: "non-empty display name", tool: name)
        guard case .value(let watcherName) = nameReq else { return nameReq.failureEnvelope ?? "" }
        let instrReq = requireString(args, "instructions", expected: "non-empty instructions", tool: name)
        guard case .value(let instructions) = instrReq else { return instrReq.failureEnvelope ?? "" }
        let pathReq = requireString(args, "path", expected: "directory path", tool: name)
        guard case .value(let rawPath) = pathReq else { return pathReq.failureEnvelope ?? "" }

        let path: String
        switch validatedDirectoryPath(rawPath) {
        case .failure(let envelope): return envelope
        case .value(let p): path = p
        }

        let agentReq = requireString(args, "agent_id", expected: "UUID of a custom agent", tool: name)
        guard case .value(let rawAgentId) = agentReq else { return agentReq.failureEnvelope ?? "" }
        let agentId: UUID
        switch parsedAgentId(rawAgentId) {
        case .failure(let envelope): return envelope
        case .value(let id): agentId = id
        }

        var responsiveness: Responsiveness = .balanced
        if let raw = args["responsiveness"] as? String {
            switch responsivenessValue(raw) {
            case .failure(let envelope): return envelope
            case .value(let r): responsiveness = r
            }
        }

        let recursive = coerceBool(args["recursive"]) ?? false
        let isEnabled = coerceBool(args["enabled"]) ?? true

        return await MainActor.run {
            if AgentManager.shared.agent(for: agentId) == nil {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No agent found with id \(agentId.uuidString).",
                    field: "agent_id",
                    tool: name
                )
            }
            let watcher = WatcherManager.shared.create(
                name: watcherName,
                instructions: instructions,
                agentId: agentId,
                watchPath: path,
                watchBookmark: nil,
                isEnabled: isEnabled,
                recursive: recursive,
                responsiveness: responsiveness
            )
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "watcher_id": watcher.id.uuidString,
                    "name": watcher.name,
                    "path": path,
                    "status": "created",
                    "note":
                        "The watcher uses a plain folder path. If macOS blocks access to it, "
                        + "re-pick the folder in the Watchers tab.",
                ]
            )
        }
    }

    // MARK: - update

    private func handleUpdate(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "watcher UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }

        // Extract patch values into Sendable locals before the @MainActor hop.
        let newName = args["name"] as? String
        let newInstructions = args["instructions"] as? String
        let newRecursive = coerceBool(args["recursive"])
        let newEnabled = coerceBool(args["enabled"])

        var newPath: String?
        if let raw = args["path"] as? String {
            switch validatedDirectoryPath(raw) {
            case .failure(let envelope): return envelope
            case .value(let p): newPath = p
            }
        }

        var agentIdPatch: UUID?
        if let raw = args["agent_id"] as? String {
            switch parsedAgentId(raw) {
            case .failure(let envelope): return envelope
            case .value(let id): agentIdPatch = id
            }
        }

        var newResponsiveness: Responsiveness?
        if let raw = args["responsiveness"] as? String {
            switch responsivenessValue(raw) {
            case .failure(let envelope): return envelope
            case .value(let r): newResponsiveness = r
            }
        }

        return await MainActor.run {
            guard var watcher = WatcherManager.shared.watchers.first(where: { $0.id == id }) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No watcher found with id \(idStr).",
                    field: "id",
                    tool: name
                )
            }
            if let agentId = agentIdPatch {
                if AgentManager.shared.agent(for: agentId) == nil {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "No agent found with id \(agentId.uuidString).",
                        field: "agent_id",
                        tool: name
                    )
                }
                watcher.agentId = agentId
            }
            if let v = newName { watcher.name = v }
            if let v = newInstructions { watcher.instructions = v }
            if let v = newPath {
                // A chat-supplied path replaces any picker-granted bookmark;
                // the old bookmark points at the old folder and must not win
                // over the new path in resolveWatchPath.
                watcher.watchPath = v
                watcher.watchBookmark = nil
            }
            if let v = newRecursive { watcher.recursive = v }
            if let v = newResponsiveness { watcher.responsiveness = v }
            if let v = newEnabled { watcher.isEnabled = v }

            WatcherManager.shared.update(watcher)
            return ToolEnvelope.success(
                tool: name,
                result: ["watcher_id": watcher.id.uuidString, "status": "updated"]
            )
        }
    }

    // MARK: - delete

    private func handleDelete(_ args: [String: Any]) async -> String {
        let idReq = requireString(args, "id", expected: "watcher UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }

        let deleted: Bool = await MainActor.run { WatcherManager.shared.delete(id: id) }
        if !deleted {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No watcher found with id \(idStr).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["watcher_id": id.uuidString, "status": "deleted"]
        )
    }

    // MARK: - enable / disable

    private func handleEnable(_ args: [String: Any], action: String) async -> String {
        let idReq = requireString(args, "id", expected: "watcher UUID", tool: name)
        guard case .value(let idStr) = idReq else { return idReq.failureEnvelope ?? "" }
        guard let id = UUID(uuidString: idStr) else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "`id` must be a valid UUID.", tool: name)
        }
        // The action carries the intent; an explicit `enabled` boolean
        // overrides it — matching osaurus_schedule semantics.
        let enabled = coerceBool(args["enabled"]) ?? (action == "enable")

        let ok: Bool = await MainActor.run {
            guard WatcherManager.shared.watchers.contains(where: { $0.id == id }) else { return false }
            WatcherManager.shared.setEnabled(id, enabled: enabled)
            return true
        }
        guard ok else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No watcher found with id \(idStr).",
                field: "id",
                tool: name
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["watcher_id": id.uuidString, "enabled": enabled, "status": "updated"]
        )
    }
}

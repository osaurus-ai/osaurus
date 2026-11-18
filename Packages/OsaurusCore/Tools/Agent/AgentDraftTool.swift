//
//  AgentDraftTool.swift
//  osaurus
//
//  The Configurator's New Agent draft tool. It reads and patches the
//  unsaved draft bound to the current chat and never creates or saves an
//  agent: only the person's Create Agent click on the agent card does that.
//  The composer keeps it out of every other agent's schema.
//

import Foundation

final class AgentDraftTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    static let toolName = "agent_draft"
    let name = AgentDraftTool.toolName
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto

    /// Matches `tools` returns for a query.
    static let toolMatchLimit = 20

    /// Keys a `patch`'s `agent` object may carry.
    static let agentKeys: [String] = [
        "name", "description", "avatar", "model", "system_prompt", "template",
        "capabilities", "tools", "mcp_servers", "plugins",
    ]

    let description =
        "Read or change the New Agent draft shown beside this chat. Nothing is created until the user clicks "
        + "Create Agent on the card. `get` returns the draft, what is still missing, and which fields the user edited "
        + "themselves. `patch` sets fields with an `agent` object (the `osaurus_config` agent keys: name, "
        + "description, avatar, model, system_prompt, capabilities, tools, mcp_servers, plugins); if any part is "
        + "invalid nothing changes. Fields the user edited stay as they set them unless `override_user_edits`. "
        + "`tools` searches what the agent can be given on this Mac: built-in capabilities, Apple apps, and "
        + "installed tools, MCP servers, and plugins, with their exact names. `import` reads a link, snippet, "
        + "command, or file the user shared (`source`): an agent file fills the draft, and skills and MCP servers "
        + "are listed on the card to install when the user clicks Create."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("get"), .string("patch"), .string("tools"), .string("import")]),
            ]),
            "source": AgentDraftTool.stringField(
                "For `import`: the link, snippet, command, or file text exactly as the user shared it."),
            "agent": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "description": .string("For `patch`: only the fields to change."),
                "properties": .object([
                    "name": AgentDraftTool.stringField("Short, friendly name."),
                    "description": AgentDraftTool.stringField(
                        "One sentence on what the agent does, as other agents see it when routing work."),
                    "avatar": .object([
                        "type": .string("string"),
                        "enum": .array(([""] + AgentMascot.allCases.map(\.rawValue)).map { .string($0) }),
                        "description": .string("Mascot id; \"\" shows the name's initial."),
                    ]),
                    "model": .object([
                        "type": .array([.string("string"), .string("null")]),
                        "description": .string(
                            "Model id from `osaurus_inspect` (models); null uses the default model."),
                    ]),
                    "system_prompt": AgentDraftTool.stringField(
                        "The agent's instructions, written to the agent in second person."),
                    "template": AgentDraftTool.stringField(
                        "Starter template id that seeds description and instructions: "
                            + AgentStarterTemplate.configTemplateIds.joined(separator: ", ") + "."),
                    "capabilities": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(true),
                        "description": .string(
                            "Built-in abilities, each a boolean (e.g. {\"web_search_enabled\": true}), plus "
                                + "`apple_apps`: a list that replaces the set ("
                                + AppleApp.allCases.map(\.rawValue).joined(separator: ", ")
                                + "). Keys: " + AgentDraftTool.capabilityKeys.joined(separator: ", ") + "."),
                    ]),
                    "tools": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "properties": .object([
                            "mode": .object([
                                "type": .string("string"), "enum": .array([.string("auto"), .string("manual")]),
                            ]),
                            "enabled": .object([
                                "type": .string("array"), "items": .object(["type": .string("string")]),
                                "description": .string("Manual mode: exact tool names from `tools`."),
                            ]),
                        ]),
                        "description": .string(
                            "auto (default): every installed tool is available and picked per message. manual: "
                                + "only `enabled` plus the listed `mcp_servers` / `plugins`."),
                    ]),
                    "mcp_servers": AgentDraftTool.groupField("MCP server names"),
                    "plugins": AgentDraftTool.groupField("Plugin ids"),
                ]),
            ]),
            "reasons": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")]),
                "description": .string(
                    "For `patch`: a short reason per choice, keyed by field (model, avatar), capability key, "
                        + "Apple app (`apple_apps.calendar`), tool name, MCP server, or plugin. The card shows it to the user."),
            ]),
            "why": AgentDraftTool.stringField(
                "For `patch`: one sentence on the change in the user's terms; used as the reason for each "
                    + "changed field that has none in `reasons`."),
            "override_user_edits": .object([
                "type": .string("boolean"),
                "description": .string(
                    "For `patch`: also change fields the user edited on the card. Only when they asked for it."),
            ]),
            "query": AgentDraftTool.stringField(
                "For `tools`: a few words (\"calendar\", \"github issues\", \"browse websites\"). Without it, "
                    + "`tools` lists every capability and provider."),
        ]),
        "required": .array([.string("action")]),
    ])

    private static func stringField(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func groupField(_ what: String) -> JSONValue {
        let list: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(["enabled": list, "disabled": list]),
            "description": .string("Manual mode: \(what) whose tools to add (`enabled`) or remove (`disabled`)."),
        ])
    }

    // MARK: - Execute

    func execute(argumentsJSON: String) async throws -> String {
        let tool = name
        guard ChatExecutionContext.currentAgentId == Agent.configuratorId else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "The agent draft is only available to the Configurator.",
                tool: tool, retryable: false)
        }
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let args = JSONValue.parse(trimmed.isEmpty ? "{}" : trimmed)?.objectValue else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "Arguments must be a JSON object.", tool: tool)
        }
        let sessionID = ChatExecutionContext.currentSessionId
        if args["action"]?.stringValue == "import" {
            return await Self.importSource(args["source"]?.stringValue ?? "", sessionID: sessionID, tool: tool)
        }
        return await MainActor.run {
            guard let draft = AgentDraftStore.shared.draft(forSession: sessionID) else {
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message: "This chat has no New Agent draft. Agents are created from Agents → New agent.",
                    tool: tool, retryable: false)
            }
            switch args["action"]?.stringValue ?? "get" {
            case "get":
                return ToolEnvelope.success(tool: tool, result: Self.summary(draft))
            case "patch":
                return Self.patch(draft, args: args, tool: tool)
            case "tools":
                return ToolEnvelope.success(
                    tool: tool, result: Self.lookup(query: args["query"]?.stringValue, agent: draft.agent))
            case let other:
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "Unknown action `\(other)`. Use get, patch, tools, or import.",
                    field: "action", tool: tool)
            }
        }
    }

    // MARK: - patch

    @MainActor
    static func patch(_ draft: AgentDraft, args: [String: JSONValue], tool: String) -> String {
        guard var object = args["agent"]?.objectValue, !object.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`patch` needs an `agent` object with the fields to change.",
                field: "agent", tool: tool)
        }
        let unknown = object.keys.filter { !agentKeys.contains($0) }.sorted()
        guard unknown.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unknown agent keys: \(unknown.joined(separator: ", ")). Allowed: "
                    + agentKeys.joined(separator: ", ") + ".",
                field: "agent", tool: tool)
        }
        if object["name"] == nil { object["name"] = .string("") }
        let entry: AgentEntry
        do {
            entry = try JSONDecoder().decode(AgentEntry.self, from: JSONEncoder().encode(JSONValue.object(object)))
        } catch {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "The `agent` object does not match the agent keys: \(error).",
                field: "agent", tool: tool)
        }
        var reasons: [String: String] = [:]
        for (key, value) in args["reasons"]?.objectValue ?? [:] {
            if let text = value.stringValue { reasons[key] = text }
        }
        let why = args["why"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !why.isEmpty {
            for field in AgentDraftStore.fields(in: entry) where reasons[field.rawValue] == nil {
                reasons[field.rawValue] = why
            }
        }
        let store = AgentDraftStore.shared
        let result: AgentDraftStore.PatchResult
        do {
            result = try store.applyConfiguratorPatch(
                draft.id, entry: entry, reasons: reasons,
                overrideUserEdits: args["override_user_edits"]?.boolValue == true)
        } catch let error as AgentDraftStore.PatchError {
            return ToolEnvelope.failure(kind: .invalidArgs, message: error.message, field: "agent", tool: tool)
        } catch {
            return ToolEnvelope.failure(kind: .executionError, message: "\(error)", tool: tool)
        }
        let updated = store.draft(id: draft.id) ?? draft
        if draft.touched.isEmpty, !updated.touched.isEmpty { FeatureTelemetry.agentCreationDrafted() }
        var out: [String: Any] = [
            "changed": result.changed.map(\.rawValue),
            "draft": summary(updated),
        ]
        if !result.notes.isEmpty { out["notes"] = result.notes }
        if !result.keptUserEdits.isEmpty {
            out["kept_user_edits"] = result.keptUserEdits.map(\.rawValue)
            out["hint"] =
                "The user set " + result.keptUserEdits.map(\.label).joined(separator: ", ")
                + " on the card, so those stay as they are. Pass `override_user_edits` only if they ask you to "
                + "change them."
        }
        return ToolEnvelope.success(tool: tool, result: out)
    }

    // MARK: - import

    /// Reads what the user shared with the same pipeline as `osaurus_import`.
    /// The first agent fills the draft through `patch`, so the user's own
    /// edits stay; everything else waits on the card until Create.
    static func importSource(_ source: String, sessionID: String?, tool: String) async -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`import` needs `source`: what the user shared.", field: "source",
                tool: tool)
        }
        let target: (id: UUID, agentId: UUID, name: String)? = await MainActor.run {
            guard let draft = AgentDraftStore.shared.draft(forSession: sessionID), !draft.isCreated else { return nil }
            return (draft.id, draft.agent.id, draft.agent.name)
        }
        guard let target else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "This chat has no open New Agent draft.", tool: tool, retryable: false)
        }
        let prepared = await ChatImportPipeline.prepare(
            source: trimmed, userText: ChatExecutionContext.currentUserRequest, surface: .agentCreation,
            targetAgentId: target.agentId, targetAgentName: target.name.isEmpty ? nil : target.name)
        defer { prepared.bundle.cleanUp() }
        return await MainActor.run { queueImport(prepared.review, draftId: target.id, tool: tool) }
    }

    @MainActor
    static func queueImport(_ review: ChatImportReview, draftId: UUID, tool: String) -> String {
        let store = AgentDraftStore.shared
        var items = review.items
        var out: [String: Any] = [:]
        var notes = review.notes

        if let index = items.firstIndex(where: { $0.kind == .agent && $0.allowsKindChoice && $0.isActionable }),
            case .instructions(let spec) = items[index].payload
        {
            items.remove(at: index)
            let entry = ChatImportApplier.agentEntry(spec, name: spec.name)
            do {
                let result = try store.applyConfiguratorPatch(
                    draftId, entry: entry, reasons: [:], overrideUserEdits: false)
                out["filled"] = result.changed.map(\.rawValue)
                if !result.keptUserEdits.isEmpty { out["kept_user_edits"] = result.keptUserEdits.map(\.rawValue) }
                notes += result.notes
            } catch let error as AgentDraftStore.PatchError {
                notes.append("The agent file couldn't fill the draft: \(error.message)")
            } catch {
                notes.append("The agent file couldn't fill the draft: \(error)")
            }
        }

        let installed = items.filter { $0.isActionable && $0.state == .alreadyInstalled }
        let blocked = items.filter { $0.kind != .manualStep && $0.blockedReason != nil }
        let queueable = items.filter {
            ($0.isActionable && $0.state != .alreadyInstalled) || $0.kind == .manualStep
        }
        let queued = store.queueImports(draftId, items: queueable)

        let rows = queued.filter { $0.kind != .manualStep }.map { item -> [String: Any] in
            var row: [String: Any] = ["kind": item.kind.rawValue, "name": item.name]
            if !item.needsSetup.isEmpty { row["needs_setup"] = item.needsSetup }
            if !item.risks.isEmpty { row["risks"] = item.risks }
            return row
        }
        let steps = queued.filter { $0.kind == .manualStep }.map(\.name)
        if out["filled"] == nil, rows.isEmpty, steps.isEmpty {
            var parts = review.refusals.map(\.message)
            if !installed.isEmpty {
                parts.append("Already installed: " + installed.map(\.name).joined(separator: ", ") + ".")
            }
            parts += blocked.map { "\($0.name): \($0.blockedReason ?? "")" }
            if parts.isEmpty { parts.append("Osaurus didn't find anything it can import there.") }
            return ToolEnvelope.failure(kind: .notFound, message: parts.joined(separator: " "), tool: tool, retryable: false)
        }
        out["status"] = "queued"
        if !rows.isEmpty { out["installs_on_create"] = rows }
        if !steps.isEmpty { out["manual_steps"] = steps }
        if !installed.isEmpty { out["already_installed"] = installed.map(\.name) }
        if !blocked.isEmpty { out["blocked"] = blocked.map { ["name": $0.name, "reason": $0.blockedReason ?? ""] } }
        if !review.refusals.isEmpty { out["refused"] = review.refusals.map(\.payload) }
        if !notes.isEmpty { out["notes"] = notes }
        out["summary"] = importSummary(filled: out["filled"] != nil, queued: rows.count, steps: steps.count)
        if let updated = store.draft(id: draftId) { out["draft"] = summary(updated) }
        return ToolEnvelope.success(tool: tool, result: out)
    }

    static func importSummary(filled: Bool, queued: Int, steps: Int) -> String {
        var parts: [String] = []
        if filled { parts.append("Filled the draft from the agent file.") }
        if queued > 0 {
            parts.append(
                "\(queued) item\(queued == 1 ? "" : "s") will install when you click Create Agent; "
                    + "remove any on the card first.")
        }
        if steps > 0 { parts.append("The card lists \(steps) step\(steps == 1 ? "" : "s") to do yourself.") }
        return parts.joined(separator: " ")
    }

    // MARK: - get

    @MainActor
    static func summary(_ draft: AgentDraft) -> [String: Any] {
        let agent = draft.agent
        let mode = agent.toolSelectionMode ?? .auto
        var tools: [String: Any] = ["mode": mode.rawValue]
        if mode == .manual { tools["enabled"] = (agent.manualToolNames ?? []).sorted() }
        var out: [String: Any] = [
            "name": agent.name,
            "description": agent.description,
            "avatar": agent.avatar ?? "",
            "model": agent.defaultModel ?? NSNull(),
            "system_prompt": agent.systemPrompt,
            "capabilities_on": enabledCapabilities(agent),
            "tools": tools,
            "checklist": Dictionary(
                uniqueKeysWithValues: AgentDraft.Step.allCases.map { ($0.rawValue, draft.isDone($0)) }),
            "user_edited": draft.userEdited.map(\.rawValue).sorted(),
            "created": draft.isCreated,
        ]
        if !draft.reasons.isEmpty { out["reasons"] = draft.reasons }
        if !draft.isCreated {
            let blocked = createBlocker(draft)
            out["can_create"] = blocked == nil
            if let blocked { out["create_blocked"] = blocked }
        }
        let queued = draft.queuedImports.filter { $0.kind != .manualStep }
        if !queued.isEmpty {
            out["installs_on_create"] = queued.map { ["kind": $0.kind.rawValue, "name": $0.name] }
        }
        let setup = SetupChecker.check(agent)
        if !setup.isClean {
            out["setup"] = setup.items.map { ["title": $0.title, "detail": $0.detail, "blocking": $0.isBlocking] }
        }
        return out
    }

    /// Why the card's Create Agent button is off, in the Configurator's terms;
    /// nil when the user can create the draft.
    @MainActor
    static func createBlocker(_ draft: AgentDraft) -> String? {
        let name = draft.agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "The draft has no name. Patch one." }
        guard AgentManager.shared.isCustomAgentNameTaken(name) else { return nil }
        let taken = "Another agent is already named \"\(name)\", so Create Agent is off. "
        if draft.userEdited.contains(.name) {
            return taken + "The user typed this name: tell them, suggest a different one, and patch it with "
                + "`override_user_edits` once they agree."
        }
        return taken + "Patch a different name now and tell the user why it changed."
    }

    /// Capability keys on for the agent, with its Apple apps, in the patch
    /// format.
    @MainActor
    static func enabledCapabilities(_ agent: Agent) -> [String] {
        guard let caps = ConfigExporter.exportAgent(agent).capabilities,
            let data = try? JSONEncoder().encode(caps),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        var on = object.compactMap { key, value in (value as? Bool) == true ? key : nil }
        on.removeAll { $0 == "tools_enabled" || $0 == "relay_enabled" }
        let apps = (object["apple_apps"] as? [String]) ?? []
        return on.sorted() + apps.sorted().map { "apple_apps.\($0)" }
    }

    // MARK: - tools

    struct Capability {
        let key: String
        let summary: String
    }

    /// Built-in abilities a draft can turn on, in the words people use for
    /// them so a query finds them.
    static let capabilities: [Capability] = [
        .init(key: "web_search_enabled", summary: "Search the web and read pages: news, research, looking things up online."),
        .init(key: "browser_use_enabled", summary: "Drive a real web browser: open sites, sign in, fill forms, click."),
        .init(key: "computer_use_enabled", summary: "Control Mac apps on screen by clicking and typing."),
        .init(key: "applescript_enabled", summary: "Automate and query Mac apps with AppleScript."),
        .init(key: "memory_enabled", summary: "Remember facts and preferences about the user across chats."),
        .init(key: "search_memory_enabled", summary: "Search past conversations and memory."),
        .init(key: "knowledge_enabled", summary: "Search the user's knowledge collections: documents, notes, files."),
        .init(key: "db_enabled", summary: "Keep a private database: track, log, and query structured data with SQL tables."),
        .init(key: "self_scheduling_enabled", summary: "Schedule its own later or recurring runs: reminders, daily checks."),
        .init(key: "image_enabled", summary: "Generate and edit images."),
        .init(key: "render_chart_enabled", summary: "Draw charts and graphs from data."),
        .init(key: "calculator_enabled", summary: "Exact arithmetic and math."),
        .init(key: "speak_enabled", summary: "Speak replies aloud with text to speech."),
        .init(key: "task_checklist_enabled", summary: "Keep a todo checklist while working through multi-step tasks."),
        .init(key: "clarify_enabled", summary: "Ask the user a clarifying question when a request is ambiguous."),
        .init(key: "artifacts_enabled", summary: "Share files and documents it makes with the user."),
        .init(key: "redaction_tools_enabled", summary: "Detect and redact personal information (PII) in files."),
    ]

    static var capabilityKeys: [String] { capabilities.map(\.key) + ["apple_apps"] }

    @MainActor
    static func lookup(query: String?, agent: Agent) -> [String: Any] {
        let terms = Set(
            (query ?? "").lowercased().split { $0.isWhitespace || $0 == "," }.map(String.init).filter { !$0.isEmpty })
        let on = Set(enabledCapabilities(agent))
        func hits(_ text: String) -> Int { terms.filter(text.lowercased().contains).count }

        var capabilityRows: [(row: [String: Any], hits: Int)] = capabilities.map { cap in
            (["key": cap.key, "summary": cap.summary, "on": on.contains(cap.key)], hits("\(cap.key) \(cap.summary)"))
        }
        capabilityRows += AppleApp.allCases.map { app in
            let summary = "\(app.displayName) on this Mac (Apple app)."
            return (
                ["key": "apple_apps", "app": app.rawValue, "summary": summary, "on": on.contains("apple_apps.\(app.rawValue)")],
                hits("\(app.rawValue) \(summary) apple")
            )
        }

        let registry = ToolRegistry.shared
        let assigned = Set(agent.manualToolNames ?? [])
        let installed = registry.listDynamicTools().map { tool -> (row: [String: Any], hits: Int, nameHits: Int) in
            let group = registry.portableToolGroup(for: tool.name)
            let provider: String
            switch group {
            case .mcpServer(let server)?: provider = "mcp_server:\(server)"
            case .plugin(let plugin)?: provider = "plugin:\(plugin)"
            case nil: provider = "installed"
            }
            let firstLine = tool.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let summary = firstLine.count > 160 ? String(firstLine.prefix(157)) + "…" : firstLine
            return (
                ["name": tool.name, "provider": provider, "summary": summary, "assigned": assigned.contains(tool.name)],
                hits("\(tool.name) \(tool.description) \(provider)"), hits(tool.name)
            )
        }

        var groups: [String: [String: Any]] = [:]
        for (group, names) in registry.portableToolGroups() {
            switch group {
            case .mcpServer(let server): groups["mcp_server:\(server)"] = ["mcp_servers": server, "tools": names.count]
            case .plugin(let plugin): groups["plugin:\(plugin)"] = ["plugins": plugin, "tools": names.count]
            }
        }

        var out: [String: Any] = [
            "tool_mode": (agent.toolSelectionMode ?? .auto).rawValue,
            "hint": "Turn on built-in abilities with `capabilities`. In auto mode every installed tool is already "
                + "available and picked per message, so leave tools in auto unless the user wants a fixed set; then "
                + "set `tools.mode` manual with exact names, `mcp_servers`, or `plugins`.",
        ]
        if terms.isEmpty {
            out["capabilities"] = capabilityRows.map(\.row)
            out["providers"] = groups.keys.sorted().compactMap { groups[$0] }
            out["installed_tools"] = installed.count
        } else {
            out["capabilities"] = capabilityRows.filter { $0.hits > 0 }.sorted { $0.hits > $1.hits }.map(\.row)
            let matched = installed.filter { $0.hits > 0 }.sorted { a, b in
                if a.hits != b.hits { return a.hits > b.hits }
                if a.nameHits != b.nameHits { return a.nameHits > b.nameHits }
                return (a.row["name"] as? String ?? "") < (b.row["name"] as? String ?? "")
            }
            out["tools"] = matched.prefix(toolMatchLimit).map(\.row)
            if matched.count > toolMatchLimit { out["more_tools"] = matched.count - toolMatchLimit }
        }
        return out
    }
}

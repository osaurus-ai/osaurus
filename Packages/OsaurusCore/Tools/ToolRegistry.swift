//
//  ToolRegistry.swift
//  osaurus
//
//  Central registry for chat tools. Provides OpenAI tool specs and execution by name.
//

import Combine
import Foundation
import OSLog

/// Marker for dynamic tools that intentionally have no plugin/provider group
/// but still need an exact `tool/<name>` entry in capability manifests.
protocol IndividuallyManifestedCapabilityTool: OsaurusTool {}

/// A dynamically registered tool that declares plugin-group membership
/// directly. Real plugins and providers expose this through their concrete
/// wrapper types; deterministic eval fixtures use this protocol to exercise
/// the same `plugin/<id>` manifest and group-load contract without installing
/// an external plugin.
protocol CapabilityToolGroupDeclaring: OsaurusTool {
    var capabilityGroupId: String { get }
}

/// Refusals here are security-relevant: a tool the request never exposed tried to run.
enum ToolRegistryLogger {
    static let registry = Logger(subsystem: "ai.osaurus", category: "tool.registry")
}

private let toolBodyTimeoutQueue = DispatchQueue(label: "ai.osaurus.tool-registry.timeout")

private final class ToolBodyRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var pendingResult: String?
    private var continuation: CheckedContinuation<String, Never>?
    private var bodyTask: Task<Void, Never>?
    private var timeoutTimer: DispatchSourceTimer?

    func install(continuation: CheckedContinuation<String, Never>) {
        lock.lock()
        if didResume, let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(returning: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(bodyTask: Task<Void, Never>, timeoutTimer: DispatchSourceTimer) {
        lock.lock()
        if didResume {
            lock.unlock()
            bodyTask.cancel()
            timeoutTimer.cancel()
            return
        }
        self.bodyTask = bodyTask
        self.timeoutTimer = timeoutTimer
        lock.unlock()
    }

    func complete(_ result: String) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = self.continuation
        if continuation == nil {
            pendingResult = result
        }
        self.continuation = nil
        let bodyTask = self.bodyTask
        let timeoutTimer = self.timeoutTimer
        self.bodyTask = nil
        self.timeoutTimer = nil
        lock.unlock()

        bodyTask?.cancel()
        timeoutTimer?.cancel()
        continuation?.resume(returning: result)
    }
}

/// Shared rough estimator for actual `tools[]` payloads. The budget UI
/// must price the spec that will be sent this turn, not the registry's
/// canonical full schema, because the prompt composer can now ship compact
/// bootstrap schemas and hot-load full ones later.
enum ToolSpecTokenEstimator {
    static func estimate(name: String, description: String?, parameters: JSONValue?) -> Int {
        var total = name.count + (description?.count ?? 0)
        if let parameters {
            total += estimateJSONSize(parameters)
        }
        // Overhead for JSON structure:
        // {"type":"function","function":{"name":"...","description":"...","parameters":...}}
        total += 72
        return max(1, total / TokenEstimator.charsPerToken)
    }

    /// Recursively estimate serialized JSON size without paying to encode
    /// every tool during every context-budget refresh.
    private static func estimateJSONSize(_ value: JSONValue) -> Int {
        switch value {
        case .null:
            return 4
        case .bool(let value):
            return value ? 4 : 5
        case .number(let value):
            return String(value).count
        case .string(let value):
            return value.count + 2
        case .array(let array):
            return array.reduce(2) { $0 + estimateJSONSize($1) + 1 }
        case .object(let object):
            return object.reduce(2) { total, pair in
                total + pair.key.count + 5 + estimateJSONSize(pair.value)
            }
        }
    }
}

@MainActor
public final class ToolRegistry: ObservableObject {
    static let shared = ToolRegistry()

    @Published private var toolsByName: [String: OsaurusTool] = [:]
    @Published private var configuration: ToolConfiguration = ToolConfigurationStore.load()

    /// Memoized result of `listTools()`. Building it sorts every tool and
    /// constructs each one's `parameters` JSON schema, which is slow enough to
    /// trip the main-thread hang watchdog when it runs on render paths (the
    /// system prompt preview pipeline calls it through an 80 ms debounce).
    /// Invalidated from `objectWillChange`, so any `@Published` mutation
    /// (register / unregister / enablement) clears it automatically.
    private var cachedListTools: [ToolEntry]?
    private var cacheInvalidations = Set<AnyCancellable>()
    /// Names of tools registered via registerBuiltInTools (always loaded).
    private(set) var builtInToolNames: Set<String> = []

    /// Tool names that require the sandbox container to be running
    private var sandboxToolNames: Set<String> = []
    /// Built-in sandbox execution tools managed by runtime context.
    private var builtInSandboxToolNames: Set<String> = []
    /// Identity of the agent whose sandbox built-ins are currently
    /// registered. Captured at registration so the combined-mode unified
    /// `file_*` tools can route `/workspace/...` reads to the sandbox
    /// without depending on `ChatExecutionContext.currentAgentId` being
    /// bound at the call site. Single active set is guaranteed by the
    /// unregister-then-register pattern in `SandboxToolRegistrar`.
    private(set) var activeSandboxAgentContext: SandboxReadBridge?
    /// Tool names registered from remote MCP providers.
    private var mcpToolNames: Set<String> = []
    /// Tool names registered from native dylib plugins.
    private var pluginToolNames: Set<String> = []

    struct ToolPolicyInfo {
        let isPermissioned: Bool
        let defaultPolicy: ToolPermissionPolicy
        let configuredPolicy: ToolPermissionPolicy?
        let effectivePolicy: ToolPermissionPolicy
        let requirements: [String]
        let grantsByRequirement: [String: Bool]
        /// System permissions required by this tool (e.g., automation, accessibility)
        let systemPermissions: [SystemPermission]
        /// Which system permissions are currently granted at the OS level
        let systemPermissionStates: [SystemPermission: Bool]
    }

    struct ToolEntry: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let description: String
        var enabled: Bool
        let parameters: JSONValue?

        /// Estimated tokens for full tool schema (rough heuristic: ~4 chars per token)
        var estimatedTokens: Int {
            ToolSpecTokenEstimator.estimate(
                name: name,
                description: description,
                parameters: parameters
            )
        }
    }

    private init() {
        registerBuiltInTools()
        // Any mutation to a `@Published` store fires `objectWillChange`; drop
        // the memoized tool list so the next read rebuilds it from fresh state.
        objectWillChange
            .sink { [weak self] in self?.cachedListTools = nil }
            .store(in: &cacheInvalidations)
    }

    /// Register built-in tools that are always available.
    /// Auto-enables tools on first registration so the UI reflects their actual state
    /// (built-in tools are always loaded regardless, but this keeps config consistent).
    private func registerBuiltInTools() {
        let builtIns: [OsaurusTool] = [
            // Agent loop — `ChatView` intercepts execute results to drive
            // the inline UI; the registry runs them like any other tool.
            TodoTool(),
            CompleteTool(),
            ClarifyTool(),
            // Voice output: model calls this when the user explicitly
            // asks to hear the response. ChatView intercepts the
            // successful call and routes through TTSService.
            SpeakTool(),
            // Only sanctioned path for surfacing files / inline blobs to
            // the user (file_write / sandbox writes do not show in chat).
            ShareArtifactTool(),
            // Compact chat gateway plus legacy non-chat compatibility aliases.
            CapabilitiesTool(),
            CapabilitiesDiscoverTool(),
            CapabilitiesLoadTool(),
            // Persistent memory recall — one tool, dispatched by `scope`.
            SearchMemoryTool(),
            // Knowledge collection retrieval (read-only). Registered as
            // built-ins so the runtime can execute them; the system prompt
            // composer strips them unless the agent opts in via
            // `knowledgeEnabled` with at least one granted collection.
            // Collection scoping is additionally enforced at execution
            // time inside each tool.
            SearchKnowledgeTool(),
            ReadKnowledgeTool(),
            ListKnowledgeTool(),
            // Direct write, gated by the ordinary permission modal, which
            // renders paths + diffs for this tool instead of raw JSON. The
            // user approves the call and the documents land immediately, so
            // the agent can verify them with `search_knowledge` — the loop
            // closure the proposal queue structurally could not provide.
            WriteKnowledgeTool(),
            // Deletion is separate from writing, and conforms to
            // `PerCallApprovalTool`: a lease taken for a bulk import must never
            // end up covering removal later in the same run.
            DeleteKnowledgeTool(),
            // Find/replace on one document. Preferred over `write_knowledge` for
            // editing: restating a long document is slow and truncates, and a
            // truncated restatement replaces the original.
            EditKnowledgeTool(),
            // Skill self-improvement: find/replace on a user skill's
            // instructions, behind the same `.ask` modal. Without it, skills
            // are read-only text in the prompt and "update my skill" gets a
            // fabricated "Done" with nothing saved.
            SkillUpdateTool(),
            // Knowledge curation loop: staleness tickets (annotation only,
            // same gate as the retrieval tools). Tickets remain the right
            // shape for drift the agent NOTICES but is not being asked to fix
            // now; that is an async signal to a human, not a consent gate.
            FlagKnowledgeStaleTool(),
            ListKnowledgeTicketsTool(),
            // Ticket queue coordination (claim/release). Bookkeeping over
            // annotations, so it follows the ordinary knowledge grant now that
            // the curator role is gone.
            UpdateKnowledgeTicketTool(),
            // Native web search (Settings → Search providers). Always loaded;
            // the composer strips it per-agent via `webSearchEnabled`. Its
            // sibling `search_and_extract` is registered as a dynamic native
            // tool below (large payloads; loaded via capabilities on demand).
            WebSearchTool(),
            // Inline data visualization rendered as a chart card.
            RenderChartTool(),
            // Current date/time. Local models have no clock in-context, so a
            // plain "what is the time?" (a common first-message smoke test)
            // otherwise makes them guess. Always loaded; no side effects.
            CurrentTimeTool(),
            // Text-delegation family: `spawn_agent` hands a task to a configured
            // agent (its prompt + model); `spawn_model` hands a task to a bare
            // spawnable model id; `spawn_batch` performs bounded fan-out over
            // either pool. All three gate per-agent (their pools) in
            // `SystemPromptComposer.resolveTools` via `SubagentToolVisibility`.
            SpawnAgentTool(),
            SpawnModelTool(),
            SpawnBatchTool(),
            // Native local image generation/editing (one `image` tool; source_paths
            // → edit). Tool body enforces the separate Agent Delegation permission
            // defaults and low-RAM unload policy.
            ImageTool(),
            // Billable remote text/image-to-video generation. The subagent kind
            // obtains a live quote before permission and persists queued jobs.
            VideoTool(),
            // Agent DB feature (spec §6). The system prompt composer
            // gates these per-agent via `Agent.settings.dbEnabled`;
            // registering them as built-ins means agents that *do*
            // enable the feature don't pay an install-time round-trip.
            DBSchemaTool(),
            DBCreateTableTool(),
            DBAlterTableTool(),
            DBMigrateTool(),
            DBInsertTool(),
            DBUpsertTool(),
            DBImportTool(),
            DBExportTool(),
            DBUpdateTool(),
            DBDeleteTool(),
            DBRestoreTool(),
            DBQueryTool(),
            DBExecuteTool(),
            DBDefineViewTool(),
            DBRunViewTool(),
            DBListViewsTool(),
            DBDropViewTool(),
            // Self-scheduling + notification (spec §9, §10). Registered as
            // built-ins so the runtime can execute them, but the system
            // prompt composer strips them from the model-visible schema
            // unless the agent opts in via `selfSchedulingEnabled` (they
            // are not gated by `dbEnabled`).
            ScheduleNextRunTool(),
            CancelNextRunTool(),
            NotifyTool(),
            // Default-agent generic reads (Phase C). Always loaded; the
            // composer further restricts visibility to the default
            // agent only. The matching consolidated writes live under
            // `ConfigurationDomainRegistry`: the Default agent receives
            // them DIRECTLY (see `orchestratorAllowedToolNames`), while
            // custom agents reach them on demand via
            // `capabilities_discover` / `capabilities_load`.
            OsaurusInspectTool(),
            OsaurusHelpTool(),
            // Computer Use (macOS automation harness). Registered as a
            // built-in so the runtime can execute it and ChatView can
            // intercept its live activity feed, but the system prompt
            // composer strips it authoritatively unless the agent opts in
            // via `computerUseEnabled` (custom agents only). Conforms to
            // PermissionedTool: execution preflights Accessibility +
            // Screen Recording before the loop runs.
            ComputerUseTool(),
            // Browser Use (persistent per-agent WebKit session — the native
            // replacement for the osaurus.browser plugin). Registered as a
            // built-in so the runtime can execute it and ChatView can
            // intercept its live activity feed, but the composer strips it
            // authoritatively unless a custom agent opts in via
            // `browserUseEnabled`; the Default agent is hard-off. The `browser_*` primitives are
            // PRIVATE to the nested runner and are never registered here.
            BrowserUseTool(),
            // AppleScript subagent. Like the other delegation-family tools it
            // is registered as a built-in so the runtime can execute it and
            // ChatView can intercept its feed, but the composer strips it
            // unless the agent has AppleScript enabled AND a model installed
            // (gated via `SubagentToolVisibility`). Its on-device AppleScript
            // model generates the script; macOS prompts for Automation consent
            // at script-send time. `mac_query` is its read-only sibling (same
            // capability + model + gating), so both register and gate together.
            AppleScriptTool(),
            MacQueryTool(),
        ]
        var configChanged = false
        for tool in builtIns {
            register(tool)
            builtInToolNames.insert(tool.name)
            // Auto-enable on first registration (same as registerPluginTool).
            // Preserves user's choice if they later disable it.
            if !configuration.enabled.keys.contains(tool.name) {
                configuration.setEnabled(true, for: tool.name)
                configChanged = true
            }
        }
        if configChanged {
            ToolConfigurationStore.save(configuration)
        }

        for tool in Self.agentChannelTools {
            registerNativeDynamicTool(tool)
        }

        // Web-search companion: search + Readability extraction. Dynamic so
        // its large schema/results stay out of the always-loaded baseline.
        registerNativeDynamicTool(SearchAndExtractTool())
    }

    private static let agentChannelTools: [OsaurusTool] = [
        // First-party Agent Channel tools. Discord is the first executable
        // channel driver, but the model-facing action vocabulary is shared
        // by future Slack, Telegram, and custom JSON channel connections.
        AgentChannelListConnectionsTool(),
        AgentChannelDiagnosticsTool(),
        AgentChannelListSpacesTool(),
        AgentChannelListRoomsTool(),
        AgentChannelReadMessagesTool(),
        AgentChannelReadThreadTool(),
        AgentChannelSearchMessagesTool(),
        AgentChannelDraftMessageTool(),
        AgentChannelSendMessageTool(),
        AgentChannelReplyThreadTool(),
        AgentChannelEditMessageTool(),
        AgentChannelDeleteMessageTool(),
        AgentChannelAddReactionTool(),
        AgentChannelRemoveReactionTool(),
        AgentChannelSendTypingTool(),
        // iMessage-only advanced (private-API) actions. Gated inside the
        // service on per-action operator enablement AND a live bridge
        // capability probe, in addition to the family-wide external-surface
        // deny list below.
        AgentChannelIMessageSendAttachmentTool(),
        AgentChannelIMessageSendEffectTool(),
        AgentChannelIMessageCreatePollTool(),
        AgentChannelIMessageManageGroupTool(),
        // WhatsApp-only media send; same family-wide external deny list.
        AgentChannelWhatsAppSendAttachmentTool(),
        // Proactive, binding-scoped publish. Joins the family deny list
        // below automatically, so it can never run from external surfaces.
        AgentChannelPublishTool(),
    ]

    nonisolated static let agentChannelToolNames: Set<String> = [
        "agent_channel_list_connections",
        "agent_channel_diagnostics",
        "agent_channel_list_spaces",
        "agent_channel_list_rooms",
        "agent_channel_read_messages",
        "agent_channel_read_thread",
        "agent_channel_search_messages",
        "agent_channel_draft_message",
        "agent_channel_send_message",
        "agent_channel_reply_thread",
        "agent_channel_edit_message",
        "agent_channel_delete_message",
        "agent_channel_add_reaction",
        "agent_channel_remove_reaction",
        "agent_channel_send_typing",
        "agent_channel_imessage_send_attachment",
        "agent_channel_imessage_send_effect",
        "agent_channel_imessage_create_poll",
        "agent_channel_imessage_manage_group",
        "agent_channel_whatsapp_send_attachment",
        "agent_channel_publish",
    ]

    /// Register a plain (non-bucketed) tool. Used by built-in registration
    /// and folder-tool installation; sandbox / MCP / plugin paths use the
    /// dedicated typed helpers so they can also stamp their bucket sets.
    ///
    /// Names are sanitised to `^[a-zA-Z0-9_-]{1,64}$`. Cross-type collisions
    /// are warned. Overwrites strip stale bucket flags so `isSandboxTool`
    /// / `isMCPTool` / `isPluginTool` reflect the live registration source.
    func register(_ tool: OsaurusTool) {
        let sanitized = Self.sanitizeToolName(tool.name)
        if sanitized != tool.name {
            NSLog(
                "[ToolRegistry] Tool name '\(tool.name)' contains illegal characters; using '\(sanitized)' instead"
            )
        }
        if let existing = toolsByName[sanitized] {
            let existingType = String(describing: type(of: existing))
            let newType = String(describing: type(of: tool))
            if existingType != newType {
                NSLog(
                    "[ToolRegistry] WARNING: tool name collision on '\(sanitized)'; existing=\(existingType) new=\(newType). Previous registration will be overwritten — consider namespacing the providers."
                )
            }
            sandboxToolNames.remove(sanitized)
            builtInSandboxToolNames.remove(sanitized)
            mcpToolNames.remove(sanitized)
            pluginToolNames.remove(sanitized)
        }
        toolsByName[sanitized] = tool
    }

    /// Mark a previously-registered tool as a built-in so it's
    /// always loaded (independent of user toggle). Used by
    /// `ConfigurationDomainRegistry` to flag every tool a domain
    /// registers, since those need to be available for the default
    /// agent's discovery path. The receiving name must already
    /// exist in `toolsByName`; we sanitise here for symmetry with
    /// `register(_:)`.
    func markBuiltIn(toolName: String) {
        let sanitized = Self.sanitizeToolName(toolName)
        guard toolsByName[sanitized] != nil else {
            NSLog(
                "[ToolRegistry] markBuiltIn('\(sanitized)') called for unknown tool; ignoring."
            )
            return
        }
        builtInToolNames.insert(sanitized)
        if !configuration.enabled.keys.contains(sanitized) {
            configuration.setEnabled(true, for: sanitized)
            ToolConfigurationStore.save(configuration)
        }
    }

    /// Sanitize a candidate tool name so it satisfies `^[a-zA-Z0-9_-]{1,64}$`.
    /// Disallowed characters become underscores; empty results fall back to
    /// `tool_unnamed`; over-length names are truncated to 64.
    static func sanitizeToolName(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            if ch.isASCII, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        if out.isEmpty { out = "tool_unnamed" }
        if out.count > 64 { out = String(out.prefix(64)) }
        return out
    }

    private static func estimateTokenCount(_ tool: OsaurusTool) -> Int {
        tool.asOpenAITool().function.name.count
            + (tool.description.count / TokenEstimator.charsPerToken)
    }

    /// Get specs for specific tools by name (ignores enabled state). The spawn /
    /// image delegation family is never excluded here — there is no global master
    /// switch; the base set is a superset and the per-agent narrowing happens in
    /// `SystemPromptComposer.resolveTools` where the launching agent is known.
    func specs(forTools toolNames: [String]) -> [Tool] {
        toolNames.compactMap { name in
            toolsByName[name]?.asOpenAITool()
        }
    }

    /// Get only tools that have an audited spawned-operation cancellation
    /// path. This keeps target-agent schemas honest: a child must not be
    /// invited to call a tool that the owned dispatcher will reject before
    /// execution. Argument-aware support is still checked at dispatch time
    /// for tools such as `file_read` whose rich-document/sandbox variants
    /// are not yet abortable.
    func specsForSpawnedOperations(forTools toolNames: [String]) -> [Tool] {
        toolNames.compactMap { name in
            guard let tool = toolsByName[name], tool.canExposeToSpawnedOperation else {
                return nil
            }
            return tool.asOpenAITool()
        }
    }

    // MARK: - External surface deny list

    /// Host-mutation tool classes that must never be invocable from EXTERNAL
    /// surfaces. Kept separate from `agentChannelToolNames` so the full deny
    /// list below stays a derived union with a single source of truth per
    /// tool family.
    nonisolated static let externallyDeniedHostToolNames: Set<String> = [
        "file_write", "file_edit", "file_copy", "shell_run", "git_commit", "file_undo",
        // Mutates host files (in-place redaction) — same class as file_edit.
        "redact_file",
        // Direct corpus mutation. Their ONLY gate is the interactive approval
        // modal, which an external caller cannot be shown, so there is no
        // safe way to honor these off-surface.
        "write_knowledge", "delete_knowledge", "edit_knowledge",
        // Same class: mutates the user's skills on disk, and its only gate is
        // the interactive approval modal.
        "update_skill",
    ]

    /// Tool classes that must never be invocable from EXTERNAL surfaces
    /// (the HTTP `/agents/{id}/run` loop and the `/mcp/call` bridge).
    /// With a working folder open, folder tools register process-wide
    /// with policy `.auto`; an external caller — loopback skips Bearer
    /// auth entirely — could otherwise rewrite the user's files or run
    /// arbitrary shell commands. Agent-channel tools are denied as a family:
    /// the deny list is derived from `agentChannelToolNames`, so adding a new
    /// `agent_channel_*` tool automatically keeps it off external surfaces.
    /// These names refuse with a structured envelope regardless of
    /// registration state and are hidden from `/mcp/tools` listings.
    nonisolated public static let externallyDeniedToolNames: Set<String> =
        externallyDeniedHostToolNames.union(agentChannelToolNames)

    /// Subset of `externallyDeniedToolNames` that an AUTHENTICATED,
    /// folder-bounded remote agent run may use (gated on
    /// `ChatExecutionContext.authenticatedHostFolderRoot`). Host *file*
    /// mutation is permitted — confined to the granted folder by the folder
    /// tools' own captured root — so a paired peer can have the agent create
    /// or edit files in the folder its owner chose. `shell_run` /
    /// `git_commit` / `file_undo` are deliberately NOT here: they stay denied
    /// on every external surface regardless of authentication.
    nonisolated static let hostFolderAllowedWhenAuthenticated: Set<String> = [
        "file_write", "file_edit",
    ]

    /// `.ask` tools that may run without an approval card on an UNATTENDED,
    /// app-authored background dispatch (`ChatExecutionContext.isUnattendedDispatch`
    /// — schedule / self-schedule / watcher, never external). Membership is
    /// justified per tool by a SEPARATE human gate downstream.
    ///
    /// Currently EMPTY. Its only member was `propose_knowledge_update`, which
    /// qualified because a human still reviewed the draft in the Knowledge tab
    /// afterwards. Direct write has no such downstream gate — approving the
    /// card is the only review — so neither `write_knowledge` nor
    /// `delete_knowledge` may join this list. An unattended run stalls rather
    /// than mutating a collection nobody ever saw a diff of.
    nonisolated static let unattendedAutoApprovableToolNames: Set<String> = []

    /// Whether `name` is blocked for the current execution because an
    /// external surface (`ChatExecutionContext.isExternalSurface`) is
    /// driving the call. An authenticated, folder-bounded remote agent run
    /// (`authenticatedHostFolderRoot` set) is allowed the host file tools in
    /// `hostFolderAllowedWhenAuthenticated`; the `/mcp/call` bridge, loopback,
    /// plaintext, and cross-agent callers never set that task-local, so they
    /// remain fully denied.
    nonisolated static func isDeniedForCurrentSurface(_ name: String) -> Bool {
        guard ChatExecutionContext.isExternalSurface,
            externallyDeniedToolNames.contains(name)
        else { return false }
        if ChatExecutionContext.authenticatedHostFolderRoot != nil,
            hostFolderAllowedWhenAuthenticated.contains(name)
        {
            return false
        }
        return true
    }

    /// The structured refusal handed to external callers for denied
    /// tool classes.
    nonisolated static func externalSurfaceDenialEnvelope(tool: String) -> String {
        ToolEnvelope.failure(
            kind: .rejected,
            message:
                "'\(tool)' is not available to external callers. This tool can only run from the Osaurus app.",
            tool: tool
        )
    }

    /// Resolve the permission gate (missing system permissions, ask/deny
    /// policy, auto-grants) for one tool call without executing it. Throws
    /// the same errors `execute` would on denial. Unknown tools are a
    /// no-op — `execute` produces the structured `toolNotFound` envelope.
    ///
    /// Used by parallel tool batches: approvals resolve serially in model
    /// order first, then the approved set executes concurrently with
    /// `execute(..., permissionGateResolved: true)`.
    func resolvePermissionGate(name rawName: String, argumentsJSON: String) async throws {
        let name = resolvedRegisteredName(for: rawName)
        // External-surface deny happens BEFORE the gate so a denied tool
        // can never pop an approval prompt from an external request.
        if Self.isDeniedForCurrentSurface(name) {
            throw NSError(
                domain: "ToolRegistry",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "'\(name)' is not available to external callers. This tool can only run from the Osaurus app."
                ]
            )
        }
        guard let tool = toolsByName[name] else { return }
        // Preflight first, mirroring `execute`: a batch member that cannot
        // pass schema validation must not raise an approval card, and the
        // card must show the coerced arguments the body will receive.
        // A rejection is not thrown here — `execute` re-runs preflight and
        // returns the structured envelope — so this only decides what the
        // user is shown.
        let normalized = tool.normalizeArgumentsBeforeValidation(argumentsJSON)
        guard case .ready(let effectiveArgumentsJSON) = Self.preflight(
            argumentsJSON: normalized,
            schema: tool.parameters,
            toolName: name
        ) else { return }
        try await runPermissionGate(
            tool: tool,
            name: name,
            argumentsJSON: effectiveArgumentsJSON
        )
    }

    /// Parse the capability-manifest alias syntax shared by permission
    /// resolution, execution, and secret-recording classification.
    nonisolated static func deferredToolAliasTarget(_ rawName: String) -> String? {
        guard rawName.hasPrefix("tool/") else { return nil }
        let target = String(rawName.dropFirst("tool/".count))
        return target.isEmpty ? nil : target
    }

    /// Resolve an alias only when the raw name is not itself registered and
    /// the bare target is. This preserves the (unusual but valid) possibility
    /// of a plugin whose literal registered name starts with `tool/`.
    private func resolvedRegisteredName(for rawName: String) -> String {
        guard toolsByName[rawName] == nil,
            let target = Self.deferredToolAliasTarget(rawName),
            toolsByName[target] != nil
        else {
            return rawName
        }
        return target
    }

    /// The permission gate shared by `execute` and `resolvePermissionGate`:
    /// system-permission prompts, the per-tool ask/deny/auto policy
    /// (including the user approval prompt), and `.auto` grant backfill.
    private func runPermissionGate(tool: OsaurusTool, name: String, argumentsJSON: String) async throws {
        let approvalArgumentsJSON = SecretArgumentScrubber.recordedArguments(
            toolName: name,
            argumentsJSON: argumentsJSON
        )
        if let permissioned = tool as? PermissionedTool {
            let requirements = permissioned.requirements

            // Check system permissions and prompt the user for any that are missing
            let missingSystemPermissions = await SystemPermissionService.shared.missingPermissions(
                from: requirements
            )
            for permission in missingSystemPermissions {
                _ = await SystemPermissionService.shared.requestPermissionAndWait(permission)
            }
            let stillMissing = await SystemPermissionService.shared.missingPermissions(
                from: requirements
            )
            if !stillMissing.isEmpty {
                let missingNames = stillMissing.map { $0.displayName }.joined(separator: ", ")
                throw NSError(
                    domain: "ToolRegistry",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing system permissions for tool: \(name). Required: \(missingNames). Please grant these permissions in the Permissions tab or System Settings."
                    ]
                )
            }

            let defaultPolicy = permissioned.defaultPermissionPolicy
            var effectivePolicy = configuration.policy[name] ?? defaultPolicy
            // Argument-aware narrowing (strictest wins): a contextual tool
            // resolves this specific invocation's policy from its arguments
            // (e.g. the destination binding's outbound mode for
            // `agent_channel_publish`). The configured/user policy can narrow
            // the contextual result and the contextual result can narrow the
            // configured policy; neither can loosen the other.
            if let contextual = tool as? ContextualPermissionedTool {
                let resolved = await contextual.resolveContextualPermissionPolicy(
                    argumentsJSON: argumentsJSON
                )
                effectivePolicy = ToolPermissionPolicy.strictest(effectivePolicy, resolved)
            }
            switch effectivePolicy {
            case .deny:
                throw NSError(
                    domain: "ToolRegistry",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Execution denied by policy for tool: \(name)"]
                )
            case .ask:
                let approved: Bool
                // A per-call tool refuses every pre-grant: the run lease and
                // the global auto-allow both go through the shortcuts below,
                // and a lease taken for a bulk WRITE must not end up covering
                // a delete later in the same run.
                let perCallApproval =
                    (tool as? PerCallApprovalTool)?.requiresApprovalEveryCall == true
                if permissioned.handlesOwnApproval {
                    // The tool runs its own purpose-built interactive
                    // approval in its body (osaurus_config's plan-review
                    // card) — the generic args-JSON panel here would be a
                    // redundant double prompt that hides the real diff.
                    approved = true
                } else if ChatExecutionContext.autoApproveToolPrompts {
                    approved = true
                } else if !perCallApproval,
                    ChatExecutionContext.toolPermissionRunScope?.allows(name) == true
                {
                    approved = true
                } else if ChatExecutionContext.denyUnapprovedToolPrompts {
                    // Headless eval / external MCP with no UI: deny instead of
                    // hanging on an approval card nobody can click.
                    approved = false
                } else if ChatExecutionContext.isExternalSurface {
                    // External MCP/HTTP callers cannot interact with GUI prompts.
                    approved = false
                } else if ChatExecutionContext.isUnattendedDispatch
                    && Self.unattendedAutoApprovableToolNames.contains(name)
                {
                    // Unattended schedule/watcher run with no user to click the
                    // card. Approved only for tools whose real human gate is
                    // downstream (see `unattendedAutoApprovableToolNames`).
                    approved = true
                } else if ChatExecutionContext.isUnattendedDispatch,
                    let contextual = tool as? ContextualPermissionedTool,
                    await contextual.unattendedAskQueuesForApproval(argumentsJSON: argumentsJSON)
                {
                    // Unattended run, `.ask` effective policy, and the tool
                    // declares it converts unanswerable asks into a QUEUED
                    // operator approval inside its body (e.g.
                    // `agent_channel_publish` records a pending outbox item
                    // instead of writing to the provider). Proceeding here is
                    // NOT an approval of the side effect — the human gate
                    // moves into the outbox rather than blocking the run on a
                    // card nobody can answer.
                    approved = true
                } else if ToolApprovalSettings.autoAllowAll, !perCallApproval {
                    // User opted into the global auto-allow chat setting: skip
                    // the interactive card. Only reachable where a card would
                    // have been shown, so external/headless denials above win.
                    // A per-call tool opts out: "auto-allow tools" is not
                    // consent to destroy a knowledge collection unseen.
                    approved = true
                } else {
                    // A knowledge write renders paths + diffs instead of the
                    // JSON block; nil for every other tool keeps the card
                    // exactly as it was.
                    let writePreview =
                        await (tool as? KnowledgeWritePreviewingTool)?
                        .approvalPreview(argumentsJSON: approvalArgumentsJSON)
                    let outcome = await ToolPermissionPromptService.requestApprovalOutcome(
                        toolName: name,
                        description: tool.description,
                        argumentsJSON: approvalArgumentsJSON,
                        knowledgeWritePreview: writePreview,
                        perCallApprovalOnly: perCallApproval
                    )
                    switch outcome {
                    case .denied:
                        approved = false
                    case .allowOnce, .alwaysAllow:
                        approved = true
                    case .allowForRun:
                        // Never record a lease for a per-call tool. The modal
                        // does not offer the button, but the outcome is
                        // re-checked here so the invariant does not depend on
                        // the view.
                        if !perCallApproval {
                            ChatExecutionContext.toolPermissionRunScope?.allow(name)
                        }
                        approved = true
                    }
                }
                if !approved {
                    let message =
                        ChatExecutionContext.isExternalSurface
                            || ChatExecutionContext.denyUnapprovedToolPrompts
                        ? "Tool '\(name)' requires interactive approval in the Osaurus app. Enable auto-approve or change the tool policy to auto before calling it from an external MCP client."
                        : "User denied execution for tool: \(name)"
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            case .auto:
                // Filter out system permissions from per-tool grant requirements
                let nonSystemRequirements = requirements.filter { !SystemPermissionService.isSystemPermission($0) }
                // Auto-grant missing requirements when policy is .auto
                // This ensures backwards compatibility for existing configurations
                if !configuration.hasGrants(for: name, requirements: nonSystemRequirements) {
                    for req in nonSystemRequirements {
                        configuration.setGrant(true, requirement: req, for: name)
                    }
                    ToolConfigurationStore.save(configuration)
                }
            }
        } else {
            // Default for tools without requirements: auto-run unless explicitly denied
            let effectivePolicy = configuration.policy[name] ?? .auto
            if effectivePolicy == .deny {
                throw NSError(
                    domain: "ToolRegistry",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Execution denied by policy for tool: \(name)"]
                )
            } else if effectivePolicy == .ask {
                let approved: Bool
                if ChatExecutionContext.autoApproveToolPrompts {
                    approved = true
                } else if ChatExecutionContext.denyUnapprovedToolPrompts {
                    // Headless eval with no UI: deny instead of hanging on an
                    // approval card nobody can click (see task-local doc).
                    approved = false
                } else if ToolApprovalSettings.autoAllowAll {
                    approved = true
                } else {
                    approved = await ToolPermissionPromptService.requestApproval(
                        toolName: name,
                        description: tool.description,
                        argumentsJSON: approvalArgumentsJSON
                    )
                }
                if !approved {
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "User denied execution for tool: \(name)"]
                    )
                }
            }
        }
    }

    /// Execute a tool by name with raw JSON arguments. Access control
    /// happens upstream (alwaysLoadedSpecs + capabilities_load decides
    /// which tools are visible to the model).
    ///
    /// Unknown tools return `kind: .toolNotFound` with no "did you mean"
    /// list — listing other tool names triggers hallucinations (the model
    /// treats the suggestion as proof a tool exists and invents siblings).
    /// One exception: sandbox tools that race the container startup get a
    /// `kind: .unavailable` "still initializing" notice so the model knows
    /// to retry rather than pivot.
    func execute(
        name rawName: String,
        argumentsJSON: String,
        permissionGateResolved: Bool = false,
        ownsExecutionUntilTermination: Bool = false
    ) async throws -> String {
        // The capabilities manifest lists deferred tools to the model as
        // `tool/<name>` (SystemPromptTemplates.enabledCapabilitiesManifest). Some
        // models copy that `tool/` prefix verbatim into a tool call even for a
        // first-class function tool, yielding a spurious tool_not_found. Worse,
        // the default agent can't self-heal — capabilities_load is gated off for
        // it — so it just gives up and refuses ("I cannot generate images").
        // Resolve to the model's real intent by stripping a `tool/` prefix when
        // the bare name isn't registered but the stripped one is, mirroring the
        // `tool/` handling in CapabilityTools.resolve.
        let name = resolvedRegisteredName(for: rawName)

        // Hallucinated fetch tools get steered, not dead-ended. Models trained
        // on other harnesses call `web_fetch` / `fetch_url` / `open_url` as if
        // they were universal — observed live: a Raptor research run burned its
        // entire turn on `web_fetch` (a tool that has never existed in osaurus)
        // and produced zero page reads. The general no-"did you mean" rule
        // exists because naming other tools teaches models to invent siblings;
        // it does not apply here, because the steering target is only named
        // when THIS request already exposes it — the model is being pointed at
        // a tool sitting in its own schema, not at a rumor. Guarded to names
        // with no real registration so a plugin/MCP tool that legitimately
        // registers one of these names always wins — and a user-installed
        // plugin GROUP that happens to share an alias name (`plugin/fetch`)
        // keeps its own load rescue instead of being steered away from the
        // capability the user deliberately installed.
        // A prefix-dropped plugin tool name: the Exa plugin registers
        // `exa_search_web_fetch_exa`; the model (Ornith, 2026-09-05 report)
        // called `web_fetch_exa`. When exactly ONE tool exposed to THIS
        // request ends in `_<name>`, point the model at that real name — the
        // tool it was shown, not a guess. Ambiguity (two candidates) falls
        // through to the generic handling; nothing is executed here.
        if toolsByName[name] == nil, let intended = uniqueExposedSuffixMatch(for: name) {
            ToolRegistryLogger.registry.notice(
                "steering prefix-dropped tool '\(name, privacy: .public)' to '\(intended, privacy: .public)'"
            )
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason:
                    "There is no '\(name)' tool. The tool you mean is named '\(intended)' — "
                    + "call it with that exact name\(schemaHint(for: intended)).",
                toolName: name,
                retryable: true
            ).toJSONString()
        }

        if toolsByName[name] == nil, Self.isHallucinatedFetchToolName(name),
            toolsByName["search_and_extract"] != nil,
            ChatExecutionContext.toolExecutionScope?.permits("search_and_extract") == true,
            groupIdCallRescueEnvelope(for: name) == nil
        {
            ToolRegistryLogger.registry.notice(
                "steering hallucinated fetch tool '\(name, privacy: .public)' to search_and_extract"
            )
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason:
                    "There is no '\(name)' tool. To fetch a web page, call search_and_extract "
                    + "with {\"urls\": [\"<url>\"]} — it fetches the pages and returns their "
                    + "readable content. To find sources first, call web_search.",
                toolName: name,
                retryable: true
            ).toJSONString()
        }

        // A tool this request never exposed must not run, however convincingly the model asks
        // for it.
        //
        // Exposure and execution were not bound together. The prompt chose which tools the model
        // was TOLD about, but nothing stopped it from naming one it was never shown: the parser
        // records any name once at least one schema is present, and this registry then ran it,
        // because the comment above used to say access control had already happened upstream. It
        // had not. A sandbox / plugin / MCP tool deliberately withheld from an agent would execute
        // if the model merely guessed its name — and tools fired in the app with the tools toggle
        // visibly OFF.
        //
        // Deliberately AFTER the `tool/` normalization above: checking `rawName` would let the
        // model bypass the whole thing by prefixing the name it was never given.
        //
        // `nil` scope means the surface published none and gates its own tools — the registry then
        // behaves exactly as before. See `ChatExecutionContext.toolExecutionScope`.
        if let scope = ChatExecutionContext.toolExecutionScope, !scope.permits(name) {
            ToolRegistryLogger.registry.error(
                "refusing '\(name, privacy: .public)': not exposed to this request"
            )
            // Distinguish "real tool, just never loaded into this
            // conversation" from "withheld". A skill's instructions or the
            // user can name a dynamic tool that was never exposed to the
            // turn; the old unconditional dead end ("not available in this
            // conversation", retryable: false) taught small models to
            // apologize and give up when one `capabilities_load` away from
            // succeeding (#2145). Only tools `capabilities_load` would
            // actually grant get the hint — anything unregistered, globally
            // disabled, or outside this agent's grant keeps the opaque
            // refusal, so the gate still reveals nothing about tools that
            // were deliberately withheld.
            let agentAllowed: Set<String>? = ChatExecutionContext.currentAgentId.flatMap {
                AgentManager.shared.effectiveEnabledToolNames(for: $0).map(Set.init)
            }
            let loadableCodes: Set<ToolAvailabilityReasonCode> = [
                .available, .alreadyLoaded, .loadableViaCapabilitiesLoad,
            ]
            // Workspace file/shell tools FIRST, before the loadable-hint: they
            // are runtime-managed, so on any process where a folder was ever
            // mounted (or a sandbox agent exists) `availability` reports them
            // `.alreadyLoaded` and the loadable branch below would steer the
            // model into `capabilities {"ids":["tool/file_write"]}` — a load
            // the dynamic gates then refuse opaquely. Their one actionable
            // next step is user-facing (attach a folder), never a loader
            // round-trip; keyed on the NAME so the answer is identical
            // whether or not the tools happen to be registered right now.
            // The refusal stands — no execution boundary moves. Naming the
            // Folder chip leaks nothing: it is public UX.
            if Self.coreWorkspaceToolNames.contains(name) {
                return ToolErrorEnvelope(
                    kind: .toolNotFound,
                    reason:
                        "\(name) needs a workspace attached to THIS chat and there is none. "
                        + "The agent's Host Files folder is not active in chat (it applies "
                        + "only to authenticated remote agent runs). Ask the user to attach "
                        + "a folder via the Folder chip (or enable Autonomous execution). "
                        + "Until then, deliver file content with share_artifact and say why.",
                    toolName: name,
                    retryable: false
                ).toJSONString()
            }
            let toolAvailability = availability(forTool: name, agentAllowedNames: agentAllowed)
            // The default agent's capabilities_load is gated to the configure
            // write tools, so the hint would only steer it into a rejected
            // load for anything else. Likewise, a registered built-in withheld
            // by an agent/mode/readiness gate is not dynamically loadable: an
            // exact guessed name must not be laundered through capabilities_load.
            let isDeferredDefaultConfigureWrite =
                ChatExecutionContext.currentAgentId == Agent.defaultId
                && Self.configureWriteToolNames.contains(name)
            let isNonLoadableBuiltIn =
                builtInToolNames.contains(name) && !isDeferredDefaultConfigureWrite
            let loadGateAllows =
                !isNonLoadableBuiltIn
                && (ChatExecutionContext.currentAgentId != Agent.defaultId
                    || Self.configureWriteToolNames.contains(name))
            if loadGateAllows, loadableCodes.isSuperset(of: toolAvailability.reasonCodes) {
                // Name the loader tool this request actually exposes. Chat
                // surfaces publish the merged `capabilities` gateway and NOT
                // the legacy `capabilities_load`, so hinting the legacy name
                // sends the model straight into a second tool_not_found dead
                // end (#2279). Fall back to `capabilities` when neither is in
                // scope — it is the only loader small models can discover.
                let loaderName =
                    scope.permits("capabilities")
                    ? "capabilities"
                    : (scope.permits("capabilities_load") ? "capabilities_load" : "capabilities")
                return ToolErrorEnvelope(
                    kind: .toolNotFound,
                    reason:
                        "\(name) exists but is not loaded in this conversation. "
                        + "Call \(loaderName) with ids: [\"tool/\(name)\"] to load it, "
                        + "then retry this call.",
                    toolName: name,
                    retryable: true
                ).toJSONString()
            }
            if let groupRescue = groupIdCallRescueEnvelope(for: name) {
                return groupRescue
            }
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason: "\(name) is not available in this conversation.",
                toolName: name,
                retryable: false
            ).toJSONString()
        }

        // External-surface deny list: refuse workspace-mutating tool
        // classes for HTTP/MCP-initiated executions regardless of
        // registration state or permission policy.
        if Self.isDeniedForCurrentSurface(name) {
            return Self.externalSurfaceDenialEnvelope(tool: name)
        }
        guard let tool = toolsByName[name] else {
            if name.hasPrefix("sandbox_") {
                return ToolErrorEnvelope(
                    kind: .unavailable,
                    reason:
                        "Sandbox is still initializing — \(name) isn't registered yet. "
                        + "Wait a moment and try again.",
                    toolName: name,
                    retryable: true
                ).toJSONString()
            }
            if let groupRescue = groupIdCallRescueEnvelope(for: name) {
                return groupRescue
            }
            // No "did you mean" list on purpose (names trigger invention of
            // siblings) — but a bare dead-end leaves small models apologizing
            // and giving up ("the tool to delete X is not available") when the
            // REAL tool is sitting in their schema under a name they didn't
            // guess. Point back at the ground truth they already have.
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason:
                    "Tool '\(name)' is not available in this session. Do not guess "
                    + "tool names: use exactly the names in your tool schema and "
                    + "instructions (check them for the tool covering this task "
                    + "before answering that it can't be done).",
                toolName: name
            ).toJSONString()
        }
        if let invalidArguments = Self.invalidToolArgumentsEnvelope(
            argumentsJSON,
            toolName: name
        ) {
            return invalidArguments
        }
        if ownsExecutionUntilTermination,
            tool.spawnedOperationCancellationSupport(argumentsJSON: argumentsJSON) != .cooperative
        {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Tool '\(name)' cannot run inside a cancellable spawned worker because "
                    + "this invocation does not expose cooperative abort-and-drain ownership.",
                tool: name,
                retryable: false
            )
        }
        // Coerce + preflight against the tool's schema BEFORE the permission
        // gate. Returns either a (possibly rewritten) `argumentsJSON` ready
        // for dispatch, or a structured failure envelope to short-circuit
        // with.
        //
        // Order matters, and it used to be the other way round. Gating first
        // meant a call that could never execute still raised an approval card:
        // observed live, a `write_knowledge` whose `documents` was a string
        // instead of an array sat in front of the user for 2m26s before schema
        // validation rejected it in milliseconds. Never ask a person to
        // approve something already known to be invalid.
        //
        // It also closes a consent gap: the gate now sees the SAME coerced
        // arguments the tool body will receive, so an approval card cannot
        // preview one thing while execution does another.
        let normalizedArguments = tool.normalizeArgumentsBeforeValidation(argumentsJSON)
        switch Self.preflight(
            argumentsJSON: normalizedArguments,
            schema: tool.parameters,
            toolName: name
        ) {
        case .rejected(let envelopeJSON):
            return envelopeJSON
        case .ready(let effectiveArgumentsJSON):
            // Skipped when the caller already resolved the gate via
            // `resolvePermissionGate` (parallel batches resolve every approval
            // serially in model order BEFORE executing concurrently, so
            // approval prompts never stack or race).
            if !permissionGateResolved {
                try await runPermissionGate(
                    tool: tool,
                    name: name,
                    argumentsJSON: effectiveArgumentsJSON
                )
            }
            // Prefill diagnostics: time the actual tool body (sandbox boot,
            // embedding search, shell, network) so the /tmp log can separate
            // tool-execution latency from model decode between agent-loop steps.
            let toolExecStart = CFAbsoluteTimeGetCurrent()
            if PrefillDebugLog.shared.isEnabled {
                // Capture the (coerced) call arguments so the log shows WHICH
                // capability a load targeted — e.g. `plugin/calendar` — since
                // the tool name alone can't. Single-lined and truncated to
                // bound log size and avoid dumping large tool payloads (file
                // contents, shell scripts) verbatim into /tmp.
                let safeArguments = SecretArgumentScrubber.recordedArguments(
                    toolName: name,
                    argumentsJSON: effectiveArgumentsJSON
                )
                let flat = safeArguments.replacingOccurrences(of: "\n", with: " ")
                let argsForLog = flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
                PrefillDebugLog.shared.log("       TOOL-EXEC-BEGIN name=\(name) args=\(argsForLog)")
            }
            // Captured for the END line below: the result of a `capabilities_*`
            // call (which tools a `plugin/<id>` load expanded to, or what a
            // discover returned). Scoped to capability tools ONLY — other tool
            // results (file contents, shell/web output) can be large or
            // sensitive and have no place in this diagnostic.
            var resultForLog: String? = nil
            defer {
                var line =
                    "       TOOL-EXEC-END   name=\(name) "
                    + "ms=\(Int((CFAbsoluteTimeGetCurrent() - toolExecStart) * 1000))"
                if let resultForLog { line += " result=\(resultForLog)" }
                PrefillDebugLog.shared.log(line)
            }
            // Run the tool body off MainActor so long-running tools (file
            // I/O, network, shell) don't contend with SwiftUI layout on the
            // main thread.
            //
            // By default a global wall-clock timeout caps every tool body
            // so a misbehaving tool can never block the agent loop
            // forever. Streaming-aware tools (`sandbox_exec`, `shell_run`)
            // opt out via `bypassRegistryTimeout`: they have no usable
            // wall-clock budget — a `cargo build` legitimately runs for
            // 30+ minutes — and rely on the user's `[Terminate]` button
            // + container resource limits + their own optional inactivity
            // timeout as the safety net.
            //
            // Bind the combined-mode host-read policy HERE — the one
            // chokepoint every execute entrypoint (chat, plugin host,
            // `/v1`, MCP, bridge) funnels through — so the host read
            // tools enforce the secret denylist uniformly instead of
            // relying on each caller to remember. Inert outside combined
            // mode, leaving plain folder + plain sandbox modes untouched.
            let policy = combinedHostReadPolicy
            let sandboxAgent = activeSandboxAgentName
            // Sandbox change tracking: wrap mutation-capable sandbox tools
            // in a workspace checkpoint so every file the call creates,
            // edits, deletes, or moves lands in the owning chat's Changes
            // list. Only when the call is attributable (session id bound)
            // and a sandbox agent identity is resolvable.
            let readBridge = combinedSandboxReadBridge
            // Sandbox tools checkpoint the sandbox roots; host-folder tools
            // checkpoint the user-selected folder. In WRITABLE combined mode
            // the unified `file_write`/`file_edit` can mutate EITHER
            // filesystem (a `/workspace/...` path routes through the sandbox
            // bridge), so they take both checkpoints — the untouched side
            // diffs to zero rows and costs one manifest scan.
            var changeCheckpoints: [SandboxWorkspaceChangeTracker.CheckpointToken] = []
            if let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty {
                if tool.mutatesSandboxWorkspace, let agentName = sandboxAgent {
                    changeCheckpoints.append(
                        await SandboxWorkspaceChangeTracker.shared.beginCheckpoint(
                            sessionId: sessionId,
                            agentName: agentName,
                            sourceTool: name
                        )
                    )
                } else if tool.mutatesHostFolder {
                    // The EXECUTING chat's folder root (TaskLocal, bound by
                    // the send/run surface) — never a process-wide folder, so
                    // concurrent chats checkpoint their own roots.
                    if let folderRoot = ChatExecutionContext.currentFolderRoot {
                        changeCheckpoints.append(
                            await SandboxWorkspaceChangeTracker.shared.beginHostCheckpoint(
                                sessionId: sessionId,
                                folderPath: folderRoot.standardizedFileURL.path,
                                sourceTool: name
                            )
                        )
                    }
                    if let bridge = readBridge {
                        changeCheckpoints.append(
                            await SandboxWorkspaceChangeTracker.shared.beginCheckpoint(
                                sessionId: sessionId,
                                agentName: bridge.agentName,
                                sourceTool: name
                            )
                        )
                    }
                }
            }
            // Count real tool work for the run, so `todo` can tell progress
            // from assertion. Recorded at dispatch rather than on success: a
            // tool that ran and failed is still an attempt the model can
            // honestly report on, and only "nothing ran at all" is the signal
            // the Todo tool acts on.
            ChatExecutionContext.agentTodoRunScope?.recordToolExecution(name: name)

            let result: String
            do {
                result = try await ChatExecutionContext.$hostReadOnlyScope.withValue(policy.scope) {
                    try await ChatExecutionContext.$allowHostSecretReads.withValue(policy.allowSecretReads) {
                        try await ChatExecutionContext.$allowHostFolderWrites.withValue(policy.allowFolderWrites) {
                            try await ChatExecutionContext.$sandboxReadBridge.withValue(readBridge) {
                                try await ChatExecutionContext.$sandboxAgentName.withValue(sandboxAgent) {
                                    if tool.bypassRegistryTimeout || ownsExecutionUntilTermination {
                                        // Spawned runners pass
                                        // `ownsExecutionUntilTermination`: their
                                        // `OwnedSubagentOperation` supplies the
                                        // deadline/interrupt signal and MUST
                                        // drain this direct body before the
                                        // child can finish. Using the generic
                                        // timeout race here would return while
                                        // its losing body task was still live.
                                        return Self.normalizeToolResult(
                                            try await Self.runToolBodyUntimed(
                                                tool,
                                                argumentsJSON: effectiveArgumentsJSON
                                            ),
                                            tool: name
                                        )
                                    }
                                    return Self.normalizeToolResult(
                                        try await Self.runToolBody(
                                            tool,
                                            argumentsJSON: effectiveArgumentsJSON,
                                            timeoutSeconds: Self.defaultToolTimeoutSeconds
                                        ),
                                        tool: name
                                    )
                                }
                            }
                        }
                    }
                }
            } catch {
                // Bodies normally fold errors into envelopes, but the
                // checkpoints must still reconcile whatever was written
                // before a throw (e.g. cancellation mid-write).
                for checkpoint in changeCheckpoints {
                    await SandboxWorkspaceChangeTracker.shared.endCheckpoint(checkpoint)
                }
                throw error
            }
            for checkpoint in changeCheckpoints {
                await SandboxWorkspaceChangeTracker.shared.endCheckpoint(checkpoint)
            }
            if PrefillDebugLog.shared.isEnabled, name.hasPrefix("capabilities_") {
                let flat = result.replacingOccurrences(of: "\n", with: " ")
                resultForLog = flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
            }
            return result
        }
    }

    /// Combined sandbox + host-read policy bound around every tool body:
    /// the read-only host workspace `scope` (or `nil` outside combined
    /// mode) and whether the active agent opted into reading secret files
    /// within it. Combined mode is the registered sandbox exec tool
    /// (present only when autonomous sandbox is active) plus an active
    /// folder root — exactly the condition `resolveExecutionMode` maps to
    /// `.sandbox(hostRead: ctx)`. Resolved once per call so the two
    /// task-locals stay consistent, and inert (`nil` / `false`) in plain
    /// folder and plain sandbox modes.
    private var combinedHostReadPolicy: (scope: URL?, allowSecretReads: Bool, allowFolderWrites: Bool) {
        (nil, false, false)
    }

    /// Sandbox identity bound around every tool body while VM execution is
    /// active. The five public workspace tools use it as their backend router.
    private var combinedSandboxReadBridge: SandboxReadBridge? {
        guard toolsByName.keys.contains("sandbox_exec") else { return nil }
        // A dispatched host-folder run (Watcher / schedule / plugin folder)
        // has exactly one filesystem — the folder it was pointed at. The
        // autonomous agent's `sandbox_exec` stays registered process-wide,
        // so without this gate the bridge was bound in `.hostFolder` mode
        // and `/workspace/...` reads were answered from the VM.
        guard !ChatExecutionContext.hostFolderIsDispatchTarget else { return nil }
        // The process-wide tool objects can be refreshed by another agent
        // between turns. A request TaskLocal is authoritative and keeps
        // concurrent/non-active sessions routed to their own Linux user.
        if let agentId = ChatExecutionContext.currentAgentId {
            let agentName = SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
            return SandboxReadBridge(
                agentId: agentId.uuidString,
                agentName: agentName,
                home: OsaurusPaths.inContainerAgentHome(agentName),
                maxCommandsPerTurn: resolvedAutonomousExecConfig?.maxCommandsPerTurn
                    ?? AutonomousExecConfig.default.maxCommandsPerTurn,
                backgroundEnabled: resolvedAutonomousExecConfig?.backgroundProcessEnabled == true
            )
        }
        return activeSandboxAgentContext
    }

    /// Sandbox agent name bound for Agent DB file tools. Same resolution
    /// order as `combinedSandboxReadBridge`, but also set in plain sandbox
    /// mode when only sandbox built-ins are registered.
    private var activeSandboxAgentName: String? {
        if let bridge = combinedSandboxReadBridge { return bridge.agentName }
        if let captured = activeSandboxAgentContext?.agentName { return captured }
        guard
            toolsByName.keys.contains("sandbox_exec")
                || toolsByName.keys.contains("sandbox_read_file"),
            let agentId = ChatExecutionContext.currentAgentId
        else { return nil }
        return SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
    }

    /// The effective autonomous-exec config for the agent driving the
    /// current tool call, resolved via the execution context's agent id.
    /// `nil` when there's no agent in context (e.g. a bare test call).
    private var resolvedAutonomousExecConfig: AutonomousExecConfig? {
        guard let agentId = ChatExecutionContext.currentAgentId else { return nil }
        return AgentManager.shared.effectiveAutonomousExec(for: agentId)
    }

    private static func invalidToolArgumentsEnvelope(
        _ argumentsJSON: String,
        toolName: String
    ) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["_error"] as? String == "invalid_tool_arguments"
        else { return nil }

        let message = object["_message"] as? String ?? "invalid tool arguments"
        let field = object["_field"] as? String
        let expected = object["_expected"] as? String
        // Observed in live transcripts: a model whose history shows the
        // sentinel object as its own previous arguments will pattern-match
        // and re-emit `{"_error": ...}` verbatim as its next call. Say
        // explicitly that the error object is not a template to copy.
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message: message
                + " Your previous call was malformed, so its arguments were "
                + "discarded. Do NOT copy this error object into `arguments` — "
                + "re-issue the call with real arguments per the tool schema.",
            field: field,
            expected: expected,
            tool: toolName,
            retryable: true
        )
    }

    /// Bypass-path for streaming-aware tools. Runs the body straight
    /// through with the same error-mapping as `runToolBody`, but no
    /// wall-clock race. Cancellation still propagates: when the calling
    /// task is cancelled, the body's own `Task.isCancelled` checks (or
    /// the underlying process signals) tear it down.
    nonisolated internal static func runToolBodyUntimed(
        _ tool: OsaurusTool,
        argumentsJSON: String
    ) async throws -> String {
        do {
            return try await tool.execute(argumentsJSON: argumentsJSON)
        } catch is CancellationError {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: L("Tool '\(tool.name)' was cancelled."),
                tool: tool.name,
                retryable: false
            )
        } catch {
            return ToolEnvelope.fromError(error, tool: tool.name)
        }
    }

    /// Outcome of `preflight`: either the cleaned arguments to dispatch
    /// with, or a ready-to-return failure envelope JSON string.
    private enum PreflightOutcome {
        case ready(argumentsJSON: String)
        case rejected(envelopeJSON: String)
    }

    /// Pre-dispatch step that applies schema-aware coercion and then
    /// validation. Coercion runs FIRST so quantized models that send
    /// arrays / objects as JSON-encoded strings (e.g.
    /// `"actions": "[{\"action\":\"type\"}]"` for a schema declaring
    /// `actions: array`) get auto-unwrapped before either the validator
    /// or the tool body sees them.
    ///
    /// Returns `.rejected` when the validator finds the (post-coercion)
    /// arguments invalid; otherwise `.ready` with the JSON the tool body
    /// should consume. Re-serialisation only happens when coercion
    /// actually changed the shape — when the model sent native types we
    /// preserve the original literal byte-for-byte so downstream
    /// consumers (logging, storage) see what the client sent.
    ///
    /// Tools without a declared schema or with un-parseable JSON args
    /// fall through unchanged: parsing is best-effort, and tool bodies
    /// keep their richer `requireXxx` helpers as the second line of
    /// defence.
    nonisolated private static func preflight(
        argumentsJSON: String,
        schema: JSONValue?,
        toolName: String
    ) -> PreflightOutcome {
        guard let schema,
            let data = argumentsJSON.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return .ready(argumentsJSON: argumentsJSON) }

        let coerced = SchemaValidator.coerceArguments(parsed, against: schema)
        let result = SchemaValidator.validate(arguments: coerced, against: schema)
        if !result.isValid, let message = result.errorMessage {
            return .rejected(
                envelopeJSON: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: message,
                    field: result.field,
                    tool: toolName
                )
            )
        }

        // Try to detect "coercion changed the shape" via canonicalised
        // JSON byte equality. When the bytes match, hand back the
        // original literal; otherwise re-serialise so the tool body
        // gets native types.
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let coercedData = try? JSONSerialization.data(withJSONObject: coerced, options: opts),
            let originalData = try? JSONSerialization.data(withJSONObject: parsed, options: opts)
        else { return .ready(argumentsJSON: argumentsJSON) }

        if coercedData == originalData {
            return .ready(argumentsJSON: argumentsJSON)
        }
        guard let coercedJSON = String(data: coercedData, encoding: .utf8) else {
            return .ready(argumentsJSON: argumentsJSON)
        }
        return .ready(argumentsJSON: coercedJSON)
    }

    /// Registry-boundary result normalization, applied to EVERY executed
    /// tool body's output (built-in, MCP, plugin, dynamic):
    ///
    /// 1. Envelope normalization — plain-text results (MCP content
    ///    conversions, plugin prose, legacy tools) wrap into the canonical
    ///    success envelope so every consumer (`isError`, `classify`,
    ///    dedupe, transcripts) sees one shape.
    /// 2. Universal output cap — results above
    ///    `ToolOutputCaps.universalResult` are head+tail truncated and
    ///    re-wrapped with `truncated: true` plus a recovery hint, so no
    ///    single call (base64 payload, giant diff, runaway listing) can
    ///    blow the context window in one turn. Error-ness is preserved.
    nonisolated static func normalizeToolResult(_ raw: String, tool: String) -> String {
        // The secret-prompt marker is deliberately NOT an envelope —
        // `SecretPromptParser` keys off `action` at the JSON root and the
        // chat loop replaces it with a real envelope after the overlay
        // resolves. Wrapping it here would break the secure-input flow.
        // Bound the marker scan to the payload head — `raw` can be hundreds of
        // MB and this runs on the (main-actor) registry path; the secret-prompt
        // marker is a leading root key, so scanning the whole string just to
        // detect it could hang the UI.
        if raw.prefix(4096).contains("\"action\":\"\(SecretPromptAction.actionKey)\""),
            SecretPromptParser.parse(raw) != nil
        {
            return raw
        }

        // Lossless formatting compaction at ingest. Runs AFTER the
        // secret-prompt guard (the marker must reach the chat loop byte-exact)
        // and BEFORE the cap, so an external pretty-JSON payload that crushes
        // back under the cap avoids truncation entirely. Meaning-preserving and
        // deterministic, so the KV-prefix stays byte-stable. See
        // `ToolOutputCompressor`.
        let payload = ToolOutputCompressor.compact(raw)

        // The cap protects a TOKEN budget (~25K tokens), and tokens track
        // UTF-8 bytes far better than Swift characters: a 100,000-character
        // CJK/emoji-heavy payload is ~300 KB and ~3× the tokens of ASCII.
        // Measure in bytes; slice in characters at the proportional length so
        // ASCII payloads behave exactly as before (bytes == characters).
        let cap = ToolOutputCaps.universalResult
        let isEnvelope = ToolEnvelope.isSuccess(payload) || ToolEnvelope.isError(payload)
        let byteCount = payload.utf8.count

        if byteCount <= cap {
            return isEnvelope ? payload : ToolEnvelope.success(tool: tool, text: payload)
        }
        // Head-biased: at the registry backstop the front of an oversized
        // payload is what identifies it (the recovery hint rides in the
        // envelope, not the marker). The cap is a BYTE budget: a proportional
        // character slice is only a first guess (mixed emoji/ASCII payloads
        // are denser at one end than the other), so shrink the character
        // budget until the kept text really fits.
        var characterCap = max(1, Int(Double(cap) * Double(payload.count) / Double(byteCount)))
        var truncatedContent = HeadTailTruncation.apply(payload, cap: characterCap, headFraction: 2.0 / 3.0)
        var passes = 0
        while truncatedContent.utf8.count > cap, characterCap > 1, passes < 12 {
            passes += 1
            characterCap = max(1, Int(Double(characterCap) * Double(cap) / Double(truncatedContent.utf8.count)))
            truncatedContent = HeadTailTruncation.apply(payload, cap: characterCap, headFraction: 2.0 / 3.0)
        }
        // Character slicing cannot bound bytes when a single grapheme is
        // larger than the budget (one base letter plus tens of thousands of
        // combining marks is ONE Character), or when the pass limit ran out:
        // the byte-exact cut is the guarantee, the loop above only the
        // grapheme-friendly first choice.
        if truncatedContent.utf8.count > cap {
            truncatedContent = HeadTailTruncation.applyByteExact(payload, byteCap: cap, headFraction: 2.0 / 3.0)
        }
        let hint =
            "Output exceeded the per-call cap and was truncated (head and tail kept). "
            + "Re-run with narrower arguments — filters, `max_results`, line ranges, or "
            + "head/tail options — to retrieve the missing region."

        if ToolEnvelope.isError(payload) {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Tool '\(tool)' failed and its error output exceeded the per-call cap. " + hint,
                tool: tool,
                metadata: [
                    "truncated": true,
                    "original_chars": payload.count,
                    "content": truncatedContent,
                ]
            )
        }
        return ToolEnvelope.success(
            tool: tool,
            result: [
                "kind": "truncated_output",
                "truncated": true,
                "original_chars": payload.count,
                "content": truncatedContent,
            ] as [String: Any],
            warnings: [hint]
        )
    }

    /// Default per-tool wall-clock cap (seconds). Mirrors
    /// `PluginHostAPI.toolExecutionTimeout` so the chat-side and plugin-side
    /// loops have matching semantics. Tools that need a tighter or looser
    /// budget (e.g. sandbox shell, MCP provider) still set their own.
    public static let defaultToolTimeoutSeconds: TimeInterval = 120

    /// Trampoline that executes the tool outside of MainActor isolation,
    /// racing the body against a wall-clock timeout. On timeout we cancel
    /// the body task and return a `kind: .timeout` envelope so the model
    /// sees a structured signal instead of a hung agent loop. Internal so
    /// tests can drive it with a small `timeoutSeconds` value without
    /// waiting for the full 120s production budget.
    ///
    /// This intentionally does not use `withTaskGroup`: structured child
    /// groups must drain before returning, so a non-cooperative tool body
    /// that ignores cancellation can still hold the caller until it exits.
    /// The timeout branch also uses a dedicated GCD timer queue rather than
    /// `Task.sleep`, because a saturated Swift executor can otherwise delay
    /// the "wall-clock" timeout behind unrelated async work.
    nonisolated internal static func runToolBody(
        _ tool: OsaurusTool,
        argumentsJSON: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let toolName = tool.name
        let timeoutEnvelope = ToolEnvelope.failure(
            kind: .timeout,
            message:
                L("Tool '\(toolName)' exceeded the \(Int(timeoutSeconds))s execution budget."),
            tool: toolName,
            retryable: true
        )
        let cancellationEnvelope = ToolEnvelope.failure(
            kind: .executionError,
            message: L("Tool '\(toolName)' was cancelled."),
            tool: toolName,
            retryable: false
        )
        let race = ToolBodyRaceState()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation: continuation)
                let timeoutTimer = DispatchSource.makeTimerSource(queue: toolBodyTimeoutQueue)
                let timeoutNanoseconds = max(0, Int(timeoutSeconds * 1_000_000_000))
                timeoutTimer.schedule(deadline: .now() + .nanoseconds(timeoutNanoseconds))
                timeoutTimer.setEventHandler {
                    race.complete(timeoutEnvelope)
                }
                timeoutTimer.resume()

                let bodyTask = Task {
                    do {
                        let result = try await tool.execute(argumentsJSON: argumentsJSON)
                        race.complete(result)
                    } catch is CancellationError {
                        race.complete(cancellationEnvelope)
                    } catch {
                        race.complete(ToolEnvelope.fromError(error, tool: toolName))
                    }
                }
                race.setTasks(bodyTask: bodyTask, timeoutTimer: timeoutTimer)
            }
        } onCancel: {
            race.complete(cancellationEnvelope)
        }
    }

    // MARK: - Listing / Enablement

    /// Returns all registered tools with global enabled state.
    /// Memoized via `cachedListTools`; the result is reused until a registry
    /// mutation invalidates it (see `cachedListTools`).
    func listTools() -> [ToolEntry] {
        if let cached = cachedListTools { return cached }
        let entries = toolsByName.values
            // Locale-independent compare: tool names are identifiers, so
            // `localizedCaseInsensitiveCompare`'s ICU/locale round-trip was
            // pure overhead — and it made a cold rebuild trip the main-thread
            // hang watchdog. A fixed order is also better for KV-cache
            // stability across users with different locales.
            .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
            .map { t in
                ToolEntry(
                    name: t.name,
                    description: t.description,
                    enabled: configuration.isEnabled(name: t.name),
                    parameters: t.parameters
                )
            }
        cachedListTools = entries
        return entries
    }

    /// Number of registered tools. O(1), and crucially avoids building the
    /// full `ToolEntry` list — `listTools()` sorts every tool and constructs
    /// each one's `parameters` JSON schema, which is slow enough to trip the
    /// main-thread hang watchdog when called just to read a count.
    var toolCount: Int {
        return toolsByName.count
    }

    /// Names of all currently registered tools. Used when minting MCP tool
    /// names so two providers with the same sanitized prefix can't collide.
    func registeredToolNames() -> [String] {
        Array(toolsByName.keys)
    }

    /// True when `name` is a registered DYNAMIC tool (plugin/MCP/dynamic
    /// native) — i.e. a name `capabilities` can legitimately load as
    /// `tool/<name>`. Matches `listDynamicTools`' classification exactly:
    /// built-in AND runtime-managed tools are excluded — neither is a
    /// loadable id, so rescuing a bare `file_write`/`shell_run` into
    /// `tool/<name>` would only route the caller into the dynamic-load
    /// gates' opaque refusals instead of the workspace guidance.
    func isDynamicRegisteredTool(named name: String) -> Bool {
        toolsByName[name] != nil
            && !builtInToolNames.contains(name)
            && !runtimeManagedToolNames.contains(name)
    }

    /// Immutable snapshot of every name `isDynamicRegisteredTool` currently
    /// classifies as dynamic. Exists for `AgentTaskState.dynamicToolClassifier`:
    /// the registry is MainActor-bound while HTTP/plugin drive the loop
    /// nonisolated, so the loop gets a value-type snapshot instead of a live
    /// registry call. The classifier is advisory-only, so a tool registered
    /// mid-run is merely missed until the next snapshot — never a wrong block.
    func dynamicToolNameSnapshot() -> Set<String> {
        Set(toolsByName.keys.filter { isDynamicRegisteredTool(named: $0) })
    }

    /// O(1) single-tool lookup as a `ToolEntry`. Prefer this over
    /// `listTools().first(where:)` on UI/render paths: `listTools()` sorts the
    /// entire registry and rebuilds every tool's JSON schema, while this only
    /// touches the one requested tool.
    func entry(named name: String) -> ToolEntry? {
        guard let tool = toolsByName[name] else { return nil }
        return ToolEntry(
            name: tool.name,
            description: tool.description,
            enabled: configuration.isEnabled(name: tool.name),
            parameters: tool.parameters
        )
    }

    /// Set enablement for a tool and persist.
    func setEnabled(_ enabled: Bool, for name: String) {
        configuration.setEnabled(enabled, for: name)
        ToolConfigurationStore.save(configuration)
    }

    /// Check if a tool is enabled in the global configuration
    func isGlobalEnabled(_ name: String) -> Bool {
        return configuration.isEnabled(name: name)
    }

    /// Whether a tool with this name is registered.
    func isRegistered(_ name: String) -> Bool {
        return toolsByName[name] != nil
    }

    /// Explicit per-tool enablement and policy overrides, for the
    /// declarative config exporter/planner. Only names the user (or a
    /// previous apply) explicitly touched appear here.
    func explicitToolSettings() -> (enabled: [String: Bool], policies: [String: ToolPermissionPolicy]) {
        (configuration.enabled, configuration.policy)
    }

    /// Retrieve parameter schema for a tool by name.
    func parametersForTool(name: String) -> JSONValue? {
        return toolsByName[name]?.parameters
    }

    /// Get estimated tokens for a tool by name (returns 0 if not found).
    func estimatedTokens(for name: String) -> Int {
        return listTools().first(where: { $0.name == name })?.estimatedTokens ?? 0
    }

    /// Total estimated tokens for all currently enabled tools.
    func totalEstimatedTokens() -> Int {
        return listTools()
            .filter { $0.enabled }
            .reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Total estimated tokens for an explicit set of tool specs.
    /// Useful when the active tool list is mode- or session-dependent.
    func totalEstimatedTokens(for tools: [Tool]) -> Int {
        tools.reduce(0) { total, tool in
            total
                + ToolSpecTokenEstimator.estimate(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
        }
    }

    // MARK: - Policy / Grants

    /// Returns the explicitly configured policy for a tool, or nil if the
    /// user has not overridden the default. Reads from the in-memory
    /// `configuration` snapshot — never hits disk — so SwiftUI rows can
    /// rely on `objectWillChange` for live updates without re-parsing
    /// `tools.json` on every body evaluation.
    ///
    /// Unlike `policyInfo(for:)`, this works even for tool names that are
    /// not currently registered (e.g. when the Work tool permission row
    /// in `ConfigurationView` lists `file_write` before the registry has
    /// been populated).
    func configuredPolicy(for name: String) -> ToolPermissionPolicy? {
        configuration.policy[name]
    }

    func setPolicy(_ policy: ToolPermissionPolicy, for name: String) {
        configuration.setPolicy(policy, for: name)

        // When setting to .auto, automatically grant all non-system requirements
        // This ensures tools can execute without requiring separate manual grants
        if policy == .auto, let tool = toolsByName[name] as? PermissionedTool {
            let requirements = tool.requirements
            for req in requirements where !SystemPermissionService.isSystemPermission(req) {
                configuration.setGrant(true, requirement: req, for: name)
            }
        }

        ToolConfigurationStore.save(configuration)
    }

    func clearPolicy(for name: String) {
        configuration.clearPolicy(for: name)
        ToolConfigurationStore.save(configuration)
    }

    /// Returns policy and requirements information for a given tool
    func policyInfo(for name: String) -> ToolPolicyInfo? {
        guard let tool = toolsByName[name] else { return nil }
        let isPermissioned = (tool as? PermissionedTool) != nil
        let defaultPolicy: ToolPermissionPolicy
        let requirements: [String]
        if let p = tool as? PermissionedTool {
            defaultPolicy = p.defaultPermissionPolicy
            requirements = p.requirements
        } else {
            defaultPolicy = .auto
            requirements = []
        }
        let configured = configuration.policy[name]
        let effective = configured ?? defaultPolicy
        var grants: [String: Bool] = [:]
        // Only track grants for non-system requirements
        for r in requirements where !SystemPermissionService.isSystemPermission(r) {
            grants[r] = configuration.isGranted(name: name, requirement: r)
        }

        // Extract system permissions from requirements
        let systemPermissions = requirements.compactMap { SystemPermission(rawValue: $0) }
        var systemPermissionStates: [SystemPermission: Bool] = [:]
        for perm in systemPermissions {
            // Read the cached state: this runs during view updates, and the live
            // check can synchronously block on EventKit XPC and hang the UI.
            systemPermissionStates[perm] = SystemPermissionService.shared.cachedIsGranted(perm)
        }

        return ToolPolicyInfo(
            isPermissioned: isPermissioned,
            defaultPolicy: defaultPolicy,
            configuredPolicy: configured,
            effectivePolicy: effective,
            requirements: requirements,
            grantsByRequirement: grants,
            systemPermissions: systemPermissions,
            systemPermissionStates: systemPermissionStates
        )
    }

    // MARK: - Sandbox Tool Registration

    /// Register a tool that requires the sandbox container.
    /// Non-runtime-managed tools are auto-enabled on first registration so they
    /// are immediately usable; subsequent registrations preserve the user's choice.
    /// Strips any pre-existing MCP / plugin bucket flag — live registration wins.
    func registerSandboxTool(_ tool: OsaurusTool, runtimeManaged: Bool = false) {
        let firstTime =
            toolsByName[tool.name] == nil
            && !configuration.enabled.keys.contains(tool.name)
        toolsByName[tool.name] = tool
        mcpToolNames.remove(tool.name)
        pluginToolNames.remove(tool.name)
        sandboxToolNames.insert(tool.name)
        if runtimeManaged {
            builtInSandboxToolNames.insert(tool.name)
        } else {
            if firstTime {
                setEnabled(true, for: tool.name)
            }
            builtInSandboxToolNames.remove(tool.name)
            Task {
                await ToolIndexService.shared.onToolRegistered(
                    name: tool.name,
                    description: tool.description,
                    runtime: .sandbox,
                    tokenCount: Self.estimateTokenCount(tool),
                    parameters: tool.parameters
                )
            }
        }
    }

    /// Register all tools from a sandbox plugin (agent-agnostic).
    /// Agent identity is resolved at execution time via ChatExecutionContext.
    func registerSandboxPluginTools(plugin: SandboxPlugin) {
        guard let tools = plugin.tools else { return }
        for spec in tools {
            let tool = SandboxPluginTool(spec: spec, plugin: plugin)
            registerSandboxTool(tool)
        }
    }

    /// Unregister all sandbox tools for a given plugin.
    func unregisterSandboxPluginTools(pluginId: String) {
        let prefix = "\(pluginId)_"
        let names = toolsByName.keys.filter { $0.hasPrefix(prefix) && sandboxToolNames.contains($0) }
        for name in names {
            unregisterSandboxTool(named: name)
        }
    }

    /// Unregister all sandbox tools (e.g., when sandbox becomes unavailable).
    func unregisterAllSandboxTools() {
        let snapshot = Array(sandboxToolNames)
        for name in snapshot {
            unregisterSandboxTool(named: name)
        }
    }

    /// Unregister only builtin sandbox tools, leaving plugin tools intact.
    func unregisterAllBuiltinSandboxTools() {
        let snapshot = Array(builtInSandboxToolNames)
        for name in snapshot {
            unregisterSandboxTool(named: name)
        }
        activeSandboxAgentContext = nil
    }

    /// Record the agent whose sandbox built-ins are now registered, so the
    /// combined-mode unified `file_*` tools can route `/workspace/...`
    /// reads to that agent's sandbox. Called by `BuiltinSandboxTools.register`.
    func setActiveSandboxAgentContext(
        agentId: String = "compat",
        agentName: String,
        home: String,
        config: AutonomousExecConfig? = nil
    ) {
        activeSandboxAgentContext = SandboxReadBridge(
            agentId: agentId,
            agentName: agentName,
            home: home,
            maxCommandsPerTurn: config?.maxCommandsPerTurn
                ?? AutonomousExecConfig.default.maxCommandsPerTurn,
            backgroundEnabled: config?.backgroundProcessEnabled == true
        )
    }

    private func unregisterSandboxTool(named name: String) {
        toolsByName.removeValue(forKey: name)
        sandboxToolNames.remove(name)
        builtInSandboxToolNames.remove(name)
        Task { await ToolIndexService.shared.onToolUnregistered(name: name) }
    }

    /// Whether a tool requires the sandbox container.
    func isSandboxTool(_ name: String) -> Bool {
        sandboxToolNames.contains(name)
    }

    // MARK: - MCP Tool Registration

    /// Register a tool from a remote MCP provider.
    /// Auto-enables the tool on first registration so it is immediately usable;
    /// subsequent registrations preserve the user's choice.
    func registerMCPTool(_ tool: MCPProviderTool) {
        let name = tool.name
        if let existing = toolsByName[name] as? MCPProviderTool,
            existing.providerId != tool.providerId
        {
            NSLog(
                "[ToolRegistry] MCP tool name collision on '\(name)': "
                    + "existing provider '\(existing.providerName)' (\(existing.providerId)) "
                    + "overwritten by '\(tool.providerName)' (\(tool.providerId)). "
                    + "Consider renaming one of the providers."
            )
        }
        let firstTime =
            toolsByName[name] == nil
            && !configuration.enabled.keys.contains(name)
        toolsByName[name] = tool
        sandboxToolNames.remove(name)
        builtInSandboxToolNames.remove(name)
        pluginToolNames.remove(name)
        mcpToolNames.insert(name)
        if firstTime {
            setEnabled(true, for: name)
        }
        Task {
            await ToolIndexService.shared.onToolRegistered(
                name: name,
                description: tool.description,
                runtime: .mcp,
                tokenCount: Self.estimateTokenCount(tool),
                parameters: tool.parameters
            )
        }
    }

    /// Whether a tool was registered from a remote MCP provider.
    func isMCPTool(_ name: String) -> Bool {
        mcpToolNames.contains(name)
    }

    // MARK: - Plugin Tool Registration

    /// Register a first-party native tool that should be loaded on demand
    /// instead of joining the always-loaded built-in baseline. This is for
    /// system-owned dynamic surfaces such as Agent Channels; plugin-owned tools
    /// must use `registerPluginTool(_:)` so ownership diagnostics stay correct.
    func registerNativeDynamicTool(_ tool: OsaurusTool) {
        let firstTime =
            toolsByName[tool.name] == nil
            && !configuration.enabled.keys.contains(tool.name)
        toolsByName[tool.name] = tool
        sandboxToolNames.remove(tool.name)
        builtInSandboxToolNames.remove(tool.name)
        mcpToolNames.remove(tool.name)
        pluginToolNames.remove(tool.name)
        if firstTime {
            setEnabled(true, for: tool.name)
        }
        Task {
            await ToolIndexService.shared.onToolRegistered(
                name: tool.name,
                description: tool.description,
                runtime: .native,
                tokenCount: Self.estimateTokenCount(tool),
                parameters: tool.parameters
            )
        }
    }

    /// Register a tool from a native dylib plugin.
    /// Auto-enables the tool on first registration so it is immediately usable;
    /// subsequent registrations (e.g. hot-reload) preserve the user's choice.
    func registerPluginTool(_ tool: OsaurusTool) {
        let firstTime =
            toolsByName[tool.name] == nil
            && !configuration.enabled.keys.contains(tool.name)
        toolsByName[tool.name] = tool
        sandboxToolNames.remove(tool.name)
        builtInSandboxToolNames.remove(tool.name)
        mcpToolNames.remove(tool.name)
        pluginToolNames.insert(tool.name)
        if firstTime {
            setEnabled(true, for: tool.name)
        }
        Task {
            await ToolIndexService.shared.onToolRegistered(
                name: tool.name,
                description: tool.description,
                runtime: .native,
                tokenCount: Self.estimateTokenCount(tool),
                parameters: tool.parameters
            )
        }
    }

    /// Whether a tool was registered from a native dylib plugin.
    func isPluginTool(_ name: String) -> Bool {
        pluginToolNames.contains(name)
    }

    /// Names of every currently registered native dylib plugin tool.
    /// Channel dispatch pre-loads these into the session's schema: channel
    /// turns start with an empty loaded-tools set every message, and small
    /// local models rarely self-serve through `capabilities_load`, so a
    /// granted plugin tool would otherwise read as unavailable (#2443).
    var registeredPluginToolNames: Set<String> {
        pluginToolNames
    }

    // MARK: - Unregister
    func unregister(names: [String]) {
        for n in names {
            toolsByName.removeValue(forKey: n)
            sandboxToolNames.remove(n)
            builtInSandboxToolNames.remove(n)
            mcpToolNames.remove(n)
            pluginToolNames.remove(n)
            Task { await ToolIndexService.shared.onToolUnregistered(name: n) }
        }
    }

    // MARK: - Work-Conflicting Plugin Tools

    /// Plugins that duplicate built-in folder/git tools and bypass undo + sandboxing.
    static let folderConflictingPluginIds: Set<String> = [
        "osaurus.filesystem",
        "osaurus.git",
    ]

    /// Registered tool names from plugins that conflict with the built-in
    /// folder tools. Excluded from the schema while the folder backend is
    /// active so the model has a single canonical entry point.
    var folderConflictingToolNames: Set<String> {
        Set(
            toolsByName.values
                .compactMap { $0 as? ExternalTool }
                .filter { Self.folderConflictingPluginIds.contains($0.pluginId) }
                .map { $0.name }
        )
    }

    // MARK: - User-Facing Tool List

    /// Folder tool names that should be excluded from user-facing tool lists.
    /// These tools are automatically managed based on folder selection.
    static var folderToolNames: Set<String> {
        Set(FolderToolManager.shared.folderToolNames)
    }

    /// The git subset of the folder tools. Registered process-wide with the
    /// core set; visible only when the executing session's folder is a git
    /// repo (schema filtering in `excludedToolNames`).
    static let gitToolNames: Set<String> = [
        "git_status", "git_diff", "git_commit",
    ]

    /// The read-only subset of the folder tools. In combined sandbox +
    /// host-read mode these stay visible (the agent reads the host
    /// workspace) while every other folder tool — host write / edit /
    /// shell / git — is hidden, because exec is confined to the sandbox
    /// and the host is read-only. Single source of truth shared by
    /// `excludedToolNames` and the combined-mode tests.
    static let folderReadOnlyToolNames: Set<String> = [
        "file_read", "file_search",
    ]

    /// The write subset of the folder tools that joins the schema in
    /// WRITABLE combined mode (`allowHostFolderWrites` opt-in). Only the
    /// file writers — never `shell_run` / git / `file_undo`, so exec
    /// stays sandbox-only and undo stays in the Changes sheet.
    static let folderWriteToolNames: Set<String> = [
        "file_write", "file_edit",
    ]

    /// Folder tools that exist ONLY for combined mode. `file_copy` bridges
    /// file bytes between the workspace and the sandbox — meaningless in
    /// plain folder mode (shell `cp` covers host-side copies) and in plain
    /// sandbox mode (no workspace). Visible in BOTH read-only and writable
    /// combined mode; host-bound destinations are gated at execute time on
    /// the `allowHostFolderWrites` grant, not by hiding the tool.
    static let combinedModeBridgeToolNames: Set<String> = [
        "file_copy"
    ]

    /// Runtime-managed tools are execution infrastructure, always loaded when registered.
    var runtimeManagedToolNames: Set<String> {
        Self.folderToolNames.union(builtInSandboxToolNames)
    }

    /// Spawn-family tool names, DERIVED from the capability registry (the SSOT
    /// for subagent tool visibility) — never hand-maintained here.
    static var agentDelegationSpawnToolNames: Set<String> {
        Set(SubagentCapabilityRegistry.spawn.toolNames)
    }
    /// Image-family tool names, derived from the capability registry.
    static var agentDelegationImageToolNames: Set<String> {
        Set(SubagentCapabilityRegistry.image.toolNames)
    }
    static var agentDelegationVideoToolNames: Set<String> {
        Set(SubagentCapabilityRegistry.video.toolNames)
    }
    /// AppleScript-family tool names, derived from the capability registry.
    static var agentDelegationAppleScriptToolNames: Set<String> {
        Set(SubagentCapabilityRegistry.appleScript.toolNames)
    }
    /// All agent-delegation tool names (spawn + image + applescript), derived
    /// from the registry's delegation family. Used by the authoritative
    /// per-agent `spawnDelegationEnabled` gate in
    /// `SystemPromptComposer.resolveTools`.
    static var agentDelegationAllToolNames: Set<String> {
        SubagentToolVisibility.delegationToolNames
    }

    /// Read-only snapshot of the built-in sandbox tool names. Exposed so the
    /// composer's canonical-order helper can group them at the top of the
    /// `<tools>` block without reaching into private state.
    var builtInSandboxToolNamesSnapshot: Set<String> {
        builtInSandboxToolNames
    }

    /// Tools that should be hidden from the model in this execution mode.
    ///
    /// Three orthogonal rules, each derivable from `mode`:
    ///   - if mode does NOT claim folder tools → exclude all folder tools
    ///   - if mode does NOT claim sandbox tools → exclude all built-in sandbox tools
    ///   - if mode is agentic at all (folder OR sandbox) → exclude any
    ///     plugin/MCP tool that overlaps a folder tool name (the folder
    ///     surface is treated as authoritative when active)
    ///
    /// Replaces the older per-mode switch so adding a new mode means
    /// teaching `ExecutionMode` two booleans, not editing this function.
    private func excludedToolNames(for mode: ExecutionMode) -> Set<String> {
        var excluded: Set<String> = []
        if !mode.usesHostFolderTools {
            // VM mode reuses exactly the same five public tool schemas as a
            // trusted folder. Their bodies route through the active sandbox
            // bridge; every other host/history/git helper remains hidden.
            var folderExcluded = Self.folderToolNames
            if mode.usesSandboxTools {
                folderExcluded.subtract(Self.coreWorkspaceToolNames)
            }
            excluded.formUnion(folderExcluded)
        } else {
            // Plain folder mode: hide the combined-mode-only bridge —
            // there is no sandbox to bridge to, and `shell_run` (`cp`)
            // covers host-side copies.
            excluded.formUnion(Self.combinedModeBridgeToolNames)
            // Git tools are registered process-wide with the rest of the
            // folder surface but only make sense against a repo — filter
            // them per request from THIS session's folder context (the old
            // behavior registered them per folder; now it's schema-level).
            if mode.folderContext?.isGitRepo != true {
                excluded.formUnion(Self.gitToolNames)
            }
        }
        // The running sandbox registers two distinct surfaces: private backend
        // adapters used behind the five public workspace tools, and public
        // control-plane tools (install, secrets, process, registration). Hide
        // only adapters in sandbox mode. Outside sandbox mode hide the complete
        // running surface, except the transient first-use handshake: its live
        // registration is the signal that provisioning awaits an explicit call.
        let hiddenSandboxNames: Set<String>
        if mode.usesSandboxTools {
            hiddenSandboxNames =
                builtInSandboxToolNames
                .intersection(Self.sandboxBackendAdapterToolNames)
        } else {
            hiddenSandboxNames =
                builtInSandboxToolNames
                .subtracting([BuiltinSandboxTools.initPendingToolName])
        }
        excluded.formUnion(hiddenSandboxNames)
        if mode.usesHostFolderTools || mode.usesSandboxTools {
            excluded.formUnion(folderConflictingToolNames)
        }
        // The spawn / image delegation family is never excluded from the base
        // schema — there is no global master switch. The base set stays a
        // superset; the per-agent / Default-vs-custom narrowing happens in
        // `SystemPromptComposer.resolveTools` (and the HTTP agent-run path) via
        // `SubagentToolVisibility`, where the launching agent is known. That is
        // what lets a custom agent surface `spawn` even when the main-chat pool
        // is empty. Off-by-default still holds: every agent ships with the
        // capability disabled until opted in from its Subagents tab.
        return excluded
    }

    /// Sandbox read tools made redundant by the unified, path-routed host
    /// `file_*` tools in combined mode. Hidden from the schema there (still
    /// registered so tear-down and capability indexing track them).
    static let sandboxReadToolNames: Set<String> = [
        "sandbox_read_file", "sandbox_search_files",
    ]

    /// Sandbox write tool made redundant by the path-routed `file_write` /
    /// `file_edit` in WRITABLE combined mode. Hidden from the schema there
    /// (still registered, mirroring `sandboxReadToolNames`).
    static let sandboxWriteToolNames: Set<String> = [
        "sandbox_write_file"
    ]

    /// Private runtime adapters. Model-visible file/shell calls use the stable
    /// core workspace names and route to these only after mode/scope checks.
    static let sandboxBackendAdapterToolNames: Set<String> = [
        "sandbox_read_file",
        "sandbox_search_files",
        "sandbox_write_file",
        "sandbox_exec",
    ]

    /// Runtime-managed control plane. The composer narrows this set from the
    /// captured agent configuration before publishing a request schema.
    static let sandboxControlPlaneToolNames: Set<String> = [
        BuiltinSandboxTools.initPendingToolName,
        "sandbox_install",
        "sandbox_secret_check",
        "sandbox_secret_set",
        "sandbox_process",
        "sandbox_plugin_register",
    ]

    static let coreWorkspaceToolNames: Set<String> = [
        "file_read", "file_search", "file_write", "file_edit", "shell_run",
    ]

    /// Redaction tools: part of the host-folder schema (they resolve the
    /// executing chat's folder root) but NOT of `coreWorkspaceToolNames`,
    /// because that set also surfaces in sandbox/VM mode where these have
    /// no bridge routing and would dead-end in `noActiveFolderEnvelope`.
    static let redactionToolNames: Set<String> = [
        "detect_pii", "redact_file",
    ]

    /// Resolve the active execution mode for a chat send. Single source of
    /// truth: callers pass the user's explicit intent (autonomous toggle +
    /// optional folder context) and we apply the priority rule once.
    ///
    /// Trusted workspace and sandbox are mutually exclusive execution
    /// boundaries. When autonomous sandbox execution is enabled, a selected
    /// host folder is deliberately NOT threaded into the sandbox mode: the
    /// folder remains selected in the chat UI so it can resume when sandbox is
    /// disabled, but the VM receives no host read/write bridge.
    ///
    /// Sandbox mode is only returned when both autonomous is enabled AND
    /// `sandbox_exec` is registered. If autonomous is on but sandbox tools
    /// haven't registered yet (provision still in flight), we return `.none`
    /// — the composer's "Sandbox not ready" notice + the placeholder tool
    /// take it from there. Avoids the hidden assumption that
    /// `autonomousEnabled` alone implied `.sandbox`.
    func resolveExecutionMode(
        folderContext: FolderContext?,
        autonomousEnabled: Bool,
        allowHostFolderWrites _: Bool = false,
        preferHostFolder: Bool = false
    ) -> ExecutionMode {
        // `preferHostFolder` honors an explicitly-targeted host folder over the
        // sandbox. It exists for folder-targeted background dispatches — above
        // all a Watcher, whose entire purpose is a host folder. Combined
        // sandbox+host mode was removed in #2250 (pure-VM five-tool contract),
        // which left such a dispatch with NO way to reach its folder: the
        // autonomous agent went pure-VM, its file tools jailed to
        // `/workspace/agents/<id>/`, so it read its own empty workspace and
        // reported the watched folder "empty" (the Voice Memo Watcher bug).
        // A watcher has no interactive sandbox toggle, so the folder it was
        // pointed at must win — trusted host-folder mode, the same surface a
        // normal folder chat uses (no combined-mode exfiltration path
        // reintroduced). Interactive chats do NOT set this: a user who picked
        // the VM boundary keeps it, and toggles sandbox off to use the folder
        // (the historical `sandbox > host folder` priority, still pinned by
        // ResolveExecutionModeTests).
        if preferHostFolder, let folderContext {
            return .hostFolder(folderContext)
        }
        if autonomousEnabled {
            guard toolsByName.keys.contains("sandbox_exec") else {
                // Never fall through to the host folder while the user has
                // explicitly selected the untrusted VM boundary.
                return .none
            }
            return .sandbox(hostRead: nil, hostWrite: false)
        }
        if let folderContext {
            return .hostFolder(folderContext)
        }
        return .none
    }

    /// Runtime-managed tools for diagnostics and execution-mode decisions.
    func listRuntimeManagedTools() -> [ToolEntry] {
        listTools().filter { runtimeManagedToolNames.contains($0.name) }
    }

    /// Dynamic tools eligible for on-demand loading (MCP, plugin, sandbox-plugin).
    /// Excludes built-in and runtime-managed tools which are always loaded.
    func listDynamicTools() -> [ToolEntry] {
        let alwaysLoaded = builtInToolNames.union(runtimeManagedToolNames)
        return listTools().filter { $0.enabled && !alwaysLoaded.contains($0.name) }
    }

    /// Explain why a tool is callable now, loadable through
    /// `capabilities_load`, or unavailable. This is read-only diagnostic
    /// state: callers still enforce visibility/loading through the existing
    /// toolset and `capabilities_load` gates.
    func availability(
        forTool toolName: String,
        agentAllowedNames: Set<String>? = nil,
        executionMode: ExecutionMode? = nil,
        selectedPreflightNames: Set<String>? = nil
    ) -> ToolAvailability {
        // O(1) existence + enabled lookups. Avoids `listTools()` here — that
        // sorts every tool and rebuilds each one's JSON schema, which is far
        // too expensive to run per row on the SwiftUI render path (it tripped
        // the main-thread hang watchdog; see `toolCount`).
        guard toolsByName[toolName] != nil else {
            return ToolAvailability(
                toolName: toolName,
                runtime: nil,
                groupName: nil,
                reasonCodes: [.notRegistered],
                detail: L("tool is not registered; install or enable the plugin/provider that owns it")
            )
        }
        let isEnabled = configuration.isEnabled(name: toolName)

        let builtIn = builtInToolNames.contains(toolName)
        let runtimeManaged = runtimeManagedToolNames.contains(toolName)
        let dynamic = !builtIn && !runtimeManaged
        let runtime = availabilityRuntimeLabel(for: toolName, builtIn: builtIn)
        let group = groupName(for: toolName)
        var reasons: [ToolAvailabilityReasonCode] = []
        var details: [String] = []

        func appendReason(_ reason: ToolAvailabilityReasonCode) {
            if !reasons.contains(reason) {
                reasons.append(reason)
            }
        }

        if dynamic, !isEnabled {
            appendReason(.disabled)
            details.append(L("globally disabled"))
        }

        if dynamic, let agentAllowedNames, !agentAllowedNames.contains(toolName) {
            appendReason(.hiddenByAgentScope)
            details.append(L("not enabled for this agent"))
        }

        if let executionMode, excludedToolNames(for: executionMode).contains(toolName) {
            appendReason(.hiddenByExecutionMode)
            details.append(L("hidden in \(String(describing: executionMode)) mode"))
        }

        if let policy = policyInfo(for: toolName) {
            if policy.effectivePolicy == .deny {
                appendReason(.permissionBlocked)
                details.append(L("permission policy is deny"))
            }
            let missingPermissions = policy.systemPermissionStates
                .filter { !$0.value }
                .map { $0.key.displayName }
                .sorted()
            if !missingPermissions.isEmpty {
                appendReason(.missingPermission)
                details.append(L("missing system permission(s): \(missingPermissions.joined(separator: ", "))"))
            }
        }

        let onDemandBuiltIn = Self.onDemandBuiltInToolNames.contains(toolName)
        if !runtimeManaged, !onDemandBuiltIn,
            let selectedPreflightNames,
            !selectedPreflightNames.contains(toolName)
        {
            appendReason(.notSelectedByPreflight)
            details.append(L("not exposed in the current request schema"))
        }

        if reasons.isEmpty {
            // On-demand built-ins read as loadable, not "already in the
            // baseline": they are deliberately kept out of it.
            if dynamic || onDemandBuiltIn {
                appendReason(.loadableViaCapabilitiesLoad)
                details.append(L("registered \(runtime) tool; load with capabilities_load"))
            } else {
                appendReason(.alreadyLoaded)
                details.append(L("registered \(runtime) tool; already in the active baseline"))
            }
        }

        return ToolAvailability(
            toolName: toolName,
            runtime: runtime,
            groupName: group,
            reasonCodes: reasons,
            detail: details.joined(separator: "; ")
        )
    }

    /// Recover when a model calls a manifest plugin-group id as though it were
    /// a function name. Compact enabled-capability manifests intentionally
    /// publish one `plugin/<id>` value per group, while the callable schema
    /// contains only the `capabilities` gateway. Small models can copy that
    /// value into `function.name`; an opaque non-retryable miss then leaves
    /// them one load call away from the real tools.
    ///
    /// This is a redirect only: it never loads or executes the group. The
    /// guessed id must exactly match a registered, globally enabled group with
    /// at least one member allowed for the current agent, and the current
    /// request must expose a capability loader. Unknown and withheld names
    /// therefore retain the opaque refusal above.
    private func groupIdCallRescueEnvelope(for guessedName: String) -> String? {
        let bare: String
        if guessedName.hasPrefix("plugin/") {
            bare = String(guessedName.dropFirst("plugin/".count))
        } else {
            guard !guessedName.contains("/") else { return nil }
            bare = guessedName
        }
        guard !bare.isEmpty else { return nil }

        let memberNames = toolsByName.keys.filter {
            groupName(for: $0) == bare && isGlobalEnabled($0)
        }
        guard !memberNames.isEmpty else { return nil }

        let agentAllowed: Set<String>? = ChatExecutionContext.currentAgentId.flatMap {
            AgentManager.shared.effectiveEnabledToolNames(for: $0).map(Set.init)
        }
        guard memberNames.contains(where: { agentAllowed?.contains($0) ?? true }) else {
            return nil
        }

        guard let scope = ChatExecutionContext.toolExecutionScope else { return nil }
        let loaderName: String
        if scope.permits("capabilities") {
            loaderName = "capabilities"
        } else if scope.permits("capabilities_load") {
            loaderName = "capabilities_load"
        } else {
            return nil
        }

        return ToolErrorEnvelope(
            kind: .toolNotFound,
            reason:
                "'\(guessedName)' is a capability id for a plugin group, not a callable "
                + "function. Call \(loaderName) with {\"ids\":[\"plugin/\(bare)\"]} to "
                + "load it, then call one of the loaded tool names to continue.",
            toolName: guessedName,
            retryable: true
        ).toJSONString()
    }

    /// Returns the plugin or provider name that a tool belongs to, if any.
    func groupName(for toolName: String) -> String? {
        guard let tool = toolsByName[toolName] else { return nil }
        if Self.agentChannelToolNames.contains(toolName) { return "agent_channels" }
        if let ext = tool as? ExternalTool { return ext.pluginId }
        if let mcp = tool as? MCPProviderTool { return mcp.providerName }
        if let sandbox = tool as? SandboxPluginTool { return sandbox.plugin.id }
        if let declared = tool as? any CapabilityToolGroupDeclaring {
            return declared.capabilityGroupId
        }
        return nil
    }

    func manifestsIndividually(_ toolName: String) -> Bool {
        toolsByName[toolName] is any IndividuallyManifestedCapabilityTool
    }

    private func availabilityRuntimeLabel(for toolName: String, builtIn: Bool) -> String {
        if isSandboxTool(toolName) { return L("sandbox") }
        if isMCPTool(toolName) { return "mcp" }
        if Self.agentChannelToolNames.contains(toolName) { return L("native") }
        if isPluginTool(toolName) { return L("plugin") }
        if builtIn { return L("builtin") }
        return L("native")
    }

    static let capabilityToolNames: Set<String> = [
        "capabilities", "capabilities_discover", "capabilities_load",
    ]

    /// Fetch-tool names models import from other harnesses (Claude Code's
    /// WebFetch, LangChain requests_get, the reference MCP fetch server, …).
    /// None have ever existed in osaurus; calls to them are steered to
    /// `search_and_extract` when this request exposes it (see `execute`).
    /// Lowercase; matched case-insensitively. Only consulted for names with
    /// NO real registration, so a plugin/MCP tool legitimately claiming one
    /// of these always wins. Deliberately excludes browser-intent names
    /// (`browse`, `open_url`) — steering "log in and click" intent to a
    /// read-only extractor points AWAY from a `browser_use` sitting in the
    /// schema — and shell-intent names (`curl`), whose POST/API shapes
    /// extraction cannot serve.
    /// The single registered tool, exposed to the current request, whose
    /// name is `<group>_<name>` for the unregistered `name` the model used;
    /// nil when there is none or more than one.
    func uniqueExposedSuffixMatch(for name: String) -> String? {
        let lower = name.lowercased()
        guard lower.count >= 6 else { return nil }
        let scope = ChatExecutionContext.toolExecutionScope
        let candidates = toolsByName.keys.filter { registered in
            registered.lowercased().hasSuffix("_" + lower)
                && (scope?.permits(registered) ?? false)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// " and its own arguments: required <a, b>; optional <c>" for the
    /// steered-to tool, so the model does not carry the invented tool's
    /// argument shape over (following "same arguments" got an invalid_args
    /// rejection in the independent audit). Empty when the tool declares no
    /// object schema.
    func schemaHint(for registeredName: String) -> String {
        guard let tool = toolsByName[registeredName],
            case .object(let root)? = tool.parameters,
            case .object(let props)? = root["properties"]
        else { return "" }
        var required: [String] = []
        if case .array(let req)? = root["required"] {
            required = req.compactMap { if case .string(let r) = $0 { return r } else { return nil } }
        }
        let optional = props.keys.filter { !required.contains($0) }.sorted()
        var parts: [String] = []
        if !required.isEmpty { parts.append("required: \(required.sorted().joined(separator: ", "))") }
        if !optional.isEmpty { parts.append("optional: \(optional.joined(separator: ", "))") }
        guard !parts.isEmpty else { return "" }
        return " and its own arguments (\(parts.joined(separator: "; ")))"
    }

    static let hallucinatedFetchToolNames: Set<String> = [
        "web_fetch", "webfetch", "fetch", "fetch_url", "fetch_page",
        "fetch_webpage", "http_get", "get_url", "get_webpage", "read_url",
        "read_webpage", "visit_page", "load_url", "url_fetch",
    ]

    /// The exact set above plus the provider-suffixed shapes models invent
    /// from other stacks (`web_fetch_exa` — the name in the Ornith research
    /// report — `fetch_url_firecrawl`, `webfetch_tavily`): any unregistered
    /// name that starts with `web_fetch`/`webfetch`/`fetch_` or ends with
    /// `_fetch` is a fetch intent. Still consulted only for names with no
    /// real registration.
    static func isHallucinatedFetchToolName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if hallucinatedFetchToolNames.contains(lower) { return true }
        return lower.hasPrefix("web_fetch") || lower.hasPrefix("webfetch") || lower.hasPrefix("fetch_")
            || lower.hasSuffix("_fetch")
    }

    /// Built-in tools that are authoritatively gated per-agent and must never
    /// surface through `capabilities_discover`. Unlike the lean-by-default
    /// built-in gates (render_chart, speak, search_memory, the scheduler trio,
    /// db_*) — which stay discoverable so a `capabilities_load` can pull them in
    /// mid-session — these have NO load carve-out: `SystemPromptComposer`
    /// auto-injects them into the schema when the owning agent flag is on and
    /// strips them otherwise. Indexing them would let the model "discover" a
    /// capability it can never load (the per-agent gate re-strips it), so they
    /// are kept out of the search index entirely.
    /// Built-in tools that are kept OUT of every turn-1 baseline and enter a
    /// session only through `capabilities` load. The opposite contract from
    /// `nonDiscoverableBuiltInToolNames`: discoverable, and loadable by any
    /// agent that has the gateway.
    ///
    /// Exists for `update_skill`. Most users never edit a skill from chat, and
    /// a spec in the baseline is a spec in every user's cached prompt prefix:
    /// adding one costs a cold prefill per conversation after the update, on
    /// every device. Loading it on demand appends the schema to the
    /// conversation suffix instead, so the prefix stays byte-identical for
    /// everyone who never asks. The `.ask` permission modal remains the gate;
    /// this set only decides how the spec reaches the schema.
    nonisolated static let onDemandBuiltInToolNames: Set<String> = [
        "update_skill"
    ]

    static let nonDiscoverableBuiltInToolNames: Set<String> = [
        ComputerUseTool.toolName,
        BrowserUseTool.toolName,
        // Same authoritative per-agent contract as the pair above: the
        // composer injects these only when the owning agent flag is on and
        // strips them otherwise, with no capabilities_load carve-out.
        // Discovering them on an agent with the flag off produced a
        // discover→load dead loop ("gated built-in and cannot be enabled").
        "spawn_agent", "spawn_model", "spawn_batch",
        "applescript", "mac_query",
    ]

    /// Always-loaded tool specs: built-in + runtime-managed tools.
    /// These are always included when registered — mode exclusions handle
    /// which runtime tools are relevant. Plugin/MCP/sandbox-plugin tools
    /// load on demand via capabilities_discover / capabilities_load.
    ///
    /// When `excludeCapabilityTools` is true (manual tool selection mode),
    /// dynamic discovery tools are stripped so the model only sees
    /// the user's explicitly chosen tools.
    func alwaysLoadedSpecs(mode: ExecutionMode, excludeCapabilityTools: Bool = false) -> [Tool] {
        let builtInNames = Set(builtInToolNames)
        let runtimeNames = runtimeManagedToolNames
        let excluded = excludedToolNames(for: mode)

        let specs =
            toolsByName.values
            .filter { tool in
                builtInNames.contains(tool.name) || runtimeNames.contains(tool.name)
            }
            .filter { !excluded.contains($0.name) }
            .filter { !excludeCapabilityTools || !Self.capabilityToolNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { $0.asOpenAITool() }
        return annotatedForCombinedMode(specs, mode: mode)
    }

    /// Sandbox built-in tool specs available for the given execution mode.
    /// Used by manual tool-selection mode to keep sandbox tools discoverable
    /// even when the user has not explicitly opted into them.
    func sandboxBuiltInSpecs(mode: ExecutionMode) -> [Tool] {
        let excluded = excludedToolNames(for: mode)
        let specs =
            toolsByName.values
            .filter { builtInSandboxToolNames.contains($0.name) }
            .filter { !excluded.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { $0.asOpenAITool() }
        return annotatedForCombinedMode(specs, mode: mode)
    }

    /// Routing note appended to the unified `file_*` read tools' rendered
    /// descriptions in combined mode. Their base descriptions only mention
    /// the host "working directory", but in combined mode the same tools
    /// also reach the Linux sandbox by path, so the model needs to be told
    /// at the schema level (not just in the prompt) that `/workspace/...`
    /// is a valid target.
    private static let combinedModeFileRoutingNote =
        " In this mode the `path` may also be an absolute `/workspace/...` location, "
        + "which reads the Linux sandbox scratch area instead of your workspace."

    /// Write-tool variant of the routing note for WRITABLE combined mode.
    private static let combinedModeWriteRoutingNote =
        " In this mode the `path` decides the filesystem: a relative path writes the user's "
        + "folder (tracked, undoable), an absolute `/workspace/...` path writes the Linux "
        + "sandbox scratch area."

    /// Staging hint appended to `sandbox_exec`'s rendered description in
    /// combined mode: commands cannot see the workspace, and `file_copy`
    /// (not `file_read`+`file_write`) is how bytes — especially binaries —
    /// get into the sandbox first.
    private static let combinedModeExecStagingNote =
        " The sandbox has no mount of the user's workspace — stage a workspace file "
        + "(any type, including binaries like PDFs and images) into `/workspace/...` "
        + "with `file_copy` before processing it."

    /// In combined sandbox + host-read mode the host `file_*` tools are the
    /// single, path-routed read family (and, with the write grant, the
    /// single write family). Annotate their rendered specs so the model
    /// knows they reach `/workspace/...` sandbox paths too, and retarget
    /// `sandbox_exec`'s `sandbox_write_file` references at the unified
    /// writers when `sandbox_write_file` is hidden. Inert (returns `specs`
    /// unchanged) in every other mode and for every other tool, so pure
    /// folder / pure sandbox schemas are untouched.
    private func annotatedForCombinedMode(_ specs: [Tool], mode: ExecutionMode) -> [Tool] {
        guard mode.usesSandboxTools, mode.allowsHostReadTools else { return specs }
        let writable = mode.allowsHostWriteTools
        return specs.map { spec in
            let name = spec.function.name
            let base = spec.function.description ?? ""
            let description: String
            if Self.folderReadOnlyToolNames.contains(name) {
                description = base + Self.combinedModeFileRoutingNote
            } else if writable, Self.folderWriteToolNames.contains(name) {
                description = base + Self.combinedModeWriteRoutingNote
            } else if name == "sandbox_exec" {
                var updated = base
                if writable {
                    // `sandbox_write_file` is hidden in writable combined
                    // mode; don't advertise a tool that isn't in the schema
                    // — point at the unified writer.
                    updated = updated.replacingOccurrences(
                        of: "`sandbox_write_file`",
                        with: "`file_write` (with a `/workspace/...` path)"
                    )
                }
                description = updated + Self.combinedModeExecStagingNote
            } else if writable, base.contains("`sandbox_write_file`") {
                // Any other tool referencing the hidden `sandbox_write_file`
                // in writable combined mode gets the same retarget.
                description = base.replacingOccurrences(
                    of: "`sandbox_write_file`",
                    with: "`file_write` (with a `/workspace/...` path)"
                )
            } else {
                return spec
            }
            return Tool(
                type: spec.type,
                function: ToolFunction(
                    name: name,
                    description: description,
                    parameters: spec.function.parameters
                )
            )
        }
    }
}

// MARK: - Configure tool name sets (default-agent surface)
//
// Single source of truth for the consolidated `osaurus_*` configure
// surface. The write set is derived from
// `ConfigurationDomainRegistry.shared.domains` (computed property —
// stays in sync as new domains register without touching this file).
// The Default agent loads these directly in its turn-1 schema.
//
// These sets are read by:
//  - `SystemPromptComposer.resolveTools` to allowlist the configure
//    tools for the Default agent and strip them from every other agent
//  - `CapabilitiesDiscoverTool` / `CapabilitiesLoadTool` to scope FTS5
//    results and gate loads for *custom* agents (the Default agent no
//    longer uses capability search — it gets these tools directly)

extension ToolRegistry {
    /// Write tools across every registered `ConfigurationDomain`.
    /// Computed live so adding a new domain at runtime expands the
    /// set without an extra step. `public` so the out-of-process eval kit
    /// (`EvalRunner`, plain `import OsaurusCore`) can reuse the exact
    /// production set for its compact-model `capabilities_load` exemption.
    public static var configureWriteToolNames: Set<String> {
        var union: Set<String> = []
        for domain in ConfigurationDomainRegistry.shared.domains {
            union.formUnion(domain.writeToolNames)
        }
        return union
    }

    /// Every tool that exists for the *configure* surface — the two
    /// generic reads (`osaurus_inspect`, `osaurus_help`) plus every
    /// write across every domain. Used by
    /// `SystemPromptComposer.resolveTools` to strip configure tools
    /// from non-default agents' schemas.
    static var configureToolNames: Set<String> {
        configureWriteToolNames.union([
            "osaurus_inspect",
            "osaurus_help",
        ])
    }

    // MARK: - Tool surfaces (declarative per-role policy)
    //
    // The four roles a schema is assembled for. Declaring the role policies
    // HERE — in one table — is what keeps the orchestrator resolver
    // (`SystemPromptComposer.resolveTools`) and the worker resolver
    // (`TextSubagentKind.autoChildToolNames` / `childToolNames`) from
    // drifting apart again:
    //
    //   * `.orchestrator` — the Default agent (direct chat): the
    //     consolidated configure surface + agent-loop
    //     tools + `get_current_time` + the native search pair
    //     (`web_search` / `search_and_extract` for quick lookups), plus
    //     (applied in `resolveTools`) the visible
    //     delegation tools. It NEVER carries the tools in
    //     `orchestratorExcludedToolNames`: heavy work is dispatched to
    //     workers, not done in the orchestrator's own loop.
    //   * `.customAgent` — a custom agent's direct chat: the capability-gated
    //     baseline (`resolveTools` gates), untouched by this table.
    //   * `.spawnedWorker` — an agent-target spawned child: the target
    //     agent's capability-gated tools plus
    //     `spawnedWorkerBaselineToolNames`, minus the spawn family and
    //     `clarify` (`TextSubagentKind.isExcludedChildTool`), intersected
    //     with `specsForSpawnedOperations` (cancellation audit).
    //   * `.bareModelWorker` — a bare-model spawned child: only the curated
    //     read-only file set (`TextSubagentKind.readOnlyChildToolNames`).
    public enum ToolSurface: Sendable {
        case orchestrator
        case customAgent
        case spawnedWorker
        case bareModelWorker
    }

    /// Tools the orchestrator (Default agent) must NEVER carry, because its
    /// contract is to dispatch that work to spawned helpers:
    ///   * `share_artifact` — workers deliver files; the artifact pipeline
    ///     promotes a worker's shared artifact straight to the user, so the
    ///     orchestrator has no re-share step.
    /// Custom agents keep this tool in their OWN direct chats — this
    /// exclusion is about the orchestrator role, not the tool. Note that
    /// `web_search` / `search_and_extract` are NOT excluded: quick lookups
    /// are a basic orchestrator capability (heavy research still dispatches
    /// to workers).
    nonisolated static let orchestratorExcludedToolNames: Set<String> = [
        "share_artifact"
    ]

    /// Baseline names every agent-target spawned worker carries regardless
    /// of the target's capability toggles: time for grounding, and
    /// `share_artifact` because a worker's shared file is the ONLY way its
    /// output artifacts reach the user (the parent receives just a digest).
    nonisolated static let spawnedWorkerBaselineToolNames: Set<String> = [
        "get_current_time", "share_artifact",
    ]

    /// Turn-1 schema for the `.orchestrator` surface (the Default agent):
    /// the consolidated configure surface — the two generic reads
    /// (`osaurus_inspect` / `osaurus_help`) plus the single declarative write tool
    /// (`osaurus_config`) — together with the agent-loop tools
    /// (`todo` / `complete` / `clarify`),
    /// `get_current_time`, and the native search pair (`web_search` /
    /// `search_and_extract`) for quick lookups — heavy research still
    /// dispatches to workers. The Default agent loads its write tools
    /// **directly**; it does NOT use `capabilities_discover` /
    /// `capabilities_load` (those stay available to custom agents). Computed
    /// from the live domain registry so a newly registered domain expands
    /// the set automatically, and stable across a session for KV-cache
    /// reuse.
    static var orchestratorAllowedToolNames: Set<String> {
        configureToolNames.union([
            "todo", "complete", "clarify", "get_current_time",
            "web_search", "search_and_extract",
        ])
    }
}

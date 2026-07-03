//
//  ToolRegistry.swift
//  osaurus
//
//  Central registry for chat tools. Provides OpenAI tool specs and execution by name.
//

import Foundation
import Combine

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
private enum ToolSpecTokenEstimator {
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
            // Capability discovery (search -> load) for mid-session growth.
            CapabilitiesDiscoverTool(),
            CapabilitiesLoadTool(),
            // Persistent memory recall — one tool, dispatched by `scope`.
            SearchMemoryTool(),
            // Inline data visualization rendered as a chart card.
            RenderChartTool(),
            // Text-delegation family: `spawn_agent` hands a task to a configured
            // agent (its prompt + model); `spawn_model` hands a task to a bare
            // spawnable model id. Both gate per-agent (their pools) in
            // `SystemPromptComposer.resolveTools` via `SubagentToolVisibility`.
            SpawnAgentTool(),
            SpawnModelTool(),
            // Native local image generation/editing (one `image` tool; source_paths
            // → edit). Tool body enforces the separate Agent Delegation permission
            // defaults and low-RAM unload policy.
            ImageTool(),
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
            // them DIRECTLY (see `defaultAgentAllowedToolNames`), while
            // custom agents reach them on demand via
            // `capabilities_discover` / `capabilities_load`.
            OsaurusStatusTool(),
            OsaurusListTool(),
            OsaurusDescribeTool(),
            // Computer Use (macOS automation harness). Registered as a
            // built-in so the runtime can execute it and ChatView can
            // intercept its live activity feed, but the system prompt
            // composer strips it authoritatively unless the agent opts in
            // via `computerUseEnabled` (custom agents only). Conforms to
            // PermissionedTool: execution preflights Accessibility +
            // Screen Recording before the loop runs.
            ComputerUseTool(),
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

    // MARK: - External surface deny list

    /// Host-mutation tool classes that must never be invocable from EXTERNAL
    /// surfaces. Kept separate from `agentChannelToolNames` so the full deny
    /// list below stays a derived union with a single source of truth per
    /// tool family.
    nonisolated static let externallyDeniedHostToolNames: Set<String> = [
        "file_write", "file_edit", "shell_run", "git_commit", "file_undo",
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
    func resolvePermissionGate(name: String, argumentsJSON: String) async throws {
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
        try await runPermissionGate(tool: tool, name: name, argumentsJSON: argumentsJSON)
    }

    /// The permission gate shared by `execute` and `resolvePermissionGate`:
    /// system-permission prompts, the per-tool ask/deny/auto policy
    /// (including the user approval prompt), and `.auto` grant backfill.
    private func runPermissionGate(tool: OsaurusTool, name: String, argumentsJSON: String) async throws {
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
            let effectivePolicy = configuration.policy[name] ?? defaultPolicy
            switch effectivePolicy {
            case .deny:
                throw NSError(
                    domain: "ToolRegistry",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Execution denied by policy for tool: \(name)"]
                )
            case .ask:
                let approved: Bool
                if ChatExecutionContext.autoApproveToolPrompts {
                    approved = true
                } else if ChatExecutionContext.denyUnapprovedToolPrompts {
                    // Headless eval with no UI: deny instead of hanging on an
                    // approval card nobody can click (see task-local doc).
                    approved = false
                } else {
                    approved = await ToolPermissionPromptService.requestApproval(
                        toolName: name,
                        description: tool.description,
                        argumentsJSON: argumentsJSON
                    )
                }
                if !approved {
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "User denied execution for tool: \(name)"]
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
                } else {
                    approved = await ToolPermissionPromptService.requestApproval(
                        toolName: name,
                        description: tool.description,
                        argumentsJSON: argumentsJSON
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
        permissionGateResolved: Bool = false
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
        var name = rawName
        if toolsByName[name] == nil, name.hasPrefix("tool/") {
            let stripped = String(name.dropFirst("tool/".count))
            if toolsByName[stripped] != nil { name = stripped }
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
        // Permission gating. Skipped when the caller already resolved the
        // gate via `resolvePermissionGate` (parallel batches resolve every
        // approval serially in model order BEFORE executing concurrently,
        // so approval prompts never stack or race).
        if !permissionGateResolved {
            try await runPermissionGate(tool: tool, name: name, argumentsJSON: argumentsJSON)
        }
        // Coerce + preflight against the tool's schema. Returns either
        // a (possibly rewritten) `argumentsJSON` ready for dispatch, or
        // a structured failure envelope to short-circuit with.
        switch Self.preflight(argumentsJSON: argumentsJSON, schema: tool.parameters, toolName: name) {
        case .rejected(let envelopeJSON):
            return envelopeJSON
        case .ready(let effectiveArgumentsJSON):
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
                let flat = effectiveArgumentsJSON.replacingOccurrences(of: "\n", with: " ")
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
            let result = try await ChatExecutionContext.$hostReadOnlyScope.withValue(policy.scope) {
                try await ChatExecutionContext.$allowHostSecretReads.withValue(policy.allowSecretReads) {
                    try await ChatExecutionContext.$sandboxReadBridge.withValue(combinedSandboxReadBridge) {
                        if tool.bypassRegistryTimeout {
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
    private var combinedHostReadPolicy: (scope: URL?, allowSecretReads: Bool) {
        guard toolsByName.keys.contains("sandbox_exec"),
            let root = FolderContextService.cachedRootPath
        else { return (nil, false) }
        return (root, resolvedAutonomousExecConfig?.allowHostSecretReads ?? false)
    }

    /// Sandbox identity bound around every tool body in combined mode so the
    /// unified host `file_*` tools can serve an absolute `/workspace/...`
    /// path from the Linux sandbox (path-routed file access). Same gate as
    /// `combinedHostReadPolicy` (sandbox exec registered + folder root),
    /// plus a resolvable agent id; `nil` in plain folder / plain sandbox
    /// modes so they stay untouched.
    private var combinedSandboxReadBridge: SandboxReadBridge? {
        guard toolsByName.keys.contains("sandbox_exec"),
            FolderContextService.cachedRootPath != nil
        else { return nil }
        // Prefer the identity captured at sandbox-tool registration; it
        // can't go stale mid-turn and doesn't require `currentAgentId` to
        // be bound at the call site. Fall back to the execution context's
        // agent id for any path that drives a tool call without going
        // through `BuiltinSandboxTools.register` first.
        if let captured = activeSandboxAgentContext {
            return captured
        }
        guard let agentId = ChatExecutionContext.currentAgentId else { return nil }
        let agentName = SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
        return SandboxReadBridge(
            agentName: agentName,
            home: OsaurusPaths.inContainerAgentHome(agentName)
        )
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
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message: message,
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

        let cap = ToolOutputCaps.universalResult
        let isEnvelope = ToolEnvelope.isSuccess(payload) || ToolEnvelope.isError(payload)

        if payload.count <= cap {
            return isEnvelope ? payload : ToolEnvelope.success(tool: tool, text: payload)
        }

        // Head-biased: at the registry backstop the front of an oversized
        // payload is what identifies it (the recovery hint rides in the
        // envelope, not the marker).
        let truncatedContent = HeadTailTruncation.apply(payload, cap: cap, headFraction: 2.0 / 3.0)
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
    func setActiveSandboxAgentContext(agentName: String, home: String) {
        activeSandboxAgentContext = SandboxReadBridge(agentName: agentName, home: home)
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
    func registerMCPTool(_ tool: OsaurusTool) {
        let firstTime =
            toolsByName[tool.name] == nil
            && !configuration.enabled.keys.contains(tool.name)
        toolsByName[tool.name] = tool
        sandboxToolNames.remove(tool.name)
        builtInSandboxToolNames.remove(tool.name)
        pluginToolNames.remove(tool.name)
        mcpToolNames.insert(tool.name)
        if firstTime {
            setEnabled(true, for: tool.name)
        }
        Task {
            await ToolIndexService.shared.onToolRegistered(
                name: tool.name,
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

    /// The read-only subset of the folder tools. In combined sandbox +
    /// host-read mode these stay visible (the agent reads the host
    /// workspace) while every other folder tool — host write / edit /
    /// shell / git — is hidden, because exec is confined to the sandbox
    /// and the host is read-only. Single source of truth shared by
    /// `excludedToolNames` and the combined-mode tests.
    static let folderReadOnlyToolNames: Set<String> = [
        "file_read", "file_search",
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
            // Combined sandbox + host-read mode keeps the read-only host
            // subset (`file_read` / `file_search`) visible while still
            // hiding host write / edit / shell / git — exec is
            // sandbox-only, the host is read-only.
            var folderExcluded = Self.folderToolNames
            if mode.allowsHostReadTools {
                folderExcluded.subtract(Self.folderReadOnlyToolNames)
            }
            excluded.formUnion(folderExcluded)
        }
        if !mode.usesSandboxTools {
            excluded.formUnion(builtInSandboxToolNames)
        } else if mode.allowsHostReadTools {
            // Combined sandbox + host-read mode: the host `file_*` tools are
            // the single, path-routed read family the model sees, so hide
            // the redundant sandbox read tools (`file_read` / `file_search`
            // serve `/workspace/...` paths via the bridge; `file_read` also
            // lists directories). They stay registered (just hidden from the
            // schema) so tear-down and capability indexing see them.
            excluded.formUnion(Self.sandboxReadToolNames)
        }
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

    /// Resolve the active execution mode for a chat send. Single source of
    /// truth: callers pass the user's explicit intent (autonomous toggle +
    /// optional folder context) and we apply the priority rule once.
    ///
    /// Priority: sandbox > host folder > none. Sandbox wins because the
    /// container takes longer to provision and a user who toggled it on is
    /// signalling "use this when ready"; folder mode requires an explicit
    /// folder selection so it only fires when sandbox is off.
    ///
    /// Sandbox mode is only returned when both autonomous is enabled AND
    /// `sandbox_exec` is registered. If autonomous is on but sandbox tools
    /// haven't registered yet (provision still in flight), we return `.none`
    /// — the composer's "Sandbox not ready" notice + the placeholder tool
    /// take it from there. Avoids the hidden assumption that
    /// `autonomousEnabled` alone implied `.sandbox`.
    func resolveExecutionMode(
        folderContext: FolderContext?,
        autonomousEnabled: Bool
    ) -> ExecutionMode {
        if autonomousEnabled, toolsByName.keys.contains("sandbox_exec") {
            // Combined mode: exec runs in the sandbox, and any mounted
            // folder rides along as a read-only host workspace
            // (`hostRead`). When no folder is picked this is plain
            // sandbox mode. Either way exec is confined to the VM, which
            // has no mount of the host workspace.
            return .sandbox(hostRead: folderContext)
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

        if dynamic, let selectedPreflightNames, !selectedPreflightNames.contains(toolName) {
            appendReason(.notSelectedByPreflight)
            details.append(L("not selected by preflight for this turn"))
        }

        if reasons.isEmpty {
            if dynamic {
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

    /// Returns the plugin or provider name that a tool belongs to, if any.
    func groupName(for toolName: String) -> String? {
        guard let tool = toolsByName[toolName] else { return nil }
        if Self.agentChannelToolNames.contains(toolName) { return "agent_channels" }
        if let ext = tool as? ExternalTool { return ext.pluginId }
        if let mcp = tool as? MCPProviderTool { return mcp.providerName }
        if let sandbox = tool as? SandboxPluginTool { return sandbox.plugin.id }
        return nil
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
        "capabilities_discover", "capabilities_load",
    ]

    /// Built-in tools that are authoritatively gated per-agent and must never
    /// surface through `capabilities_discover`. Unlike the lean-by-default
    /// built-in gates (render_chart, speak, search_memory, the scheduler trio,
    /// db_*) — which stay discoverable so a `capabilities_load` can pull them in
    /// mid-session — these have NO load carve-out: `SystemPromptComposer`
    /// auto-injects them into the schema when the owning agent flag is on and
    /// strips them otherwise. Indexing them would let the model "discover" a
    /// capability it can never load (the per-agent gate re-strips it), so they
    /// are kept out of the search index entirely. `computer_use` is the sole
    /// member today.
    static let nonDiscoverableBuiltInToolNames: Set<String> = [
        ComputerUseTool.toolName
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

    /// In combined sandbox + host-read mode the host `file_*` tools are the
    /// single, path-routed read family. Annotate their rendered specs so
    /// the model knows they reach `/workspace/...` sandbox paths too. Inert
    /// (returns `specs` unchanged) in every other mode and for every other
    /// tool, so pure folder / pure sandbox schemas are untouched.
    private func annotatedForCombinedMode(_ specs: [Tool], mode: ExecutionMode) -> [Tool] {
        guard mode.usesSandboxTools, mode.allowsHostReadTools else { return specs }
        return specs.map { spec in
            guard Self.folderReadOnlyToolNames.contains(spec.function.name) else { return spec }
            let base = spec.function.description ?? ""
            return Tool(
                type: spec.type,
                function: ToolFunction(
                    name: spec.function.name,
                    description: base + Self.combinedModeFileRoutingNote,
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

    /// Every tool that exists for the *configure* surface — the three
    /// generic reads (`osaurus_status`, `osaurus_list`,
    /// `osaurus_describe`) plus every write across every domain. Used
    /// by `SystemPromptComposer.resolveTools` to strip configure tools
    /// from non-default agents' schemas.
    static var configureToolNames: Set<String> {
        configureWriteToolNames.union([
            "osaurus_status",
            "osaurus_list",
            "osaurus_describe",
        ])
    }

    /// Turn-1 schema for the Default (configuration) agent: the consolidated
    /// configure surface — the three generic reads (`osaurus_status` /
    /// `osaurus_list` / `osaurus_describe`) plus the per-domain `osaurus_*`
    /// write tools — together with the agent-loop tools (`todo` / `complete` /
    /// `clarify`). The Default agent loads its write tools **directly**; it
    /// does NOT use `capabilities_discover` / `capabilities_load` (those stay
    /// available to custom agents). Computed from the live domain registry so
    /// a newly registered domain expands the set automatically, and stable
    /// across a session for KV-cache reuse.
    static var defaultAgentAllowedToolNames: Set<String> {
        configureToolNames.union(["todo", "complete", "clarify"])
    }
}

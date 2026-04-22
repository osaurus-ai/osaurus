//
//  ToolRegistry.swift
//  osaurus
//
//  Central registry for chat tools. Provides OpenAI tool specs and execution by name.
//

import Foundation
import Combine

@MainActor
final class ToolRegistry: ObservableObject {
    static let shared = ToolRegistry()

    @Published private var toolsByName: [String: OsaurusTool] = [:]
    @Published private var configuration: ToolConfiguration = ToolConfigurationStore.load()
    /// Names of tools registered via registerBuiltInTools (always loaded).
    private(set) var builtInToolNames: Set<String> = []

    /// Tool names that require the sandbox container to be running
    private var sandboxToolNames: Set<String> = []
    /// Built-in sandbox execution tools managed by runtime context.
    private var builtInSandboxToolNames: Set<String> = []
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
            var total = name.count + description.count
            if let params = parameters {
                total += Self.estimateJSONSize(params)
            }
            // Overhead for JSON structure: {"type":"function","function":{"name":"...","description":"...","parameters":...}}
            // = 38 (prefix) + 17 (desc key) + 15 (params key) + 2 (closing) = 72 chars
            total += 72
            return max(1, total / 4)
        }

        /// Recursively estimate the serialized size of a JSONValue
        private static func estimateJSONSize(_ value: JSONValue) -> Int {
            switch value {
            case .null:
                return 4  // "null"
            case .bool(let b):
                return b ? 4 : 5  // "true" or "false"
            case .number(let n):
                return String(n).count
            case .string(let s):
                return s.count + 2  // quotes
            case .array(let arr):
                return arr.reduce(2) { $0 + estimateJSONSize($1) + 1 }  // brackets + commas
            case .object(let dict):
                return dict.reduce(2) { acc, pair in
                    // "key": value, = key.count + 4 (quotes + colon + space) + value + 1 (comma)
                    acc + pair.key.count + 5 + estimateJSONSize(pair.value)
                }
            }
        }
    }

    private init() {
        registerBuiltInTools()
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
            // Only sanctioned path for surfacing files / inline blobs to
            // the user (file_write / sandbox writes do not show in chat).
            ShareArtifactTool(),
            // Capability discovery (search -> load) for mid-session growth.
            CapabilitiesSearchTool(),
            CapabilitiesLoadTool(),
            // Persistent memory recall — one tool, dispatched by `scope`.
            SearchMemoryTool(),
            // Inline data visualization rendered as a chart card.
            RenderChartTool(),
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
    }

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
        tool.asOpenAITool().function.name.count + (tool.description.count / 4)
    }

    /// Get specs for specific tools by name (ignores enabled state).
    func specs(forTools toolNames: [String]) -> [Tool] {
        return toolNames.compactMap { name in
            toolsByName[name]?.asOpenAITool()
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
    func execute(name: String, argumentsJSON: String) async throws -> String {
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
            return ToolErrorEnvelope(
                kind: .toolNotFound,
                reason: "Tool '\(name)' is not available in this session.",
                toolName: name
            ).toJSONString()
        }
        // Permission gating
        if let permissioned = tool as? PermissionedTool {
            let requirements = permissioned.requirements

            // Check system permissions and prompt the user for any that are missing
            let missingSystemPermissions = SystemPermissionService.shared.missingPermissions(from: requirements)
            for permission in missingSystemPermissions {
                _ = await SystemPermissionService.shared.requestPermissionAndWait(permission)
            }
            let stillMissing = SystemPermissionService.shared.missingPermissions(from: requirements)
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
                let approved = await ToolPermissionPromptService.requestApproval(
                    toolName: name,
                    description: tool.description,
                    argumentsJSON: argumentsJSON
                )
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
                let approved = await ToolPermissionPromptService.requestApproval(
                    toolName: name,
                    description: tool.description,
                    argumentsJSON: argumentsJSON
                )
                if !approved {
                    throw NSError(
                        domain: "ToolRegistry",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "User denied execution for tool: \(name)"]
                    )
                }
            }
        }
        // Schema preflight: catches `additionalProperties: false` violations
        // and obvious type mismatches before the tool body sees them. Parse
        // failure and missing schema are tolerated — tool bodies typically
        // have richer field-aware `require…` helpers.
        if let schema = tool.parameters,
            let data = argumentsJSON.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        {
            let result = SchemaValidator.validate(arguments: parsed, against: schema)
            if !result.isValid, let message = result.errorMessage {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: message,
                    field: result.field,
                    tool: name
                )
            }
        }

        // Run the tool body off MainActor so long-running tools (file I/O,
        // network, shell) don't contend with SwiftUI layout on the main thread.
        return try await Self.runToolBody(tool, argumentsJSON: argumentsJSON)
    }

    /// Trampoline that executes the tool outside of MainActor isolation.
    private nonisolated static func runToolBody(
        _ tool: OsaurusTool,
        argumentsJSON: String
    ) async throws -> String {
        try await tool.execute(argumentsJSON: argumentsJSON)
    }

    // MARK: - Listing / Enablement

    /// Returns all registered tools with global enabled state.
    func listTools() -> [ToolEntry] {
        return toolsByName.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { t in
                ToolEntry(
                    name: t.name,
                    description: t.description,
                    enabled: configuration.isEnabled(name: t.name),
                    parameters: t.parameters
                )
            }
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
            total + estimatedTokens(for: tool.function.name)
        }
    }

    // MARK: - Policy / Grants
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
            systemPermissionStates[perm] = SystemPermissionService.shared.isGranted(perm)
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

    /// Runtime-managed tools are execution infrastructure, always loaded when registered.
    var runtimeManagedToolNames: Set<String> {
        Self.folderToolNames.union(builtInSandboxToolNames)
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
            excluded.formUnion(Self.folderToolNames)
        }
        if !mode.usesSandboxTools {
            excluded.formUnion(builtInSandboxToolNames)
        }
        if mode.usesHostFolderTools || mode.usesSandboxTools {
            excluded.formUnion(folderConflictingToolNames)
        }
        return excluded
    }

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
            return .sandbox
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

    /// True when no dynamic (MCP / plugin / sandbox-plugin) tool is enabled
    /// for the agent. Used by `SystemPromptComposer` to decide whether the
    /// "Sandbox Plugin Creator" skill should be injected as a backstop —
    /// only when the agent literally has no way to satisfy a request via
    /// existing tools, not just when this turn's preflight didn't pick one.
    func dynamicCatalogIsEmpty() -> Bool {
        listDynamicTools().isEmpty
    }

    /// Returns the plugin or provider name that a tool belongs to, if any.
    func groupName(for toolName: String) -> String? {
        guard let tool = toolsByName[toolName] else { return nil }
        if let ext = tool as? ExternalTool { return ext.pluginId }
        if let mcp = tool as? MCPProviderTool { return mcp.providerName }
        if let sandbox = tool as? SandboxPluginTool { return sandbox.plugin.id }
        return nil
    }

    static let capabilityToolNames: Set<String> = [
        "capabilities_search", "capabilities_load",
    ]

    /// Always-loaded tool specs: built-in + runtime-managed tools.
    /// These are always included when registered — mode exclusions handle
    /// which runtime tools are relevant. Plugin/MCP/sandbox-plugin tools
    /// load on demand via capabilities_search / capabilities_load.
    ///
    /// When `excludeCapabilityTools` is true (manual tool selection mode),
    /// dynamic discovery tools are stripped so the model only sees
    /// the user's explicitly chosen tools.
    func alwaysLoadedSpecs(mode: ExecutionMode, excludeCapabilityTools: Bool = false) -> [Tool] {
        let builtInNames = Set(builtInToolNames)
        let runtimeNames = runtimeManagedToolNames
        let excluded = excludedToolNames(for: mode)

        return toolsByName.values
            .filter { tool in
                builtInNames.contains(tool.name) || runtimeNames.contains(tool.name)
            }
            .filter { !excluded.contains($0.name) }
            .filter { !excludeCapabilityTools || !Self.capabilityToolNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { $0.asOpenAITool() }
    }

    /// Sandbox built-in tool specs available for the given execution mode.
    /// Used by manual tool-selection mode to keep sandbox tools discoverable
    /// even when the user has not explicitly opted into them.
    func sandboxBuiltInSpecs(mode: ExecutionMode) -> [Tool] {
        let excluded = excludedToolNames(for: mode)
        return toolsByName.values
            .filter { builtInSandboxToolNames.contains($0.name) }
            .filter { !excluded.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { $0.asOpenAITool() }
    }
}

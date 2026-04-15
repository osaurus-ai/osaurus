//
//  PluginHostAPI.swift
//  osaurus
//
//  Implements the host-side callbacks passed to v2 plugins via osr_host_api.
//  Each plugin gets its own host context with config (Keychain-backed),
//  database (sandboxed SQLite), dispatch, inference, models, and HTTP access.
//

import Foundation

extension Notification.Name {
    static let pluginConfigDidChange = Notification.Name("PluginConfigDidChange")
}

// MARK: - Per-Plugin Host Context

/// Holds per-plugin state needed by host API callbacks.
/// Registered in a global dictionary keyed by plugin ID so that
/// @convention(c) trampolines can look up the right context.
final class PluginHostContext: @unchecked Sendable {

    // MARK: - Context Registry (thread-safe)

    private nonisolated(unsafe) static var contexts: [String: PluginHostContext] = [:]
    private static let contextsLock = NSLock()

    static func getContext(for pluginId: String) -> PluginHostContext? {
        contextsLock.withLock { contexts[pluginId] }
    }

    static func setContext(_ ctx: PluginHostContext, for pluginId: String) {
        contextsLock.withLock { contexts[pluginId] = ctx }
    }

    static func removeContext(for pluginId: String) {
        contextsLock.withLock { _ = contexts.removeValue(forKey: pluginId) }
    }

    static func rekeyContext(from oldId: String, to newId: String) {
        contextsLock.withLock {
            if let ctx = contexts.removeValue(forKey: oldId) {
                contexts[newId] = ctx
            }
        }
    }

    /// Temporary fallback used only during plugin init.
    nonisolated(unsafe) static var currentContext: PluginHostContext?

    // MARK: - Instance Properties

    let pluginId: String
    let database: PluginDatabase

    /// Heap-allocated host API struct whose pointer is handed to the plugin at
    /// init. Must outlive the plugin because it may store the pointer rather
    /// than copying the struct.
    private(set) var hostAPIPtr: UnsafeMutablePointer<osr_host_api>?

    /// Shared URLSession for plugin HTTP requests (thread-safe).
    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config)
    }()

    /// Shared URLSession that suppresses redirects. Singleton to avoid per-request session leaks.
    private static let noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }()

    /// Sliding window timestamps for dispatch rate limiting, keyed by agent ID.
    /// Each agent gets its own 10/min budget so multiple agents sharing a
    /// plugin don't exhaust each other's quota.
    private let rateLimitLock = NSLock()
    private var dispatchTimestamps: [UUID: [Date]] = [:]
    private static let dispatchRateLimit = 10
    private static let dispatchRateWindow: TimeInterval = 60

    // MARK: - Per-Request Agent Context

    /// Resolved agent ID for the current thread. Checks thread-local storage
    /// first (set per-dispatch in ExternalPlugin wrappers), then falls back to
    /// `Agent.defaultId`. This is the primary concurrent-safe mechanism --
    /// each invokeQueue / eventQueue thread gets its own value.
    var resolvedAgentId: UUID {
        Self.activeAgentId() ?? Agent.defaultId
    }

    init(pluginId: String) throws {
        self.pluginId = pluginId
        self.database = PluginDatabase(pluginId: pluginId)
        try database.open()
    }

    deinit {
        hostAPIPtr?.deinitialize(count: 1)
        hostAPIPtr?.deallocate()
        database.close()
    }

    // MARK: - Config Callbacks

    func configGet(key: String) -> String? {
        return ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: resolvedAgentId)
    }

    func configSet(key: String, value: String) {
        ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: resolvedAgentId)
        postConfigChange(key: key, value: value)
    }

    func configDelete(key: String) {
        ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: resolvedAgentId)
        postConfigChange(key: key, value: nil)
    }

    private func postConfigChange(key: String, value: String?) {
        DispatchQueue.main.async { [pluginId] in
            var userInfo: [String: String] = ["pluginId": pluginId, "key": key]
            if let value { userInfo["value"] = value }
            NotificationCenter.default.post(
                name: .pluginConfigDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    }

    // MARK: - Database Callbacks

    func dbExec(sql: String, paramsJSON: String?) -> String {
        return database.exec(sql: sql, paramsJSON: paramsJSON)
    }

    func dbQuery(sql: String, paramsJSON: String?) -> String {
        return database.query(sql: sql, paramsJSON: paramsJSON)
    }

    // MARK: - Dispatch Callbacks

    func dispatch(requestJSON: String) -> (result: String, taskId: UUID?) {
        return Self.blockingAsync { [pluginId] in
            let data = Data(requestJSON.utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let prompt = json["prompt"] as? String
            else {
                return (
                    Self.jsonString(["error": "invalid_request", "message": "Missing required field: prompt"]),
                    UUID?.none
                )
            }

            let modeStr = json["mode"] as? String ?? "work"
            let mode: ChatMode = modeStr == "chat" ? .chat : .work

            var requestId = UUID()
            if let idStr = json["id"] as? String, let parsed = UUID(uuidString: idStr) {
                requestId = parsed
            }

            var agentId: UUID?
            if let address = json["agent_address"] as? String {
                agentId = await MainActor.run { AgentManager.shared.agent(byAddress: address)?.id }
            } else if let idStr = json["agent_id"] as? String {
                agentId = UUID(uuidString: idStr)
            }

            let resolvedAgent = agentId ?? Agent.defaultId

            guard let ctx = PluginHostContext.getContext(for: pluginId),
                ctx.checkDispatchRateLimit(agentId: resolvedAgent)
            else {
                return (
                    Self.jsonString([
                        "error": "rate_limit_exceeded", "message": "Dispatch rate limit (10/min) exceeded",
                    ]),
                    UUID?.none
                )
            }

            let title = json["title"] as? String

            var folderBookmark: Data?
            if let bookmarkStr = json["folder_bookmark"] as? String {
                folderBookmark = Data(base64Encoded: bookmarkStr)
            }

            let request = DispatchRequest(
                id: requestId,
                mode: mode,
                prompt: prompt,
                agentId: resolvedAgent,
                title: title,
                folderBookmark: folderBookmark,
                showToast: true,
                sourcePluginId: pluginId
            )

            await MainActor.run {
                BackgroundTaskManager.shared.holdEventsForDispatch(taskId: requestId)
            }

            let handle = await TaskDispatcher.shared.dispatch(request)
            guard handle != nil else {
                await MainActor.run {
                    BackgroundTaskManager.shared.releaseEventsForDispatch(taskId: requestId)
                }
                return (
                    Self.jsonString([
                        "error": "task_limit_reached", "message": "Maximum concurrent background tasks reached",
                    ]), UUID?.none
                )
            }

            return (Self.jsonString(["id": requestId.uuidString, "status": "running"]), requestId)
        }
    }

    func taskStatus(taskId: String) -> String {
        guard let uuid = UUID(uuidString: taskId) else {
            return Self.jsonString(["error": "invalid_task_id", "message": "Invalid UUID format"])
        }

        return Self.blockingMainActor { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId
            else {
                return Self.jsonString(["error": "not_found", "message": "Task not found"])
            }
            return Self.serializeTaskState(id: uuid, state: state)
        }
    }

    func dispatchCancel(taskId: String) {
        guard let uuid = UUID(uuidString: taskId) else { return }
        Self.blockingMainActor { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId
            else { return }
            BackgroundTaskManager.shared.cancelTask(uuid)
        }
    }

    func dispatchClarify(taskId: String, response: String) {
        guard let uuid = UUID(uuidString: taskId) else { return }
        Self.blockingMainActor { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId
            else { return }
            BackgroundTaskManager.shared.submitClarification(uuid, response: response)
        }
    }

    func listActiveTasks() -> String {
        Self.blockingMainActor { [pluginId] in
            let tasks = BackgroundTaskManager.shared.backgroundTasks.values
                .filter { $0.sourcePluginId == pluginId && $0.status.isActive }
                .map { PluginHostContext.taskStateDict(id: $0.id, state: $0) }
            return Self.jsonString(["tasks": tasks])
        }
    }

    func sendDraft(taskId: String, draftJSON: String) {
        guard let uuid = UUID(uuidString: taskId) else { return }
        Self.blockingMainActor { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId, state.status.isActive
            else { return }
            state.draftText = draftJSON
            BackgroundTaskManager.shared.emitDraftEvent(state, draftJSON: draftJSON)
        }
    }

    func dispatchInterrupt(taskId: String, message: String?) {
        guard let uuid = UUID(uuidString: taskId) else { return }
        Self.blockingMainActor { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId
            else { return }
            BackgroundTaskManager.shared.interruptTask(uuid, message: message)
        }
    }

    func dispatchAddIssue(taskId: String, issueJSON: String) -> String {
        guard let uuid = UUID(uuidString: taskId) else {
            return Self.jsonString(["error": "invalid_task_id", "message": "Invalid UUID format"])
        }

        let data = Data(issueJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = json["title"] as? String
        else {
            return Self.jsonString(["error": "invalid_request", "message": "Missing required field: title"])
        }
        let query = json["description"] as? String ?? title

        return Self.blockingMainActor { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId,
                state.status.isActive, state.mode == .work,
                let session = state.session
            else {
                return Self.jsonString(["error": "not_found", "message": "Active work task not found"])
            }

            Task { await session.addIssueFromPlugin(query: query) }
            return Self.jsonString(["status": "queued", "title": title])
        }
    }

    // MARK: - Inference Callbacks

    private static let toolExecutionTimeout: UInt64 = 120
    private static let defaultMaxIterations = 1
    private static let maxIterationsCap = 30

    // MARK: Inference Types

    private struct AgentContext {
        let agentId: UUID
        let systemPrompt: String
        let model: String?
        let temperature: Float?
        let maxTokens: Int?
        let tools: [Tool]?
        let executionMode: WorkExecutionMode
        var cacheHint: String?
        var staticPrefix: String?

        func prependingSystemContent(_ content: String) -> AgentContext {
            var ctx = self
            ctx = AgentContext(
                agentId: agentId,
                systemPrompt: content + "\n\n" + systemPrompt,
                model: model,
                temperature: temperature,
                maxTokens: maxTokens,
                tools: tools,
                executionMode: executionMode,
                cacheHint: cacheHint,
                staticPrefix: staticPrefix
            )
            return ctx
        }

        func withSystemPrompt(_ newPrompt: String) -> AgentContext {
            AgentContext(
                agentId: agentId,
                systemPrompt: newPrompt,
                model: model,
                temperature: temperature,
                maxTokens: maxTokens,
                tools: tools,
                executionMode: executionMode,
                cacheHint: cacheHint,
                staticPrefix: staticPrefix
            )
        }
    }

    private struct InferenceOptions {
        let maxIterations: Int
        let wantsAgentTools: Bool
        let wantsPreflight: Bool

        init(from json: [String: Any]) {
            let raw = json["max_iterations"] as? Int ?? defaultMaxIterations
            self.maxIterations = max(1, min(raw, maxIterationsCap))
            self.wantsAgentTools = json["tools"] as? Bool == true
            self.wantsPreflight = json["preflight"] as? Bool == true
        }
    }

    private struct EnrichedInference {
        var request: ChatCompletionRequest
        let tools: [Tool]?
    }

    /// Fully prepared inference state ready for the agentic loop.
    private struct PreparedInference {
        let enriched: EnrichedInference
        let options: InferenceOptions
        let engine: ChatEngine
        let budgetManager: ContextBudgetManager?
        let agentId: UUID?
        let executionMode: WorkExecutionMode
        let contextId: String
    }

    // MARK: Request Parsing

    /// Strips extension fields (`agent_address`, `max_iterations`, `"tools": true`)
    /// that would break the Codable decoder, returning both the raw dict and clean Data.
    private static func parseRawRequest(_ requestJSON: String) -> (json: [String: Any], sanitized: Data)? {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var clean = json
        clean.removeValue(forKey: "agent_address")
        clean.removeValue(forKey: "max_iterations")
        clean.removeValue(forKey: "preflight")
        if json["tools"] is Bool { clean.removeValue(forKey: "tools") }

        guard let cleanData = try? JSONSerialization.data(withJSONObject: clean) else { return nil }
        return (json, cleanData)
    }

    /// Shared setup for both `complete` and `completeStream`: resolves agent context,
    /// enriches the request, creates the engine and budget manager.
    private static func prepareInference(
        request: ChatCompletionRequest,
        rawJSON: [String: Any],
        pluginId: String? = nil
    ) async -> PreparedInference {
        let options = InferenceOptions(from: rawJSON)
        let agentCtx = await resolveAgentContext(json: rawJSON)
        let execMode = agentCtx?.executionMode ?? .none
        var enriched = enrichRequest(request, context: agentCtx, options: options)
        if let pid = pluginId {
            let instructions: String? = await MainActor.run {
                if let agentId = agentCtx?.agentId,
                    let agent = AgentManager.shared.agent(for: agentId),
                    let override = agent.pluginInstructions?[pid],
                    !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return override
                }
                return PluginManager.shared.loadedPlugin(for: pid)?.plugin.manifest.instructions
            }
            if let instructions {
                SystemPromptComposer.appendSystemContent(instructions, into: &enriched.request.messages)
            }
        }
        let resolvedAgentId = agentCtx?.agentId ?? Agent.defaultId
        let (agentToolsOff, isManual) = await MainActor.run {
            let mgr = AgentManager.shared
            return (
                mgr.effectiveToolsDisabled(for: resolvedAgentId),
                mgr.effectiveToolSelectionMode(for: resolvedAgentId) == .manual
            )
        }
        if options.wantsPreflight && !agentToolsOff {
            enriched = await applyPreflightSearch(
                to: enriched,
                executionMode: execMode,
                agentId: resolvedAgentId
            )
        }
        if isManual,
            let section = await SkillManager.shared.manualSkillPromptSection(for: resolvedAgentId)
        {
            SystemPromptComposer.appendSystemContent(section, into: &enriched.request.messages)
        }

        let engine = ChatEngine(source: .plugin)
        let budgetMgr = await createBudgetManager(for: enriched, maxIterations: options.maxIterations)
        return PreparedInference(
            enriched: enriched,
            options: options,
            engine: engine,
            budgetManager: budgetMgr,
            agentId: agentCtx?.agentId,
            executionMode: execMode,
            contextId: enriched.request.session_id ?? UUID().uuidString
        )
    }

    // MARK: Agent Context Resolution

    private static func resolveAgentContext(json: [String: Any]) async -> AgentContext? {
        guard let address = json["agent_address"] as? String else { return nil }

        let resolved: (id: UUID, autonomousEnabled: Bool)? = await MainActor.run {
            guard let agent = AgentManager.shared.agent(byAddress: address) else { return nil }
            let enabled = AgentManager.shared.effectiveAutonomousExec(for: agent.id)?.enabled == true
            return (agent.id, enabled)
        }
        guard let resolved else { return nil }
        let agentId = resolved.id

        if resolved.autonomousEnabled {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }

        let execMode = await MainActor.run { ToolRegistry.shared.resolveWorkExecutionMode(folderContext: nil) }
        let composed = await SystemPromptComposer.composeChatContext(agentId: agentId, executionMode: execMode)
        return await MainActor.run {
            let mgr = AgentManager.shared
            return AgentContext(
                agentId: agentId,
                systemPrompt: composed.prompt,
                model: mgr.effectiveModel(for: agentId),
                temperature: mgr.effectiveTemperature(for: agentId),
                maxTokens: mgr.effectiveMaxTokens(for: agentId),
                tools: composed.tools.isEmpty ? nil : composed.tools,
                executionMode: execMode,
                cacheHint: composed.cacheHint,
                staticPrefix: composed.staticPrefix
            )
        }
    }

    // MARK: Request Enrichment

    private static func enrichRequest(
        _ request: ChatCompletionRequest,
        context: AgentContext?,
        options: InferenceOptions
    ) -> EnrichedInference {
        guard let ctx = context else {
            return EnrichedInference(request: request, tools: request.tools)
        }

        var model = request.model
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("default") == .orderedSame,
            let agentModel = ctx.model, !agentModel.isEmpty
        {
            model = agentModel
        }

        var messages = request.messages
        SystemPromptComposer.injectSystemContent(ctx.systemPrompt, into: &messages)

        let effectiveTools: [Tool]?
        if let explicit = request.tools, !explicit.isEmpty {
            effectiveTools = explicit
        } else if options.wantsAgentTools {
            effectiveTools = ctx.tools
        } else {
            effectiveTools = nil
        }

        var enriched = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: request.temperature ?? ctx.temperature,
            max_tokens: request.max_tokens ?? ctx.maxTokens,
            stream: request.stream,
            top_p: request.top_p,
            frequency_penalty: request.frequency_penalty,
            presence_penalty: request.presence_penalty,
            stop: request.stop,
            n: request.n,
            tools: effectiveTools,
            tool_choice: request.tool_choice,
            session_id: request.session_id
        )
        enriched.cache_hint = ctx.cacheHint
        enriched.staticPrefix = ctx.staticPrefix
        return EnrichedInference(request: enriched, tools: effectiveTools)
    }

    private static func iterationRequest(
        from base: ChatCompletionRequest,
        messages: [ChatMessage],
        tools: [Tool]?
    ) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: base.model,
            messages: messages,
            temperature: base.temperature,
            max_tokens: base.max_tokens,
            stream: nil,
            top_p: base.top_p,
            frequency_penalty: base.frequency_penalty,
            presence_penalty: base.presence_penalty,
            stop: base.stop,
            n: base.n,
            tools: tools,
            tool_choice: base.tool_choice,
            session_id: base.session_id
        )
    }

    // MARK: Preflight Capability Search

    /// Session-scoped preflight cache. Once a preflight result is computed for a session,
    /// it is reused for all subsequent turns in that session. This keeps the tool list and
    /// system-prompt snippet stable across turns, which is required for KV-cache reuse:
    /// any change to the tool list causes prompt divergence before token ~1000 and forces
    /// a full re-prefill even when the conversation content is otherwise identical.
    private nonisolated(unsafe) static var preflightCache: [String: PreflightResult] = [:]
    private static let preflightCacheLock = NSLock()

    /// Call when a session ends (e.g. chat window closes) to release the memoized result.
    static func invalidatePreflightCache(sessionId: String) {
        _ = preflightCacheLock.withLock { preflightCache.removeValue(forKey: sessionId) }
    }

    private static func extractPreflightQuery(from messages: [ChatMessage]) -> String {
        messages.last(where: { $0.role == "user" })?.content ?? ""
    }

    private static func applyPreflightSearch(
        to inference: EnrichedInference,
        executionMode: WorkExecutionMode = .none,
        agentId: UUID = Agent.defaultId
    ) async -> EnrichedInference {
        let toolMode = await MainActor.run {
            AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        }
        let isManualTools = toolMode == .manual

        // Manual mode: merge user-selected tools, skip RAG entirely.
        // Also strip any capability tools that may already be on the inference
        // from resolveAgentContext, since manual mode disables dynamic discovery.
        if isManualTools {
            let (builtInTools, manualSpecs, capNames) = await MainActor.run {
                let base = ToolRegistry.shared.alwaysLoadedSpecs(
                    mode: executionMode,
                    excludeCapabilityTools: true
                )
                let names = AgentManager.shared.effectiveManualToolNames(for: agentId) ?? []
                let manual = ToolRegistry.shared.specs(forTools: names)
                return (base, manual, ToolRegistry.capabilityToolNames)
            }
            let filteredExisting = (inference.tools ?? []).filter { !capNames.contains($0.function.name) }
            let cleanInference = EnrichedInference(
                request: inference.request,
                tools: filteredExisting.isEmpty ? nil : filteredExisting
            )
            let empty = PreflightResult(toolSpecs: manualSpecs, contextSnippet: "", items: [])
            return applyPreflightResult(empty, to: cleanInference, builtInTools: builtInTools)
        }

        // Auto mode: RAG-based preflight
        if let sid = inference.request.session_id {
            let cached = preflightCacheLock.withLock { preflightCache[sid] }
            if let cached {
                let builtInTools = await MainActor.run { ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode) }
                return applyPreflightResult(cached, to: inference, builtInTools: builtInTools)
            }
        }

        let query = extractPreflightQuery(from: inference.request.messages)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return inference }

        let (preflightMode, builtInTools) = await MainActor.run {
            let mode = ChatConfigurationStore.load().preflightSearchMode ?? .balanced
            let tools = ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
            return (mode, tools)
        }

        let preflight = await PreflightCapabilitySearch.search(query: query, mode: preflightMode, agentId: agentId)

        if let sid = inference.request.session_id {
            preflightCacheLock.withLock { preflightCache[sid] = preflight }
        }

        return applyPreflightResult(preflight, to: inference, builtInTools: builtInTools)
    }

    /// Merges a cached `PreflightResult` into an inference request without re-running the search.
    private static func applyPreflightResult(
        _ preflight: PreflightResult,
        to inference: EnrichedInference,
        builtInTools: [Tool]
    ) -> EnrichedInference {
        var seen = Set((inference.tools ?? []).map { $0.function.name })
        var tools = inference.tools ?? []
        for spec in builtInTools + preflight.toolSpecs where !seen.contains(spec.function.name) {
            tools.append(spec)
            seen.insert(spec.function.name)
        }

        var messages = inference.request.messages
        if !preflight.contextSnippet.isEmpty {
            SystemPromptComposer.appendSystemContent(preflight.contextSnippet, into: &messages)
        }

        let effectiveTools = tools.isEmpty ? nil : tools
        let request = ChatCompletionRequest(
            model: inference.request.model,
            messages: messages,
            temperature: inference.request.temperature,
            max_tokens: inference.request.max_tokens,
            stream: inference.request.stream,
            top_p: inference.request.top_p,
            frequency_penalty: inference.request.frequency_penalty,
            presence_penalty: inference.request.presence_penalty,
            stop: inference.request.stop,
            n: inference.request.n,
            tools: effectiveTools,
            tool_choice: inference.request.tool_choice,
            session_id: inference.request.session_id
        )
        return EnrichedInference(request: request, tools: effectiveTools)
    }

    // MARK: Context Budget

    private static func createBudgetManager(
        for inf: EnrichedInference,
        maxIterations: Int
    ) async -> ContextBudgetManager? {
        guard maxIterations > 1 else { return nil }

        let contextLength: Int
        if let info = ModelInfo.load(modelId: inf.request.model), let ctx = info.model.contextLength {
            contextLength = ctx
        } else {
            contextLength = await MainActor.run { ChatConfigurationStore.load().contextLength ?? 128_000 }
        }
        let toolTokens = await MainActor.run {
            ToolRegistry.shared.totalEstimatedTokens()
        }
        let sysChars = inf.request.messages.first(where: { $0.role == "system" })?.content?.count ?? 0

        var mgr = ContextBudgetManager(contextLength: contextLength)
        mgr.reserveByCharCount(.systemPrompt, characters: sysChars)
        mgr.reserve(.tools, tokens: toolTokens)
        mgr.reserve(.response, tokens: inf.request.max_tokens ?? 4096)
        return mgr
    }

    // MARK: Tool Execution

    private typealias PostProcessResult = (result: String, artifactDict: [String: Any]?)

    /// Post-processes a tool result after execution, handling special tools
    /// like `share_artifact` (copy files, notify handlers, collect artifact metadata)
    /// and `capabilities_load` (hot-load newly discovered tools into the active set).
    private static func postProcessToolResult(
        toolName: String,
        result: String,
        prep: PreparedInference,
        toolSpecs: inout [Tool]?
    ) async -> PostProcessResult {
        switch toolName {
        case "share_artifact":
            return await processShareArtifact(result: result, prep: prep)

        case "capabilities_load":
            let newTools = await CapabilityLoadBuffer.shared.drain()
            let existing = Set((toolSpecs ?? []).map { $0.function.name })
            let additions = newTools.filter { !existing.contains($0.function.name) }
            if !additions.isEmpty {
                toolSpecs = (toolSpecs ?? []) + additions
            }
            return (result, nil)

        default:
            return (result, nil)
        }
    }

    /// Processes a `share_artifact` tool result: copies the file to the artifacts
    /// directory, notifies artifact handler plugins, and returns metadata for the
    /// inference response so the calling plugin can act on it immediately.
    private static func processShareArtifact(
        result: String,
        prep: PreparedInference
    ) async -> PostProcessResult {
        let agentName: String? = await MainActor.run {
            prep.agentId.map { SandboxAgentProvisioner.linuxName(for: $0.uuidString) }
        }

        if let processed = SharedArtifact.processToolResult(
            result,
            contextId: prep.contextId,
            contextType: .chat,
            executionMode: prep.executionMode,
            sandboxAgentName: agentName
        ) {
            NSLog("[PluginHostAPI] share_artifact processed: %@", processed.artifact.filename)
            await PluginManager.shared.notifyArtifactHandlers(artifact: processed.artifact)
            return (processed.enrichedToolResult, serializeArtifactDict(processed.artifact))
        }

        NSLog(
            "[PluginHostAPI] share_artifact processToolResult returned nil (mode=%@, agent=%@, ctx=%@)",
            String(describing: prep.executionMode),
            agentName ?? "nil",
            prep.contextId
        )

        // Fallback: notify handlers with metadata only so plugins that don't need
        // the host file (e.g. Telegram just needs the filename) can still act.
        if let fallback = SharedArtifact.fromToolResultFallback(
            result,
            contextId: prep.contextId,
            contextType: .chat
        ) {
            NSLog("[PluginHostAPI] share_artifact fallback artifact: %@", fallback.filename)
            await PluginManager.shared.notifyArtifactHandlers(artifact: fallback)
            return (result, serializeArtifactDict(fallback))
        }

        return (result, nil)
    }

    private static func executeToolCall(
        name: String,
        argumentsJSON: String,
        agentId: UUID? = nil,
        executionMode: WorkExecutionMode = .none
    ) async -> String {
        if executionMode.usesSandboxTools, let agentId {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    return try await WorkExecutionContext.$currentAgentId.withValue(agentId) {
                        try await ToolRegistry.shared.execute(
                            name: name,
                            argumentsJSON: argumentsJSON
                        )
                    }
                } catch {
                    return "[REJECTED] \(error.localizedDescription)"
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: toolExecutionTimeout * 1_000_000_000)
                return nil
            }
            guard let first = await group.next() else {
                return "[TIMEOUT] Tool '\(name)' did not complete within \(toolExecutionTimeout)s."
            }
            group.cancelAll()
            return first ?? "[TIMEOUT] Tool '\(name)' did not complete within \(toolExecutionTimeout)s."
        }
    }

    // MARK: complete (non-streaming)

    func complete(requestJSON: String) -> String {
        let pid = self.pluginId
        return Self.blockingAsync {
            guard let (rawJSON, sanitized) = Self.parseRawRequest(requestJSON),
                let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: sanitized)
            else {
                return Self.jsonString([
                    "error": "invalid_request", "message": "Failed to parse chat completion request",
                ])
            }

            let prep = await Self.prepareInference(
                request: request,
                rawJSON: rawJSON,
                pluginId: pid
            )
            var messages = prep.enriched.request.messages
            var toolCallsExecuted: [[String: String]] = []
            var sharedArtifacts: [[String: Any]] = []
            var toolSpecs = prep.enriched.tools

            for iteration in 1 ... prep.options.maxIterations {
                let effective = prep.budgetManager?.trimMessages(messages) ?? messages
                let iterReq = Self.iterationRequest(
                    from: prep.enriched.request,
                    messages: effective,
                    tools: toolSpecs
                )

                do {
                    let response = try await prep.engine.completeChat(request: iterReq)
                    guard let choice = response.choices.first else {
                        return Self.jsonString(["error": "inference_error", "message": "No choices returned"])
                    }

                    if let calls = choice.message.tool_calls, !calls.isEmpty,
                        choice.finish_reason == "tool_calls",
                        iteration < prep.options.maxIterations
                    {
                        messages.append(choice.message)
                        for tc in calls {
                            var result = await Self.executeToolCall(
                                name: tc.function.name,
                                argumentsJSON: tc.function.arguments,
                                agentId: prep.agentId,
                                executionMode: prep.executionMode
                            )
                            let postProcessed = await Self.postProcessToolResult(
                                toolName: tc.function.name,
                                result: result,
                                prep: prep,
                                toolSpecs: &toolSpecs
                            )
                            result = postProcessed.result
                            if let dict = postProcessed.artifactDict { sharedArtifacts.append(dict) }
                            messages.append(
                                ChatMessage(
                                    role: "tool",
                                    content: result,
                                    tool_calls: nil,
                                    tool_call_id: tc.id
                                )
                            )
                            toolCallsExecuted.append(["name": tc.function.name, "tool_call_id": tc.id])
                        }
                        continue
                    }

                    guard let encoded = try? JSONEncoder().encode(response),
                        var json = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
                    else {
                        return Self.jsonString([
                            "error": "serialization_error", "message": "Failed to serialize response",
                        ])
                    }
                    if !toolCallsExecuted.isEmpty { json["tool_calls_executed"] = toolCallsExecuted }
                    if !sharedArtifacts.isEmpty { json["shared_artifacts"] = sharedArtifacts }
                    return Self.jsonString(json)

                } catch {
                    return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
                }
            }

            return Self.jsonString([
                "error": "max_iterations_reached",
                "message": "Reached max iterations (\(prep.options.maxIterations)) without a final response",
            ])
        }
    }

    // MARK: complete_stream (streaming)

    func completeStream(
        requestJSON: String,
        onChunk: osr_on_chunk_t?,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        let pid = self.pluginId
        nonisolated(unsafe) let userData = userData
        return Self.blockingAsync {
            guard let (rawJSON, sanitized) = Self.parseRawRequest(requestJSON),
                let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: sanitized)
            else {
                return Self.jsonString([
                    "error": "invalid_request", "message": "Failed to parse chat completion request",
                ])
            }

            let prep = await Self.prepareInference(
                request: request,
                rawJSON: rawJSON,
                pluginId: pid
            )
            let cid = "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
            var messages = prep.enriched.request.messages
            var lastContent = ""
            var toolCallsExecuted: [[String: String]] = []
            var sharedArtifacts: [[String: Any]] = []
            var toolSpecs = prep.enriched.tools

            let emit: ([String: Any]) -> Void = { payload in
                Self.emitChunk(payload, callback: onChunk, userData: userData)
            }

            for iteration in 1 ... prep.options.maxIterations {
                let effective = prep.budgetManager?.trimMessages(messages) ?? messages
                let iterReq = Self.iterationRequest(
                    from: prep.enriched.request,
                    messages: effective,
                    tools: toolSpecs
                )

                do {
                    let stream = try await prep.engine.streamChat(request: iterReq)
                    var iterContent = ""

                    for try await delta in stream {
                        if StreamingToolHint.isSentinel(delta) { continue }
                        iterContent += delta
                        lastContent += delta
                        emit(Self.chunkPayload(id: cid, delta: ["content": delta]))
                    }

                    if !iterContent.isEmpty {
                        messages.append(ChatMessage(role: "assistant", content: iterContent))
                    }
                    emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "stop"))
                    return Self.buildStreamResult(
                        id: cid,
                        model: prep.enriched.request.model,
                        content: lastContent,
                        toolCallsExecuted: toolCallsExecuted,
                        sharedArtifacts: sharedArtifacts
                    )

                } catch let inv as ServiceToolInvocation {
                    guard iteration < prep.options.maxIterations else {
                        emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "stop"))
                        break
                    }

                    let callId =
                        inv.toolCallId
                        ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

                    let tcDelta: [String: Any] = [
                        "tool_calls": [
                            ["id": callId, "function": ["name": inv.toolName, "arguments": inv.jsonArguments]]
                        ]
                    ]
                    emit(Self.chunkPayload(id: cid, delta: tcDelta, finishReason: "tool_calls"))

                    var result = await Self.executeToolCall(
                        name: inv.toolName,
                        argumentsJSON: inv.jsonArguments,
                        agentId: prep.agentId,
                        executionMode: prep.executionMode
                    )
                    let postProcessed = await Self.postProcessToolResult(
                        toolName: inv.toolName,
                        result: result,
                        prep: prep,
                        toolSpecs: &toolSpecs
                    )
                    result = postProcessed.result
                    if let dict = postProcessed.artifactDict { sharedArtifacts.append(dict) }

                    emit(
                        Self.chunkPayload(
                            id: cid,
                            delta: [
                                "role": "tool", "tool_call_id": callId, "content": result,
                            ]
                        )
                    )

                    toolCallsExecuted.append(["name": inv.toolName, "tool_call_id": callId])

                    let toolCall = ToolCall(
                        id: callId,
                        type: "function",
                        function: ToolCallFunction(name: inv.toolName, arguments: inv.jsonArguments),
                        geminiThoughtSignature: inv.geminiThoughtSignature
                    )
                    messages.append(
                        ChatMessage(
                            role: "assistant",
                            content: lastContent.isEmpty ? nil : lastContent,
                            tool_calls: [toolCall],
                            tool_call_id: nil
                        )
                    )
                    messages.append(
                        ChatMessage(
                            role: "tool",
                            content: result,
                            tool_calls: nil,
                            tool_call_id: callId
                        )
                    )
                    lastContent = ""
                    continue

                } catch {
                    return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
                }
            }

            return Self.buildStreamResult(
                id: cid,
                model: prep.enriched.request.model,
                content: lastContent,
                toolCallsExecuted: toolCallsExecuted,
                sharedArtifacts: sharedArtifacts
            )
        }
    }

    // MARK: Inference Helpers

    private static func buildStreamResult(
        id: String,
        model: String,
        content: String,
        toolCallsExecuted: [[String: String]],
        sharedArtifacts: [[String: Any]] = []
    ) -> String {
        var result: [String: Any] = [
            "id": id, "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
        ]
        if !toolCallsExecuted.isEmpty { result["tool_calls_executed"] = toolCallsExecuted }
        if !sharedArtifacts.isEmpty { result["shared_artifacts"] = sharedArtifacts }
        return jsonString(result)
    }

    private static func chunkPayload(
        id: String,
        delta: [String: Any],
        finishReason: String? = nil
    ) -> [String: Any] {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let reason = finishReason { choice["finish_reason"] = reason }
        return ["id": id, "choices": [choice]]
    }

    private static func emitChunk(
        _ payload: [String: Any],
        callback: osr_on_chunk_t?,
        userData: UnsafeMutableRawPointer?
    ) {
        guard let callback,
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let str = String(data: data, encoding: .utf8)
        else { return }
        str.withCString { callback($0, userData) }
    }

    func embed(requestJSON: String) -> String {
        Self.blockingAsync {
            let data = Data(requestJSON.utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Self.jsonString(["error": "invalid_request", "message": "Failed to parse embedding request"])
            }

            var texts: [String] = []
            if let single = json["input"] as? String {
                texts = [single]
            } else if let batch = json["input"] as? [String] {
                texts = batch
            } else {
                return Self.jsonString(["error": "invalid_request", "message": "Missing or invalid 'input' field"])
            }

            do {
                let vectors = try await EmbeddingService.shared.embed(texts: texts)
                var embeddings: [[String: Any]] = []
                for (i, vec) in vectors.enumerated() {
                    embeddings.append([
                        "index": i,
                        "embedding": vec,
                        "dimensions": vec.count,
                    ])
                }
                let tokenEstimate = texts.reduce(0) { $0 + max(1, $1.count / 4) }
                let response: [String: Any] = [
                    "model": json["model"] as? String ?? EmbeddingService.modelName,
                    "data": embeddings,
                    "usage": ["prompt_tokens": tokenEstimate, "total_tokens": tokenEstimate],
                ]
                return Self.jsonString(response)
            } catch {
                return Self.jsonString(["error": "embedding_error", "message": error.localizedDescription])
            }
        }
    }

    // MARK: - Models Callback

    func listModels() -> String {
        Self.blockingAsync {
            var models: [[String: Any]] = []

            // Apple Foundation Model
            if FoundationModelService.isDefaultModelAvailable() {
                models.append([
                    "id": "foundation",
                    "name": "Apple Foundation Model",
                    "provider": "apple",
                    "type": "chat",
                    "capabilities": ["chat"],
                ])
            }

            // Local MLX models
            for name in MLXService.getAvailableModels() {
                models.append([
                    "id": name,
                    "name": name,
                    "provider": "local",
                    "type": "chat",
                    "capabilities": ["chat", "tool_calling"],
                ])
            }

            // Local embedding model
            models.append([
                "id": EmbeddingService.modelName,
                "name": "Potion Base 4M",
                "provider": "local",
                "type": "embedding",
                "dimensions": 768,
                "capabilities": ["embedding"],
            ])

            // Remote provider models
            let remoteModels = await MainActor.run {
                RemoteProviderManager.shared.getOpenAIModels()
            }
            for m in remoteModels {
                models.append([
                    "id": m.id,
                    "name": m.id,
                    "provider": m.owned_by,
                    "type": "chat",
                    "capabilities": ["chat", "tool_calling"],
                ])
            }

            return Self.jsonString(["models": models])
        }
    }

    // MARK: - HTTP Client Callback

    func httpRequest(requestJSON: String) -> String {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = json["method"] as? String,
            let urlStr = json["url"] as? String,
            let url = URL(string: urlStr)
        else {
            return Self.jsonString(["error": "invalid_request", "message": "Missing required fields: method, url"])
        }

        if let ssrfError = Self.checkSSRF(url: url) {
            return Self.jsonString(["error": "ssrf_blocked", "message": ssrfError])
        }

        let timeoutMs = json["timeout_ms"] as? Int ?? 30000
        let clampedTimeout = min(timeoutMs, 300000)
        let followRedirects = json["follow_redirects"] as? Bool ?? true

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = TimeInterval(clampedTimeout) / 1000.0

        if let headers = json["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let body = json["body"] as? String {
            let encoding = json["body_encoding"] as? String ?? "utf8"
            if encoding == "base64" {
                request.httpBody = Data(base64Encoded: body)
            } else {
                request.httpBody = Data(body.utf8)
            }

            if let bodyData = request.httpBody, bodyData.count > 50_000_000 {
                return Self.jsonString(["error": "request_too_large", "message": "Request body exceeds 50MB limit"])
            }
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let suffix = "Osaurus/\(appVersion) Plugin/\(pluginId)"
        let existing = request.value(forHTTPHeaderField: "User-Agent")
        request.setValue(existing.map { "\($0) \(suffix)" } ?? suffix, forHTTPHeaderField: "User-Agent")

        let session = followRedirects ? Self.httpSession : Self.noRedirectSession
        let finalRequest = request

        return Self.blockingAsync {
            let startTime = Date()
            do {
                let (responseData, urlResponse) = try await session.data(for: finalRequest)
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

                guard let httpResponse = urlResponse as? HTTPURLResponse else {
                    return Self.jsonString([
                        "error": "invalid_response", "message": "Non-HTTP response", "elapsed_ms": elapsed,
                    ])
                }

                if responseData.count > 50_000_000 {
                    return Self.jsonString([
                        "error": "response_too_large", "message": "Response body exceeds 50MB limit",
                        "elapsed_ms": elapsed,
                    ])
                }

                var responseHeaders: [String: String] = [:]
                for (key, value) in httpResponse.allHeaderFields {
                    responseHeaders[String(describing: key).lowercased()] = String(describing: value)
                }

                let bodyStr: String
                let bodyEncoding: String
                if let str = String(data: responseData, encoding: .utf8) {
                    bodyStr = str
                    bodyEncoding = "utf8"
                } else {
                    bodyStr = responseData.base64EncodedString()
                    bodyEncoding = "base64"
                }

                let response: [String: Any] = [
                    "status": httpResponse.statusCode,
                    "headers": responseHeaders,
                    "body": bodyStr,
                    "body_encoding": bodyEncoding,
                    "elapsed_ms": elapsed,
                ]
                return Self.jsonString(response)
            } catch let error as URLError {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                let errorType: String
                switch error.code {
                case .timedOut: errorType = "connection_timeout"
                case .cannotConnectToHost: errorType = "connection_refused"
                case .cannotFindHost: errorType = "dns_failure"
                case .serverCertificateUntrusted, .secureConnectionFailed: errorType = "tls_error"
                case .httpTooManyRedirects: errorType = "too_many_redirects"
                default: errorType = "network_error"
                }
                return Self.jsonString([
                    "error": errorType, "message": error.localizedDescription, "elapsed_ms": elapsed,
                ])
            } catch {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                return Self.jsonString([
                    "error": "network_error", "message": error.localizedDescription, "elapsed_ms": elapsed,
                ])
            }
        }
    }

    // MARK: - File Read Callback

    private static let fileReadMaxBytes = 50_000_000

    func fileRead(requestJSON: String) -> String {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = json["path"] as? String
        else {
            return Self.jsonString(["error": "invalid_request", "message": "Missing required field: path"])
        }

        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let allowedPrefix = OsaurusPaths.artifactsDir().standardizedFileURL.path + "/"

        guard fileURL.path.hasPrefix(allowedPrefix) else {
            return Self.jsonString(["error": "access_denied", "message": "File read restricted to artifact paths"])
        }

        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? Int
        else {
            return Self.jsonString(["error": "not_found", "message": "File does not exist"])
        }

        guard size <= Self.fileReadMaxBytes else {
            return Self.jsonString(["error": "file_too_large", "message": "File exceeds 50MB limit"])
        }

        guard let fileData = try? Data(contentsOf: fileURL) else {
            return Self.jsonString(["error": "read_error", "message": "Failed to read file"])
        }

        let mimeType = SharedArtifact.mimeType(from: fileURL.lastPathComponent)
        return Self.jsonString([
            "data": fileData.base64EncodedString(),
            "size": size,
            "mime_type": mimeType,
        ])
    }

    // MARK: - Build osr_host_api Struct

    /// Builds a heap-allocated C-compatible host API struct with trampoline
    /// function pointers. The returned pointer is stable for the lifetime of
    /// this context, so plugins may store it directly.
    func buildHostAPI() -> UnsafeMutablePointer<osr_host_api> {
        let ptr = UnsafeMutablePointer<osr_host_api>.allocate(capacity: 1)
        ptr.initialize(
            to: osr_host_api(
                version: 2,
                config_get: PluginHostContext.trampolineConfigGet,
                config_set: PluginHostContext.trampolineConfigSet,
                config_delete: PluginHostContext.trampolineConfigDelete,
                db_exec: PluginHostContext.trampolineDbExec,
                db_query: PluginHostContext.trampolineDbQuery,
                log: PluginHostContext.trampolineLog,
                dispatch: PluginHostContext.trampolineDispatch,
                task_status: PluginHostContext.trampolineTaskStatus,
                dispatch_cancel: PluginHostContext.trampolineDispatchCancel,
                dispatch_clarify: PluginHostContext.trampolineDispatchClarify,
                complete: PluginHostContext.trampolineComplete,
                complete_stream: PluginHostContext.trampolineCompleteStream,
                embed: PluginHostContext.trampolineEmbed,
                list_models: PluginHostContext.trampolineListModels,
                http_request: PluginHostContext.trampolineHttpRequest,
                file_read: PluginHostContext.trampolineFileRead,
                list_active_tasks: PluginHostContext.trampolineListActiveTasks,
                send_draft: PluginHostContext.trampolineSendDraft,
                dispatch_interrupt: PluginHostContext.trampolineDispatchInterrupt,
                dispatch_add_issue: PluginHostContext.trampolineDispatchAddIssue
            )
        )
        hostAPIPtr = ptr
        return ptr
    }

    /// Removes this context from the global registry and closes the database.
    func teardown() {
        PluginHostContext.removeContext(for: pluginId)
        database.close()
    }
}

// MARK: - Rate Limiting

extension PluginHostContext {
    /// Returns true if the dispatch is allowed under the per-agent rate limit.
    func checkDispatchRateLimit(agentId: UUID) -> Bool {
        rateLimitLock.withLock {
            let now = Date()
            let cutoff = now.addingTimeInterval(-Self.dispatchRateWindow)
            var timestamps = dispatchTimestamps[agentId, default: []]
            timestamps.removeAll { $0 < cutoff }
            guard timestamps.count < Self.dispatchRateLimit else {
                dispatchTimestamps[agentId] = timestamps
                return false
            }
            timestamps.append(now)
            dispatchTimestamps[agentId] = timestamps
            return true
        }
    }
}

// MARK: - SSRF Protection

extension PluginHostContext {
    /// Returns an error message if the URL targets a private/loopback address, nil if safe.
    static func checkSSRF(url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return "Missing host" }

        if host == "localhost" || host == "::1" {
            return ssrfBlocked("localhost")
        }

        if host.hasPrefix("fe80:") || host.hasPrefix("[fe80:") {
            return ssrfBlocked("link-local IPv6")
        }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        let (a, b) = (octets[0], octets[1])

        let isPrivate =
            a == 127 || a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || a == 0
            || (a == 169 && b == 254)

        return isPrivate ? ssrfBlocked(host) : nil
    }

    private static func ssrfBlocked(_ target: String) -> String {
        "Requests to \(target) are blocked (SSRF protection)"
    }
}

// MARK: - No-Redirect URLSession Delegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Task State Serialization

extension PluginHostContext {
    @MainActor
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    @MainActor
    static func taskStateDict(id: UUID, state: BackgroundTaskState) -> [String: Any] {
        var result: [String: Any] = [
            "id": id.uuidString,
            "title": state.taskTitle,
            "mode": state.mode == .work ? "work" : "chat",
        ]

        if let draft = state.draftText, let parsed = parseJSON(draft) { result["draft"] = parsed }

        switch state.status {
        case .running:
            result["status"] = "running"
            result["progress"] = state.progress
            if let step = state.currentStep { result["current_step"] = step }

            if let output = state.session?.streamingContent, !output.isEmpty {
                result["output"] = output
            }

            let activity: [[String: Any]] = state.activityFeed.suffix(20).map { item in
                var entry: [String: Any] = [
                    "kind": Self.activityKindString(item.kind),
                    "title": item.title,
                    "timestamp": isoFormatter.string(from: item.date),
                ]
                if let detail = item.detail { entry["detail"] = detail }
                return entry
            }
            if !activity.isEmpty { result["activity"] = activity }

        case .awaitingClarification:
            result["status"] = "awaiting_clarification"
            result["progress"] = state.progress
            result["current_step"] = "Needs input"
            if let clarification = state.pendingClarification {
                var clarObj: [String: Any] = ["question": clarification.question]
                if let options = clarification.options, !options.isEmpty {
                    clarObj["options"] = options
                }
                result["clarification"] = clarObj
            }

        case .completed(let success, let summary):
            result["status"] = success ? "completed" : "failed"
            result["success"] = success
            result["summary"] = summary
            if let execCtx = state.executionContext {
                result["session_id"] = execCtx.id.uuidString
            }

        case .cancelled:
            result["status"] = "cancelled"
        }

        return result
    }

    @MainActor
    static func serializeTaskState(id: UUID, state: BackgroundTaskState) -> String {
        jsonString(taskStateDict(id: id, state: state))
    }

    private static func activityKindString(_ kind: BackgroundTaskActivityItem.Kind) -> String {
        switch kind {
        case .tool: "tool"
        case .toolCall: "tool_call"
        case .toolResult: "tool_result"
        case .thinking: "thinking"
        case .writing: "writing"
        case .info: "info"
        case .progress: "progress"
        case .warning: "warning"
        case .success: "success"
        case .error: "error"
        }
    }

    // MARK: - Task Event Serialization

    @MainActor
    static func serializeStartedEvent(state: BackgroundTaskState) -> String {
        jsonString([
            "status": "running",
            "mode": state.mode == .work ? "work" : "chat",
            "title": state.taskTitle,
        ])
    }

    @MainActor
    static func serializeActivityEvent(
        kind: BackgroundTaskActivityItem.Kind,
        title: String,
        detail: String?,
        metadata: [String: Any]? = nil
    ) -> String {
        var dict: [String: Any] = [
            "kind": activityKindString(kind),
            "title": title,
            "timestamp": isoFormatter.string(from: Date()),
        ]
        if let detail { dict["detail"] = detail }
        if let metadata, !metadata.isEmpty { dict["metadata"] = metadata }
        return jsonString(dict)
    }

    @MainActor
    static func serializeProgressEvent(progress: Double, currentStep: String?, taskTitle: String) -> String {
        var dict: [String: Any] = ["progress": progress, "title": taskTitle]
        if let step = currentStep { dict["current_step"] = step }
        return jsonString(dict)
    }

    @MainActor
    static func serializeClarificationEvent(clarification: ClarificationRequest) -> String {
        var dict: [String: Any] = ["question": clarification.question]
        if let options = clarification.options, !options.isEmpty {
            dict["options"] = options
        }
        if let context = clarification.context, !context.isEmpty {
            dict["context"] = context
        }
        return jsonString(dict)
    }

    @MainActor
    static func serializeCompletedEvent(
        success: Bool,
        summary: String,
        sessionId: UUID?,
        taskTitle: String,
        artifacts: [SharedArtifact] = [],
        outputText: String? = nil
    ) -> String {
        var dict: [String: Any] = ["success": success, "summary": summary, "title": taskTitle]
        if let sid = sessionId { dict["session_id"] = sid.uuidString }
        if !artifacts.isEmpty {
            dict["artifacts"] = artifacts.map { serializeArtifactDict($0) }
        }
        if let output = outputText, !output.isEmpty {
            dict["output"] = output
        }
        return jsonString(dict)
    }

    static func serializeArtifactEvent(artifact: SharedArtifact) -> String {
        return jsonString(serializeArtifactDict(artifact))
    }

    private static func serializeArtifactDict(_ artifact: SharedArtifact) -> [String: Any] {
        var dict: [String: Any] = [
            "filename": artifact.filename,
            "mime_type": artifact.mimeType,
            "size": artifact.fileSize,
            "host_path": artifact.hostPath,
            "is_directory": artifact.isDirectory,
        ]
        if let desc = artifact.description { dict["description"] = desc }
        return dict
    }

    static func serializeCancelledEvent(taskTitle: String) -> String {
        jsonString(["title": taskTitle])
    }

    static func serializeOutputEvent(text: String, taskTitle: String) -> String {
        jsonString(["text": text, "title": taskTitle])
    }

    static func serializeDraftEvent(draftJSON: String, taskTitle: String) -> String {
        var dict: [String: Any] = ["title": taskTitle]
        if let draft = parseJSON(draftJSON) { dict["draft"] = draft }
        return jsonString(dict)
    }
}

// MARK: - Async Bridging Helpers

/// Thread-safe box for passing a result out of a Task closure in Swift 6 strict concurrency.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

extension PluginHostContext {
    /// Block the current (non-main) thread while running async work.
    /// Used by C trampolines that must return synchronously.
    static func blockingAsync<T>(_ work: @escaping @Sendable () async -> T) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await work()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    /// Block the current (non-main) thread while running @MainActor work.
    @discardableResult
    static func blockingMainActor<T>(_ work: @MainActor @escaping @Sendable () -> T) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { @MainActor in
            box.value = work()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    /// Serialize a dictionary to a JSON string. Falls back to "{}" on encoding failure.
    static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse a JSON string back into a dictionary.
    static func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

// MARK: - C Trampoline Functions

/// These are @convention(c) functions that look up the active PluginHostContext
/// via thread-local storage (primary), a best-effort global fallback, or
/// `currentContext` (during init).
///
/// Context resolution order in `activeContext()`:
/// 1. Thread-local storage — set per-thread around each plugin call. This is
///    the primary and fully concurrent-safe mechanism.
/// 2. `lastDispatchedPluginId` — best-effort global fallback for background
///    threads that plugins spawn (e.g. DispatchQueue.global().async). Because
///    invoke queues are per-plugin and concurrent, this value is racy when
///    multiple plugins or handlers run simultaneously. It exists only as a
///    convenience for simple single-plugin setups; plugins that spawn their
///    own threads should not rely on it.
/// 3. `currentContext` — temporary fallback used only during plugin init.
extension PluginHostContext {
    /// Thread-local storage for the active plugin ID during C callback dispatch
    private static let tlsKey: String = "ai.osaurus.plugin.active"

    /// Thread-local storage for the active agent ID during C callback dispatch.
    /// Set per-thread around each plugin call so concurrent requests for
    /// different agents on the same invokeQueue resolve the correct agent.
    private static let agentTlsKey: String = "ai.osaurus.plugin.agent"

    /// Best-effort fallback for plugin-spawned background threads that don't
    /// have TLS set. Protected by `fallbackLock` to avoid data races under
    /// concurrent execution. TLS (option 1) is the authoritative mechanism.
    private static let fallbackLock = NSLock()
    private nonisolated(unsafe) static var _lastDispatchedPluginId: String?

    private static var lastDispatchedPluginId: String? {
        get { fallbackLock.withLock { _lastDispatchedPluginId } }
        set { fallbackLock.withLock { _lastDispatchedPluginId = newValue } }
    }

    static func setActivePlugin(_ pluginId: String) {
        Thread.current.threadDictionary[tlsKey] = pluginId
        lastDispatchedPluginId = pluginId
    }

    static func clearActivePlugin() {
        Thread.current.threadDictionary.removeObject(forKey: tlsKey)
    }

    static func setActiveAgent(_ agentId: UUID) {
        Thread.current.threadDictionary[agentTlsKey] = agentId
    }

    static func clearActiveAgent() {
        Thread.current.threadDictionary.removeObject(forKey: agentTlsKey)
    }

    static func activeAgentId() -> UUID? {
        Thread.current.threadDictionary[agentTlsKey] as? UUID
    }

    private static func activeContext() -> PluginHostContext? {
        if let pluginId = Thread.current.threadDictionary[tlsKey] as? String {
            return getContext(for: pluginId)
        }
        if let pluginId = lastDispatchedPluginId {
            return getContext(for: pluginId)
        }
        return currentContext
    }

    private static func makeCString(_ str: String) -> UnsafePointer<CChar>? {
        let cStr = strdup(str)
        return UnsafePointer(cStr)
    }

    // MARK: - Insights Logging Helpers

    private static func logPluginCall(
        pluginId: String,
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        requestBody: String? = nil,
        responseBody: String? = nil,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        InsightsService.logRequest(
            source: .plugin,
            method: method,
            path: path,
            statusCode: statusCode,
            durationMs: durationMs,
            requestBody: requestBody,
            responseBody: responseBody,
            pluginId: pluginId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    private static func measureMs(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// Extract a top-level string value from JSON without full deserialization.
    private static func extractJSONStringValue(from json: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]*)\""
        guard let range = json.range(of: pattern, options: .regularExpression) else { return nil }
        let match = json[range]
        guard let colonQuote = match.range(of: ":\\s*\"", options: .regularExpression)?.upperBound else { return nil }
        return String(match[colonQuote ..< match.index(before: match.endIndex)])
    }

    private static func responseContainsError(_ json: String) -> Bool {
        json.contains("\"error\"")
    }

    // MARK: Config Trampolines

    static let trampolineConfigGet: osr_config_get_t = { keyPtr in
        guard let keyPtr, let ctx = activeContext() else { return nil }
        let key = String(cString: keyPtr)
        guard let value = ctx.configGet(key: key) else { return nil }
        return makeCString(value)
    }

    static let trampolineConfigSet: osr_config_set_t = { keyPtr, valuePtr in
        guard let keyPtr, let valuePtr, let ctx = activeContext() else { return }
        let key = String(cString: keyPtr)
        let value = String(cString: valuePtr)
        ctx.configSet(key: key, value: value)
    }

    static let trampolineConfigDelete: osr_config_delete_t = { keyPtr in
        guard let keyPtr, let ctx = activeContext() else { return }
        let key = String(cString: keyPtr)
        ctx.configDelete(key: key)
    }

    // MARK: Database Trampolines

    static let trampolineDbExec: osr_db_exec_t = { sqlPtr, paramsPtr in
        guard let sqlPtr, let ctx = activeContext() else { return nil }
        let sql = String(cString: sqlPtr)
        let params = paramsPtr.map { String(cString: $0) }
        let result = ctx.dbExec(sql: sql, paramsJSON: params)
        return makeCString(result)
    }

    static let trampolineDbQuery: osr_db_query_t = { sqlPtr, paramsPtr in
        guard let sqlPtr, let ctx = activeContext() else { return nil }
        let sql = String(cString: sqlPtr)
        let params = paramsPtr.map { String(cString: $0) }
        let result = ctx.dbQuery(sql: sql, paramsJSON: params)
        return makeCString(result)
    }

    // MARK: Logging Trampoline

    static let trampolineLog: osr_log_t = { level, msgPtr in
        guard let msgPtr, let ctx = activeContext() else { return }
        let message = String(cString: msgPtr)
        let levelName: String
        let statusCode: Int
        switch level {
        case 0: levelName = "DEBUG"; statusCode = 200
        case 1: levelName = "INFO"; statusCode = 200
        case 2: levelName = "WARN"; statusCode = 299
        case 3: levelName = "ERROR"; statusCode = 500
        default: levelName = "LOG"; statusCode = 200
        }
        NSLog("[Plugin:%@] [%@] %@", ctx.pluginId, levelName, message)
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "LOG",
            path: "[\(levelName)] \(message)",
            statusCode: statusCode,
            durationMs: 0,
            requestBody: message
        )
    }

    // MARK: Dispatch Trampolines

    static let trampolineDispatch: osr_dispatch_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        var result = ""
        var taskId: UUID?
        let ms = measureMs { (result, taskId) = ctx.dispatch(requestJSON: json) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/dispatch",
            statusCode: responseContainsError(result) ? 429 : 202,
            durationMs: ms,
            requestBody: json,
            responseBody: result
        )
        if let taskId {
            Task { @MainActor in
                BackgroundTaskManager.shared.releaseEventsForDispatch(taskId: taskId)
            }
        }
        return makeCString(result)
    }

    static let trampolineTaskStatus: osr_task_status_t = { taskIdPtr in
        guard let taskIdPtr, let ctx = activeContext() else { return nil }
        let taskId = String(cString: taskIdPtr)
        var result = ""
        let ms = measureMs { result = ctx.taskStatus(taskId: taskId) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "GET",
            path: "/host-api/tasks/\(taskId)",
            statusCode: 200,
            durationMs: ms,
            responseBody: result
        )
        return makeCString(result)
    }

    static let trampolineDispatchCancel: osr_dispatch_cancel_t = { taskIdPtr in
        guard let taskIdPtr, let ctx = activeContext() else { return }
        let taskId = String(cString: taskIdPtr)
        let ms = measureMs { ctx.dispatchCancel(taskId: taskId) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "DELETE",
            path: "/host-api/tasks/\(taskId)",
            statusCode: 204,
            durationMs: ms
        )
    }

    static let trampolineDispatchClarify: osr_dispatch_clarify_t = { taskIdPtr, responsePtr in
        guard let taskIdPtr, let responsePtr, let ctx = activeContext() else { return }
        let taskId = String(cString: taskIdPtr)
        let response = String(cString: responsePtr)
        let ms = measureMs { ctx.dispatchClarify(taskId: taskId, response: response) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/tasks/\(taskId)/clarify",
            statusCode: 200,
            durationMs: ms,
            requestBody: response
        )
    }

    // MARK: Extended Dispatch Trampolines

    static let trampolineListActiveTasks: osr_list_active_tasks_t = {
        guard let ctx = activeContext() else { return nil }
        var result = ""
        let ms = measureMs { result = ctx.listActiveTasks() }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "GET",
            path: "/host-api/tasks",
            statusCode: 200,
            durationMs: ms,
            responseBody: result
        )
        return makeCString(result)
    }

    static let trampolineSendDraft: osr_send_draft_t = { taskIdPtr, draftPtr in
        guard let taskIdPtr, let draftPtr, let ctx = activeContext() else { return }
        let taskId = String(cString: taskIdPtr)
        let draftJSON = String(cString: draftPtr)
        let ms = measureMs { ctx.sendDraft(taskId: taskId, draftJSON: draftJSON) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/tasks/\(taskId)/draft",
            statusCode: 200,
            durationMs: ms,
            requestBody: draftJSON
        )
    }

    static let trampolineDispatchInterrupt: osr_dispatch_interrupt_t = { taskIdPtr, messagePtr in
        guard let taskIdPtr, let ctx = activeContext() else { return }
        let taskId = String(cString: taskIdPtr)
        let message: String? = messagePtr.map { String(cString: $0) }
        let ms = measureMs { ctx.dispatchInterrupt(taskId: taskId, message: message) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/tasks/\(taskId)/interrupt",
            statusCode: 200,
            durationMs: ms,
            requestBody: message
        )
    }

    static let trampolineDispatchAddIssue: osr_dispatch_add_issue_t = { taskIdPtr, issuePtr in
        guard let taskIdPtr, let issuePtr, let ctx = activeContext() else { return nil }
        let taskId = String(cString: taskIdPtr)
        let issueJSON = String(cString: issuePtr)
        var result = ""
        let ms = measureMs { result = ctx.dispatchAddIssue(taskId: taskId, issueJSON: issueJSON) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/tasks/\(taskId)/issues",
            statusCode: responseContainsError(result) ? 400 : 201,
            durationMs: ms,
            requestBody: issueJSON,
            responseBody: result
        )
        return makeCString(result)
    }

    // MARK: Inference Trampolines

    static let trampolineComplete: osr_complete_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        var result = ""
        let ms = measureMs { result = ctx.complete(requestJSON: json) }
        let model = extractJSONStringValue(from: json, key: "model")
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/chat/completions",
            statusCode: responseContainsError(result) ? 500 : 200,
            durationMs: ms,
            requestBody: json,
            responseBody: result,
            model: model
        )
        return makeCString(result)
    }

    static let trampolineCompleteStream: osr_complete_stream_t = { requestPtr, onChunk, userData in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        var result = ""
        let ms = measureMs { result = ctx.completeStream(requestJSON: json, onChunk: onChunk, userData: userData) }
        let model = extractJSONStringValue(from: json, key: "model")
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/chat/completions",
            statusCode: responseContainsError(result) ? 500 : 200,
            durationMs: ms,
            requestBody: json,
            responseBody: result,
            model: model
        )
        return makeCString(result)
    }

    static let trampolineEmbed: osr_embed_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        var result = ""
        let ms = measureMs { result = ctx.embed(requestJSON: json) }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/embeddings",
            statusCode: responseContainsError(result) ? 500 : 200,
            durationMs: ms,
            requestBody: json,
            responseBody: result
        )
        return makeCString(result)
    }

    // MARK: Models Trampoline

    static let trampolineListModels: osr_list_models_t = {
        guard let ctx = activeContext() else { return nil }
        var result = ""
        let ms = measureMs { result = ctx.listModels() }
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "GET",
            path: "/host-api/models",
            statusCode: 200,
            durationMs: ms,
            responseBody: result
        )
        return makeCString(result)
    }

    // MARK: HTTP Client Trampoline

    static let trampolineHttpRequest: osr_http_request_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        var result = ""
        let ms = measureMs { result = ctx.httpRequest(requestJSON: json) }
        let method = extractJSONStringValue(from: json, key: "method") ?? "GET"
        let url = extractJSONStringValue(from: json, key: "url") ?? "?"
        let statusStr = extractJSONStringValue(from: result, key: "status")
        let statusCode = statusStr.flatMap { Int($0) } ?? (responseContainsError(result) ? 500 : 200)
        logPluginCall(
            pluginId: ctx.pluginId,
            method: method,
            path: "/host-api/http \u{2192} \(url)",
            statusCode: statusCode,
            durationMs: ms,
            requestBody: json,
            responseBody: result
        )
        return makeCString(result)
    }

    // MARK: File Read Trampoline

    static let trampolineFileRead: osr_file_read_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        var result = ""
        let ms = measureMs { result = ctx.fileRead(requestJSON: json) }
        let path = extractJSONStringValue(from: json, key: "path") ?? "?"
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "GET",
            path: "/host-api/file_read \u{2192} \(path)",
            statusCode: responseContainsError(result) ? 500 : 200,
            durationMs: ms,
            requestBody: json,
            responseBody: nil
        )
        return makeCString(result)
    }
}

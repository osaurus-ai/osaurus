//
//  PluginHostAPI.swift
//  osaurus
//
//  Implements the host-side callbacks passed to v2 plugins via osr_host_api.
//  Each plugin gets its own host context with config (Keychain-backed),
//  database (sandboxed SQLite), dispatch, inference, models, and HTTP access.
//

import Foundation
import os

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

    // MARK: - Per-Plugin In-Flight Inference Cap

    /// Maximum simultaneous inference calls (`complete` + `completeStream` + `embed`)
    /// per plugin. Bursts above this fail fast with `plugin_busy` instead of
    /// piling up blocked plugin worker threads — every `blockingAsync` parks
    /// a thread on a semaphore for the entire MLX serialization wait, and
    /// without a cap a single misbehaving plugin can starve the host.
    static let maxInflightPerPlugin = 2

    private let inflightLock = NSLock()
    private var inflightInferenceCount = 0

    /// Try to take one inflight slot. Returns `false` if the plugin is already
    /// at the per-plugin cap; the caller should reject with `plugin_busy`.
    private func tryEnterInflightInference() -> Bool {
        inflightLock.withLock {
            guard inflightInferenceCount < Self.maxInflightPerPlugin else { return false }
            inflightInferenceCount += 1
            return true
        }
    }

    /// Release one inflight slot. Floors at zero so a buggy double-release
    /// can never poison the count.
    private func exitInflightInference() {
        inflightLock.withLock {
            inflightInferenceCount = max(0, inflightInferenceCount - 1)
        }
    }

    /// Reusable JSON for the "plugin already at concurrency cap" response.
    private static func pluginBusyJSON(kind: String) -> String {
        jsonString([
            "error": "plugin_busy",
            "message":
                "Plugin already has \(maxInflightPerPlugin) concurrent \(kind) calls in flight. Retry after a previous call returns.",
            "max_inflight": maxInflightPerPlugin,
        ])
    }

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
        // NOTE: deliberately do NOT call `database.open()` here.
        // Most plugins never call `db.exec` / `db.query`, so eagerly
        // opening every plugin's SQLCipher database at host-api init
        // costs the user 50–100ms × N-plugins of PBKDF2 work for
        // nothing. The first `dbExec` / `dbQuery` call below opens
        // it on demand instead. See `ensureDatabaseOpen()`.
    }

    deinit {
        hostAPIPtr?.deinitialize(count: 1)
        hostAPIPtr?.deallocate()
        database.close()
    }

    /// Set after the first `database.open()` failure so we don't
    /// flood the log when a plugin keeps re-trying SQL against a
    /// permanently-failed DB (e.g. disk full, wrong key).
    /// `PluginDatabase.open()` is itself idempotent so the
    /// "already open" common path is essentially free.
    private let dbOpenLogLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Lazy-open the per-plugin database on first SQL call.
    /// Idempotent — `PluginDatabase.open()` short-circuits when the
    /// connection is already up. Called from every `dbExec` /
    /// `dbQuery` entry point so plugins that never touch SQL pay
    /// zero open cost.
    private func ensureDatabaseOpen() {
        do {
            try database.open()
        } catch {
            // Non-fatal — `dbExec` / `dbQuery` will return the
            // standard `{"error":"Database not open"}` JSON
            // envelope from `PluginDatabase` on any subsequent
            // call when `db == nil`. Log the *first* failure per
            // plugin only so a plugin that keeps re-trying doesn't
            // flood the unified log.
            let alreadyLogged = dbOpenLogLock.withLock { logged -> Bool in
                if logged { return true }
                logged = true
                return false
            }
            if !alreadyLogged {
                print("[PluginHostAPI:\(pluginId)] Failed to open plugin database: \(error)")
            }
        }
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
        ensureDatabaseOpen()
        return database.exec(sql: sql, paramsJSON: paramsJSON)
    }

    func dbQuery(sql: String, paramsJSON: String?) -> String {
        ensureDatabaseOpen()
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

            // Empty/whitespace prompts make `ChatSession.send` no-op (no Task,
            // no `isStreaming` flip), which would leave the dispatched task
            // hanging in `.running` until the awaitCompletion watchdog.
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return (
                    Self.jsonString(["error": "invalid_request", "message": "Prompt is empty"]),
                    UUID?.none
                )
            }

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

            let externalSessionKey =
                json["external_session_key"] as? String
                ?? json["session_id"] as? String

            let request = DispatchRequest(
                id: requestId,
                prompt: prompt,
                agentId: resolvedAgent,
                title: title,
                folderBookmark: folderBookmark,
                showToast: true,
                sourcePluginId: pluginId,
                source: .plugin,
                externalSessionKey: externalSessionKey
            )

            // BackgroundTaskManager.dispatchChat now self-holds plugin
            // events between registerTask and trampoline-return, since
            // reattach can resolve a different task id than `requestId`.
            let handle = await TaskDispatcher.shared.dispatch(request)
            guard let handle else {
                return (
                    Self.jsonString([
                        "error": "task_limit_reached", "message": "Maximum concurrent background tasks reached",
                    ]), UUID?.none
                )
            }

            // Use the resolved task id (may differ from `requestId` if the
            // dispatcher reattached to an existing session via the
            // `external_session_key` find-or-create path).
            let resolvedId = handle.id
            return (Self.jsonString(["id": resolvedId.uuidString, "status": "running"]), resolvedId)
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

    /// No-op: clarifications are surfaced inline in the chat window via
    /// the `clarify` agent intercept. The C ABI slot is preserved so old
    /// plugins keep loading.
    func dispatchClarify(taskId: String, response: String) {
        _ = taskId
        _ = response
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
        let executionMode: ExecutionMode

        func withSystemPrompt(_ newPrompt: String) -> AgentContext {
            AgentContext(
                agentId: agentId,
                systemPrompt: newPrompt,
                model: model,
                temperature: temperature,
                maxTokens: maxTokens,
                tools: tools,
                executionMode: executionMode
            )
        }

        func prependingSystemContent(_ content: String) -> AgentContext {
            withSystemPrompt(content + "\n\n" + systemPrompt)
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
        let executionMode: ExecutionMode
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

        // Honour the same execution-mode rules the chat UI uses so a
        // plugin invocation against this agent sees the same tool surface
        // (sandbox > host folder > none). Previously this path was hard-
        // coded to `folderContext: nil`, so a host-folder agent driven via
        // a plugin would silently lose its folder tools.
        let execMode = await MainActor.run {
            ToolRegistry.shared.resolveExecutionMode(
                folderContext: FolderContextService.shared.currentContext,
                autonomousEnabled: resolved.autonomousEnabled
            )
        }
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
                executionMode: execMode
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

        let enriched = ChatCompletionRequest(
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

    /// Session-scoped preflight cache lives in the shared
    /// `SessionToolStateStore` so HTTP/plugin and chat windows hit the same
    /// snapshot. Once a preflight result is computed for a session it is
    /// reused for all subsequent turns; any change to the tool list causes
    /// prompt divergence before token ~1000 and forces a full re-prefill,
    /// so stability matters more than freshness here.

    /// Call when a session ends (e.g. chat window closes) to release the memoized result.
    static func invalidatePreflightCache(sessionId: String) {
        Task { await SessionToolStateStore.shared.invalidate(sessionId) }
    }

    /// Persist newly loaded tool names (from `capabilities_load`) onto a
    /// session's preflight cache entry so subsequent requests with the same
    /// `session_id` re-include them via `additionalToolNames` instead of
    /// losing them when preflight is reused. No-op when the session has
    /// no entry yet (load before first compose) — the next preflight will
    /// rediscover what the model needs.
    private static func recordSessionLoadedTools(sessionId: String, names: [String]) {
        guard !names.isEmpty else { return }
        Task {
            guard await SessionToolStateStore.shared.get(sessionId) != nil else { return }
            await SessionToolStateStore.shared.appendLoadedTools(
                sessionId,
                names: names,
                fallbackPreflight: .empty,
                fallbackAlwaysLoadedNames: nil
            )
        }
    }

    private static func extractPreflightQuery(from messages: [ChatMessage]) -> String {
        messages.last(where: { $0.role == "user" })?.content ?? ""
    }

    private static func applyPreflightSearch(
        to inference: EnrichedInference,
        executionMode: ExecutionMode = .none,
        agentId: UUID = Agent.defaultId
    ) async -> EnrichedInference {
        let toolMode = await MainActor.run {
            AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        }
        let isManualTools = toolMode == .manual

        // Manual mode mirrors the pragmatic chat-side rule (always-loaded
        // baseline + user picks), just without the LLM-driven preflight.
        // Same shape across chat / plugin so the agent's schema doesn't
        // change with entry point. See SystemPromptComposer.resolveTools.
        if isManualTools {
            let (builtInTools, manualSpecs) = await MainActor.run {
                let base = ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
                let names = AgentManager.shared.effectiveManualToolNames(for: agentId) ?? []
                let manual = ToolRegistry.shared.specs(forTools: names)
                return (base, manual)
            }
            let empty = PreflightResult(toolSpecs: manualSpecs, items: [])
            return applyPreflightResult(empty, to: inference, builtInTools: builtInTools)
        }

        // Auto mode: RAG-based preflight
        if let sid = inference.request.session_id {
            // Drop the cache if the (mode, toolMode) signature changed
            // since last turn — same rule as the chat send path.
            let liveFp = SessionToolState.fingerprint(
                executionMode: executionMode,
                toolMode: toolMode
            )
            await SessionToolStateStore.shared.invalidateIfFingerprintChanged(sid, liveFingerprint: liveFp)
            let cached = await SessionToolStateStore.shared.get(sid)
            if let cached {
                // Honour the session's first-turn always-loaded snapshot
                // when present: filter the live registry result down to
                // those names so a tool that registered late doesn't
                // sneak into turn 2's schema.
                let builtInTools = await MainActor.run { () -> [Tool] in
                    let live = ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
                    if let frozen = cached.initialAlwaysLoadedNames {
                        return live.filter { frozen.contains($0.function.name) }
                    }
                    return live
                }
                let extraSpecs = await MainActor.run {
                    ToolRegistry.shared.specs(forTools: Array(cached.loadedToolNames))
                }
                return applyPreflightResult(
                    cached.initialPreflight,
                    to: inference,
                    builtInTools: builtInTools,
                    additionalToolSpecs: extraSpecs
                )
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
            // Snapshot the always-loaded names this turn so subsequent
            // turns freeze against them. Stamp the (mode, toolMode)
            // fingerprint so a flip on a later turn invalidates the
            // cache (mirrors `ChatView`'s behaviour).
            let builtInNames = Set(builtInTools.map { $0.function.name })
            let fp = SessionToolState.fingerprint(
                executionMode: executionMode,
                toolMode: toolMode
            )
            await SessionToolStateStore.shared.setInitial(
                sid,
                preflight: preflight,
                alwaysLoadedNames: builtInNames,
                fingerprint: fp
            )
        }

        return applyPreflightResult(preflight, to: inference, builtInTools: builtInTools)
    }

    /// Merges a cached `PreflightResult` (and any session-loaded tool specs)
    /// into an inference request without re-running the search.
    private static func applyPreflightResult(
        _ preflight: PreflightResult,
        to inference: EnrichedInference,
        builtInTools: [Tool],
        additionalToolSpecs: [Tool] = []
    ) -> EnrichedInference {
        var seen = Set((inference.tools ?? []).map { $0.function.name })
        var tools = inference.tools ?? []
        for spec in builtInTools + preflight.toolSpecs + additionalToolSpecs
        where !seen.contains(spec.function.name) {
            tools.append(spec)
            seen.insert(spec.function.name)
        }

        let messages = inference.request.messages
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
                // Persist additions to the per-session cache so subsequent
                // requests with the same `session_id` continue to see these
                // tools without the model having to re-discover them.
                if let sid = prep.enriched.request.session_id {
                    recordSessionLoadedTools(
                        sessionId: sid,
                        names: additions.map { $0.function.name }
                    )
                }
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
        executionMode: ExecutionMode = .none
    ) async -> String {
        if executionMode.usesSandboxTools, let agentId {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    return try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                        try await ToolRegistry.shared.execute(
                            name: name,
                            argumentsJSON: argumentsJSON
                        )
                    }
                } catch {
                    return ToolEnvelope.fromError(error, tool: name)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: toolExecutionTimeout * 1_000_000_000)
                return nil
            }
            let timeoutEnvelope = ToolErrorEnvelope(
                kind: .timeout,
                reason: "Tool did not complete within \(toolExecutionTimeout)s.",
                toolName: name
            ).toJSONString()
            guard let first = await group.next() else {
                return timeoutEnvelope
            }
            group.cancelAll()
            return first ?? timeoutEnvelope
        }
    }

    // MARK: complete (non-streaming)

    func complete(requestJSON: String) -> String {
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "complete")
        }
        let pid = self.pluginId
        let releaseSlot: @Sendable () -> Void = { [weak self] in
            self?.exitInflightInference()
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .complete)
        return Self.blockingAsync {
            defer {
                releaseSlot()
                Self.endPluginActivity(activityId)
            }
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
                        // The non-streaming path already appends the full
                        // assistant message (with all tool_calls) once,
                        // then appends only the tool-result messages per call.
                        messages.append(choice.message)
                        for tc in calls {
                            let processed = await Self.processToolCall(
                                toolName: tc.function.name,
                                argumentsJSON: tc.function.arguments,
                                callId: tc.id,
                                priorAssistantContent: "",
                                prep: prep,
                                toolSpecs: &toolSpecs
                            )
                            // assistantMessage from processToolCall is unused
                            // here because choice.message already represents
                            // the full assistant turn for this iteration.
                            if let dict = processed.artifactDict { sharedArtifacts.append(dict) }
                            messages.append(processed.toolMessage)
                            toolCallsExecuted.append(processed.toolCallExecuted)
                        }
                        continue
                    }

                    // Persist the final assistant turn into the chat-history
                    // SQLite so this conversation is browsable in the sidebar.
                    var persistedMessages = messages
                    persistedMessages.append(choice.message)
                    Self.persistInference(
                        pluginId: pid,
                        agentId: prep.agentId,
                        externalSessionKey: prep.enriched.request.session_id,
                        finalMessages: persistedMessages,
                        model: prep.enriched.request.model
                    )

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
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "complete_stream")
        }
        let pid = self.pluginId
        nonisolated(unsafe) let userData = userData
        let releaseSlot: @Sendable () -> Void = { [weak self] in
            self?.exitInflightInference()
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .completeStream)
        return Self.blockingAsync {
            defer {
                releaseSlot()
                Self.endPluginActivity(activityId)
            }
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
                        // Reasoning sentinel must be decoded BEFORE the
                        // generic `isSentinel` filter, otherwise reasoning
                        // text gets dropped together with tool/stats hints.
                        // We forward reasoning to plugins on the OpenAI
                        // extended `reasoning_content` field of the chunk
                        // delta — plugins that ignore the field continue
                        // to work unchanged.
                        if let reasoning = StreamingReasoningHint.decode(delta) {
                            emit(Self.chunkPayload(id: cid, delta: ["reasoning_content": reasoning]))
                            continue
                        }
                        if StreamingToolHint.isSentinel(delta) { continue }
                        iterContent += delta
                        lastContent += delta
                        emit(Self.chunkPayload(id: cid, delta: ["content": delta]))
                    }

                    if !iterContent.isEmpty {
                        messages.append(ChatMessage(role: "assistant", content: iterContent))
                    }
                    emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "stop"))
                    Self.persistStreamingInference(
                        pluginId: pid,
                        agentId: prep.agentId,
                        externalSessionKey: prep.enriched.request.session_id,
                        priorMessages: messages,
                        assistantContent: "",
                        model: prep.enriched.request.model
                    )
                    return Self.buildStreamResult(
                        id: cid,
                        model: prep.enriched.request.model,
                        content: lastContent,
                        toolCallsExecuted: toolCallsExecuted,
                        sharedArtifacts: sharedArtifacts
                    )

                } catch let invs as ServiceToolInvocations {
                    guard iteration < prep.options.maxIterations else {
                        emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "stop"))
                        break
                    }
                    await Self.processInvocationBatch(
                        invs.invocations,
                        cid: cid,
                        lastContent: &lastContent,
                        messages: &messages,
                        toolSpecs: &toolSpecs,
                        toolCallsExecuted: &toolCallsExecuted,
                        sharedArtifacts: &sharedArtifacts,
                        prep: prep,
                        emit: emit
                    )
                    continue

                } catch let inv as ServiceToolInvocation {
                    guard iteration < prep.options.maxIterations else {
                        emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "stop"))
                        break
                    }
                    await Self.processInvocationBatch(
                        [inv],
                        cid: cid,
                        lastContent: &lastContent,
                        messages: &messages,
                        toolSpecs: &toolSpecs,
                        toolCallsExecuted: &toolCallsExecuted,
                        sharedArtifacts: &sharedArtifacts,
                        prep: prep,
                        emit: emit
                    )
                    continue

                } catch {
                    return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
                }
            }

            // Persist whatever we have before returning, even on max-iterations
            // exit, so the user can still see the partial conversation.
            Self.persistStreamingInference(
                pluginId: pid,
                agentId: prep.agentId,
                externalSessionKey: prep.enriched.request.session_id,
                priorMessages: messages,
                assistantContent: lastContent,
                model: prep.enriched.request.model
            )
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

    /// Outcome of executing a single model-emitted tool call. Shared between
    /// `complete` (non-streaming, walks each item in `choice.message.tool_calls`)
    /// and `complete_stream` (each `ServiceToolInvocation`) so the per-call
    /// behaviour — execute, post-process, append assistant + tool messages —
    /// stays in sync between the two paths.
    private struct ToolCallProcessing {
        let result: String
        let assistantMessage: ChatMessage
        let toolMessage: ChatMessage
        let toolCallExecuted: [String: String]
        let artifactDict: [String: Any]?
    }

    /// Execute every tool in a `ServiceToolInvocations` batch and append the
    /// assistant + tool messages in order. Mirrors the `complete()`
    /// non-streaming path so a single completion that emits multiple
    /// `<tool_call>` blocks runs all of them in one streaming round.
    private static func processInvocationBatch(
        _ invocations: [ServiceToolInvocation],
        cid: String,
        lastContent: inout String,
        messages: inout [ChatMessage],
        toolSpecs: inout [Tool]?,
        toolCallsExecuted: inout [[String: String]],
        sharedArtifacts: inout [[String: Any]],
        prep: PreparedInference,
        emit: ([String: Any]) -> Void
    ) async {
        for inv in invocations {
            let callId =
                inv.toolCallId
                ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

            let tcDelta: [String: Any] = [
                "tool_calls": [
                    ["id": callId, "function": ["name": inv.toolName, "arguments": inv.jsonArguments]]
                ]
            ]
            emit(Self.chunkPayload(id: cid, delta: tcDelta, finishReason: "tool_calls"))

            let processed = await Self.processToolCall(
                toolName: inv.toolName,
                argumentsJSON: inv.jsonArguments,
                callId: callId,
                priorAssistantContent: lastContent,
                prep: prep,
                toolSpecs: &toolSpecs
            )
            if let dict = processed.artifactDict { sharedArtifacts.append(dict) }

            emit(
                Self.chunkPayload(
                    id: cid,
                    delta: [
                        "role": "tool", "tool_call_id": callId, "content": processed.result,
                    ]
                )
            )

            toolCallsExecuted.append(processed.toolCallExecuted)
            messages.append(processed.assistantMessage)
            messages.append(processed.toolMessage)
            // Only the FIRST invocation in the batch consumes the streamed
            // assistant prose — subsequent calls in the same completion
            // share the same response, so we clear lastContent after the
            // first tool to avoid duplicating prose into every assistant
            // tool-call message.
            lastContent = ""
        }
    }

    /// Execute one tool call, post-process the result, and produce the
    /// assistant + tool ChatMessages to append to the running history.
    /// Updates `toolSpecs` in place when post-processing surfaces newly
    /// loaded tools (e.g. `capabilities_load`).
    private static func processToolCall(
        toolName: String,
        argumentsJSON: String,
        callId: String,
        priorAssistantContent: String,
        prep: PreparedInference,
        toolSpecs: inout [Tool]?
    ) async -> ToolCallProcessing {
        var result = await Self.executeToolCall(
            name: toolName,
            argumentsJSON: argumentsJSON,
            agentId: prep.agentId,
            executionMode: prep.executionMode
        )
        let postProcessed = await Self.postProcessToolResult(
            toolName: toolName,
            result: result,
            prep: prep,
            toolSpecs: &toolSpecs
        )
        result = postProcessed.result

        let toolCall = ToolCall(
            id: callId,
            type: "function",
            function: ToolCallFunction(name: toolName, arguments: argumentsJSON)
        )
        let assistantMessage = ChatMessage(
            role: "assistant",
            content: priorAssistantContent.isEmpty ? nil : priorAssistantContent,
            tool_calls: [toolCall],
            tool_call_id: nil
        )
        let toolMessage = ChatMessage(
            role: "tool",
            content: result,
            tool_calls: nil,
            tool_call_id: callId
        )
        return ToolCallProcessing(
            result: result,
            assistantMessage: assistantMessage,
            toolMessage: toolMessage,
            toolCallExecuted: ["name": toolName, "tool_call_id": callId],
            artifactDict: postProcessed.artifactDict
        )
    }

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
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "embed")
        }
        let pid = self.pluginId
        let releaseSlot: @Sendable () -> Void = { [weak self] in
            self?.exitInflightInference()
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .embed)
        return Self.blockingAsync {
            defer {
                releaseSlot()
                Self.endPluginActivity(activityId)
            }
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
        ]

        if let draft = state.draftText, let parsed = parseJSON(draft) { result["draft"] = parsed }

        // Last assistant content — partial during `.running`, final on
        // `.completed`. Surfaced for both so HTTP pollers and `task_status`
        // callers can read the transcript without loading the session.
        if let output = state.chatSession?.turns.last?.content, !output.isEmpty {
            result["output"] = output
        }

        switch state.status {
        case .running:
            result["status"] = "running"
            if let step = state.currentStep { result["current_step"] = step }

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
            // Reachable only via legacy state transitions; chat tasks
            // surface clarification inline via the agent intercept and
            // do NOT mark the task awaiting from the manager's POV.
            result["status"] = "awaiting_clarification"
            result["current_step"] = "Needs input"

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
    /// Dedicated GCD queue used to run the inner async-bridge `Task` so that
    /// the cooperative thread pool's executor cannot deadlock with the
    /// outside semaphore wait. Concurrent so multiple plugin trampolines can
    /// progress in parallel; QoS matches a user-initiated request.
    ///
    /// Why this matters: `blockingAsync` parks the *trampoline thread* on a
    /// `DispatchSemaphore` while a Swift `Task` runs the async work. If that
    /// trampoline thread happened to be one of the cooperative pool's worker
    /// threads (e.g. a future refactor that calls `blockingAsync` from a
    /// `Task`), and the inner async work needs to await on something that
    /// also needs that pool, the system can deadlock — `sem.wait()` blocks
    /// the only thread the inner Task could resume on.
    ///
    /// We can't fully prevent that — `Task.detached` still uses the cooperative
    /// pool — but we *can* ensure that the inner Task never inherits
    /// the caller's actor or priority. Combined with the `!Thread.isMainThread`
    /// assert, this keeps the contract safe for plugin worker threads.
    private static let blockingBridgeQueue = DispatchQueue(
        label: "com.osaurus.pluginHost.blockingBridge",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Block the current (non-main) thread while running async work.
    /// Used by C trampolines that must return synchronously.
    ///
    /// Uses `Task.detached` so the inner work never inherits the caller's
    /// actor isolation or priority, and runs the signal on a dedicated
    /// concurrent GCD queue so the wakeup path doesn't depend on the
    /// cooperative pool having a free worker.
    static func blockingAsync<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            let value = await work()
            blockingBridgeQueue.async {
                box.value = value
                sem.signal()
            }
        }
        sem.wait()
        return box.value!
    }

    /// Block the current (non-main) thread while running @MainActor work.
    @discardableResult
    static func blockingMainActor<T: Sendable>(_ work: @MainActor @escaping @Sendable () -> T) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) { @MainActor in
            let value = work()
            blockingBridgeQueue.async {
                box.value = value
                sem.signal()
            }
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

    /// Returns a `not_supported` error envelope: nested issues no longer
    /// exist as a concept, so plugins should call `dispatch` to start a
    /// fresh task instead. The C ABI slot is retained so old plugins
    /// keep loading.
    static let trampolineDispatchAddIssue: osr_dispatch_add_issue_t = { taskIdPtr, _ in
        guard let taskIdPtr, let ctx = activeContext() else { return nil }
        let taskId = String(cString: taskIdPtr)
        let result = jsonString([
            "error": "not_supported",
            "message":
                "dispatch_add_issue is no longer supported. Call dispatch() to start a fresh task.",
        ])
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/tasks/\(taskId)/issues",
            statusCode: 410,
            durationMs: 0,
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

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

    /// Temporary fallback used only during plugin init — set right before
    /// the plugin's `init` / `osaurus_plugin_entry_v2` call and cleared
    /// right after, so trampolines fired from inside that frame can
    /// resolve the context before `setContext` has registered it under
    /// the plugin id. Plugin loads in `PluginManager` are sequential, so
    /// today there is no concurrent writer, but the unfair-lock wrapper
    /// keeps the path future-proof against a refactor that loads
    /// plugins in parallel and avoids the `nonisolated(unsafe)` hazard.
    private static let _currentContext = OSAllocatedUnfairLock<PluginHostContext?>(initialState: nil)
    static var currentContext: PluginHostContext? {
        get { _currentContext.withLock { $0 } }
        set { _currentContext.withLock { $0 = newValue } }
    }

    // MARK: - Instance Properties

    let pluginId: String
    let database: PluginDatabase

    /// Heap-allocated host API struct whose pointer is handed to the plugin at
    /// init. Must outlive the plugin because it may store the pointer rather
    /// than copying the struct.
    private(set) var hostAPIPtr: UnsafeMutablePointer<osr_host_api>?

    private struct HTTPTransportSessionState {
        let proxyKey: String
        let session: URLSession
    }

    private static let noRedirectSessionBox = OSAllocatedUnfairLock<HTTPTransportSessionState?>(initialState: nil)

    /// Shared URLSession that suppresses redirects. `http_request`
    /// follows redirects manually so every `Location` target can pass
    /// through the same SSRF guard before the host connects.
    static func noRedirectSession() -> URLSession {
        let proxyKey = currentHTTPTransportProxyKey()
        return noRedirectSessionBox.withLock { state in
            if let state, state.proxyKey == proxyKey {
                return state.session
            }

            state?.session.finishTasksAndInvalidate()
            let session = makeNoRedirectSession()
            state = HTTPTransportSessionState(proxyKey: proxyKey, session: session)
            return session
        }
    }

    private static func currentHTTPTransportProxyKey() -> String {
        GlobalProxySettings.currentConfiguration()?.redactedDescription ?? ""
    }

    private static func makeNoRedirectSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 10
        return GlobalProxySettings.makeSession(
            base: config,
            delegate: NoRedirectDelegate.shared,
            delegateQueue: nil
        )
    }

    private static let maxHTTPRedirects = 20

    /// Sliding window timestamps for dispatch rate limiting, keyed by agent ID.
    /// The bucket is **per (plugin, agent) pair** — each plugin keeps its own
    /// `PluginHostContext`, so two plugins running for the same agent each
    /// get an independent 10/min quota. This is intentional: it prevents a
    /// chatty plugin from starving another plugin's dispatches against the
    /// same agent. Plugin authors should size their dispatch cadence
    /// against the per-plugin budget, not against a notional global one.
    private let rateLimitLock = NSLock()
    private var dispatchTimestamps: [UUID: [Date]] = [:]
    private static let dispatchRateLimit = 10
    private static let dispatchRateWindow: TimeInterval = 60

    /// Sliding-window timestamps for `http_request` rate limiting,
    /// keyed by the resolved active agent so each agent's bucket is
    /// independent (matches the dispatch limiter's shape). Caps a
    /// chatty plugin's outbound HTTP traffic so it can't saturate the
    /// `httpSession` connection pool or trip third-party rate limits
    /// silently. Note: this is a *host-side* control to stop runaway
    /// plugins, not a substitute for the plugin's own backoff against
    /// upstream APIs.
    private var httpTimestamps: [UUID: [Date]] = [:]
    static let httpRateLimit = 60
    static let httpRateWindow: TimeInterval = 60

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

    // MARK: - Streaming Cancellation Registry

    /// Per-plugin set of stream IDs marked for cancellation. The plugin
    /// supplies a `stream_id` UUID when it calls `complete_stream`; calling
    /// `complete_cancel(stream_id)` flips the entry, and the streaming task
    /// observes it between deltas and unwinds with `finish_reason: "cancelled"`.
    /// Membership in the set means "this stream id should be cancelled" —
    /// the streaming task removes the entry on exit (success or cancel).
    private let streamLock = NSLock()
    private var cancelledStreamIds: Set<String> = []

    /// Register a stream ID as in-flight. Idempotent; calling twice with
    /// the same id is harmless.
    private func registerStream(_ streamId: String) {
        streamLock.withLock { _ = cancelledStreamIds.remove(streamId) }
    }

    /// Mark a stream as cancelled. The streaming task's `isStreamCancelled`
    /// check picks it up on the next delta. Internal access so unit tests
    /// can verify the cancellation registry directly.
    func markStreamCancelled(_ streamId: String) {
        streamLock.withLock { _ = cancelledStreamIds.insert(streamId) }
    }

    /// Returns true if the stream id has been marked for cancellation.
    /// Internal access so unit tests can assert registry state.
    func isStreamCancelled(_ streamId: String) -> Bool {
        streamLock.withLock { cancelledStreamIds.contains(streamId) }
    }

    /// Drop bookkeeping for a stream that finished (success or cancel).
    private func unregisterStream(_ streamId: String) {
        streamLock.withLock { _ = cancelledStreamIds.remove(streamId) }
    }

    // MARK: - Per-Request Agent Context

    /// Resolved agent ID for the current thread, or `nil` when no chat agent
    /// is bound to this invocation. Checks thread-local storage (set per-
    /// dispatch in `ExternalPlugin` wrappers); each invokeQueue / eventQueue
    /// thread gets its own value.
    ///
    /// The Default (built-in) agent is intentionally treated as "no agent
    /// context" for plugin operations: plugins MUST NOT silently inherit
    /// the Default agent's secret namespace, tool grants, or rate-limit
    /// quota when invoked without an explicit chat binding. That historical
    /// `?? Agent.defaultId` fallback leaked the Default agent's data and
    /// permissions to anonymous plugin paths.
    var resolvedAgentIdOrNil: UUID? {
        guard let id = Self.activeAgentId() else { return nil }
        return id == Agent.defaultId ? nil : id
    }

    /// Deterministic synthetic UUID used as the bucket key for per-agent rate
    /// limiting when the current invocation has no chat-bound agent context.
    /// Distinct from `Agent.defaultId` so anonymous plugin traffic doesn't
    /// share a bucket with — or accrue quota against — the Default agent.
    static let anonymousPluginRateBucketId = UUID(
        uuidString: "ffffffff-ffff-ffff-ffff-fffffffffff0"
    )!

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
        // Anonymous reads (no chat-bound agent) must not silently fall back
        // to the Default agent's secret namespace. Warn-once and return nil
        // so the plugin reads no value rather than the Default agent's.
        guard let agentId = resolvedAgentIdOrNil else {
            Self.warnNoAgentContextOnce(pluginId: pluginId, op: "config_get")
            return nil
        }
        return ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: agentId)
    }

    /// Maximum config value byte size accepted by `config_set`. The
    /// keychain is for credentials and small state, not blob storage;
    /// values larger than this are silently rejected with a one-shot
    /// warning (the plugin is expected to use `db_exec` / `db_query`
    /// for larger payloads). The cap is documented under `config_set`
    /// in `osaurus_plugin.h`.
    static let configValueMaxBytes = 1 * 1024 * 1024  // 1 MiB

    func configSet(key: String, value: String) {
        // Reject oversized values up front — silently, since the C ABI
        // is `void`-returning and there's no envelope channel back to
        // the plugin. The one-shot warning surfaces the bug to the
        // plugin author the first time they trigger it.
        if value.utf8.count > Self.configValueMaxBytes {
            Self.warnConfigValueTooLargeOnce(
                pluginId: pluginId,
                key: key,
                size: value.utf8.count
            )
            return
        }
        // Anonymous writes (no chat-bound agent) must not silently land in
        // the Default agent's secret namespace. No-op + warn-once instead.
        guard let agentId = resolvedAgentIdOrNil else {
            Self.warnNoAgentContextOnce(pluginId: pluginId, op: "config_set")
            return
        }
        ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: agentId)
        postConfigChange(key: key, value: value)
    }

    func configDelete(key: String) {
        guard let agentId = resolvedAgentIdOrNil else {
            Self.warnNoAgentContextOnce(pluginId: pluginId, op: "config_delete")
            return
        }
        ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: agentId)
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

    /// Outcome of `planDispatch`: either an error envelope to return
    /// straight to the plugin, or a fully-built `DispatchRequest` ready
    /// for `TaskDispatcher`. Surfaced to tests so the security boundary
    /// (agent-scope enforcement, prompt validation, request-id parse,
    /// session_id passthrough) can be pinned without spinning up
    /// `BackgroundTaskManager` or a real chat engine.
    enum DispatchPlan {
        case error(envelope: String)
        case request(DispatchRequest)
    }

    /// Parses the plugin's `dispatch(requestJSON:)` payload and applies
    /// the host-enforced agent scope (`activeAgent`, captured from TLS
    /// before `blockingAsync`). The returned `DispatchPlan` either
    /// carries the error envelope to send back, or the
    /// `DispatchRequest` to hand to `TaskDispatcher`.
    ///
    /// Rate limiting is intentionally *not* in this function: it
    /// requires per-context state (`PluginHostContext.getContext(for:)`
    /// + `checkDispatchRateLimit`), whereas this helper is a pure
    /// transform from `(json, pluginId, activeAgent) -> plan`. Keeping
    /// it pure lets unit tests assert "this JSON + this TLS agent
    /// produces this DispatchRequest" without singletons.
    static func planDispatch(
        requestJSON: String,
        pluginId: String,
        activeAgent: UUID?,
        allowedToolNames: Set<String> = []
    ) -> DispatchPlan {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let prompt = json["prompt"] as? String
        else {
            return .error(
                envelope: jsonString([
                    "error": "invalid_request", "message": "Missing required field: prompt",
                ])
            )
        }

        // Empty/whitespace prompts make `ChatSession.send` no-op (no Task,
        // no `isStreaming` flip), which would leave the dispatched task
        // hanging in `.running` until the awaitCompletion watchdog.
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(
                envelope: jsonString(["error": "invalid_request", "message": "Prompt is empty"])
            )
        }

        var requestId = UUID()
        if let idStr = json["id"] as? String, let parsed = UUID(uuidString: idStr) {
            requestId = parsed
        }

        // Agent scope is host-enforced — caller-supplied `agent_address`
        // / `agent_id` is ignored. Plugin dispatch with no active chat
        // agent (or with the built-in Default agent) is refused outright:
        // the previous `?? Agent.defaultId` fallback let plugins
        // anonymously route work onto the Default agent, which is
        // unreachable by design from external surfaces.
        auditAgentScope(json: json, pluginId: pluginId, op: "dispatch", activeAgent: activeAgent)
        if let rejection = Agent.rejectBuiltInForExternalSurface(
            activeAgent,
            source: "plugin/planDispatch"
        ) {
            return .error(
                envelope: jsonString([
                    "error": rejection.code,
                    "message": rejection.message,
                ])
            )
        }
        guard let resolvedAgent = activeAgent else {
            // Unreachable: `rejectBuiltInForExternalSurface(nil, ...)`
            // already returned an error above. Belt-and-suspenders for
            // future refactors of the guard.
            return .error(
                envelope: jsonString([
                    "error": "missing_agent_context",
                    "message": "Plugin dispatch requires an active chat agent context.",
                ])
            )
        }

        let title = json["title"] as? String

        var folderBookmark: Data?
        if let bookmarkStr = json["folder_bookmark"] as? String {
            folderBookmark = Data(base64Encoded: bookmarkStr)
        }

        // v3: only `session_id` is accepted. The legacy `external_session_key`
        // alias was removed; old plugins passing it will need to migrate.
        let externalSessionKey = json["session_id"] as? String

        // Optional `tools` array — see `parseRequestedTools` for the
        // validation contract. Empty when the plugin omits the field
        // or `allowedToolNames` is empty (e.g. test paths that drive
        // `planDispatch` directly without the MainActor lookup).
        let requestedToolNames = parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: allowedToolNames
        )

        let request = DispatchRequest(
            id: requestId,
            prompt: prompt,
            agentId: resolvedAgent,
            title: title,
            folderBookmark: folderBookmark,
            showToast: true,
            sourcePluginId: pluginId,
            source: .plugin,
            externalSessionKey: externalSessionKey,
            requestedToolNames: requestedToolNames
        )
        return .request(request)
    }

    /// Parses the optional `tools` field on a dispatch JSON payload and
    /// returns the validated, deduplicated subset that survives the
    /// allowed-set scope check. Pure helper — extracted so unit tests
    /// can pin the validation table independently of the rest of
    /// `planDispatch`.
    ///
    /// Order is preserved (first occurrence wins). Non-string entries,
    /// blanks, and duplicates are dropped silently. Names outside the
    /// allowed set fire one `PluginOnceLogger.warnOnce` per (plugin,
    /// name) so plugin authors see the drop without flooding the log
    /// on hot paths.
    static func parseRequestedTools(
        json: [String: Any],
        pluginId: String,
        allowedToolNames: Set<String>
    ) -> [String] {
        guard let raw = json["tools"] as? [Any] else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in raw {
            guard let name = entry as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            if allowedToolNames.contains(trimmed) {
                ordered.append(trimmed)
            } else {
                warnDispatchToolScopeOnce(pluginId: pluginId, name: trimmed)
            }
        }
        return ordered
    }

    /// Tool names a plugin's `dispatch` call is allowed to request:
    /// the plugin's own manifest tool ids
    /// (`ExternalTool.name == manifest.tools[].id`) plus host built-in
    /// always-loaded names (`builtInToolNames` ∪ `runtimeManagedToolNames`).
    /// Plugins can pin their own tools and host built-ins like
    /// `share_artifact` / `search_memory`, but cannot smuggle in another
    /// plugin's tools. A missing loaded-plugin record (e.g. mid-unload)
    /// collapses to "built-ins only"; `parseRequestedTools` then
    /// warn-onces any of the plugin's own names that no longer resolve.
    @MainActor
    static func dispatchToolAllowedSet(pluginId: String) -> Set<String> {
        let registry = ToolRegistry.shared
        var allowed = registry.builtInToolNames.union(registry.runtimeManagedToolNames)
        if let loaded = PluginManager.shared.loadedPlugin(for: pluginId) {
            for tool in loaded.tools { allowed.insert(tool.name) }
        }
        return allowed
    }

    func dispatch(requestJSON: String) -> (result: String, taskId: UUID?) {
        // Capture the active agent on the *calling* thread before crossing
        // into `Self.blockingAsync` — TLS does not survive `Task.detached`.
        // The host enforces that plugin-initiated dispatches always run
        // under the agent that invoked the plugin (set by ExternalPlugin's
        // invoke / handleRoute / notifyConfigBatch / notifyTaskEvent).
        // Caller-supplied `agent_address` / `agent_id` is stripped below
        // and a one-shot warning is logged so a deliberate cross-agent
        // dispatch attempt remains visible in the unified log.
        let activeAgent = Self.activeAgentId()
        return Self.blockingAsync(
            fallback: (Self.pluginHostTimeoutJSON(kind: "dispatch"), UUID?.none)
        ) { [pluginId, activeAgent] in
            // PluginManager + ToolRegistry are MainActor-isolated; hop
            // once and hand `planDispatch` a plain `Set` so the planner
            // stays a pure transform driveable from tests.
            let allowedTools: Set<String> = await MainActor.run {
                Self.dispatchToolAllowedSet(pluginId: pluginId)
            }
            let plan = Self.planDispatch(
                requestJSON: requestJSON,
                pluginId: pluginId,
                activeAgent: activeAgent,
                allowedToolNames: allowedTools
            )
            let request: DispatchRequest
            switch plan {
            case .error(let envelope):
                return (envelope, UUID?.none)
            case .request(let r):
                request = r
            }

            // `planDispatch` guarantees `request.agentId` is non-nil and not
            // `Agent.defaultId` by the time we reach here. Force-unwrap to
            // avoid resurrecting the old `?? Agent.defaultId` fallback in
            // the rate-limiter key.
            guard let ctx = PluginHostContext.getContext(for: pluginId),
                ctx.checkDispatchRateLimit(agentId: request.agentId!)
            else {
                return (
                    Self.jsonString([
                        "error": "rate_limit_exceeded", "message": "Dispatch rate limit (10/min) exceeded",
                    ]),
                    UUID?.none
                )
            }

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

        return Self.blockingMainActor(fallback: Self.pluginHostTimeoutJSON(kind: "task_status")) {
            [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId
            else {
                return Self.jsonString(["error": "not_found", "message": "Task not found"])
            }
            return Self.serializeTaskState(id: uuid, state: state)
        }
    }

    func dispatchCancel(taskId: String) {
        guard let uuid = UUID(uuidString: taskId) else {
            Self.warnInvalidTaskIdOnce(pluginId: pluginId, op: "dispatch_cancel", taskId: taskId)
            return
        }
        Self.blockingMainActor(fallback: ()) { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId
            else {
                Self.warnUnownedTaskOnce(pluginId: pluginId, op: "dispatch_cancel", taskId: taskId)
                return
            }
            BackgroundTaskManager.shared.cancelTask(uuid)
        }
    }

    /// RESERVED — preserved for ABI compatibility. The host returns void
    /// (the C signature does not allow a JSON response), but the trampoline
    /// logs the call with HTTP 410 + a `not_supported` body so plugin
    /// developers see in Insights that the slot has no runtime effect.
    /// Clarifications are surfaced inline via the `clarify` agent intercept.
    func dispatchClarify(taskId _: String, response _: String) {}

    func listActiveTasks() -> String {
        Self.blockingMainActor(fallback: Self.pluginHostTimeoutJSON(kind: "list_active_tasks")) {
            [pluginId] in
            let tasks = BackgroundTaskManager.shared.backgroundTasks.values
                .filter { $0.sourcePluginId == pluginId && $0.status.isActive }
                .map { PluginHostContext.taskStateDict(id: $0.id, state: $0) }
            return Self.jsonString(["tasks": tasks])
        }
    }

    func sendDraft(taskId: String, draftJSON: String) {
        guard let uuid = UUID(uuidString: taskId) else {
            Self.warnInvalidTaskIdOnce(pluginId: pluginId, op: "send_draft", taskId: taskId)
            return
        }
        Self.blockingMainActor(fallback: ()) { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId, state.status.isActive
            else {
                Self.warnUnownedTaskOnce(pluginId: pluginId, op: "send_draft", taskId: taskId)
                return
            }
            state.draftText = draftJSON
            BackgroundTaskManager.shared.emitDraftEvent(state, draftJSON: draftJSON)
        }
    }

    func dispatchInterrupt(taskId: String, message: String?) {
        guard let uuid = UUID(uuidString: taskId) else {
            Self.warnInvalidTaskIdOnce(pluginId: pluginId, op: "dispatch_interrupt", taskId: taskId)
            return
        }
        Self.blockingMainActor(fallback: ()) { [pluginId] in
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid),
                state.sourcePluginId == pluginId
            else {
                Self.warnUnownedTaskOnce(pluginId: pluginId, op: "dispatch_interrupt", taskId: taskId)
                return
            }
            BackgroundTaskManager.shared.interruptTask(uuid, message: message)
        }
    }

    /// Mark an in-flight `complete_stream` call for cancellation by stream
    /// id. Non-blocking; the streaming task observes the flag between
    /// deltas and unwinds with `finish_reason: "cancelled"`. No-ops
    /// silently if the stream id doesn't match an active stream — useful
    /// for fire-and-forget cancel calls from `on_chunk`.
    func completeCancel(streamId: String) {
        let trimmed = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        markStreamCancelled(trimmed)
    }

    // MARK: - Inference Callbacks

    private static let toolExecutionTimeout: UInt64 = 120
    // Plugin-host completions are used by agent/tool surfaces. A one-shot
    // default turns any omitted `max_iterations` into "stop before executing
    // the first model-emitted tool call", which is especially visible on
    // Qwen-family local models that rely on multi-turn tool/result loops.
    private static let defaultMaxIterations = 30
    private static let maxIterationsCap = 120

    // MARK: Inference Types

    /// Internal so unit tests can pin `resolveAgentContext`'s nil / non-nil
    /// behavior. The fields below remain inspectable from `@testable import`
    /// so a future test can assert per-agent overrides flow through.
    struct AgentContext {
        let agentId: UUID
        let systemPrompt: String
        let memorySection: String?
        let model: String?
        let temperature: Float?
        let maxTokens: Int?
        let tools: [Tool]?
        let executionMode: ExecutionMode

        func withSystemPrompt(_ newPrompt: String) -> AgentContext {
            AgentContext(
                agentId: agentId,
                systemPrompt: newPrompt,
                memorySection: memorySection,
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

        init(from json: [String: Any]) {
            let raw = json["max_iterations"] as? Int ?? defaultMaxIterations
            self.maxIterations = max(1, min(raw, maxIterationsCap))
            self.wantsAgentTools = json["tools"] as? Bool == true
        }
    }

    private struct EnrichedInference {
        var request: ChatCompletionRequest
        let tools: [Tool]?
        /// (key, prefix) for the memory block injected into this request's
        /// latest user message, when the session ledger should record it.
        var recordedUserPrefix: (key: String, prefix: String)? = nil
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

    /// Strips extension fields (`agent_address`, `agent_id`, `max_iterations`,
    /// `"tools": true`) that would break the Codable decoder, returning both
    /// the raw dict and clean Data. `agent_address` / `agent_id` are still
    /// recognized in the raw dict so that plugin trampolines can warn-once
    /// when a plugin tries to override the host-enforced agent scope.
    /// Internal (not private) so unit tests can pin the strip behavior.
    static func parseRawRequest(_ requestJSON: String) -> (json: [String: Any], sanitized: Data)? {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var clean = json
        clean.removeValue(forKey: "agent_address")
        clean.removeValue(forKey: "agent_id")
        clean.removeValue(forKey: "max_iterations")
        if json["tools"] is Bool { clean.removeValue(forKey: "tools") }

        guard let cleanData = try? JSONSerialization.data(withJSONObject: clean, options: .osaurusCanonical)
        else { return nil }
        return (json, cleanData)
    }

    /// Shared setup for both `complete` and `completeStream`: resolves agent context,
    /// enriches the request, creates the engine and budget manager.
    ///
    /// `activeAgentId` is the host-enforced agent scope captured on the
    /// calling thread (TLS) before the plugin trampoline crossed into
    /// `Self.blockingAsync`. Pass nil for non-plugin callers, where the
    /// agent context is intentionally not bound to a specific agent.
    private static func prepareInference(
        request: ChatCompletionRequest,
        rawJSON: [String: Any],
        pluginId: String? = nil,
        activeAgentId: UUID? = nil
    ) async -> PreparedInference {
        let options = InferenceOptions(from: rawJSON)
        let agentCtx = await resolveAgentContext(
            agentId: activeAgentId,
            messages: request.messages,
            sessionId: request.session_id
        )
        let execMode = agentCtx?.executionMode ?? .none
        // Session-stable memory injection (parity with the chat surface's
        // frozen turn prefixes): fetch previously recorded per-user-message
        // prefixes so `enrichRequest` replays the exact bytes earlier
        // requests were sent with, and record the prefix newly injected into
        // this request's latest user message for the NEXT request. Without
        // this, plugin history resent clean each call diverges from the
        // prior wire bytes and re-prefills the last exchange.
        let frozenPrefixes: [String: String]
        if let sid = request.session_id, !sid.isEmpty {
            frozenPrefixes = await SessionToolStateStore.shared.frozenUserPrefixes(sid)
        } else {
            frozenPrefixes = [:]
        }
        var enriched = enrichRequest(
            request,
            context: agentCtx,
            options: options,
            frozenUserPrefixes: frozenPrefixes
        )
        if let sid = request.session_id, !sid.isEmpty,
            let recorded = enriched.recordedUserPrefix
        {
            await SessionToolStateStore.shared.recordUserPrefix(
                sid,
                key: recorded.key,
                prefix: recorded.prefix
            )
        }
        if let pid = pluginId {
            let instructions: String? = await MainActor.run {
                PluginInstructionsResolver.instructions(pluginId: pid, agentId: agentCtx?.agentId)
            }
            if let instructions {
                SystemPromptComposer.appendSystemContent(instructions, into: &enriched.request.messages)
            }
        }
        // No silent Default-agent fallback: when the plugin has no chat-bound
        // agent context, tool + skill injection are skipped (treated as
        // "tools off"). Otherwise we'd be injecting tools + skills against
        // the Default agent's grants, which leaks the built-in agent's
        // configuration to anonymous plugin inferences.
        let resolvedAgentId = agentCtx?.agentId
        let agentToolsOff: Bool
        if let id = resolvedAgentId {
            agentToolsOff = await MainActor.run {
                AgentManager.shared.effectiveToolsDisabled(for: id)
            }
        } else {
            agentToolsOff = true
        }
        if let id = resolvedAgentId, options.wantsAgentTools && !agentToolsOff {
            enriched = await applyAgentTools(
                to: enriched,
                executionMode: execMode,
                agentId: id
            )
        }
        // Skills inject in BOTH modes — see the matching block in
        // `SystemPromptComposer.compose` for the full rationale.
        if let id = resolvedAgentId, !agentToolsOff,
            let section = await SkillManager.shared.enabledSkillPromptSection(for: id)
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

    /// Resolves the per-agent inference context (system prompt, tool surface,
    /// model overrides, sampling defaults) for `agentId`. Returns nil when
    /// `agentId` is nil or no agent record is found, in which case callers
    /// fall back to host defaults. The agent id is now injected by the
    /// trampoline (captured from TLS before `blockingAsync`); plugin-supplied
    /// `agent_address` / `agent_id` is intentionally ignored — see
    /// `warnAgentOverrideOnce` in the dispatch / inference entry points.
    /// Internal (not private) so unit tests can pin the resolution surface.
    static func resolveAgentContext(
        agentId: UUID?,
        messages: [ChatMessage] = [],
        sessionId: String? = nil
    ) async -> AgentContext? {
        guard let agentId else { return nil }

        let resolved: (id: UUID, autonomousEnabled: Bool)? = await MainActor.run {
            guard AgentManager.shared.agent(for: agentId) != nil else { return nil }
            let enabled = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
            return (agentId, enabled)
        }
        guard let resolved else { return nil }

        if resolved.autonomousEnabled {
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }

        // Honour the same execution-mode rules the chat UI uses so a
        // plugin invocation against this agent sees the same tool surface
        // (sandbox > host folder > none). Previously this path was hard-
        // coded to `folderContext: nil`, so a host-folder agent driven via
        // a plugin would silently lose its folder tools.
        let (execMode, agentModel, toolMode) = await MainActor.run {
            () -> (ExecutionMode, String?, ToolSelectionMode) in
            let mode = ToolRegistry.shared.resolveExecutionMode(
                folderContext: FolderContextService.shared.currentContext,
                autonomousEnabled: resolved.autonomousEnabled
            )
            // Snapshot the agent's effective model so it can ride along to
            // `composeChatContext` as the chat-model fallback
            // (GitHub issue #823).
            let model = AgentManager.shared.effectiveModel(for: agentId)
            return (mode, model, AgentManager.shared.effectiveToolSelectionMode(for: agentId))
        }
        // Session-frozen compose inputs (parity with the chat send path):
        // the first compose for a `session_id` snapshots the manifest /
        // SOUL / always-loaded names, and every later compose echoes them
        // so the static system-prompt prefix stays byte-identical across
        // the session (KV-cache reuse). Without this, every
        // `prepareInference` recomposed fresh and any drifting section
        // forced a full re-prefill.
        var cachedSession: SessionToolState?
        if let sid = sessionId {
            let liveFp = SessionToolState.fingerprint(executionMode: execMode, toolMode: toolMode)
            await SessionToolStateStore.shared.invalidateIfFingerprintChanged(
                sid,
                liveFingerprint: liveFp
            )
            cachedSession = await SessionToolStateStore.shared.get(sid)
        }
        let composed = await SystemPromptComposer.composeChatContext(
            agentId: agentId,
            executionMode: execMode,
            model: agentModel,
            query: extractLatestUserQuery(from: messages),
            messages: messages,
            additionalToolNames: cachedSession?.loadedToolNames ?? [],
            frozenAlwaysLoadedNames: cachedSession?.initialAlwaysLoadedNames,
            frozenManifest: cachedSession?.frozenManifest,
            frozenSoul: cachedSession?.frozenSoul
        )
        if let sid = sessionId, cachedSession == nil {
            await SessionToolStateStore.shared.setInitial(
                sid,
                alwaysLoadedNames: composed.alwaysLoadedNames,
                fingerprint: SessionToolState.fingerprint(executionMode: execMode, toolMode: toolMode),
                manifest: composed.enabledManifest,
                soul: composed.soul
            )
        }
        return await MainActor.run {
            let mgr = AgentManager.shared
            return AgentContext(
                agentId: agentId,
                systemPrompt: composed.prompt,
                memorySection: composed.memorySection,
                model: agentModel,
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
        options: InferenceOptions,
        frozenUserPrefixes: [String: String] = [:]
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
        // Byte-stable memory injection: replay prefixes recorded on earlier
        // requests of this session onto matching history messages, then
        // inject this request's memory into the latest user message (see
        // SystemPromptComposer.applyFrozenMemoryPrefixes). The recorded pair
        // rides back on EnrichedInference so `prepareInference` can persist
        // it into the session ledger.
        let recordedUserPrefix = SystemPromptComposer.applyFrozenMemoryPrefixes(
            memorySection: ctx.memorySection,
            frozen: frozenUserPrefixes,
            into: &messages
        )

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
        var enrichedWithRuntimeOptions = enriched
        enrichedWithRuntimeOptions.enable_thinking = request.enable_thinking
        enrichedWithRuntimeOptions.reasoning_effort = request.reasoning_effort
        enrichedWithRuntimeOptions.modelOptions = request.modelOptions
        return EnrichedInference(
            request: enrichedWithRuntimeOptions,
            tools: effectiveTools,
            recordedUserPrefix: recordedUserPrefix
        )
    }

    private static func iterationRequest(
        from base: ChatCompletionRequest,
        messages: [ChatMessage],
        tools: [Tool]?
    ) -> ChatCompletionRequest {
        var request = ChatCompletionRequest(
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
        request.enable_thinking = base.enable_thinking
        request.reasoning_effort = base.reasoning_effort
        request.modelOptions = base.modelOptions
        return request
    }

    // MARK: Session Tool Cache

    /// Session-scoped tool-state cache lives in the shared
    /// `SessionToolStateStore` so HTTP/plugin and chat windows hit the same
    /// snapshot. Once the always-loaded baseline is captured for a session it
    /// is frozen for all subsequent turns; any change to the tool list causes
    /// prompt divergence before token ~1000 and forces a full re-prefill,
    /// so stability matters more than freshness here.

    /// Call when a session ends (e.g. chat window closes) to release the cached state.
    static func invalidateSessionToolCache(sessionId: String) {
        Task { await SessionToolStateStore.shared.invalidate(sessionId) }
    }

    /// Persist newly loaded tool names (from `capabilities_load`) onto a
    /// session's tool-state entry so subsequent requests with the same
    /// `session_id` re-include them via `additionalToolNames`. No-op when the
    /// session has no entry yet (load before first compose) — the next compose
    /// captures the baseline.
    private static func recordSessionLoadedTools(sessionId: String, names: [String]) {
        guard !names.isEmpty else { return }
        Task {
            guard await SessionToolStateStore.shared.get(sessionId) != nil else { return }
            await SessionToolStateStore.shared.appendLoadedTools(
                sessionId,
                names: names,
                fallbackAlwaysLoadedNames: nil
            )
        }
    }

    private static func extractLatestUserQuery(from messages: [ChatMessage]) -> String {
        messages.last(where: { $0.role == "user" })?.content ?? ""
    }

    /// Resolve the agent's tool schema for a plugin-HTTP inference, mirroring
    /// chat Design C: the always-loaded hot set plus the agent's manual picks
    /// (manual mode) or any session-loaded `capabilities_load` tools (auto
    /// mode). There is no per-turn LLM picker — capability breadth is grounded
    /// in the enabled-capabilities manifest and pulled in at runtime via
    /// `capabilities_discover` / `capabilities_load`.
    private static func applyAgentTools(
        to inference: EnrichedInference,
        executionMode: ExecutionMode = .none,
        agentId: UUID = Agent.defaultId
    ) async -> EnrichedInference {
        // Built-in default agent is in-app chat only and gets a fixed
        // baseline; injected picks would be stripped downstream.
        // Defense-in-depth on top of `BuiltInAgentGuard`.
        if agentId == Agent.defaultId {
            return inference
        }
        let toolMode = await MainActor.run {
            AgentManager.shared.effectiveToolSelectionMode(for: agentId)
        }
        let isManualTools = toolMode == .manual

        // Manual mode: always-loaded baseline + the user's explicit picks.
        // Same shape across chat / plugin so the agent's schema doesn't
        // change with entry point. See SystemPromptComposer.resolveTools.
        if isManualTools {
            let (builtInTools, manualSpecs) = await MainActor.run {
                let base = ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
                let names = AgentManager.shared.effectiveManualToolNames(for: agentId) ?? []
                let manual = ToolRegistry.shared.specs(forTools: names)
                return (base, manual)
            }
            return await applyResolvedTools(builtInTools + manualSpecs, to: inference)
        }

        // Auto mode (Design C): always-loaded hot set + session-loaded tools.
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
                return await applyResolvedTools(builtInTools + extraSpecs, to: inference)
            }
        }

        // First turn for this session: inject the always-loaded baseline and
        // snapshot its names so subsequent turns freeze against them. Stamp
        // the (mode, toolMode) fingerprint so a flip on a later turn
        // invalidates the cache (mirrors `ChatView`'s behaviour).
        let builtInTools = await MainActor.run {
            ToolRegistry.shared.alwaysLoadedSpecs(mode: executionMode)
        }
        if let sid = inference.request.session_id {
            let builtInNames = Set(builtInTools.map { $0.function.name })
            let fp = SessionToolState.fingerprint(
                executionMode: executionMode,
                toolMode: toolMode
            )
            await SessionToolStateStore.shared.setInitial(
                sid,
                alwaysLoadedNames: builtInNames,
                fingerprint: fp
            )
        }

        return await applyResolvedTools(builtInTools, to: inference)
    }

    /// Merge a set of resolved tool specs into an inference request, replacing
    /// any existing spec with the same name, then sort into canonical order.
    private static func applyResolvedTools(
        _ specs: [Tool],
        to inference: EnrichedInference
    ) async -> EnrichedInference {
        var tools = inference.tools ?? []
        for spec in specs {
            if let index = tools.firstIndex(where: { $0.function.name == spec.function.name }) {
                tools[index] = spec
            } else {
                tools.append(spec)
            }
        }
        // Sort into canonical order so the plugin path produces the same
        // `<tools>` layout the chat composer would — appended specs would
        // otherwise drift relative to the next recompose and bust the cache.
        if !tools.isEmpty {
            tools = await SystemPromptComposer.canonicalToolOrder(tools)
        }

        let messages = inference.request.messages
        let effectiveTools = tools.isEmpty ? nil : tools
        var request = ChatCompletionRequest(
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
        request.enable_thinking = inference.request.enable_thinking
        request.reasoning_effort = inference.request.reasoning_effort
        request.modelOptions = inference.request.modelOptions
        return EnrichedInference(request: request, tools: effectiveTools)
    }

    // MARK: Context Budget

    private static func createBudgetManager(
        for inf: EnrichedInference,
        maxIterations: Int
    ) async -> ContextBudgetManager? {
        guard maxIterations > 1 else { return nil }

        // Window resolution + reservations are shared with the chat and
        // HTTP loop surfaces via `AgentLoopBudget`. The tool reservation is
        // for THIS request's tool schema, not the whole registry — the
        // model only ever sees the request's toolset, so reserving for
        // every registered tool would starve the history budget.
        let contextLength = await AgentLoopBudget.resolveContextWindow(modelId: inf.request.model)
        let toolTokens = await MainActor.run {
            ToolRegistry.shared.totalEstimatedTokens(for: inf.tools ?? [])
        }
        let sysChars = inf.request.messages.first(where: { $0.role == "system" })?.content?.count ?? 0

        return AgentLoopBudget.makeBudgetManager(
            contextWindow: contextLength,
            systemPromptChars: sysChars,
            toolTokens: toolTokens,
            maxResponseTokens: inf.request.max_tokens
        )
    }

    // MARK: Tool Execution

    private typealias PostProcessResult = (result: String, artifactDict: [String: Any]?)

    /// Post-processes a tool result after execution, handling special tools
    /// like `share_artifact` (copy files, notify handlers, collect artifact metadata)
    /// and `capabilities_load` (record newly loaded tools for the NEXT request).
    private static func postProcessToolResult(
        toolName: String,
        result: String,
        prep: PreparedInference
    ) async -> PostProcessResult {
        switch toolName {
        case "share_artifact":
            return await processShareArtifact(result: result, prep: prep)

        case "capabilities_load":
            // Deferred-schema policy (KV stability): loaded tools are
            // callable IMMEDIATELY — the registry dispatches by name and
            // schema visibility is not an execution gate — but this run's
            // rendered tool schema stays FROZEN. Hot-patching `toolSpecs`
            // mid-run rewrote the prompt prefix and busted the paged-KV
            // cache for the rest of the conversation. The names persist
            // onto the session entry so the next request with the same
            // `session_id` composes their full schemas in.
            let newTools = await CapabilityLoadBuffer.shared.drain()
            guard !newTools.isEmpty else { return (result, nil) }
            if let sid = prep.enriched.request.session_id {
                recordSessionLoadedTools(
                    sessionId: sid,
                    names: newTools.map { $0.function.name }
                )
            }
            // The loaded tools' schemas already ride in the tool result
            // (`CapabilitiesLoadTool.loadedSchemaBlock`) so the model can call
            // them by name this same turn — no extra notice to append.
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
                        // The combined-mode host-read scope + secret-read
                        // policy are bound centrally inside
                        // ToolRegistry.execute (keyed off the agent in
                        // context), so this path inherits them uniformly.
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

    /// Internal abort signals thrown out of the shared-loop hooks so the
    /// plugin entrypoints can map them to their historical error envelopes.
    private enum PluginLoopAbort: Error {
        case noChoices
    }

    func complete(requestJSON: String) -> String {
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "complete")
        }
        let pid = self.pluginId
        // Capture host-enforced agent scope on the calling thread before
        // crossing into `Self.blockingAsync` — TLS does not survive the
        // `Task.detached` hop. See `dispatch` for the full rationale.
        let activeAgent = Self.activeAgentId()
        let releaseSlot: @Sendable () -> Void = { [weak self] in
            self?.exitInflightInference()
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .complete)
        return Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "complete")) {
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

            // Agent scope is host-enforced — see `auditAgentScope`.
            Self.auditAgentScope(json: rawJSON, pluginId: pid, op: "complete", activeAgent: activeAgent)

            let prep = await Self.prepareInference(
                request: request,
                rawJSON: rawJSON,
                pluginId: pid,
                activeAgentId: activeAgent
            )
            var messages = prep.enriched.request.messages
            var toolCallsExecuted: [[String: String]] = []
            var sharedArtifacts: [[String: Any]] = []
            // Frozen for the whole run (deferred-schema policy): the tool
            // schema never changes mid-run, even after `capabilities_load`.
            let toolSpecs = prep.enriched.tools
            // Per-invocation harness state (plugin completions are one-shot
            // across requests). Provides within-run dedupe + post-listing nudge.
            let taskState = AgentTaskState()
            // Run-scoped sticky compaction: trims stay monotonic across this
            // completion's iterations (KV-prefix-stable transcript).
            let compactionWatermark = CompactionWatermark()
            // The final model response, stashed by the modelStep hook when the
            // completion carries no executable tool calls (or the iteration
            // budget says to stop executing).
            var finalResponse: ChatCompletionResponse?
            // Set when a successful `complete`/`clarify` intercept ends the
            // run (`endRun` → driver `.endedBySurface`), so the terminal
            // handler below can build the matching envelope. Parity with
            // chat's agent-loop intercepts.
            var interceptedExit: (tool: String, args: String)?

            // Canonical loop skeleton lives in `AgentToolLoop`; these hooks
            // carry the plugin host's non-streaming specifics — message-array
            // history, budget-managed trimming, and `processToolCall`
            // post-processing (share_artifact / capabilities_load).
            let hooks = AgentLoopHooks(
                buildMessages: { notices in
                    // Canonical notice contract (shared with chat/HTTP):
                    // trim with the system prefix kept byte-stable, then
                    // append driver-staged notices TRANSIENTLY — they ride
                    // exactly one iteration and never persist into
                    // `messages`.
                    AgentLoopBudget.composeIterationMessages(
                        messages,
                        notices: notices,
                        manager: prep.budgetManager,
                        watermark: compactionWatermark
                    )
                },
                modelStep: { effective, _ in
                    let iterReq = Self.iterationRequest(
                        from: prep.enriched.request,
                        messages: effective,
                        tools: toolSpecs
                    )
                    let response = try await prep.engine.completeChat(request: iterReq)
                    guard let choice = response.choices.first else {
                        throw PluginLoopAbort.noChoices
                    }

                    if let calls = choice.message.tool_calls, !calls.isEmpty,
                        choice.finish_reason == "tool_calls"
                    {
                        // The non-streaming path appends the full assistant
                        // message (with all tool_calls) once; the per-call
                        // hooks then append only the tool-result messages.
                        // The iteration cap is owned by the DRIVER (same
                        // taxonomy as the HTTP surface): the final
                        // iteration's calls still execute, then the loop
                        // exits `.iterationCapReached`.
                        messages.append(choice.message)
                        return .toolCalls(
                            calls.map {
                                ServiceToolInvocation(
                                    toolName: $0.function.name,
                                    jsonArguments: $0.function.arguments,
                                    toolCallId: $0.id
                                )
                            }
                        )
                    }

                    // Final answer.
                    finalResponse = response
                    return .finalResponse
                },
                onDedupedResult: { _, callId, held in
                    // Dedupe a still-fresh re-read: replay the exact held
                    // envelope instead of re-running the read. The assistant
                    // message with the tool_calls is already in history.
                    messages.append(
                        ChatMessage(role: "tool", content: held, tool_calls: nil, tool_call_id: callId)
                    )
                },
                executeTool: { inv, callId in
                    let processed = await Self.processToolCall(
                        toolName: inv.toolName,
                        argumentsJSON: inv.jsonArguments,
                        callId: callId,
                        priorAssistantContent: "",
                        prep: prep
                    )
                    // assistantMessage from processToolCall is unused here
                    // because choice.message already represents the full
                    // assistant turn for this iteration.
                    if let dict = processed.artifactDict { sharedArtifacts.append(dict) }
                    messages.append(processed.toolMessage)
                    toolCallsExecuted.append(processed.toolCallExecuted)
                    // Agent-loop intercepts: a successful `complete`/`clarify`
                    // ends the run cleanly instead of riding to the iteration
                    // cap. The tool turn is already in `messages` (above), so
                    // history stays paired.
                    if AgentToolLoop.isSuccessfulIntercept(
                        toolName: inv.toolName,
                        result: processed.result
                    ) {
                        interceptedExit = (inv.toolName, inv.jsonArguments)
                        return AgentLoopToolExecution(result: processed.result, endRun: true)
                    }
                    return AgentLoopToolExecution(result: processed.result)
                }
            )

            let exit: AgentToolLoop.Exit
            do {
                let runResult = try await AgentToolLoop.run(
                    policy: AgentLoopPolicy(
                        maxIterations: prep.options.maxIterations,
                        stopOnToolRejection: false,
                        dedupeNoticeEnabled: false,
                        maxDataMovementSteps: min(16, prep.options.maxIterations)
                    ),
                    state: taskState,
                    hooks: hooks
                )
                exit = runResult.exit
            } catch PluginLoopAbort.noChoices {
                return Self.jsonString(["error": "inference_error", "message": "No choices returned"])
            } catch {
                return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
            }

            // Even fully-compacted history can't fit the window — the
            // driver ended the run before sending a doomed request.
            if exit == .overBudget {
                return Self.jsonString([
                    "error": "context_overflow",
                    "message": AgentToolLoop.overBudgetMessage,
                    "tool_calls_executed": toolCallsExecuted,
                    "shared_artifacts": sharedArtifacts,
                ])
            }
            if exit == .emptyResponseExhausted {
                return Self.jsonString([
                    "error": "empty_tool_task_completion",
                    "message": AgentToolLoop.emptyToolTaskFallback,
                    "tool_calls_executed": toolCallsExecuted,
                    "shared_artifacts": sharedArtifacts,
                ])
            }

            // A successful `complete`/`clarify` intercept ended the run
            // (`.endedBySurface`): build the matching terminal envelope
            // instead of falling through to `max_iterations_reached`.
            if exit == .endedBySurface, let intercept = interceptedExit {
                Self.persistInference(
                    pluginId: pid,
                    agentId: prep.agentId,
                    externalSessionKey: prep.enriched.request.session_id,
                    finalMessages: messages,
                    model: prep.enriched.request.model
                )
                if intercept.tool == "clarify" {
                    // The headless loop cannot pause for input; surface the
                    // question so the plugin can ask its user and follow up.
                    return Self.jsonString([
                        "error": "clarify_requested",
                        "message":
                            "The model paused to ask a clarifying question; answer it in a follow-up request.",
                        "question": ClarifyTool.parse(argumentsJSON: intercept.args)?.question ?? "",
                        "tool_calls_executed": toolCallsExecuted,
                        "shared_artifacts": sharedArtifacts,
                    ])
                }
                // `complete`: synthesize a normal chat-completion response
                // whose content is the model's verified summary.
                let summary = CompleteTool.parseSummary(from: intercept.args) ?? "Task completed."
                let synthesized = ChatCompletionResponse(
                    id: "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))",
                    created: Int(Date().timeIntervalSince1970),
                    model: prep.enriched.request.model,
                    choices: [
                        ChatChoice(
                            index: 0,
                            message: ChatMessage(role: "assistant", content: summary),
                            finish_reason: "stop"
                        )
                    ],
                    usage: Usage(prompt_tokens: 0, completion_tokens: 0, total_tokens: 0)
                )
                guard let encoded = try? JSONEncoder.osaurusCanonical().encode(synthesized),
                    var json = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
                else {
                    return Self.jsonString([
                        "error": "serialization_error", "message": "Failed to serialize response",
                    ])
                }
                if !toolCallsExecuted.isEmpty { json["tool_calls_executed"] = toolCallsExecuted }
                if !sharedArtifacts.isEmpty { json["shared_artifacts"] = sharedArtifacts }
                return Self.jsonString(json)
            }

            guard exit == .finalResponse, let response = finalResponse,
                let choice = response.choices.first
            else {
                // Driver-owned iteration cap (same taxonomy as HTTP): the
                // final iteration's tool calls executed, but the model
                // never produced a final text answer. Surface what ran so
                // the plugin isn't left with an opaque error.
                return Self.jsonString([
                    "error": "max_iterations_reached",
                    "message": "Reached max iterations (\(prep.options.maxIterations)) without a final response",
                    "tool_calls_executed": toolCallsExecuted,
                    "shared_artifacts": sharedArtifacts,
                ])
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

            guard let encoded = try? JSONEncoder.osaurusCanonical().encode(response),
                var json = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
            else {
                return Self.jsonString([
                    "error": "serialization_error", "message": "Failed to serialize response",
                ])
            }
            if !toolCallsExecuted.isEmpty { json["tool_calls_executed"] = toolCallsExecuted }
            if !sharedArtifacts.isEmpty { json["shared_artifacts"] = sharedArtifacts }
            return Self.jsonString(json)
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
        // Warn once per plugin if the plugin passed a null chunk callback —
        // chunks would otherwise be silently dropped, which is almost
        // always a bug rather than intent.
        if onChunk == nil {
            Self.warnNullChunkCallbackOnce(pluginId: pluginId)
        }
        let pid = self.pluginId
        // Capture host-enforced agent scope on the calling thread before
        // crossing into `Self.blockingAsync` — TLS does not survive the
        // `Task.detached` hop. See `dispatch` for the full rationale.
        let activeAgent = Self.activeAgentId()
        nonisolated(unsafe) let userData = userData
        // Single weak capture used by every callback below. `nonisolated(unsafe)`
        // is the documented way to share a weak ref into `@Sendable` closures
        // when the captured object is itself `@unchecked Sendable` (which
        // PluginHostContext is).
        nonisolated(unsafe) weak var ctxRef = self
        let releaseSlot: @Sendable () -> Void = {
            ctxRef?.exitInflightInference()
        }
        // `unregisterStream` runs once at the end of the streaming work,
        // regardless of how it terminates.
        let unregisterStream: @Sendable (String?) -> Void = { streamId in
            if let id = streamId { ctxRef?.unregisterStream(id) }
        }
        // `isCancelled` is the cheap per-delta check the for-await loop calls.
        // Returns false when no stream id was supplied.
        let isCancelled: @Sendable (String?) -> Bool = { streamId in
            guard let id = streamId, let ctx = ctxRef else { return false }
            return ctx.isStreamCancelled(id)
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .completeStream)
        return Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "complete_stream")) {
            // Stream id is per-call: if the plugin supplied one in the
            // request, register it so a concurrent `complete_cancel` call
            // can flag the stream for cancellation. We treat it as opaque
            // — any non-empty string works, but a UUID is recommended.
            var streamId: String?
            defer {
                releaseSlot()
                unregisterStream(streamId)
                Self.endPluginActivity(activityId)
            }
            guard let (rawJSON, sanitized) = Self.parseRawRequest(requestJSON),
                let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: sanitized)
            else {
                return Self.jsonString([
                    "error": "invalid_request", "message": "Failed to parse chat completion request",
                ])
            }

            if let raw = rawJSON["stream_id"] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    streamId = trimmed
                    ctxRef?.registerStream(trimmed)
                }
            }

            // Agent scope is host-enforced — see `auditAgentScope`.
            Self.auditAgentScope(
                json: rawJSON,
                pluginId: pid,
                op: "complete_stream",
                activeAgent: activeAgent
            )

            let prep = await Self.prepareInference(
                request: request,
                rawJSON: rawJSON,
                pluginId: pid,
                activeAgentId: activeAgent
            )
            let cid = "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
            var messages = prep.enriched.request.messages
            var lastContent = ""
            var toolCallsExecuted: [[String: String]] = []
            var sharedArtifacts: [[String: Any]] = []
            // Frozen for the whole run (deferred-schema policy): the tool
            // schema never changes mid-run, even after `capabilities_load`.
            let toolSpecs = prep.enriched.tools
            // Per-invocation harness state (plugin completions are one-shot
            // across requests). Provides within-run dedupe + post-listing nudge.
            let taskState = AgentTaskState()
            // Run-scoped sticky compaction: trims stay monotonic across this
            // stream's iterations (KV-prefix-stable transcript).
            let compactionWatermark = CompactionWatermark()
            // Captured token-usage stats from the underlying inference layer
            // so the final stream result mirrors non-stream `complete`'s
            // usage block, and so the last `usage` delta the plugin sees
            // is also reflected in the aggregated return value.
            var lastUsage: [String: Any]?

            let emit: ([String: Any]) -> Void = { payload in
                Self.emitChunk(payload, callback: onChunk, userData: userData)
            }

            // Terminal envelope stashed by the modelStep hook (natural finish,
            // mid-stream cancellation, last-iteration tool call). When set,
            // the driver exits `.finalResponse` and we return it verbatim.
            var terminalEnvelope: String?

            // Persist whatever we have so far — shared by every terminal path.
            let persistPartial: (String) -> Void = { assistantContent in
                Self.persistStreamingInference(
                    pluginId: pid,
                    agentId: prep.agentId,
                    externalSessionKey: prep.enriched.request.session_id,
                    priorMessages: messages,
                    assistantContent: assistantContent,
                    model: prep.enriched.request.model
                )
            }
            let maxIterationsEnvelope: () -> String = {
                Self.jsonString([
                    "error": "max_iterations_reached",
                    "message":
                        "Plugin streaming completion exhausted \(prep.options.maxIterations) iterations without converging on a final answer.",
                    "partial_content": lastContent,
                    "tool_calls_executed": toolCallsExecuted,
                    "shared_artifacts": sharedArtifacts,
                    "model": prep.enriched.request.model,
                    "id": cid,
                ])
            }

            // Canonical loop skeleton lives in `AgentToolLoop`; these hooks
            // carry the streaming plugin host's specifics — chunk emission,
            // budget-managed trimming, cancellation via `complete_cancel`,
            // and `processToolCall` post-processing.
            let hooks = AgentLoopHooks(
                isCancelled: { isCancelled(streamId) },
                buildMessages: { notices in
                    // Canonical notice contract (shared with chat/HTTP):
                    // trim with the system prefix kept byte-stable, then
                    // append driver-staged notices TRANSIENTLY — they ride
                    // exactly one iteration and never persist into
                    // `messages`.
                    AgentLoopBudget.composeIterationMessages(
                        messages,
                        notices: notices,
                        manager: prep.budgetManager,
                        watermark: compactionWatermark
                    )
                },
                modelStep: { effective, _ in
                    let iterReq = Self.iterationRequest(
                        from: prep.enriched.request,
                        messages: effective,
                        tools: toolSpecs
                    )
                    do {
                        let stream = try await prep.engine.streamChat(request: iterReq)
                        var iterContent = ""
                        var iterFinishReason = "stop"

                        for try await delta in stream {
                            // Cancellation check: plugin called `complete_cancel`
                            // with our stream id. Emit a final chunk with
                            // `finish_reason: "cancelled"` and stash the
                            // cancelled envelope as the terminal result.
                            if isCancelled(streamId) {
                                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "cancelled"))
                                persistPartial(lastContent)
                                terminalEnvelope = Self.cancelledStreamEnvelope(
                                    id: cid,
                                    streamId: streamId,
                                    model: prep.enriched.request.model,
                                    partialContent: lastContent,
                                    toolCallsExecuted: toolCallsExecuted,
                                    sharedArtifacts: sharedArtifacts,
                                    usage: lastUsage
                                )
                                return .finalResponse
                            }
                            // Reasoning and stats sentinels must be decoded
                            // BEFORE the generic `isSentinel` filter, otherwise
                            // these payloads get dropped together with tool
                            // hints and the plugin loses both reasoning text
                            // and token-usage metering.
                            if let reasoning = StreamingReasoningHint.decode(delta) {
                                emit(Self.chunkPayload(id: cid, delta: ["reasoning_content": reasoning]))
                                continue
                            }
                            if let stats = StreamingStatsHint.decode(delta) {
                                // Forward usage to the plugin as an OpenAI-style
                                // usage delta and remember it for the aggregated
                                // return so non-stream and stream paths surface
                                // the same metering shape.
                                if let stopReason = stats.stopReason {
                                    iterFinishReason = stopReason
                                }
                                let usage: [String: Any] = [
                                    "completion_tokens": stats.tokenCount,
                                    "tokens_per_second": stats.tokensPerSecond,
                                    "unclosed_reasoning": stats.unclosedReasoning,
                                ]
                                lastUsage = usage
                                emit(Self.chunkPayload(id: cid, delta: ["usage": usage]))
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
                        emit(Self.chunkPayload(id: cid, delta: [:], finishReason: iterFinishReason))
                        persistPartial("")
                        terminalEnvelope = Self.buildStreamResult(
                            id: cid,
                            model: prep.enriched.request.model,
                            content: lastContent,
                            toolCallsExecuted: toolCallsExecuted,
                            sharedArtifacts: sharedArtifacts,
                            usage: lastUsage,
                            finishReason: iterFinishReason
                        )
                        return .finalResponse

                    } catch let invs as ServiceToolInvocations {
                        // The iteration cap is owned by the DRIVER (same
                        // taxonomy as the HTTP surface): the final
                        // iteration's calls still execute, then the loop
                        // exits `.iterationCapReached` and the terminal
                        // handler below emits the honest stop chunk.
                        return .toolCalls(invs.invocations)

                    } catch let inv as ServiceToolInvocation {
                        return .toolCalls([inv])
                    }
                },
                willProcessCall: { inv, callId in
                    // Surface the tool call to the plugin before the dedupe
                    // check, exactly as the historical batch processor did.
                    let tcDelta: [String: Any] = [
                        "tool_calls": [
                            [
                                "id": callId,
                                "function": ["name": inv.toolName, "arguments": inv.jsonArguments],
                            ]
                        ]
                    ]
                    emit(Self.chunkPayload(id: cid, delta: tcDelta, finishReason: "tool_calls"))
                },
                onDedupedResult: { inv, callId, held in
                    // Dedupe a still-fresh re-read: replay the exact held
                    // envelope instead of re-running the read. Still pair an
                    // assistant tool_call message with the tool result so
                    // history stays valid.
                    emit(
                        Self.chunkPayload(
                            id: cid,
                            delta: ["role": "tool", "tool_call_id": callId, "content": held]
                        )
                    )
                    messages.append(
                        ChatMessage(
                            role: "assistant",
                            content: lastContent.isEmpty ? nil : lastContent,
                            tool_calls: [
                                ToolCall(
                                    id: callId,
                                    type: "function",
                                    function: ToolCallFunction(
                                        name: inv.toolName,
                                        arguments: inv.jsonArguments
                                    )
                                )
                            ],
                            tool_call_id: nil
                        )
                    )
                    messages.append(
                        ChatMessage(role: "tool", content: held, tool_calls: nil, tool_call_id: callId)
                    )
                    lastContent = ""
                },
                executeTool: { inv, callId in
                    let processed = await Self.processToolCall(
                        toolName: inv.toolName,
                        argumentsJSON: inv.jsonArguments,
                        callId: callId,
                        priorAssistantContent: lastContent,
                        prep: prep
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
                    // Only the FIRST invocation in the batch consumes the
                    // streamed assistant prose — subsequent calls in the same
                    // completion share the same response, so we clear
                    // lastContent after the first tool to avoid duplicating
                    // prose into every assistant tool-call message.
                    lastContent = ""
                    // Agent-loop intercepts: a successful `complete`/`clarify`
                    // ends the run cleanly (`endRun` → `.endedBySurface`)
                    // instead of riding to the iteration cap. Stream the
                    // parsed summary/question as final content and stage the
                    // terminal envelope the post-loop handler returns.
                    if AgentToolLoop.isSuccessfulIntercept(
                        toolName: inv.toolName,
                        result: processed.result
                    ) {
                        let isComplete = inv.toolName == "complete"
                        let text =
                            isComplete
                            ? (CompleteTool.parseSummary(from: inv.jsonArguments) ?? "Task completed.")
                            : (ClarifyTool.parse(argumentsJSON: inv.jsonArguments)?.question ?? "")
                        if !text.isEmpty {
                            emit(Self.chunkPayload(id: cid, delta: ["content": text]))
                        }
                        let finishReason = isComplete ? "stop" : "clarify"
                        emit(Self.chunkPayload(id: cid, delta: [:], finishReason: finishReason))
                        persistPartial(text)
                        terminalEnvelope = Self.buildStreamResult(
                            id: cid,
                            model: prep.enriched.request.model,
                            content: text,
                            toolCallsExecuted: toolCallsExecuted,
                            sharedArtifacts: sharedArtifacts,
                            usage: lastUsage,
                            finishReason: finishReason
                        )
                        return AgentLoopToolExecution(result: processed.result, endRun: true)
                    }
                    return AgentLoopToolExecution(result: processed.result)
                }
            )

            let exit: AgentToolLoop.Exit
            do {
                let runResult = try await AgentToolLoop.run(
                    policy: AgentLoopPolicy(
                        maxIterations: prep.options.maxIterations,
                        stopOnToolRejection: false,
                        dedupeNoticeEnabled: false,
                        maxDataMovementSteps: min(16, prep.options.maxIterations)
                    ),
                    state: taskState,
                    hooks: hooks
                )
                exit = runResult.exit
            } catch {
                return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
            }

            if exit == .overBudget {
                // Even fully-compacted history can't fit the window — the
                // driver ended the run before sending a doomed request.
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "context_overflow"))
                persistPartial(lastContent)
                return Self.jsonString([
                    "error": "context_overflow",
                    "message": AgentToolLoop.overBudgetMessage,
                    "tool_calls_executed": toolCallsExecuted,
                    "shared_artifacts": sharedArtifacts,
                ])
            }
            if exit == .emptyResponseExhausted {
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "empty_response"))
                persistPartial(lastContent)
                return Self.jsonString([
                    "error": "empty_tool_task_completion",
                    "message": AgentToolLoop.emptyToolTaskFallback,
                    "tool_calls_executed": toolCallsExecuted,
                    "shared_artifacts": sharedArtifacts,
                ])
            }

            if exit == .cancelled {
                // Cancellation detected at an iteration boundary (between
                // tool calls) rather than mid-stream. Emit the same final
                // chunk and envelope the mid-stream path produces.
                emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "cancelled"))
                persistPartial(lastContent)
                return Self.cancelledStreamEnvelope(
                    id: cid,
                    streamId: streamId,
                    model: prep.enriched.request.model,
                    partialContent: lastContent,
                    toolCallsExecuted: toolCallsExecuted,
                    sharedArtifacts: sharedArtifacts,
                    usage: lastUsage
                )
            }

            if let envelope = terminalEnvelope {
                return envelope
            }

            // Iteration budget exhausted while the model was still requesting
            // tools (driver `.iterationCapReached`). Emit a finish chunk
            // that is honest about why we stopped, persist whatever we have
            // before returning so the user can still see the partial
            // conversation.
            emit(Self.chunkPayload(id: cid, delta: [:], finishReason: "max_iterations"))
            persistPartial(lastContent)
            return maxIterationsEnvelope()
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

    /// Execute one tool call, post-process the result, and produce the
    /// assistant + tool ChatMessages to append to the running history.
    /// The tool schema is intentionally NOT mutated here — see the
    /// deferred-schema policy in `postProcessToolResult`.
    private static func processToolCall(
        toolName: String,
        argumentsJSON: String,
        callId: String,
        priorAssistantContent: String,
        prep: PreparedInference
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
            prep: prep
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
        sharedArtifacts: [[String: Any]] = [],
        usage: [String: Any]? = nil,
        finishReason: String = "stop"
    ) -> String {
        var result: [String: Any] = [
            "id": id, "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": content],
                    "finish_reason": finishReason,
                ]
            ],
        ]
        if !toolCallsExecuted.isEmpty { result["tool_calls_executed"] = toolCallsExecuted }
        if !sharedArtifacts.isEmpty { result["shared_artifacts"] = sharedArtifacts }
        if let usage { result["usage"] = usage }
        return jsonString(result)
    }

    /// Cancelled-stream envelope returned from `completeStream` when the
    /// plugin invokes `complete_cancel(stream_id)` mid-stream. Mirrors the
    /// fields a normal stream return carries (model, id, partial content,
    /// usage, executed tool calls, shared artifacts) plus the stream id
    /// the plugin supplied so it can correlate the cancellation back to
    /// its own bookkeeping.
    private static func cancelledStreamEnvelope(
        id: String,
        streamId: String?,
        model: String,
        partialContent: String,
        toolCallsExecuted: [[String: String]],
        sharedArtifacts: [[String: Any]],
        usage: [String: Any]?
    ) -> String {
        jsonString([
            "error": "cancelled",
            "message": "Streaming completion cancelled by plugin via complete_cancel.",
            "id": id,
            "stream_id": streamId ?? "",
            "model": model,
            "partial_content": partialContent,
            "tool_calls_executed": toolCallsExecuted,
            "shared_artifacts": sharedArtifacts,
            "usage": usage ?? [:],
        ])
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
            let data = try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical),
            let str = String(data: data, encoding: .utf8)
        else { return }
        str.withCString { callback($0, userData) }
    }

    /// Emit a one-shot warning when a plugin passes a task id that does
    /// not parse as a UUID to a void-returning task op
    /// (`dispatch_cancel`, `send_draft`, `dispatch_interrupt`). The C ABI
    /// returns void so we can't surface an envelope; logging keeps the
    /// signal visible to plugin authors without flooding the unified log.
    static func warnInvalidTaskIdOnce(pluginId: String, op: String, taskId: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|\(op)|invalid",
            "[PluginHostAPI] Plugin '%@' called %@ with an invalid UUID '%@'. The call was a no-op. "
                + "This warning is logged once per plugin per op per process.",
            pluginId,
            op,
            taskId
        )
    }

    /// Emit a one-shot warning when a plugin passes a task id that parses
    /// as a UUID but does not belong to (or is no longer active for) the
    /// calling plugin. Catches stale ids and accidental cross-plugin
    /// reference.
    static func warnUnownedTaskOnce(pluginId: String, op: String, taskId: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|\(op)|unowned",
            "[PluginHostAPI] Plugin '%@' called %@ for task '%@' that does not belong to this plugin or "
                + "is no longer active. The call was a no-op. "
                + "This warning is logged once per plugin per op per process.",
            pluginId,
            op,
            taskId
        )
    }

    /// Emit a one-shot warning when `complete_stream` is invoked with a
    /// nil `on_chunk` callback. Streamed deltas would silently be dropped
    /// in this case; the aggregated return value still works, but plugin
    /// authors usually expect chunks to be delivered.
    static func warnNullChunkCallbackOnce(pluginId: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|complete_stream|null_chunk",
            "[PluginHostAPI] Plugin '%@' invoked complete_stream with a NULL on_chunk callback. "
                + "Streamed deltas will be discarded; the aggregated return value still flows. "
                + "Pass a callback if your plugin needs incremental output. "
                + "This warning is logged once per plugin per process.",
            pluginId
        )
    }

    /// Single audit pass for the agent-scope security boundary. Called
    /// from every agent-aware trampoline (`dispatch`, `complete`,
    /// `complete_stream`, `embed`) right after capturing the TLS active
    /// agent. Emits at most one warning per (plugin, op) per process for
    /// each of the two failure modes — caller-supplied agent override
    /// and missing TLS agent — keeping the call sites a single line.
    static func auditAgentScope(
        json: [String: Any],
        pluginId: String,
        op: String,
        activeAgent: UUID?
    ) {
        if let supplied = (json["agent_address"] as? String) ?? (json["agent_id"] as? String),
            !supplied.isEmpty
        {
            warnAgentOverrideOnce(pluginId: pluginId, op: op, supplied: supplied)
        }
        if activeAgent == nil {
            warnNoAgentContextOnce(pluginId: pluginId, op: op)
        }
    }

    /// One-shot warning when a plugin's `dispatch` JSON requests a tool
    /// name outside the plugin's allowed surface (own manifest tools or
    /// host built-in always-loaded names). The name is dropped from the
    /// dispatch's `requestedToolNames`; the rest of the dispatch
    /// proceeds normally. Public so tests can pin the dedup behaviour.
    static func warnDispatchToolScopeOnce(pluginId: String, name: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|dispatch|tool_scope|\(name)",
            "[PluginHostAPI] Plugin '%@' requested tool '%@' on dispatch but it is not in the allowed "
                + "set (own manifest tools or host built-ins). The name was dropped; the rest of the "
                + "dispatch proceeds. "
                + "This warning is logged once per (plugin, name) per process.",
            pluginId,
            name
        )
    }

    /// One-shot warning when a plugin supplies `agent_address` / `agent_id`
    /// to an agent-aware trampoline. The host ignores the override and runs
    /// under the TLS-resolved invoking agent; surfacing the attempt makes
    /// cross-agent dispatch attempts visible. Public so tests can pin it.
    static func warnAgentOverrideOnce(pluginId: String, op: String, supplied: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|\(op)|agent_override",
            "[PluginHostAPI] Plugin '%@' supplied an explicit agent identifier '%@' to %@. "
                + "The host ignores caller-supplied agent_address / agent_id on plugin trampolines "
                + "and runs the call under the agent that invoked the plugin. "
                + "This warning is logged once per plugin per op per process.",
            pluginId,
            supplied,
            op
        )
    }

    /// One-shot warning when an agent-aware trampoline is called from a
    /// thread with no TLS-bound active agent (typically a background
    /// worker the plugin spawned itself at init). The host falls back to
    /// `Agent.defaultId`; the plugin should originate the call from
    /// inside `invoke` / `handle_route` / `on_config_changed` /
    /// `on_task_event` so the agent context propagates.
    static func warnNoAgentContextOnce(pluginId: String, op: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|\(op)|no_agent_context",
            "[PluginHostAPI] Plugin '%@' called %@ from a thread with no resolvable agent context. "
                + "The host fell back to the default agent. Originate plugin calls from a thread that "
                + "carries the agent (inside invoke / handle_route / on_config_changed / on_task_event). "
                + "This warning is logged once per plugin per op per process.",
            pluginId,
            op
        )
    }

    /// Emit a one-shot warning when a plugin tries to store an
    /// oversized value via `config_set`. The C ABI is void-returning
    /// so the plugin author won't see the rejection otherwise.
    static func warnConfigValueTooLargeOnce(pluginId: String, key: String, size: Int) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|config_set|too_large|\(key)",
            "[PluginHostAPI] Plugin '%@' called config_set('%@', ...) with a %d-byte value, "
                + "exceeding the 1 MiB config-value cap. The write was dropped. Use db_exec / "
                + "db_query for larger payloads. This warning is logged once per plugin per key per process.",
            pluginId,
            key,
            size
        )
    }

    func embed(requestJSON: String) -> String {
        guard tryEnterInflightInference() else {
            return Self.pluginBusyJSON(kind: "embed")
        }
        let pid = self.pluginId
        // Capture host-enforced agent scope on the calling thread before
        // crossing into `Self.blockingAsync`. Embed currently uses no
        // per-agent overrides, but we still warn-on-override so the
        // boundary is consistent across all plugin trampolines.
        let activeAgent = Self.activeAgentId()
        let releaseSlot: @Sendable () -> Void = { [weak self] in
            self?.exitInflightInference()
        }
        let activityId = Self.beginPluginActivity(pluginId: pid, kind: .embed)
        return Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "embed")) {
            defer {
                releaseSlot()
                Self.endPluginActivity(activityId)
            }
            let data = Data(requestJSON.utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Self.jsonString(["error": "invalid_request", "message": "Failed to parse embedding request"])
            }

            // Agent scope is host-enforced — see `auditAgentScope`.
            Self.auditAgentScope(json: json, pluginId: pid, op: "embed", activeAgent: activeAgent)

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
                let tokenEstimate = texts.reduce(0) { $0 + TokenEstimator.estimate($1) }
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
        Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "list_models")) {
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

        // Per-(plugin, agent) HTTP token bucket. Caps the host-side
        // outbound traffic a single plugin can emit; mirrors the
        // dispatch limiter's shape. Plugins that need higher
        // throughput should batch upstream or backoff on
        // `rate_limit_exceeded` like any other API client.
        //
        // Anonymous plugin traffic (no chat-bound agent) buckets against a
        // synthetic sentinel UUID — not `Agent.defaultId` — so its quota
        // is distinct from the Default agent's and the built-in agent's
        // identity isn't reused as a fairness key.
        let rateLimitAgentId = resolvedAgentIdOrNil ?? Self.anonymousPluginRateBucketId
        guard checkHttpRateLimit(agentId: rateLimitAgentId) else {
            return Self.jsonString([
                "error": "rate_limit_exceeded",
                "message":
                    "http_request rate limit (\(Self.httpRateLimit)/\(Int(Self.httpRateWindow))s) "
                    + "exceeded for this plugin and agent.",
                "retry_after_ms": Int(Self.httpRateWindow * 1000),
            ])
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

        let finalRequest = request

        return Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "http_request")) {
            let startTime = Date()
            do {
                var currentRequest = finalRequest
                var redirectCount = 0

                while true {
                    let (responseData, urlResponse) = try await Self.noRedirectSession().data(for: currentRequest)
                    let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

                    guard let httpResponse = urlResponse as? HTTPURLResponse else {
                        return Self.jsonString([
                            "error": "invalid_response", "message": "Non-HTTP response", "elapsed_ms": elapsed,
                        ])
                    }

                    if followRedirects {
                        let redirect = Self.checkedHTTPRedirectRequest(from: currentRequest, response: httpResponse)
                        if let ssrfError = redirect.ssrfError {
                            return Self.jsonString([
                                "error": "ssrf_blocked", "message": ssrfError, "elapsed_ms": elapsed,
                            ])
                        }
                        if let nextRequest = redirect.request {
                            redirectCount += 1
                            guard redirectCount <= Self.maxHTTPRedirects else {
                                return Self.jsonString([
                                    "error": "too_many_redirects",
                                    "message": "HTTP redirect limit exceeded",
                                    "elapsed_ms": elapsed,
                                ])
                            }
                            currentRequest = nextRequest
                            continue
                        }
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
                }
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
                // v6 surface — frozen layout. Two trampoline slots
                // (`dispatch_clarify`, `dispatch_add_issue`) remain wired
                // for ABI compat but return structured `not_supported` JSON.
                // `get_active_agent_id` (v4) lets plugins key per-agent
                // state without caching across callbacks. `log_structured`
                // (v5) attaches searchable JSON fields to log entries.
                // `free_string` (v6) is the host-controlled `free()`
                // pair for every host-returned `const char*` — added so
                // plugins don't accidentally route host-allocated
                // pointers through their own `free_string` callback,
                // which can corrupt the heap if it isn't plain `free`.
                version: 6,
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
                dispatch_add_issue: PluginHostContext.trampolineDispatchAddIssue,
                complete_cancel: PluginHostContext.trampolineCompleteCancel,
                get_active_agent_id: PluginHostContext.trampolineGetActiveAgentId,
                log_structured: PluginHostContext.trampolineLogStructured,
                free_string: PluginHostContext.trampolineHostFreeString
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
    /// Sliding-window check: returns true and records `now` if there
    /// are fewer than `limit` recorded timestamps inside `window`,
    /// false otherwise. The timestamp array is rewritten in place
    /// under `rateLimitLock` (already held by the caller), so this is
    /// a pure helper — both `checkDispatchRateLimit` and
    /// `checkHttpRateLimit` route through it to keep their semantics
    /// in lockstep.
    private func consumeSlidingWindow(
        timestamps: inout [Date],
        limit: Int,
        window: TimeInterval
    ) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)
        timestamps.removeAll { $0 < cutoff }
        guard timestamps.count < limit else { return false }
        timestamps.append(now)
        return true
    }

    /// Returns true if the dispatch is allowed under the per-agent rate limit.
    func checkDispatchRateLimit(agentId: UUID) -> Bool {
        rateLimitLock.withLock {
            var timestamps = dispatchTimestamps[agentId, default: []]
            let allowed = consumeSlidingWindow(
                timestamps: &timestamps,
                limit: Self.dispatchRateLimit,
                window: Self.dispatchRateWindow
            )
            dispatchTimestamps[agentId] = timestamps
            return allowed
        }
    }

    /// Returns true if an `http_request` call from the current
    /// `(plugin, agent)` is under the sliding-window rate limit.
    /// Sharing the same `rateLimitLock` as dispatch keeps both
    /// counters consistent under concurrency without adding another
    /// lock.
    func checkHttpRateLimit(agentId: UUID) -> Bool {
        rateLimitLock.withLock {
            var timestamps = httpTimestamps[agentId, default: []]
            let allowed = consumeSlidingWindow(
                timestamps: &timestamps,
                limit: Self.httpRateLimit,
                window: Self.httpRateWindow
            )
            httpTimestamps[agentId] = timestamps
            return allowed
        }
    }
}

// MARK: - SSRF Protection

extension PluginHostContext {
    /// Returns an error message if the URL targets a private / loopback /
    /// link-local / IPv6-mapped-private address, nil if safe.
    ///
    /// **Known limitation:** this check operates on the URL string only —
    /// it does NOT resolve the hostname before deciding. A hostname that
    /// looks public (`evil.example.com`) but resolves to a private IP at
    /// connection time (DNS rebinding, attacker-controlled DNS, internal
    /// CNAME) WILL pass this check and the host will issue the request.
    /// Mitigating that requires a custom URLSession delegate that
    /// inspects the resolved IP at the network-layer (see
    /// `URLSessionDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
    /// + a `Network.framework` resolution step). Tracked separately;
    /// document it under HOST_API.md so plugin authors don't assume
    /// SSRF is end-to-end.
    static func checkSSRF(url: URL) -> String? {
        guard let rawHost = url.host?.lowercased() else { return "Missing host" }
        // URL.host strips the surrounding `[` `]` for IPv6 literals,
        // but be defensive in case a future call site passes them in.
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if host == "localhost" || host == "ip6-localhost" || host == "ip6-loopback" {
            return ssrfBlocked("localhost")
        }

        // IPv6 literal handling. URL.host returns the bracket-stripped
        // form (`::1`, `fe80::1`, `::ffff:127.0.0.1`). We catch the
        // common loopback / link-local / unique-local prefixes, plus
        // IPv4-mapped (`::ffff:a.b.c.d`) and IPv4-compatible (`::a.b.c.d`)
        // forms that point at private IPv4 space — those are the
        // common SSRF bypass tricks against an IPv4-only blocklist.
        if host.contains(":") {
            if host == "::1" { return ssrfBlocked("loopback IPv6") }
            if host == "::" { return ssrfBlocked("unspecified IPv6") }
            if host.hasPrefix("fe80:") { return ssrfBlocked("link-local IPv6") }
            // Unique local (RFC 4193: fc00::/7 — fc00–fdff). We're
            // already inside the `host.contains(":")` IPv6 branch, so
            // an `fc`/`fd` prefix is unambiguously the literal — a
            // hostname like `fcc.gov` would have been routed to the
            // IPv4 branch above (no colon).
            if host.hasPrefix("fc") || host.hasPrefix("fd") {
                return ssrfBlocked("unique-local IPv6")
            }
            // IPv4-mapped (`::ffff:a.b.c.d`) and IPv4-compatible (`::a.b.c.d`):
            // extract the trailing IPv4 dotted-quad and re-run the IPv4 check.
            if let v4 = embeddedIPv4(in: host),
                let blocked = ssrfBlockedIPv4(v4)
            {
                return ssrfBlocked("IPv6-mapped \(blocked)")
            }
            // Any other IPv6 literal we didn't recognize — out of scope
            // for the IPv4-centric blocklist.
            return nil
        }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        if let blocked = ssrfBlockedIPv4(octets) {
            return ssrfBlocked(blocked)
        }
        return nil
    }

    /// Pulls the trailing dotted-quad out of an IPv6 literal that
    /// embeds an IPv4 address (`::ffff:127.0.0.1` or `::127.0.0.1`).
    /// Returns the four-octet form so the IPv4 blocklist can run.
    private static func embeddedIPv4(in host: String) -> [UInt8]? {
        guard let lastColon = host.lastIndex(of: ":") else { return nil }
        let tail = String(host[host.index(after: lastColon)...])
        let octets = tail.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets
    }

    /// Returns the human-readable block reason for a given IPv4
    /// dotted-quad, or nil when the address is public-routable. Pulled
    /// out so the IPv6-mapped path can reuse the same blocklist.
    private static func ssrfBlockedIPv4(_ octets: [UInt8]) -> String? {
        guard octets.count == 4 else { return nil }
        let (a, b) = (octets[0], octets[1])
        let dotted = "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
        if a == 127 { return "IPv4 loopback (\(dotted))" }
        if a == 10 { return "RFC1918 10.0.0.0/8 (\(dotted))" }
        if a == 172 && b >= 16 && b <= 31 { return "RFC1918 172.16.0.0/12 (\(dotted))" }
        if a == 192 && b == 168 { return "RFC1918 192.168.0.0/16 (\(dotted))" }
        if a == 0 { return "RFC1122 \"this network\" 0.0.0.0/8 (\(dotted))" }
        if a == 169 && b == 254 {
            // 169.254.169.254 is the AWS / GCP / Azure / DO instance
            // metadata IP. The whole 169.254/16 link-local range is
            // already blocked, but call it out so the message is
            // diagnosable.
            return "link-local 169.254.0.0/16 (cloud metadata, \(dotted))"
        }
        if a == 100 && b >= 64 && b <= 127 { return "carrier-grade NAT 100.64.0.0/10 (\(dotted))" }
        if a >= 224 && a <= 239 { return "multicast 224.0.0.0/4 (\(dotted))" }
        return nil
    }

    private static func ssrfBlocked(_ target: String) -> String {
        "Requests to \(target) are blocked (SSRF protection)"
    }

    static func checkedHTTPRedirectRequest(
        from request: URLRequest,
        response: HTTPURLResponse
    ) -> (request: URLRequest?, ssrfError: String?) {
        guard (300 ... 399).contains(response.statusCode),
            let location = redirectLocation(from: response),
            let baseURL = response.url ?? request.url,
            let redirectURL = URL(string: location, relativeTo: baseURL)?.absoluteURL
        else {
            return (nil, nil)
        }

        if let ssrfError = checkSSRF(url: redirectURL) {
            return (nil, ssrfError)
        }

        var redirected = request
        redirected.url = redirectURL
        normalizeRedirectMethod(on: &redirected, originalRequest: request, statusCode: response.statusCode)
        stripCrossOriginCredentials(on: &redirected, originalURL: request.url, redirectURL: redirectURL)
        return (redirected, nil)
    }

    /// Extracts `Location` without depending on Foundation's header
    /// key casing. Some local test responses use lowercase while
    /// remote servers commonly title-case it.
    private static func redirectLocation(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "location" else { continue }
            return String(describing: value)
        }
        return nil
    }

    /// Matches normal user-agent redirect semantics for unsafe
    /// methods: 301/302/303 drop the request body and become GET,
    /// while 307/308 preserve method and body.
    private static func normalizeRedirectMethod(
        on request: inout URLRequest,
        originalRequest: URLRequest,
        statusCode: Int
    ) {
        let method = originalRequest.httpMethod?.uppercased()
        guard [301, 302, 303].contains(statusCode), method != "GET", method != "HEAD" else { return }
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue(nil, forHTTPHeaderField: "Content-Length")
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
    }

    /// Cross-origin redirects should not carry credentials intended
    /// for the original host. `URLSession` does this for automatic
    /// redirects; manual redirect following has to preserve it here.
    private static func stripCrossOriginCredentials(
        on request: inout URLRequest,
        originalURL: URL?,
        redirectURL: URL
    ) {
        guard originFingerprint(originalURL) != originFingerprint(redirectURL) else { return }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
    }

    private static func originFingerprint(_ url: URL?) -> String? {
        guard let url,
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased()
        else {
            return nil
        }
        return "\(scheme)://\(host):\(normalizedPort(for: url, scheme: scheme))"
    }

    private static func normalizedPort(for url: URL, scheme: String) -> Int {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return -1
        }
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
        case .running, .awaitingClarification:
            // v3: chat tasks always serialize as "running". The
            // `.awaitingClarification` enum case is still used internally
            // for UI hints (toast, notch) but never exposed via task_status,
            // because clarification is handled inline through the `clarify`
            // agent intercept rather than as an out-of-band state.
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

    /// Serialize the payload for `OSR_TASK_EVENT_CLARIFICATION` (type 3).
    /// Emitted when the agent calls the inline `clarify` tool to pause for
    /// a user response. `options` is omitted entirely when empty so plugins
    /// can use key-presence as the "free-form vs choice" signal.
    @MainActor
    static func serializeClarificationEvent(payload: ClarifyPayload) -> String {
        var dict: [String: Any] = [
            "question": payload.question,
            "allow_multiple": payload.allowMultiple,
        ]
        if !payload.options.isEmpty {
            dict["options"] = payload.options
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

/// Thread-safe box for passing a result out of a Task closure in Swift 6
/// strict concurrency. Self-synchronizing via an internal lock so it doesn't
/// silently depend on an external semaphore as its only memory barrier — the
/// write happens on the bridge queue, the read on the parked trampoline
/// thread, so the lock makes the cross-thread handoff explicit and correct.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    func set(_ newValue: T) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
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
    ///
    /// Bounded: `sem.wait` carries a deadline so a wedged inner `Task`
    /// (cooperative-pool starvation, an inner `await` that never resumes,
    /// a hung downstream) can NOT hang the plugin worker thread forever.
    /// On timeout we cancel the inner work and return `fallback` instead of
    /// force-unwrapping a value that was never produced (the old `box.value!`
    /// could trap). The default ceiling is intentionally generous (30 min)
    /// so it never trips a legitimate long completion / embed, only a true
    /// deadlock; callers may shorten it.
    static func blockingAsync<T: Sendable>(
        timeout: DispatchTime = .now() + 1800,
        fallback: @autoclosure @escaping () -> T,
        _ work: @escaping @Sendable () async -> T
    ) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached(priority: .userInitiated) {
            let value = await work()
            blockingBridgeQueue.async {
                box.set(value)
                sem.signal()
            }
        }
        guard sem.wait(timeout: timeout) == .success else {
            task.cancel()
            NSLog("[PluginHostAPI] blockingAsync timed out — cancelling inner work, returning fallback")
            return fallback()
        }
        return box.get() ?? fallback()
    }

    /// Block the current (non-main) thread while running @MainActor work.
    ///
    /// Bounded for the same reason as `blockingAsync`, but with a much
    /// shorter default deadline: the wrapped work is a quick MainActor hop
    /// (read task state, toggle a flag). The deadline is also the backstop
    /// for the load-time first-delivery path — if a plugin's
    /// `on_config_changed` calls a `blockingMainActor` host API while the
    /// main thread is parked in `ExternalPlugin.notifyConfigBatchSync`'s
    /// `configEventQueue.sync`, the wait can't acquire main; the timeout
    /// converts that would-be permanent deadlock into a bounded return.
    @discardableResult
    static func blockingMainActor<T: Sendable>(
        timeout: DispatchTime = .now() + 30,
        fallback: @autoclosure @escaping () -> T,
        _ work: @MainActor @escaping @Sendable () -> T
    ) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached(priority: .userInitiated) { @MainActor in
            let value = work()
            blockingBridgeQueue.async {
                box.set(value)
                sem.signal()
            }
        }
        guard sem.wait(timeout: timeout) == .success else {
            task.cancel()
            NSLog("[PluginHostAPI] blockingMainActor timed out — cancelling inner work, returning fallback")
            return fallback()
        }
        return box.get() ?? fallback()
    }

    /// Canonical error envelope returned when a host bridge times out, so a
    /// plugin sees a structured failure instead of an opaque empty string.
    static func pluginHostTimeoutJSON(kind: String) -> String {
        jsonString([
            "error": "host_timeout",
            "message": "Host \(kind) call exceeded its time budget and was cancelled.",
        ])
    }

    /// Serialize a dictionary to a JSON string. Falls back to "{}" on encoding failure.
    /// Uses canonical (sorted-keys) output so plugin-side prompt prefixes and
    /// chunk payloads stay byte-stable across calls.
    static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical)
        else { return "{}" }
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
///    the primary and fully concurrent-safe mechanism, and the recommended
///    path for all plugin-initiated host calls.
/// 2. `lastDispatchedPluginId` — best-effort global fallback for background
///    threads that plugins spawn (e.g. `DispatchQueue.global().async`). The
///    value is protected by a lock so reads/writes are race-free, but the
///    *value itself* is the most-recently-dispatched plugin id, which is
///    racy when multiple plugins run simultaneously. The first time this
///    fallback resolves a context for a given plugin, the host emits a
///    one-shot warning so the plugin developer learns to do their own work
///    on a context-carrying thread (e.g. by capturing the host API pointer
///    on the dispatch thread and calling back from there).
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

    /// Run `body` with the plugin TLS slots set to `pluginId` and
    /// `agentId`, then clear them on exit (success or throw). Collapses
    /// the set / defer-clear pattern repeated by `dispatchPluginCall`,
    /// `notifyConfigBatch`, and `notifyTaskEvent` in `ExternalPlugin`.
    static func withTLSScope<R>(pluginId: String, agentId: UUID?, _ body: () -> R) -> R {
        setActivePlugin(pluginId)
        if let agentId { setActiveAgent(agentId) }
        defer {
            clearActivePlugin()
            clearActiveAgent()
        }
        return body()
    }

    private static func activeContext() -> PluginHostContext? {
        if let pluginId = Thread.current.threadDictionary[tlsKey] as? String {
            return getContext(for: pluginId)
        }
        if let pluginId = lastDispatchedPluginId {
            warnFallbackOnce(pluginId: pluginId)
            return getContext(for: pluginId)
        }
        return currentContext
    }

    /// Emit a one-shot deprecation-style warning per plugin when a host
    /// callback resolves via the racy `lastDispatchedPluginId` fallback.
    /// Plugin authors should structure their code so host calls happen on
    /// a thread that has TLS set (e.g. inside the original `invoke` /
    /// `handle_route` call frame, or via `DispatchQueue.async` that
    /// captures the host pointer rather than relying on the global).
    private static func warnFallbackOnce(pluginId: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|fallback_context",
            "[PluginHostAPI] Plugin '%@' resolved a host context via the global "
                + "lastDispatchedPluginId fallback. This path is racy across plugins; "
                + "perform host API calls on a thread that carries the plugin context "
                + "(e.g. inside invoke / handle_route, or by capturing the host API "
                + "pointer on the dispatching thread). This warning is logged once "
                + "per plugin per process.",
            pluginId
        )
    }

    /// Structured JSON envelope returned by trampolines when no plugin
    /// context can be resolved for the calling thread. Replaces the older
    /// silent `nil` return so plugin developers see the failure in
    /// Insights and can recover programmatically (parse the `error` key).
    static let contextUnavailableJSON: String =
        #"{"error":"context_unavailable","message":"Plugin host API was called from a thread with no resolvable plugin context. This typically indicates the call originated from a background thread the host did not register; reconsider using thread-local context or call from an invokeQueue/eventQueue thread."}"#

    /// Allocates a fresh NUL-terminated C string the plugin owns and
    /// must free via `host->free_string` (v6+) or `libc free()`.
    ///
    /// We deliberately bounce through `withCString` instead of letting
    /// the compiler implicitly bridge `String → UnsafePointer<CChar>!`
    /// for `strdup`. The implicit bridge can route through NSString /
    /// the bridged buffer pool, and there are subtle interactions
    /// with autorelease and concurrent invocation that produced a
    /// `pointer being freed was not allocated` malloc abort in
    /// production when the plugin freed the returned pointer from a
    /// `@convention(c)` callback frame. The explicit pattern below
    /// guarantees:
    ///   1. `cStrPtr` is a stable, valid C-string pointer for the
    ///      duration of the `strdup` call (UTF-8 contiguous).
    ///   2. `strdup` runs against libc directly with no Foundation
    ///      bridging, returning a freshly malloc'd buffer.
    ///   3. The returned pointer is independent of any temporary
    ///      buffer the bridging step might have used, so the plugin
    ///      can free it from any thread / autorelease frame.
    /// `nil` only when `strdup` itself fails (process-wide OOM).
    private static func makeCString(_ str: String) -> UnsafePointer<CChar>? {
        str.withCString { cStrPtr -> UnsafePointer<CChar>? in
            guard let copy = Darwin.strdup(cStrPtr) else { return nil }
            return UnsafePointer(copy)
        }
    }

    /// Resolves the active plugin context for a JSON-returning trampoline
    /// that takes one `request_json` C string argument. Returns NULL when
    /// the plugin passed a NULL pointer (nothing to work on), and the
    /// `context_unavailable` envelope when the host can't find a plugin
    /// context for the current thread. Otherwise calls `body` with the
    /// resolved context and decoded request string.
    private static func withActiveContext(
        requestPtr: UnsafePointer<CChar>?,
        _ body: (_ ctx: PluginHostContext, _ json: String) -> UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>? {
        guard let requestPtr else { return nil }
        guard let ctx = activeContext() else {
            return makeCString(contextUnavailableJSON)
        }
        return body(ctx, String(cString: requestPtr))
    }

    /// Same as `withActiveContext(requestPtr:_:)` but for trampolines that
    /// take no arguments (e.g. `list_models`, `list_active_tasks`).
    private static func withActiveContext(
        _ body: (_ ctx: PluginHostContext) -> UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>? {
        guard let ctx = activeContext() else {
            return makeCString(contextUnavailableJSON)
        }
        return body(ctx)
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

    /// Maps a top-level `error` code in a host response envelope to the
    /// closest HTTP status for Insights/observability. Returns nil if the
    /// response does not contain a string-typed `error` key — used as the
    /// "is this response an error?" predicate everywhere we record status.
    private static func errorStatusCode(for json: String) -> Int? {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = obj["error"] as? String
        else { return nil }
        switch code {
        case "invalid_request", "invalid_task_id":
            return 400
        case "unauthorized", "consent_required":
            return 401
        case "forbidden", "access_denied":
            return 403
        case "not_found":
            return 404
        case "rate_limit_exceeded", "plugin_busy", "task_limit_reached":
            return 429
        case "not_supported":
            return 501
        case "context_unavailable", "max_iterations_reached":
            return 500
        default:
            return 500
        }
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

    // MARK: Agent Context Introspection (v4)

    /// Returns the TLS-resolved active agent UUID as a heap-allocated
    /// C string the plugin owns (free with `free_string`), or NULL when
    /// no agent context is bound to the calling thread (init, plugin-
    /// spawned background work). One-line trampoline against the
    /// existing TLS getter — no new lookup machinery, no race surface
    /// beyond what `activeAgentId()` already has.
    static let trampolineGetActiveAgentId: osr_get_active_agent_id_t = {
        guard let agentId = activeAgentId() else { return nil }
        return makeCString(agentId.uuidString)
    }

    // MARK: Database Trampolines

    static let trampolineDbExec: osr_db_exec_t = { sqlPtr, paramsPtr in
        withActiveContext(requestPtr: sqlPtr) { ctx, sql in
            let params = paramsPtr.map { String(cString: $0) }
            return makeCString(ctx.dbExec(sql: sql, paramsJSON: params))
        }
    }

    static let trampolineDbQuery: osr_db_query_t = { sqlPtr, paramsPtr in
        withActiveContext(requestPtr: sqlPtr) { ctx, sql in
            let params = paramsPtr.map { String(cString: $0) }
            return makeCString(ctx.dbQuery(sql: sql, paramsJSON: params))
        }
    }

    // MARK: Logging Trampoline

    /// Maps the integer log level to the human-readable label and the
    /// synthetic HTTP status used by Insights filters. Levels mirror
    /// the documented contract in `osaurus_plugin.h`:
    /// `0=trace, 1=debug, 2=info, 3=warn, 4=error`. Shared between
    /// `trampolineLog` and `trampolineLogStructured` so the two log
    /// sources stay consistent in the dashboard.
    static func levelMetadata(for level: Int32) -> (name: String, statusCode: Int) {
        switch level {
        case 0: return ("TRACE", 200)
        case 1: return ("DEBUG", 200)
        case 2: return ("INFO", 200)
        case 3: return ("WARN", 299)
        case 4: return ("ERROR", 500)
        default: return ("LOG", 200)
        }
    }

    static let trampolineLog: osr_log_t = { level, msgPtr in
        guard let msgPtr, let ctx = activeContext() else { return }
        let message = String(cString: msgPtr)
        let (levelName, statusCode) = levelMetadata(for: level)
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

    /// Frees a string the host previously returned to a plugin (v6).
    /// Internally `libc free()` — which pairs with the `strdup` every
    /// host trampoline uses to allocate its return value. NULL is a
    /// no-op so the plugin can wire it into a generic defer block
    /// without an explicit guard. See `osr_host_free_string_fn` in
    /// `osaurus_plugin.h` for the contract rationale (plugins should
    /// never use their own `free_string` callback for host-allocated
    /// strings — that direction is reversed and may corrupt heap if
    /// the plugin's `free_string` does anything besides plain `free`).
    static let trampolineHostFreeString: osr_host_free_string_t = { ptr in
        guard let ptr else { return }
        Darwin.free(UnsafeMutableRawPointer(mutating: ptr))
    }

    /// Structured-log trampoline (v5). The plugin attaches a JSON
    /// payload that surfaces in Insights as searchable fields. NULL
    /// payload degrades gracefully to the same shape `trampolineLog`
    /// produces. Invalid JSON is treated as opaque text — the host
    /// doesn't reject the call (the plugin author would have no way
    /// to learn) but the payload appears as-is in the log row.
    static let trampolineLogStructured: osr_log_structured_t = { level, msgPtr, payloadPtr in
        guard let msgPtr, let ctx = activeContext() else { return }
        let message = String(cString: msgPtr)
        let payload = payloadPtr.map { String(cString: $0) }
        let (levelName, statusCode) = levelMetadata(for: level)

        // Console line keeps the structured payload visible alongside
        // the message. Operators reading the unified log want both.
        if let payload {
            NSLog("[Plugin:%@] [%@] %@ %@", ctx.pluginId, levelName, message, payload)
        } else {
            NSLog("[Plugin:%@] [%@] %@", ctx.pluginId, levelName, message)
        }

        logPluginCall(
            pluginId: ctx.pluginId,
            method: "LOG",
            path: "[\(levelName)] \(message)",
            statusCode: statusCode,
            durationMs: 0,
            requestBody: payload ?? message
        )
    }

    // MARK: Dispatch Trampolines

    static let trampolineDispatch: osr_dispatch_t = { requestPtr in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            var taskId: UUID?
            let ms = measureMs { (result, taskId) = ctx.dispatch(requestJSON: json) }
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "POST",
                path: "/host-api/dispatch",
                statusCode: errorStatusCode(for: result) ?? 202,
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
    }

    static let trampolineTaskStatus: osr_task_status_t = { taskIdPtr in
        withActiveContext(requestPtr: taskIdPtr) { ctx, taskId in
            var result = ""
            let ms = measureMs { result = ctx.taskStatus(taskId: taskId) }
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "GET",
                path: "/host-api/tasks/\(taskId)",
                statusCode: errorStatusCode(for: result) ?? 200,
                durationMs: ms,
                responseBody: result
            )
            return makeCString(result)
        }
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

    /// RESERVED slot — preserved for ABI compatibility. The C signature
    /// returns void, so we cannot return a `not_supported` envelope to the
    /// plugin. Insights logs the call with HTTP 410 so the plugin developer
    /// sees that the call had no effect. Clarification is now handled inline
    /// via the `clarify` agent intercept.
    static let trampolineDispatchClarify: osr_dispatch_clarify_t = { taskIdPtr, responsePtr in
        guard let taskIdPtr, let responsePtr, let ctx = activeContext() else { return }
        let taskId = String(cString: taskIdPtr)
        let response = String(cString: responsePtr)
        ctx.dispatchClarify(taskId: taskId, response: response)
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "POST",
            path: "/host-api/tasks/\(taskId)/clarify",
            statusCode: 410,
            durationMs: 0,
            requestBody: response,
            responseBody:
                #"{"error":"not_supported","message":"dispatch_clarify is reserved. Clarification is handled inline via the clarify agent intercept."}"#
        )
    }

    // MARK: Extended Dispatch Trampolines

    static let trampolineListActiveTasks: osr_list_active_tasks_t = {
        withActiveContext { ctx in
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

    /// RESERVED slot — preserved for ABI compatibility. Returns a
    /// structured `not_supported` envelope: nested issues are no longer a
    /// concept, so plugins should call `dispatch` to start a fresh task
    /// instead.
    static let trampolineDispatchAddIssue: osr_dispatch_add_issue_t = { taskIdPtr, _ in
        withActiveContext(requestPtr: taskIdPtr) { ctx, taskId in
            let result = jsonString([
                "error": "not_supported",
                "message":
                    "dispatch_add_issue is no longer supported. Call dispatch() to start a fresh task.",
            ])
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "POST",
                path: "/host-api/tasks/\(taskId)/issues",
                statusCode: 501,
                durationMs: 0,
                responseBody: result
            )
            return makeCString(result)
        }
    }

    /// Cancel an in-flight `complete_stream` call by stream id. Non-blocking;
    /// the streaming task observes the cancellation flag between deltas and
    /// unwinds with `finish_reason: "cancelled"`. Logs the call to Insights
    /// so the developer can correlate cancel intent with stream completion.
    static let trampolineCompleteCancel: osr_complete_cancel_t = { streamIdPtr in
        guard let streamIdPtr, let ctx = activeContext() else { return }
        let streamId = String(cString: streamIdPtr)
        ctx.completeCancel(streamId: streamId)
        logPluginCall(
            pluginId: ctx.pluginId,
            method: "DELETE",
            path: "/host-api/streams/\(streamId)",
            statusCode: 204,
            durationMs: 0
        )
    }

    // MARK: Inference Trampolines

    static let trampolineComplete: osr_complete_t = { requestPtr in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            let ms = measureMs { result = ctx.complete(requestJSON: json) }
            let model = extractJSONStringValue(from: json, key: "model")
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "POST",
                path: "/host-api/chat/completions",
                statusCode: errorStatusCode(for: result) ?? 200,
                durationMs: ms,
                requestBody: json,
                responseBody: result,
                model: model
            )
            return makeCString(result)
        }
    }

    static let trampolineCompleteStream: osr_complete_stream_t = { requestPtr, onChunk, userData in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            let ms = measureMs { result = ctx.completeStream(requestJSON: json, onChunk: onChunk, userData: userData) }
            let model = extractJSONStringValue(from: json, key: "model")
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "POST",
                path: "/host-api/chat/completions",
                statusCode: errorStatusCode(for: result) ?? 200,
                durationMs: ms,
                requestBody: json,
                responseBody: result,
                model: model
            )
            return makeCString(result)
        }
    }

    static let trampolineEmbed: osr_embed_t = { requestPtr in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            let ms = measureMs { result = ctx.embed(requestJSON: json) }
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "POST",
                path: "/host-api/embeddings",
                statusCode: errorStatusCode(for: result) ?? 200,
                durationMs: ms,
                requestBody: json,
                responseBody: result
            )
            return makeCString(result)
        }
    }

    // MARK: Models Trampoline

    static let trampolineListModels: osr_list_models_t = {
        withActiveContext { ctx in
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
    }

    // MARK: HTTP Client Trampoline

    static let trampolineHttpRequest: osr_http_request_t = { requestPtr in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            let ms = measureMs { result = ctx.httpRequest(requestJSON: json) }
            let method = extractJSONStringValue(from: json, key: "method") ?? "GET"
            let url = extractJSONStringValue(from: json, key: "url") ?? "?"
            let statusStr = extractJSONStringValue(from: result, key: "status")
            let statusCode = statusStr.flatMap { Int($0) } ?? (errorStatusCode(for: result) ?? 200)
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
    }

    // MARK: File Read Trampoline

    static let trampolineFileRead: osr_file_read_t = { requestPtr in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            let ms = measureMs { result = ctx.fileRead(requestJSON: json) }
            let path = extractJSONStringValue(from: json, key: "path") ?? "?"
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "GET",
                path: "/host-api/file_read \u{2192} \(path)",
                statusCode: errorStatusCode(for: result) ?? 200,
                durationMs: ms,
                requestBody: json,
                responseBody: nil
            )
            return makeCString(result)
        }
    }
}

//
//  PluginHostAPI.swift
//  osaurus
//
//  Implements the host-side callbacks passed to v2 plugins via osr_host_api.
//  Each plugin gets its own host context with config (Keychain-backed),
//  database (sandboxed SQLite), dispatch, inference, models, and HTTP access.
//

import Foundation

// MARK: - Per-Plugin Host Context

/// Holds per-plugin state needed by host API callbacks.
/// Registered in a global dictionary keyed by plugin ID so that
/// @convention(c) trampolines can look up the right context.
final class PluginHostContext: @unchecked Sendable {
    /// Global registry of active host contexts. Accessed only from PluginManager's loading path.
    nonisolated(unsafe) static var contexts: [String: PluginHostContext] = [:]

    /// The currently active context for C trampoline dispatch.
    /// Set before calling the plugin entry point and cleared after.
    nonisolated(unsafe) static var currentContext: PluginHostContext?

    let pluginId: String
    let database: PluginDatabase

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

    /// Sliding window timestamps for dispatch rate limiting (10/min per plugin).
    private let rateLimitLock = NSLock()
    private var dispatchTimestamps: [Date] = []
    private static let dispatchRateLimit = 10
    private static let dispatchRateWindow: TimeInterval = 60

    init(pluginId: String) throws {
        self.pluginId = pluginId
        self.database = PluginDatabase(pluginId: pluginId)
        try database.open()
    }

    deinit {
        database.close()
    }

    // MARK: - Config Callbacks

    func configGet(key: String) -> String? {
        return ToolSecretsKeychain.getSecret(id: key, for: pluginId)
    }

    func configSet(key: String, value: String) {
        ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId)
    }

    func configDelete(key: String) {
        ToolSecretsKeychain.deleteSecret(id: key, for: pluginId)
    }

    // MARK: - Database Callbacks

    func dbExec(sql: String, paramsJSON: String?) -> String {
        return database.exec(sql: sql, paramsJSON: paramsJSON)
    }

    func dbQuery(sql: String, paramsJSON: String?) -> String {
        return database.query(sql: sql, paramsJSON: paramsJSON)
    }

    // MARK: - Dispatch Callbacks

    func dispatch(requestJSON: String) -> String {
        guard checkDispatchRateLimit() else {
            return Self.jsonString(["error": "rate_limit_exceeded", "message": "Dispatch rate limit (10/min) exceeded"])
        }

        return Self.blockingAsync { [pluginId] in
            let data = Data(requestJSON.utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let prompt = json["prompt"] as? String
            else {
                return Self.jsonString(["error": "invalid_request", "message": "Missing required field: prompt"])
            }

            let modeStr = json["mode"] as? String ?? "work"
            let mode: ChatMode = modeStr == "chat" ? .chat : .work

            var requestId = UUID()
            if let idStr = json["id"] as? String, let parsed = UUID(uuidString: idStr) {
                requestId = parsed
            }

            var agentId: UUID?
            if let agentStr = json["agent_id"] as? String {
                agentId = UUID(uuidString: agentStr)
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
                agentId: agentId,
                title: title,
                folderBookmark: folderBookmark,
                showToast: true,
                sourcePluginId: pluginId
            )

            let handle = await TaskDispatcher.shared.dispatch(request)
            guard handle != nil else {
                return Self.jsonString([
                    "error": "task_limit_reached", "message": "Maximum concurrent background tasks reached",
                ])
            }

            return Self.jsonString(["id": requestId.uuidString, "status": "running"])
        }
    }

    func taskStatus(taskId: String) -> String {
        guard let uuid = UUID(uuidString: taskId) else {
            return Self.jsonString(["error": "invalid_task_id", "message": "Invalid UUID format"])
        }

        return Self.blockingMainActor {
            guard let state = BackgroundTaskManager.shared.taskState(for: uuid) else {
                return Self.jsonString(["error": "not_found", "message": "Task not found"])
            }
            return Self.serializeTaskState(id: uuid, state: state)
        }
    }

    func dispatchCancel(taskId: String) {
        guard let uuid = UUID(uuidString: taskId) else { return }
        Self.blockingMainActor {
            BackgroundTaskManager.shared.cancelTask(uuid)
        }
    }

    func dispatchClarify(taskId: String, response: String) {
        guard let uuid = UUID(uuidString: taskId) else { return }
        Self.blockingMainActor {
            BackgroundTaskManager.shared.submitClarification(uuid, response: response)
        }
    }

    // MARK: - Inference Callbacks

    func complete(requestJSON: String) -> String {
        Self.blockingAsync {
            let data = Data(requestJSON.utf8)
            guard let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data) else {
                return Self.jsonString([
                    "error": "invalid_request", "message": "Failed to parse chat completion request",
                ])
            }

            let engine = ChatEngine(source: .httpAPI)
            do {
                let response = try await engine.completeChat(request: request)
                guard let encoded = try? JSONEncoder().encode(response) else {
                    return Self.jsonString(["error": "serialization_error", "message": "Failed to serialize response"])
                }
                return String(decoding: encoded, as: UTF8.self)
            } catch {
                return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
            }
        }
    }

    func completeStream(
        requestJSON: String,
        onChunk: osr_on_chunk_t?,
        userData: UnsafeMutableRawPointer?
    ) -> String {
        nonisolated(unsafe) let userData = userData
        return Self.blockingAsync {
            let data = Data(requestJSON.utf8)
            guard let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data) else {
                return Self.jsonString([
                    "error": "invalid_request", "message": "Failed to parse chat completion request",
                ])
            }

            let engine = ChatEngine(source: .httpAPI)
            do {
                let stream = try await engine.streamChat(request: request)
                let completionId = "cmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
                var fullContent = ""

                for try await delta in stream {
                    fullContent += delta
                    Self.emitChunk(
                        ["id": completionId, "choices": [["index": 0, "delta": ["content": delta]]]],
                        callback: onChunk,
                        userData: userData
                    )
                }

                Self.emitChunk(
                    ["id": completionId, "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]],
                    callback: onChunk,
                    userData: userData
                )

                return Self.jsonString([
                    "id": completionId,
                    "model": request.model,
                    "choices": [
                        [
                            "index": 0, "message": ["role": "assistant", "content": fullContent],
                            "finish_reason": "stop",
                        ]
                    ],
                ])
            } catch {
                return Self.jsonString(["error": "inference_error", "message": error.localizedDescription])
            }
        }
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

    // MARK: - Build osr_host_api Struct

    /// Builds the C-compatible host API struct with trampoline function pointers.
    /// IMPORTANT: `currentContext` must be set to this instance before the plugin
    /// entry point is called, and the returned struct must remain valid for the
    /// plugin's lifetime (it's copied into the plugin at init time).
    func buildHostAPI() -> osr_host_api {
        return osr_host_api(
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
            http_request: PluginHostContext.trampolineHttpRequest
        )
    }

    /// Removes this context from the global registry and closes the database.
    func teardown() {
        PluginHostContext.contexts.removeValue(forKey: pluginId)
        database.close()
    }
}

// MARK: - Rate Limiting

extension PluginHostContext {
    /// Returns true if the dispatch is allowed under the rate limit.
    func checkDispatchRateLimit() -> Bool {
        rateLimitLock.lock()
        defer { rateLimitLock.unlock() }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.dispatchRateWindow)
        dispatchTimestamps.removeAll { $0 < cutoff }
        guard dispatchTimestamps.count < Self.dispatchRateLimit else { return false }
        dispatchTimestamps.append(now)
        return true
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
    static func serializeTaskState(id: UUID, state: BackgroundTaskState) -> String {
        var result: [String: Any] = ["id": id.uuidString]

        switch state.status {
        case .running:
            result["status"] = "running"
            result["progress"] = state.progress
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

        return jsonString(result)
    }

    private static func activityKindString(_ kind: BackgroundTaskActivityItem.Kind) -> String {
        switch kind {
        case .tool: "tool"
        case .info: "info"
        case .progress: "progress"
        case .warning: "warning"
        case .success: "success"
        case .error: "error"
        }
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
}

// MARK: - C Trampoline Functions

/// These are @convention(c) functions that look up the active PluginHostContext
/// via the global `currentContext` (during init) or per-plugin registry (at runtime).
///
/// Since the osr_host_api callbacks are called from the plugin within its own
/// execution context, we use a thread-local to identify which plugin is calling.
/// The plugin ID is stored in thread-local storage when the plugin's invoke/route
/// handler is dispatched.
extension PluginHostContext {
    /// Thread-local storage for the active plugin ID during C callback dispatch
    private static let tlsKey: String = "ai.osaurus.plugin.active"

    static func setActivePlugin(_ pluginId: String) {
        Thread.current.threadDictionary[tlsKey] = pluginId
    }

    static func clearActivePlugin() {
        Thread.current.threadDictionary.removeObject(forKey: tlsKey)
    }

    private static func activeContext() -> PluginHostContext? {
        if let pluginId = Thread.current.threadDictionary[tlsKey] as? String {
            return contexts[pluginId]
        }
        return currentContext
    }

    private static func makeCString(_ str: String) -> UnsafePointer<CChar>? {
        let cStr = strdup(str)
        return UnsafePointer(cStr)
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
        switch level {
        case 0: levelName = "DEBUG"
        case 1: levelName = "INFO"
        case 2: levelName = "WARN"
        case 3: levelName = "ERROR"
        default: levelName = "LOG"
        }
        NSLog("[Plugin:%@] [%@] %@", ctx.pluginId, levelName, message)
    }

    // MARK: Dispatch Trampolines

    static let trampolineDispatch: osr_dispatch_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        let result = ctx.dispatch(requestJSON: json)
        return makeCString(result)
    }

    static let trampolineTaskStatus: osr_task_status_t = { taskIdPtr in
        guard let taskIdPtr, let ctx = activeContext() else { return nil }
        let taskId = String(cString: taskIdPtr)
        let result = ctx.taskStatus(taskId: taskId)
        return makeCString(result)
    }

    static let trampolineDispatchCancel: osr_dispatch_cancel_t = { taskIdPtr in
        guard let taskIdPtr, let ctx = activeContext() else { return }
        let taskId = String(cString: taskIdPtr)
        ctx.dispatchCancel(taskId: taskId)
    }

    static let trampolineDispatchClarify: osr_dispatch_clarify_t = { taskIdPtr, responsePtr in
        guard let taskIdPtr, let responsePtr, let ctx = activeContext() else { return }
        let taskId = String(cString: taskIdPtr)
        let response = String(cString: responsePtr)
        ctx.dispatchClarify(taskId: taskId, response: response)
    }

    // MARK: Inference Trampolines

    static let trampolineComplete: osr_complete_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        let result = ctx.complete(requestJSON: json)
        return makeCString(result)
    }

    static let trampolineCompleteStream: osr_complete_stream_t = { requestPtr, onChunk, userData in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        let result = ctx.completeStream(requestJSON: json, onChunk: onChunk, userData: userData)
        return makeCString(result)
    }

    static let trampolineEmbed: osr_embed_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        let result = ctx.embed(requestJSON: json)
        return makeCString(result)
    }

    // MARK: Models Trampoline

    static let trampolineListModels: osr_list_models_t = {
        guard let ctx = activeContext() else { return nil }
        let result = ctx.listModels()
        return makeCString(result)
    }

    // MARK: HTTP Client Trampoline

    static let trampolineHttpRequest: osr_http_request_t = { requestPtr in
        guard let requestPtr, let ctx = activeContext() else { return nil }
        let json = String(cString: requestPtr)
        let result = ctx.httpRequest(requestJSON: json)
        return makeCString(result)
    }
}

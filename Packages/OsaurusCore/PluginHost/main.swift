//
//  main.swift
//  osaurus-plugin-host
//
//  Out-of-process native plugin host. Loads ONE plugin dylib via the same
//  frozen C ABI the in-process loader uses (`osaurus_plugin_entry_v2`,
//  see Tools/PluginABI/osaurus_plugin.h) and executes invocations on behalf
//  of the app over newline-framed JSON-RPC on stdin/stdout.
//
//  Why: accessibility/automation plugin code is synchronous C that Swift
//  cancellation cannot unblock. In-process, a wedged AX call blocks the
//  shared accessibility queue forever and can only be "recovered" by
//  restarting Osaurus. Out-of-process, the app kills this helper on
//  deadline and respawns it — a hard reset with a process-sized blast
//  radius instead of an app-sized one.
//
//  Wire protocol (one JSON object per line, both directions):
//    parent → child requests:  {"id":1,"method":"load","params":{...}}
//    child → parent responses: {"id":1,"result":{...}} | {"id":1,"error":{"message":"..."}}
//    child → parent requests (host-API callbacks, id prefixed "h-"):
//                              {"id":"h-1","method":"host.config_get","params":{...}}
//    child → parent notifications (no id): {"method":"host.log","params":{...}}
//
//  Methods: load {path}, get_manifest, invoke {type,id,payload,agent_id?},
//  config_changed {key,value,agent_id?}, ping, shutdown.
//
//  This file is dependency-free (Foundation only) so the helper binary
//  stays small and can never be wedged by app-side subsystems.
//

import Darwin
import Foundation

// MARK: - C ABI mirror (frozen layout)
//
// Duplicated from `Models/Plugin/ExternalPlugin.swift` — the layout is
// FROZEN (see PluginHostAPIStructLayoutTests). The helper cannot import
// OsaurusCore (that would pull the entire app graph into the helper), so
// it carries its own mirror of the two structs it needs.

typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?
typealias osr_handle_route_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_on_config_changed_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_on_task_event_t =
    @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void

typealias osr_config_get_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_config_set_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_config_delete_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_db_exec_t =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_db_query_t =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_log_t = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_task_status_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_dispatch_cancel_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_clarify_t =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_complete_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_on_chunk_t = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias osr_complete_stream_t =
    @convention(c) (UnsafePointer<CChar>?, osr_on_chunk_t?, UnsafeMutableRawPointer?) ->
        UnsafePointer<CChar>?
typealias osr_embed_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_list_models_t = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_http_request_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_file_read_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_list_active_tasks_t = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_send_draft_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_interrupt_t =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_add_issue_t =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_complete_cancel_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_get_active_agent_id_t = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_log_structured_t =
    @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_host_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void

struct osr_host_api {
    var version: UInt32
    var config_get: osr_config_get_t?
    var config_set: osr_config_set_t?
    var config_delete: osr_config_delete_t?
    var db_exec: osr_db_exec_t?
    var db_query: osr_db_query_t?
    var log: osr_log_t?
    var dispatch: osr_dispatch_t?
    var task_status: osr_task_status_t?
    var dispatch_cancel: osr_dispatch_cancel_t?
    var dispatch_clarify: osr_dispatch_clarify_t?
    var complete: osr_complete_t?
    var complete_stream: osr_complete_stream_t?
    var embed: osr_embed_t?
    var list_models: osr_list_models_t?
    var http_request: osr_http_request_t?
    var file_read: osr_file_read_t?
    var list_active_tasks: osr_list_active_tasks_t?
    var send_draft: osr_send_draft_t?
    var dispatch_interrupt: osr_dispatch_interrupt_t?
    var dispatch_add_issue: osr_dispatch_add_issue_t?
    var complete_cancel: osr_complete_cancel_t?
    var get_active_agent_id: osr_get_active_agent_id_t?
    var log_structured: osr_log_structured_t?
    var free_string: osr_host_free_string_t?
}

struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
    var version: UInt32
    var handle_route: osr_handle_route_t?
    var on_config_changed: osr_on_config_changed_t?
    var on_task_event: osr_on_task_event_t?
}

struct osr_plugin_api_v1 {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
}

typealias osr_plugin_entry_t = @convention(c) () -> UnsafeRawPointer?
typealias osr_plugin_entry_v2_t = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?

// MARK: - Stdout writer (line-framed, serialized)

/// All child→parent traffic funnels through one lock so concurrent
/// writers (invoke responses on the invoke queue, host callbacks from
/// plugin threads, log notifications) can never interleave bytes of two
/// JSON lines.
final class LineWriter: @unchecked Sendable {
    static let shared = LineWriter()
    private let lock = NSLock()
    private let handle = FileHandle.standardOutput

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle.write(data)
        handle.write(Data([0x0A]))
    }
}

// MARK: - Reverse RPC (host-API callbacks child → parent)

/// Synchronous request/response bridge used by the host-API trampolines.
/// A trampoline runs on a plugin thread, posts a request line, and parks
/// on a semaphore until the stdin reader delivers the matching response.
/// A bounded wait protects the helper from a dead/hung parent: on timeout
/// the trampoline returns nil (the ABI's "no value" answer) rather than
/// deadlocking the plugin thread forever.
final class HostBridge: @unchecked Sendable {
    static let shared = HostBridge()

    private let lock = NSLock()
    private var nextId = 1
    private var pending: [String: (DispatchSemaphore, UnsafeMutablePointer<[String: Any]?>)] = [:]

    static let callTimeoutSeconds: Double = 30

    /// Blocking round-trip. Returns the `result` object or nil on
    /// error/timeout.
    func call(method: String, params: [String: Any]) -> [String: Any]? {
        let id: String
        lock.lock()
        id = "h-\(nextId)"
        nextId += 1
        let semaphore = DispatchSemaphore(value: 0)
        let slot = UnsafeMutablePointer<[String: Any]?>.allocate(capacity: 1)
        slot.initialize(to: nil)
        pending[id] = (semaphore, slot)
        lock.unlock()

        LineWriter.shared.send(["id": id, "method": method, "params": params])

        let outcome = semaphore.wait(timeout: .now() + Self.callTimeoutSeconds)
        lock.lock()
        pending.removeValue(forKey: id)
        let result = outcome == .success ? slot.pointee : nil
        slot.deinitialize(count: 1)
        slot.deallocate()
        lock.unlock()
        return result
    }

    /// Fire-and-forget notification (no response expected).
    func notify(method: String, params: [String: Any]) {
        LineWriter.shared.send(["method": method, "params": params])
    }

    /// Called from the stdin reader when a response line arrives.
    func deliverResponse(id: String, result: [String: Any]?) {
        lock.lock()
        if let (semaphore, slot) = pending[id] {
            slot.pointee = result
            semaphore.signal()
        }
        lock.unlock()
    }
}

// MARK: - Current invocation context

/// The agent id of the invocation currently executing on the (serial)
/// invoke queue. Trampolines are C functions with no capture, so this is
/// process-global state — sound because the helper hosts exactly one
/// plugin and executes invocations one at a time.
final class CurrentInvocation: @unchecked Sendable {
    static let shared = CurrentInvocation()
    private let lock = NSLock()
    private var _agentId: String?

    var agentId: String? {
        get { lock.withLock { _agentId } }
        set { lock.withLock { _agentId = newValue } }
    }
}

// MARK: - Host-API trampolines

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
    UnsafePointer(strdup(s))
}

private func bridgedStringCall(
    _ method: String, _ params: [String: Any]
) -> UnsafePointer<CChar>? {
    var p = params
    if let agent = CurrentInvocation.shared.agentId { p["agent_id"] = agent }
    guard let result = HostBridge.shared.call(method: method, params: p),
        let value = result["value"] as? String
    else { return nil }
    return makeCString(value)
}

/// JSON error envelope for host-API slots that are not available
/// out-of-process (inference, dispatch, HTTP, file I/O). Matches the
/// structured error shape plugins already handle for `not_supported`.
private func unsupportedEnvelope(_ slot: String) -> UnsafePointer<CChar>? {
    makeCString(
        #"{"error":{"code":"not_supported_out_of_process","message":"host API '\#(slot)' is not available in the out-of-process plugin host"}}"#
    )
}

/// Builds the heap host-API table handed to `osaurus_plugin_entry_v2`.
/// Supported slots proxy to the parent over reverse RPC; unsupported
/// slots return a structured error envelope (string-returning) or no-op
/// (void-returning) so a plugin that touches them degrades cleanly
/// instead of crashing on a NULL function pointer.
func buildHelperHostAPI() -> UnsafeMutablePointer<osr_host_api> {
    let api = UnsafeMutablePointer<osr_host_api>.allocate(capacity: 1)
    api.initialize(
        to: osr_host_api(
            version: 6,
            config_get: { keyPtr in
                guard let keyPtr else { return nil }
                return bridgedStringCall("host.config_get", ["key": String(cString: keyPtr)])
            },
            config_set: { keyPtr, valuePtr in
                guard let keyPtr, let valuePtr else { return }
                var params: [String: Any] = [
                    "key": String(cString: keyPtr), "value": String(cString: valuePtr),
                ]
                if let agent = CurrentInvocation.shared.agentId { params["agent_id"] = agent }
                _ = HostBridge.shared.call(method: "host.config_set", params: params)
            },
            config_delete: { keyPtr in
                guard let keyPtr else { return }
                var params: [String: Any] = ["key": String(cString: keyPtr)]
                if let agent = CurrentInvocation.shared.agentId { params["agent_id"] = agent }
                _ = HostBridge.shared.call(method: "host.config_delete", params: params)
            },
            db_exec: { sqlPtr, paramsPtr in
                guard let sqlPtr else { return nil }
                var params: [String: Any] = ["sql": String(cString: sqlPtr)]
                if let paramsPtr { params["params"] = String(cString: paramsPtr) }
                return bridgedStringCall("host.db_exec", params)
            },
            db_query: { sqlPtr, paramsPtr in
                guard let sqlPtr else { return nil }
                var params: [String: Any] = ["sql": String(cString: sqlPtr)]
                if let paramsPtr { params["params"] = String(cString: paramsPtr) }
                return bridgedStringCall("host.db_query", params)
            },
            log: { level, msgPtr in
                guard let msgPtr else { return }
                HostBridge.shared.notify(
                    method: "host.log",
                    params: ["level": Int(level), "message": String(cString: msgPtr)]
                )
            },
            dispatch: { _ in unsupportedEnvelope("dispatch") },
            task_status: { _ in unsupportedEnvelope("task_status") },
            dispatch_cancel: { _ in },
            dispatch_clarify: { _, _ in },
            complete: { _ in unsupportedEnvelope("complete") },
            complete_stream: { _, _, _ in unsupportedEnvelope("complete_stream") },
            embed: { _ in unsupportedEnvelope("embed") },
            list_models: { unsupportedEnvelope("list_models") },
            http_request: { requestPtr in
                guard let requestPtr else { return nil }
                return bridgedStringCall(
                    "host.http_request", ["request": String(cString: requestPtr)]
                )
            },
            file_read: { _ in unsupportedEnvelope("file_read") },
            list_active_tasks: { unsupportedEnvelope("list_active_tasks") },
            send_draft: { _, _ in },
            dispatch_interrupt: { _, _ in },
            dispatch_add_issue: { _, _ in unsupportedEnvelope("dispatch_add_issue") },
            complete_cancel: { _ in },
            get_active_agent_id: {
                guard let agent = CurrentInvocation.shared.agentId else { return nil }
                return makeCString(agent)
            },
            log_structured: { level, msgPtr, payloadPtr in
                guard let msgPtr else { return }
                var params: [String: Any] = [
                    "level": Int(level), "message": String(cString: msgPtr),
                ]
                if let payloadPtr { params["payload"] = String(cString: payloadPtr) }
                HostBridge.shared.notify(method: "host.log_structured", params: params)
            },
            free_string: { ptr in
                if let ptr { free(UnsafeMutableRawPointer(mutating: ptr)) }
            }
        )
    )
    return api
}

// MARK: - Plugin runtime

enum HelperError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case .message(let m) = self { return m }
        return "unknown"
    }
}

final class PluginRuntime: @unchecked Sendable {
    private var handle: UnsafeMutableRawPointer?
    private var api: osr_plugin_api?
    private var ctx: osr_plugin_ctx_t?
    private var hostAPI: UnsafeMutablePointer<osr_host_api>?

    /// Serial: one plugin call at a time — mirrors the in-process
    /// accessibility-queue semantics this helper exists to replace.
    let invokeQueue = DispatchQueue(label: "com.osaurus.plugin-host.invoke")

    func load(path: String) throws -> String {
        guard handle == nil else { throw HelperError.message("plugin already loaded") }
        guard let dl = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown dlopen failure"
            throw HelperError.message("dlopen failed: \(err)")
        }

        var apiPtr: UnsafeRawPointer?
        if let sym = dlsym(dl, "osaurus_plugin_entry_v2") {
            let entry = unsafeBitCast(sym, to: osr_plugin_entry_v2_t.self)
            let host = buildHelperHostAPI()
            hostAPI = host
            apiPtr = entry(UnsafeRawPointer(host))
        } else if let sym = dlsym(dl, "osaurus_plugin_entry") {
            let entry = unsafeBitCast(sym, to: osr_plugin_entry_t.self)
            if let raw = entry() {
                let v1 = raw.assumingMemoryBound(to: osr_plugin_api_v1.self).pointee
                self.api = osr_plugin_api(
                    free_string: v1.free_string, init: v1.`init`, destroy: v1.destroy,
                    get_manifest: v1.get_manifest, invoke: v1.invoke,
                    version: 0, handle_route: nil, on_config_changed: nil, on_task_event: nil
                )
            }
        } else {
            dlclose(dl)
            throw HelperError.message("no osaurus_plugin_entry symbol")
        }

        if let apiPtr {
            self.api = apiPtr.assumingMemoryBound(to: osr_plugin_api.self).pointee
        }
        guard let api = self.api else {
            dlclose(dl)
            throw HelperError.message("plugin entry returned NULL")
        }
        guard let initFn = api.`init`, let ctx = initFn() else {
            dlclose(dl)
            throw HelperError.message("plugin init failed")
        }
        self.handle = dl
        self.ctx = ctx

        guard let manifestFn = api.get_manifest, let manifestPtr = manifestFn(ctx) else {
            throw HelperError.message("plugin returned no manifest")
        }
        let manifest = String(cString: manifestPtr)
        api.free_string?(manifestPtr)
        return manifest
    }

    func invoke(type: String, id: String, payload: String, agentId: String?) throws -> String {
        guard let api, let ctx, let invokeFn = api.invoke else {
            throw HelperError.message("plugin not loaded or invoke missing")
        }
        CurrentInvocation.shared.agentId = agentId
        defer { CurrentInvocation.shared.agentId = nil }
        let resPtr = type.withCString { typePtr in
            id.withCString { idPtr in
                payload.withCString { payloadPtr in
                    invokeFn(ctx, typePtr, idPtr, payloadPtr)
                }
            }
        }
        guard let resPtr else { throw HelperError.message("plugin returned NULL response") }
        let result = String(cString: resPtr)
        api.free_string?(resPtr)
        return result
    }

    func configChanged(key: String, value: String?, agentId: String?) {
        guard let api, let ctx, let fn = api.on_config_changed else { return }
        CurrentInvocation.shared.agentId = agentId
        defer { CurrentInvocation.shared.agentId = nil }
        key.withCString { keyPtr in
            if let value {
                value.withCString { valuePtr in fn(ctx, keyPtr, valuePtr) }
            } else {
                fn(ctx, keyPtr, nil)
            }
        }
    }

    func shutdown() {
        if let api, let ctx { api.destroy?(ctx) }
        ctx = nil
        // Deliberately no dlclose: matches the in-process loader (PAC
        // pointer-auth issues on re-open) and the process exits anyway.
    }
}

// MARK: - Main loop

let runtime = PluginRuntime()

func respond(id: Any, result: [String: Any]) {
    LineWriter.shared.send(["id": id, "result": result])
}

func respondError(id: Any, message: String) {
    LineWriter.shared.send(["id": id, "error": ["message": message]])
}

func handleRequest(_ object: [String: Any]) {
    guard let method = object["method"] as? String else {
        // No method → this is a response to one of OUR host-API requests.
        if let id = object["id"] as? String {
            HostBridge.shared.deliverResponse(id: id, result: object["result"] as? [String: Any])
        }
        return
    }
    guard let id = object["id"] else { return }
    let params = object["params"] as? [String: Any] ?? [:]

    switch method {
    case "load":
        guard let path = params["path"] as? String else {
            respondError(id: id, message: "missing path")
            return
        }
        do {
            let manifest = try runtime.load(path: path)
            respond(id: id, result: ["manifest": manifest])
        } catch {
            respondError(id: id, message: "\(error)")
        }

    case "invoke":
        guard let type = params["type"] as? String,
            let invokeId = params["id"] as? String,
            let payload = params["payload"] as? String
        else {
            respondError(id: id, message: "missing invoke params")
            return
        }
        let agentId = params["agent_id"] as? String
        // Serial queue: the reader stays responsive (ping, shutdown, host
        // responses) while plugin code runs — and a wedged plugin call
        // wedges only this queue, which the parent recovers by kill.
        runtime.invokeQueue.async {
            do {
                let result = try runtime.invoke(
                    type: type, id: invokeId, payload: payload, agentId: agentId
                )
                respond(id: id, result: ["result": result])
            } catch {
                respondError(id: id, message: "\(error)")
            }
        }

    case "config_changed":
        guard let key = params["key"] as? String else {
            respondError(id: id, message: "missing key")
            return
        }
        let value = params["value"] as? String
        let agentId = params["agent_id"] as? String
        runtime.invokeQueue.async {
            runtime.configChanged(key: key, value: value, agentId: agentId)
            respond(id: id, result: [:])
        }

    case "ping":
        respond(id: id, result: ["pid": Int(getpid())])

    case "shutdown":
        runtime.invokeQueue.async {
            runtime.shutdown()
            respond(id: id, result: [:])
            exit(0)
        }

    default:
        respondError(id: id, message: "unknown method: \(method)")
    }
}

// If the parent dies, stdin hits EOF and the helper must exit rather than
// linger as an orphan. SIGTERM is the parent's graceful kill.
signal(SIGTERM) { _ in exit(0) }
signal(SIGPIPE, SIG_IGN)

let stdinHandle = FileHandle.standardInput
var buffer = Data()
while true {
    let chunk = stdinHandle.availableData
    if chunk.isEmpty { break }  // EOF — parent is gone.
    buffer.append(chunk)
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
        buffer.removeSubrange(buffer.startIndex...newlineIndex)
        guard !lineData.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { continue }
        handleRequest(object)
    }
}
exit(0)

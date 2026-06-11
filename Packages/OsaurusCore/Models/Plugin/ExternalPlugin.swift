//
//  ExternalPlugin.swift
//  osaurus
//
//  Represents a loaded plugin instance using the generic C ABI.
//

import Foundation
import os

// MARK: - C ABI Mirror
//
// Swift mirror of the C struct in `Tools/PluginABI/osaurus_plugin.h`.
// The struct layout is FROZEN — adding/reordering fields would break
// every installed plugin that reads the host API by offset. New host
// callbacks must be appended after the existing trailing fields.

typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Required plugin-side function types (every plugin implements these).
typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?

typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?,  // type
        UnsafePointer<CChar>?,  // id
        UnsafePointer<CChar>?  // payload
    ) -> UnsafePointer<CChar>?  // returns JSON string directly

// Optional plugin-side function types (plugins that opt in to v2+ features).
typealias osr_handle_route_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?  // request_json
    ) -> UnsafePointer<CChar>?  // returns response JSON

typealias osr_on_config_changed_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?,  // key
        UnsafePointer<CChar>?  // value
    ) -> Void

typealias osr_on_task_event_t =
    @convention(c) (
        osr_plugin_ctx_t?,  // ctx
        UnsafePointer<CChar>?,  // task_id
        Int32,  // event_type (OSR_TASK_EVENT_*)
        UnsafePointer<CChar>?  // event_json
    ) -> Void

/// Swift-side mirror of the OSR_TASK_EVENT_* constants.
enum TaskEventType: Int32 {
    case started = 0
    case activity = 1
    case progress = 2
    case clarification = 3
    case completed = 4
    case failed = 5
    case cancelled = 6
    case output = 7
    case draft = 8
}

// Host API callback types (host → plugin, injected at init for v2)
typealias osr_config_get_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_config_set_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_config_delete_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_db_exec_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_db_query_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_log_t = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

// Agent dispatch
typealias osr_dispatch_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_task_status_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_dispatch_cancel_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_clarify_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

// Inference
typealias osr_complete_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_on_chunk_t = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias osr_complete_stream_t =
    @convention(c) (
        UnsafePointer<CChar>?,  // request_json
        osr_on_chunk_t?,  // on_chunk callback
        UnsafeMutableRawPointer?  // user_data
    ) -> UnsafePointer<CChar>?
typealias osr_embed_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// Models
typealias osr_list_models_t = @convention(c) () -> UnsafePointer<CChar>?

// HTTP client
typealias osr_http_request_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// File I/O
typealias osr_file_read_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// Extended Agent Dispatch
typealias osr_list_active_tasks_t = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_send_draft_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_interrupt_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_add_issue_t =
    @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// Streaming control
typealias osr_complete_cancel_t = @convention(c) (UnsafePointer<CChar>?) -> Void

// Agent context introspection (added in v4)
typealias osr_get_active_agent_id_t = @convention(c) () -> UnsafePointer<CChar>?

// Structured logging (added in v5)
typealias osr_log_structured_t =
    @convention(c) (
        Int32,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Void

// Host-side string free (added in v6)
typealias osr_host_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Frozen layout — field order and padding must match `osaurus_plugin.h`
/// exactly (see `PluginHostAPIStructLayoutTests`). Swift plugins that mirror
/// this struct must not skip middle fields (e.g. omitting v5 `log_structured`
/// but adding v6 `free_string`); misaligned slots cause wrong `host` calls
/// and heap aborts when freeing returned strings.
struct osr_host_api {
    var version: UInt32

    // Config + Storage + Logging
    var config_get: osr_config_get_t?
    var config_set: osr_config_set_t?
    var config_delete: osr_config_delete_t?
    var db_exec: osr_db_exec_t?
    var db_query: osr_db_query_t?
    var log: osr_log_t?

    // Agent Dispatch
    var dispatch: osr_dispatch_t?
    var task_status: osr_task_status_t?
    var dispatch_cancel: osr_dispatch_cancel_t?
    /// RESERVED — kept for ABI compatibility. The trampoline is a no-op;
    /// clarification is handled inline in chat via the `clarify` agent
    /// intercept. New plugins should not invoke this slot.
    var dispatch_clarify: osr_dispatch_clarify_t?

    // Inference
    var complete: osr_complete_t?
    var complete_stream: osr_complete_stream_t?
    var embed: osr_embed_t?
    var list_models: osr_list_models_t?

    // HTTP Client
    var http_request: osr_http_request_t?

    // File I/O
    var file_read: osr_file_read_t?

    // Extended Agent Dispatch (added in v2; preserved in v3)
    var list_active_tasks: osr_list_active_tasks_t?
    var send_draft: osr_send_draft_t?
    var dispatch_interrupt: osr_dispatch_interrupt_t?
    /// RESERVED — kept for ABI compatibility. The trampoline returns a
    /// structured `not_supported` JSON envelope. The issue tracker was
    /// retired; new plugins should call `dispatch` to start a fresh task.
    var dispatch_add_issue: osr_dispatch_add_issue_t?

    // Streaming control (added in v3)
    var complete_cancel: osr_complete_cancel_t?

    // Agent context introspection (added in v4)
    var get_active_agent_id: osr_get_active_agent_id_t?

    // Structured logging (added in v5)
    var log_structured: osr_log_structured_t?

    // Host-side string free (added in v6)
    var free_string: osr_host_free_string_t?
}

struct osr_plugin_api {
    // Required fields (every plugin)
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
    // Optional fields (zeroed for legacy v1 plugins; populated for v2+)
    var version: UInt32
    var handle_route: osr_handle_route_t?
    var on_config_changed: osr_on_config_changed_t?
    var on_task_event: osr_on_task_event_t?
}

// Entry point types
typealias osr_plugin_entry_t = @convention(c) () -> UnsafeRawPointer?
typealias osr_plugin_entry_v2_t = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?

// MARK: - Swift Wrapper

public struct PluginManifest: Decodable, Sendable {
    public let plugin_id: String
    public let description: String?
    public let capabilities: Capabilities

    /// System prompt instructions appended during plugin-initiated inference.
    public let instructions: String?

    // Optional fields for registry
    public let name: String?
    public let version: String?
    public let license: String?
    public let authors: [String]?
    public let min_macos: String?
    public let min_osaurus: String?

    public struct Capabilities: Decodable, Sendable {
        public let tools: [ToolSpec]?
        public let routes: [RouteSpec]?
        public let config: ConfigSpec?
        public let web: WebSpec?
        public let artifact_handler: Bool?
    }

    public struct ToolSpec: Decodable, Sendable {
        public let id: String
        public let description: String
        public let parameters: JSONValue?
        public let requirements: [String]?
        public let permission_policy: String?
    }

    /// Specification for a secret that a plugin requires (e.g., API key)
    public struct SecretSpec: Decodable, Sendable {
        /// Unique identifier for the secret (e.g., "api_key")
        public let id: String
        /// Display label for the secret (e.g., "API Key")
        public let label: String
        /// Rich text description with markdown links (e.g., "Get your key from [Example](https://example.com)")
        public let description: String?
        /// Whether this secret is required for the plugin to function
        public let required: Bool
        /// Optional URL to the settings page where users can obtain the secret
        public let url: String?

        public init(id: String, label: String, description: String? = nil, required: Bool = true, url: String? = nil) {
            self.id = id
            self.label = label
            self.description = description
            self.required = required
            self.url = url
        }
    }

    /// Plugin-level secrets (e.g., API keys, tokens)
    public let secrets: [SecretSpec]?

    /// Plugin documentation references
    public let docs: DocsSpec?

    // MARK: - Route Spec

    public enum RouteAuth: String, Decodable, Sendable {
        case none
        case verify
        case owner
    }

    public struct RouteSpec: Decodable, Sendable {
        public let id: String
        public let path: String
        public let methods: [String]
        public let description: String?
        public let auth: RouteAuth
        /// When true, the route is reachable over the agent tunnel (in
        /// addition to loopback). When false / nil, tunneled requests
        /// receive 404 even if the host knows the route exists. Defaults
        /// to false: routes are local-only by default and authors opt in
        /// explicitly for OAuth callbacks, webhooks, and other endpoints
        /// that need to be reachable over the public tunnel URL.
        public let tunnel_exposed: Bool?

        public init(
            id: String,
            path: String,
            methods: [String],
            description: String? = nil,
            auth: RouteAuth = .owner,
            tunnel_exposed: Bool? = nil
        ) {
            self.id = id
            self.path = path
            self.methods = methods
            self.description = description
            self.auth = auth
            self.tunnel_exposed = tunnel_exposed
        }

        /// Computed convenience: treats nil as the default (false).
        public var isTunnelExposed: Bool { tunnel_exposed == true }
    }

    // MARK: - Config Spec

    public struct ConfigSpec: Decodable, Sendable {
        public let title: String?
        public let sections: [ConfigSection]
    }

    public struct ConfigSection: Decodable, Sendable {
        public let title: String
        public let fields: [ConfigField]
    }

    public enum ConfigFieldType: String, Decodable, Sendable {
        case text
        case secret
        case toggle
        case select
        case multiselect
        case number
        case readonly
        case status
    }

    public struct ConfigFieldOption: Decodable, Sendable {
        public let value: String
        public let label: String
    }

    public struct ConnectAction: Decodable, Sendable {
        public let type: String?
        public let url_route: String?
    }

    public struct DisconnectAction: Decodable, Sendable {
        public let clear_keys: [String]?
    }

    public struct ValidationSpec: Decodable, Sendable {
        public let required: Bool?
        public let pattern: String?
        public let pattern_hint: String?
        public let min: Double?
        public let max: Double?
        public let min_length: Int?
        public let max_length: Int?
    }

    public struct ConfigField: Decodable, Sendable {
        public let key: String
        public let type: ConfigFieldType
        public let label: String
        public let placeholder: String?
        public let `default`: ConfigDefault?
        public let options: [ConfigFieldOption]?
        public let validation: ValidationSpec?
        public let connected_when: String?
        public let connect_action: ConnectAction?
        public let disconnect_action: DisconnectAction?
        public let value_template: String?
        public let copyable: Bool?
    }

    public enum ConfigDefault: Decodable, Sendable {
        case string(String)
        case bool(Bool)
        case number(Double)
        case stringArray([String])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let b = try? container.decode(Bool.self) { self = .bool(b); return }
            if let n = try? container.decode(Double.self) { self = .number(n); return }
            if let s = try? container.decode(String.self) { self = .string(s); return }
            if let a = try? container.decode([String].self) { self = .stringArray(a); return }
            throw DecodingError.typeMismatch(
                ConfigDefault.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported default value type")
            )
        }

        public var stringValue: String {
            switch self {
            case .string(let s): return s
            case .bool(let b): return b ? "true" : "false"
            case .number(let n): return String(n)
            case .stringArray(let a):
                let data = (try? JSONSerialization.data(withJSONObject: a, options: .osaurusCanonical)) ?? Data()
                return String(data: data, encoding: .utf8) ?? "[]"
            }
        }
    }

    // MARK: - Web Spec

    public struct WebSpec: Decodable, Sendable {
        public let static_dir: String
        public let entry: String
        public let mount: String
        public let auth: RouteAuth
        /// Optional custom API mount injected into `window.__osaurus.apiUrl`.
        /// Defaults to `/api` when nil. Plugins that mount their HTTP routes
        /// under a different prefix (e.g. `/v2`) can advertise the right URL
        /// to their web UI.
        public let api_mount: String?
        /// When true, the static UI is reachable over the agent tunnel
        /// (in addition to loopback). Defaults to false: web UIs are
        /// local-only unless the author opts in. Auth still applies on
        /// top — `auth: "owner"` requires `osk-v1` even on loopback.
        public let tunnel_exposed: Bool?

        /// Computed convenience: treats nil as the default (false).
        public var isTunnelExposed: Bool { tunnel_exposed == true }
    }

    // MARK: - Docs Spec

    public struct DocLink: Decodable, Sendable {
        public let label: String
        public let url: String
    }

    public struct DocsSpec: Decodable, Sendable {
        public let readme: String?
        public let changelog: String?
        public let links: [DocLink]?
    }

    // MARK: - Route Matching

    /// Result of `matchRouteWithParams`: the matched route plus any
    /// extracted path parameters keyed by the segment name.
    public struct RouteMatch: Sendable {
        public let route: RouteSpec
        /// Path parameters extracted by `:name` segments. Empty for routes
        /// that have no parameters.
        public let pathParams: [String: String]

        public init(route: RouteSpec, pathParams: [String: String] = [:]) {
            self.route = route
            self.pathParams = pathParams
        }
    }

    /// Finds the best matching route for a given HTTP method and subpath.
    /// The subpath is relative to the plugin's namespace (e.g., "/callback").
    public func matchRoute(method: String, subpath: String) -> RouteSpec? {
        return matchRouteWithParams(method: method, subpath: subpath)?.route
    }

    /// Finds the best matching route for a given method and subpath and
    /// extracts any `:name` path parameters. Match precedence is:
    /// 1. Exact path match (highest priority)
    /// 2. Path parameters (`:name` segments) — first defined wins
    /// 3. Wildcard suffix (`/*`) — lowest priority
    ///
    /// Path parameter syntax: `/items/:id` matches `/items/abc` and yields
    /// `{"id": "abc"}`. Multiple params are supported: `/users/:userId/posts/:postId`.
    /// Wildcards still take precedence over no-match but lose to exact and
    /// parameterised matches so plain SPA fallbacks (`/api/*`) keep working.
    public func matchRouteWithParams(method: String, subpath: String) -> RouteMatch? {
        guard let routes = capabilities.routes else { return nil }
        let normalizedMethod = method.uppercased()
        // Strip the query string if the caller passed `subpath` as a raw URI.
        let pathOnly = subpath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? subpath
        let normalizedPath = pathOnly.hasPrefix("/") ? pathOnly : "/\(pathOnly)"

        var paramMatch: RouteMatch?
        var wildcardMatch: RouteMatch?

        for route in routes {
            guard route.methods.contains(where: { $0.uppercased() == normalizedMethod }) else { continue }

            let routePath = route.path.hasPrefix("/") ? route.path : "/\(route.path)"

            // Exact match — return immediately (highest priority).
            if routePath == normalizedPath {
                return RouteMatch(route: route, pathParams: [:])
            }

            // Wildcard suffix — remember as fallback.
            if routePath.hasSuffix("/*") {
                let prefix = String(routePath.dropLast(2))
                if normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/") {
                    if wildcardMatch == nil {
                        wildcardMatch = RouteMatch(route: route, pathParams: [:])
                    }
                }
                continue
            }

            // Path parameter match — segment-by-segment, only the first
            // definition wins to give plugin authors deterministic ordering.
            if paramMatch == nil,
                let params = matchPathParams(routePath: routePath, requestPath: normalizedPath)
            {
                paramMatch = RouteMatch(route: route, pathParams: params)
            }
        }

        return paramMatch ?? wildcardMatch
    }

    /// Returns the captured path parameters when `requestPath` matches
    /// `routePath`'s `:name` segments, or nil if the paths cannot match.
    private func matchPathParams(routePath: String, requestPath: String) -> [String: String]? {
        let routeSegments = routePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let requestSegments = requestPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard routeSegments.count == requestSegments.count else { return nil }

        var params: [String: String] = [:]
        var hadParam = false
        for (rSeg, qSeg) in zip(routeSegments, requestSegments) {
            if rSeg.hasPrefix(":") {
                let name = String(rSeg.dropFirst())
                guard !name.isEmpty else { return nil }
                guard !qSeg.isEmpty else { return nil }
                params[name] = qSeg.removingPercentEncoding ?? qSeg
                hadParam = true
            } else if rSeg != qSeg {
                return nil
            }
        }
        // Must have actually used the parameter mechanism to be a "param" match;
        // exact matches were already returned above and shouldn't reach here.
        return hadParam ? params : nil
    }
}

final class ExternalPlugin: @unchecked Sendable {
    enum InvocationIsolation: Sendable, Equatable {
        case pluginQueue
        case mainActor
    }

    let id: String
    let manifest: PluginManifest
    let bundlePath: String
    let abiVersion: UInt32

    private let handle: UnsafeMutableRawPointer
    private let api: osr_plugin_api
    private let ctx: osr_plugin_ctx_t

    /// Atomic latch flipped exactly once by `shutdown()`. Read from
    /// `dispatchPluginCall` (invokeQueue), `notifyConfigBatch`
    /// (configEventQueue), and `notifyTaskEvent` (per-task queues) — three
    /// distinct queues, so a plain `Bool` would race per Swift 6 strict
    /// concurrency / TSan. The unfair lock matches the pattern used for
    /// `dbOpenLogLock` in `PluginHostContext`.
    private let isShutDown = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// One-shot latch guarding `destroy(ctx)`. `isShutDown` is flipped mid-drain
    /// (on `configEventQueue`) rather than once at the end, so it can no longer
    /// double as the "have we destroyed yet" dedup — concurrent shutdown
    /// attempts (PluginManager hot reload, etc.) each drain and await, but only
    /// the winner of this latch frees `ctx`.
    private let didDestroy = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Per-plugin concurrent queue for C ABI calls. Each plugin gets its own
    /// queue so that long-running operations (e.g. agentic inference) in one
    /// plugin don't block other plugins or additional requests to the same plugin.
    /// Concurrent (not serial) so multiple route handlers can run in parallel.
    private let invokeQueue: DispatchQueue

    /// Per-plugin **serial** queue for `on_config_changed` delivery.
    ///
    /// Config-change callbacks routinely mutate plugin-scoped state
    /// (HTTP clients, caches, webhook registrations) without internal
    /// locking, so two parallel invocations on the concurrent
    /// `invokeQueue` can race and corrupt that state. Routing config
    /// events through their own serial queue gives the plugin a one-at-a-
    /// time guarantee for the same plugin while leaving `invoke` /
    /// `handle_route` concurrency untouched. Contract is documented on
    /// `on_config_changed` in `osaurus_plugin.h`.
    private let configEventQueue: DispatchQueue

    /// Per `(agentId, key)` snapshot of the last value we successfully
    /// delivered through `on_config_changed`. Used by `notifyConfigBatch`
    /// to drop no-op pairs (same value as the prior delivery), so that a
    /// single rapid `Save` click — or the launch-time fan-out from
    /// `PluginManager` — does not cause the plugin to redo an expensive
    /// `setupWebhook` for a value it already saw. Cleared on shutdown.
    /// The key format is `"<agentId-or-default>|<configKey>"`.
    private let lastDeliveredConfig = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Per-task serial queues for event delivery. Each task gets its own queue
    /// so a slow event handler (e.g. http_request inside on_task_event) for one
    /// task doesn't block event delivery to other tasks. Serial ordering within
    /// each queue preserves the logical event sequence per task
    /// (STARTED → ACTIVITY → COMPLETED).
    private var taskEventQueues: [String: DispatchQueue] = [:]
    private let taskEventQueuesLock = NSLock()

    private func eventQueue(for taskId: String) -> DispatchQueue {
        taskEventQueuesLock.withLock {
            if let q = taskEventQueues[taskId] { return q }
            let q = DispatchQueue(
                label: "com.osaurus.plugin.events.\(id).\(taskId)",
                qos: .utility
            )
            taskEventQueues[taskId] = q
            return q
        }
    }

    private func removeEventQueue(for taskId: String) {
        taskEventQueuesLock.withLock {
            _ = taskEventQueues.removeValue(forKey: taskId)
        }
    }

    init(
        handle: UnsafeMutableRawPointer,
        api: osr_plugin_api,
        ctx: osr_plugin_ctx_t,
        manifest: PluginManifest,
        path: String,
        abiVersion: UInt32 = 1
    ) {
        self.handle = handle
        self.api = api
        self.ctx = ctx
        self.manifest = manifest
        self.bundlePath = path
        self.id = manifest.plugin_id
        self.abiVersion = abiVersion
        self.invokeQueue = DispatchQueue(
            label: "com.osaurus.plugin.invoke.\(manifest.plugin_id)",
            qos: .userInitiated,
            attributes: .concurrent
        )
        self.configEventQueue = DispatchQueue(
            label: "com.osaurus.plugin.config.\(manifest.plugin_id)",
            qos: .userInitiated
        )
    }

    var hasRouteHandler: Bool { abiVersion >= 2 && api.handle_route != nil }
    var hasTaskEventHandler: Bool { abiVersion >= 2 && api.on_task_event != nil }

    #if DEBUG
        /// Test-only: synchronously drains every per-task event queue and the
        /// config event queue, then returns. Intended to be called from the
        /// matched `removeLoadedPluginForTesting` cleanup so that any
        /// pending `notifyTaskEvent` / `notifyConfigBatch` callbacks have
        /// fired BEFORE the test's `Unmanaged.passRetained(...).release()`
        /// runs on the recorder it owns.
        ///
        /// Why this exists: the test seam in `PluginManager`
        /// (`removeLoadedPluginForTesting`) historically just dropped the
        /// plugin from `plugins`. The test then released its
        /// `Unmanaged<TaskEventRecorder>` retain in the same `defer`. Any
        /// event already enqueued on this plugin's per-task serial queue
        /// (typically a terminal event from `BackgroundTaskManager
        /// .finalizeTask` running in the inner `defer`) would fire AFTER
        /// the recorder was deallocated, dereferencing freed memory through
        /// the opaque `ctx` pointer and SIGSEGV-ing the xctest process.
        /// Symptom: 100+ tests across 50+ unrelated suites tagged
        /// "Test crashed with signal segv." in CI run 25738325529 (PR
        /// #1066). The actual offender — `PluginClarifyEmissionTests
        /// .clarifyEvent_emittedOnce_noTerminalFollows()` — was running in
        /// parallel with the dying batch, which xctest cannot identify on
        /// its own.
        ///
        /// `q.sync(flags: .barrier)` blocks the caller until the queue is
        /// idle. Safe to call from a `@MainActor` test body because the
        /// per-task event closures are pure CPU work (lock + Array
        /// append) and never re-enter the main actor.
        func drainEventQueuesForTesting() {
            let queues: [DispatchQueue] = taskEventQueuesLock.withLock {
                Array(taskEventQueues.values)
            }
            for q in queues {
                q.sync(flags: .barrier) {}
            }
            configEventQueue.sync {}
        }
    #endif

    /// Tears down the plugin context by draining the per-task event queues
    /// and the config event queue first, then the invoke queue (barrier),
    /// before calling `destroy`. Uses async dispatch so the destroy callback
    /// (which may call host API trampolines like httpRequest) never runs on
    /// the main thread, avoiding deadlocks with `blockingAsync`.
    func shutdown() async {
        let queues: [DispatchQueue] = taskEventQueuesLock.withLock {
            Array(taskEventQueues.values)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for q in queues {
                group.enter()
                q.async(flags: .barrier) { group.leave() }
            }
            // configEventQueue is serial, so a plain async tail-blocks
            // until every queued on_config_changed callback has returned.
            // Flip `isShutDown` from *inside* this drain marker rather than
            // synchronously at the top of `shutdown()`. Because the queue is
            // serial and in-order, every delivery enqueued before teardown
            // runs first (latch still false → delivered, `ctx` still valid),
            // and only a delivery enqueued *after* this marker — a
            // `notifyConfigBatch` racing teardown — sees the latch and
            // early-returns at its guard. That closes the use-after-free
            // (a late `configFn(freed ctx)` after `destroy` runs on
            // `invokeQueue`) without dropping deliveries that were already
            // in flight, which the queue drain is here to guarantee.
            group.enter()
            configEventQueue.async { [self] in
                self.isShutDown.withLock { $0 = true }
                group.leave()
            }
            group.notify(flags: .barrier, queue: self.invokeQueue) { [self] in
                // Destroy exactly once. Concurrent shutdown attempts (re-entry
                // from PluginManager hot reload, etc.) all drain and await here,
                // but only the winner of `didDestroy` frees `ctx`.
                let shouldDestroy = self.didDestroy.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard shouldDestroy else {
                    continuation.resume()
                    return
                }
                // Drop the dedup snapshot so a future re-load of the
                // same plugin path does not see stale "already delivered"
                // entries against a fresh ctx pointer.
                self.lastDeliveredConfig.withLock { $0.removeAll(keepingCapacity: false) }
                self.api.destroy?(self.ctx)
                continuation.resume()
            }
        }
    }

    /// Dispatches a blocking C ABI call on `invokeQueue` and returns the resulting string.
    /// Keeps `self` alive for the duration of the call to prevent `ctx` from being freed.
    /// `agentId` is propagated via thread-local storage so concurrent requests
    /// for different agents resolve the correct config.
    private func dispatchPluginCall(
        agentId: UUID? = nil,
        errorCode: Int,
        errorMessage: String,
        isolation: InvocationIsolation = .pluginQueue,
        _ call: @Sendable @escaping (osr_plugin_ctx_t) -> UnsafePointer<CChar>?
    ) async throws -> String {
        if isolation == .mainActor {
            return try await dispatchPluginCallOnMainActor(
                agentId: agentId,
                errorCode: errorCode,
                errorMessage: errorMessage,
                call
            )
        }

        let freeString = api.free_string
        nonisolated(unsafe) let ctx = self.ctx
        let pluginId = self.id

        return try await withCheckedThrowingContinuation { continuation in
            self.invokeQueue.async { [self] in
                guard !self.isShutDown.withLock({ $0 }) else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ExternalPlugin",
                            code: errorCode,
                            userInfo: [NSLocalizedDescriptionKey: "Plugin has been shut down"]
                        )
                    )
                    return
                }
                let resPtr = PluginHostContext.withTLSScope(pluginId: pluginId, agentId: agentId) {
                    call(ctx)
                }
                guard let resPtr else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ExternalPlugin",
                            code: errorCode,
                            userInfo: [NSLocalizedDescriptionKey: errorMessage]
                        )
                    )
                    return
                }

                let result = String(cString: resPtr)
                freeString?(resPtr)
                continuation.resume(returning: result)
                withExtendedLifetime(self) {}
            }
        }
    }

    @MainActor
    private func dispatchPluginCallOnMainActor(
        agentId: UUID? = nil,
        errorCode: Int,
        errorMessage: String,
        _ call: @Sendable (osr_plugin_ctx_t) -> UnsafePointer<CChar>?
    ) throws -> String {
        guard !isShutDown.withLock({ $0 }) else {
            throw NSError(
                domain: "ExternalPlugin",
                code: errorCode,
                userInfo: [NSLocalizedDescriptionKey: "Plugin has been shut down"]
            )
        }

        let freeString = api.free_string
        let ctx = self.ctx
        let pluginId = self.id
        // This synchronous C call runs on the main actor by design — native accessibility/
        // automation plugins hold main-thread-bound objects (see ExternalTool.invocationIsolation)
        // — and can legitimately block for seconds while it drives another app. Pause app-hang
        // tracking so that expected block isn't reported as a false-positive hang; the per-tool
        // timeout in ToolRegistry still bounds a genuinely stuck handler.
        let resPtr = CrashReportingService.shared.withAppHangTrackingPaused {
            PluginHostContext.withTLSScope(pluginId: pluginId, agentId: agentId) {
                call(ctx)
            }
        }
        guard let resPtr else {
            throw NSError(
                domain: "ExternalPlugin",
                code: errorCode,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        let result = String(cString: resPtr)
        freeString?(resPtr)
        withExtendedLifetime(self) {}
        return result
    }

    func invoke(
        type: String,
        id: String,
        payload: String,
        agentId: UUID? = nil,
        isolation: InvocationIsolation = .pluginQueue
    ) async throws -> String {
        guard let invokeFn = api.invoke else {
            throw NSError(
                domain: "ExternalPlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invoke not implemented"]
            )
        }

        // Identify the call on the Sentry scope so an app hang during a plugin invoke (which
        // otherwise symbolicates with no plugin frame) points at the responsible plugin/tool.
        CrashReportingService.recordBreadcrumb(
            category: "plugin.invoke",
            message: "plugin=\(self.id) type=\(type) id=\(id) isolation=\(isolation)"
        )

        return try await dispatchPluginCall(
            agentId: agentId,
            errorCode: 2,
            errorMessage: "Plugin returned NULL response",
            isolation: isolation
        ) { ctx in
            type.withCString { typePtr in
                id.withCString { idPtr in
                    payload.withCString { payloadPtr in
                        invokeFn(ctx, typePtr, idPtr, payloadPtr)
                    }
                }
            }
        }
    }

    /// Default per-route timeout. Mirrors `ToolRegistry.runToolBody`'s
    /// 120s wall-clock guard so a hung plugin handler never blocks the
    /// per-plugin invoke queue indefinitely.
    static let defaultRouteHandlerTimeoutSeconds: TimeInterval = 30

    func handleRoute(
        requestJSON: String,
        agentId: UUID? = nil,
        timeoutSeconds: TimeInterval = ExternalPlugin.defaultRouteHandlerTimeoutSeconds
    ) async throws -> String {
        guard abiVersion >= 2, let routeFn = api.handle_route else {
            throw NSError(
                domain: "ExternalPlugin",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Route handler not available (ABI v\(abiVersion))"]
            )
        }

        let work: @Sendable () async throws -> String = { [self] in
            try await dispatchPluginCall(
                agentId: agentId,
                errorCode: 4,
                errorMessage: "Plugin route handler returned NULL"
            ) { ctx in
                requestJSON.withCString { reqPtr in
                    routeFn(ctx, reqPtr)
                }
            }
        }

        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            for try await first in group {
                group.cancelAll()
                if let value = first { return value }
                throw NSError(
                    domain: "ExternalPlugin",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Plugin route handler timed out after \(Int(timeoutSeconds))s"
                    ]
                )
            }
            throw NSError(
                domain: "ExternalPlugin",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Plugin route handler returned without result"]
            )
        }
    }

    func notifyConfigChanged(
        key: String,
        value: String,
        agentId: UUID? = nil,
        force: Bool = false
    ) {
        notifyConfigBatch([(key: key, value: value)], agentId: agentId, force: force)
    }

    /// `force == true` bypasses the value-equality dedup in
    /// `prepareConfigDelivery` so `on_config_changed` re-fires even
    /// when every pair matches the prior delivery. Used by
    /// `PluginManager.handleAgentReconnected` so plugins re-assert
    /// upstream registrations after a relay reconnect.
    func notifyConfigBatch(
        _ changes: [(key: String, value: String)],
        agentId: UUID? = nil,
        force: Bool = false
    ) {
        guard
            let prep = prepareConfigDelivery(changes: changes, agentId: agentId, force: force)
        else { return }
        nonisolated(unsafe) let ctx = prep.ctx
        let configFn = prep.configFn
        let filtered = prep.filtered
        let pluginId = self.id

        // Serial — see `configEventQueue` for the rationale and contract.
        configEventQueue.async { [self] in
            self.runConfigDelivery(
                configFn: configFn,
                ctx: ctx,
                filtered: filtered,
                pluginId: pluginId,
                agentId: agentId
            )
            withExtendedLifetime(self) {}
        }
    }

    /// Synchronous variant of `notifyConfigBatch` — blocks the caller until
    /// the plugin's `on_config_changed` returns. Used by `PluginManager`
    /// during the load-time first-delivery window so that any plugin
    /// `abort()` (e.g. misaligned `osr_host_api` mirror calling
    /// `host->free_string` on a non-malloc pointer) leaves the
    /// `.currently_loading` marker on disk and quarantines the plugin on
    /// the next launch instead of crash-looping the host. Runtime config
    /// changes continue to use the async variant.
    ///
    /// Callers MUST hold the per-plugin loading marker around this call
    /// (see `PluginManager.runFirstDeliverySweep`); without it the
    /// crash-loop guard does nothing.
    ///
    /// Safe to call from any thread that is not the plugin's own
    /// `configEventQueue` (would deadlock). Plugins that do heavy work in
    /// `on_config_changed` (HTTP, OAuth refresh) will block the caller —
    /// the load path accepts that cost as part of a one-shot launch
    /// sweep; runtime callers should keep using the async variant.
    func notifyConfigBatchSync(
        _ changes: [(key: String, value: String)],
        agentId: UUID? = nil,
        force: Bool = false
    ) {
        guard
            let prep = prepareConfigDelivery(changes: changes, agentId: agentId, force: force)
        else { return }
        nonisolated(unsafe) let ctx = prep.ctx
        let configFn = prep.configFn
        let filtered = prep.filtered
        let pluginId = self.id

        configEventQueue.sync { [self] in
            self.runConfigDelivery(
                configFn: configFn,
                ctx: ctx,
                filtered: filtered,
                pluginId: pluginId,
                agentId: agentId
            )
            withExtendedLifetime(self) {}
        }
    }

    /// Runs the dedup pass and returns the trio of (callback, ctx,
    /// filtered changes) the queue body needs. Pulled out so `notifyConfigBatch`
    /// (async) and `notifyConfigBatchSync` (sync, used by the load-time
    /// crash-loop guard) share the same dedup contract — Telegram-style
    /// expensive-on-config_changed work must not re-run on no-op pushes
    /// regardless of which path delivered them.
    private func prepareConfigDelivery(
        changes: [(key: String, value: String)],
        agentId: UUID?,
        force: Bool = false
    ) -> (configFn: osr_on_config_changed_t, ctx: osr_plugin_ctx_t, filtered: [(key: String, value: String)])? {
        guard abiVersion >= 2, let configFn = api.on_config_changed, !changes.isEmpty else { return nil }
        let agentScope = agentId?.uuidString ?? "default"

        // Drop pairs that match the prior delivery for the same
        // `(agent, key)` so the plugin's `on_config_changed` body
        // doesn't re-run expensive work (Telegram `setupWebhook`,
        // OAuth refresh, etc.) on no-op pushes from
        // `PluginConfigView.loadConfig()` or the launch-time fan-out.
        // `force == true` skips the filter but still updates the
        // cache — opted in on relay reconnect, see callers.
        let filtered: [(key: String, value: String)] = self.lastDeliveredConfig.withLock {
            last -> [(key: String, value: String)] in
            var keep: [(key: String, value: String)] = []
            keep.reserveCapacity(changes.count)
            for change in changes {
                let cacheKey = "\(agentScope)|\(change.key)"
                if !force, last[cacheKey] == change.value { continue }
                last[cacheKey] = change.value
                keep.append(change)
            }
            return keep
        }
        guard !filtered.isEmpty else { return nil }
        return (configFn, ctx, filtered)
    }

    /// Body of the dispatch — checks the shutdown latch, scopes TLS,
    /// drives `on_config_changed` for each filtered pair. Shared between
    /// the async and sync delivery paths.
    private func runConfigDelivery(
        configFn: osr_on_config_changed_t,
        ctx: osr_plugin_ctx_t,
        filtered: [(key: String, value: String)],
        pluginId: String,
        agentId: UUID?
    ) {
        guard !self.isShutDown.withLock({ $0 }) else { return }
        PluginHostContext.withTLSScope(pluginId: pluginId, agentId: agentId) {
            for (key, value) in filtered {
                key.withCString { keyPtr in
                    value.withCString { valuePtr in
                        configFn(ctx, keyPtr, valuePtr)
                    }
                }
            }
        }
    }

    func notifyTaskEvent(taskId: String, eventType: TaskEventType, eventJSON: String, agentId: UUID? = nil) {
        guard abiVersion >= 2, let eventFn = api.on_task_event else { return }
        nonisolated(unsafe) let ctx = self.ctx
        let pluginId = self.id
        let rawType = eventType.rawValue
        let isTerminal = eventType == .completed || eventType == .failed || eventType == .cancelled

        eventQueue(for: taskId).async { [self] in
            guard !self.isShutDown.withLock({ $0 }) else { return }
            PluginHostContext.withTLSScope(pluginId: pluginId, agentId: agentId) {
                taskId.withCString { taskIdPtr in
                    eventJSON.withCString { jsonPtr in
                        eventFn(ctx, taskIdPtr, rawType, jsonPtr)
                    }
                }
            }
            if isTerminal {
                self.removeEventQueue(for: taskId)
            }
            withExtendedLifetime(self) {}
        }
    }

    /// Per-agent secrets merged on top of `Agent.defaultId` defaults.
    func resolvedSecrets(agentId: UUID) -> [String: String] {
        return ToolSecretsKeychain.resolvedSecretsWithDefaults(
            pluginId: manifest.plugin_id,
            agentId: agentId
        )
    }

    /// Checks if all required secrets are configured for the given agent.
    func hasAllRequiredSecrets(agentId: UUID) -> Bool {
        guard let specs = manifest.secrets else { return true }
        return ToolSecretsKeychain.hasAllRequiredSecrets(specs: specs, for: manifest.plugin_id, agentId: agentId)
    }
}

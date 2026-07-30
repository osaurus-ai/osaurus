//
//  PluginProcessHost.swift
//  osaurus
//
//  Parent side of the out-of-process native plugin host
//  (`PluginHost/main.swift`, built as the `osaurus-plugin-host`
//  executable). One helper process per plugin; newline-framed JSON-RPC
//  over stdin/stdout; a wall-clock deadline on every call. On breach the
//  helper is killed (SIGTERM → 2s → SIGKILL) and lazily respawned on the
//  next call — the "recover a wedged AX/automation plugin without
//  restarting Osaurus" primitive the in-process loader can never provide,
//  because synchronous plugin C code ignores Swift cancellation.
//
//  Host-API callbacks (config, db, http, log) arrive as reverse-RPC
//  requests from the helper and are served by the SAME `PluginHostContext`
//  the in-process trampolines use, under the same TLS plugin/agent scope —
//  one behavior, two transports.
//
//  Rollout is staged behind `PluginProcessHostMode.isEnabled` (default
//  off): when enabled, `ExternalPlugin.invoke` routes
//  accessibility/automation-isolated calls here and everything else stays
//  in-process.
//

import Foundation
import os

// MARK: - Mode / discovery

public enum PluginProcessHostMode {
    /// UserDefaults flag for staged rollout. Env override for tests/dev.
    public static let defaultsKey = "pluginProcessHostEnabled"

    public static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["OSAURUS_PLUGIN_PROCESS_HOST"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Locate the helper binary. Order: explicit env override (tests, dev
    /// runs), the app bundle's Helpers directory (release packaging), then
    /// next to the host executable (SwiftPM build layouts). Nil means the
    /// feature is unavailable and callers must stay in-process.
    public static func helperURL() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["OSAURUS_PLUGIN_HOST_PATH"],
            fm.isExecutableFile(atPath: override)
        {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/osaurus-plugin-host")
        if fm.isExecutableFile(atPath: bundled.path) { return bundled }
        if let exec = Bundle.main.executableURL {
            let sibling = exec.deletingLastPathComponent()
                .appendingPathComponent("osaurus-plugin-host")
            if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return nil
    }
}

// MARK: - Errors

public struct PluginProcessHostError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// JSON payloads cross task boundaries as `[String: Any]`, which Swift
/// cannot prove Sendable. Safe here: the dictionary is parsed once from
/// wire bytes, handed to exactly one continuation, and never mutated.
private struct HelperResponse: @unchecked Sendable {
    let object: [String: Any]
}

// MARK: - Client (one per plugin)

/// Owns one helper process hosting one plugin dylib. All state is
/// actor-isolated; the stdout reader runs as a child task feeding
/// responses back through actor methods.
actor PluginProcessHostClient {
    private let pluginId: String
    private let dylibPath: String
    private let helperURL: URL

    private var process: Process?
    private var stdinPipe: Pipe?
    /// Generation counter: lines read from a previous (killed) helper's
    /// pipe must not resolve pendings registered against its successor.
    private var processGeneration = 0
    private var loaded = false

    private var nextId = 1
    private var pending: [Int: CheckedContinuation<HelperResponse, Error>] = [:]

    /// Wall-clock budget for one plugin invocation before the helper is
    /// declared wedged and killed. Deliberately ABOVE ToolRegistry's 120s
    /// tool-timeout envelope: the tool layer answers the user first; this
    /// is the backstop that actually recovers the wedged process so the
    /// NEXT call doesn't queue behind dead C code forever.
    static let defaultInvokeDeadlineSeconds: Double = 150
    /// Budget for load (dlopen + init + manifest) — generous but bounded.
    static let loadDeadlineSeconds: Double = 30

    init(pluginId: String, dylibPath: String, helperURL: URL) {
        self.pluginId = pluginId
        self.dylibPath = dylibPath
        self.helperURL = helperURL
    }

    // MARK: Public surface

    func invoke(
        type: String,
        id: String,
        payload: String,
        agentId: UUID?,
        deadlineSeconds: Double = PluginProcessHostClient.defaultInvokeDeadlineSeconds
    ) async throws -> String {
        try await ensureLoaded()
        var params: [String: Any] = ["type": type, "id": id, "payload": payload]
        if let agentId { params["agent_id"] = agentId.uuidString }
        let result: [String: Any]
        do {
            result = try await callWithDeadline(
                method: "invoke", params: params, deadlineSeconds: deadlineSeconds
            )
        } catch is DeadlineExceededError {
            // The plugin is wedged in synchronous C code. Kill the helper —
            // the one recovery in-process execution can never offer.
            NSLog(
                "[PluginProcessHost] plugin=%@ invoke id=%@ exceeded %.0fs — killing helper",
                pluginId, id, deadlineSeconds
            )
            CrashReportingService.recordBreadcrumb(
                category: "plugin.host",
                message: "plugin=\(pluginId) wedged invoke killed after \(Int(deadlineSeconds))s"
            )
            await killProcess()
            throw PluginProcessHostError(
                message:
                    "Plugin '\(pluginId)' did not respond within \(Int(deadlineSeconds))s; its helper process was terminated and will restart on the next call"
            )
        }
        guard let value = result["result"] as? String else {
            throw PluginProcessHostError(message: "malformed invoke response")
        }
        return value
    }

    func notifyConfigChanged(key: String, value: String?, agentId: UUID?) async {
        guard loaded, process?.isRunning == true else { return }
        var params: [String: Any] = ["key": key]
        if let value { params["value"] = value }
        if let agentId { params["agent_id"] = agentId.uuidString }
        _ = try? await callWithDeadline(
            method: "config_changed", params: params, deadlineSeconds: 15
        )
    }

    /// Graceful shutdown: ask the helper to destroy the plugin and exit,
    /// then escalate to kill if it doesn't comply in time.
    func shutdown() async {
        guard let process, process.isRunning else { return }
        _ = try? await callWithDeadline(method: "shutdown", params: [:], deadlineSeconds: 5)
        await killProcess()
    }

    // MARK: Lifecycle

    private func ensureLoaded() async throws {
        if loaded, let process, process.isRunning { return }
        try await spawnAndLoad()
    }

    private func spawnAndLoad() async throws {
        await killProcess()

        let proc = Process()
        proc.executableURL = helperURL
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        processGeneration += 1
        self.process = proc
        self.stdinPipe = inPipe
        self.loaded = false
        startReader(
            handle: outPipe.fileHandleForReading, generation: processGeneration
        )

        do {
            let result = try await callWithDeadline(
                method: "load", params: ["path": dylibPath],
                deadlineSeconds: Self.loadDeadlineSeconds
            )
            guard result["manifest"] is String else {
                throw PluginProcessHostError(message: "helper load returned no manifest")
            }
        } catch {
            await killProcess()
            throw error
        }
        loaded = true
        NSLog(
            "[PluginProcessHost] plugin=%@ loaded in helper pid=%d",
            pluginId, proc.processIdentifier
        )
    }

    private func killProcess() async {
        failAllPending(message: "plugin helper terminated")
        loaded = false
        guard let process else { return }
        self.process = nil
        self.stdinPipe = nil  // closes helper stdin → EOF → reader exits
        guard process.isRunning else { return }
        process.terminate()
        // Grace period, then SIGKILL — same escalation as the imsg helper.
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func failAllPending(message: String) {
        let waiters = pending.values
        pending.removeAll()
        for continuation in waiters {
            continuation.resume(throwing: PluginProcessHostError(message: message))
        }
    }

    // MARK: RPC plumbing

    private func callWithDeadline(
        method: String, params: [String: Any], deadlineSeconds: Double
    ) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        guard let stdinPipe else {
            throw PluginProcessHostError(message: "helper not running")
        }
        let line: Data
        do {
            var request: [String: Any] = ["id": id, "method": method]
            if !params.isEmpty { request["params"] = params }
            line = try JSONSerialization.data(withJSONObject: request) + Data([0x0A])
        } catch {
            throw PluginProcessHostError(message: "encode failed: \(error)")
        }

        let response = try await valueWithDeadline(
            seconds: deadlineSeconds, operationName: "plugin-host \(method)"
        ) {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.register(id: id, continuation: continuation, write: line, to: stdinPipe)
                }
            }
        }
        return response.object
    }

    private func register(
        id: Int,
        continuation: CheckedContinuation<HelperResponse, Error>,
        write line: Data,
        to pipe: Pipe
    ) {
        pending[id] = continuation
        do {
            try pipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            pending.removeValue(forKey: id)
            continuation.resume(
                throwing: PluginProcessHostError(message: "helper write failed: \(error)")
            )
        }
    }

    private func resolvePending(id: Int, result: Result<HelperResponse, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    /// Reads helper stdout on a dedicated thread — `availableData` blocks,
    /// which must never park a Swift-concurrency pool thread. The thread
    /// exits on EOF, which arrives when the helper dies or `killProcess()`
    /// drops our reference to its stdin pipe.
    private func startReader(handle: FileHandle, generation: Int) {
        let pluginId = self.pluginId
        let client = self
        Thread.detachNewThread {
            Thread.current.name = "plugin-host-reader.\(pluginId)"
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF — helper exited or was killed
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    guard !lineData.isEmpty,
                        let object = try? JSONSerialization.jsonObject(with: lineData)
                            as? [String: Any]
                    else { continue }
                    if object["method"] is String {
                        // Reverse RPC: host-API callback from the plugin.
                        // Served synchronously on this thread — at most one
                        // is outstanding (the helper runs plugin calls
                        // serially, and the plugin is blocked inside its
                        // trampoline until we answer).
                        let response = PluginProcessHostCallbacks.handle(
                            pluginId: pluginId, message: object
                        )
                        if let response {
                            // Box the reply dictionary (parsed-once, single
                            // consumer) to cross into the actor.
                            let boxed = HelperResponse(object: response)
                            Task {
                                await client.writeToHelper(boxed, generation: generation)
                            }
                        }
                    } else if let id = object["id"] as? Int {
                        let result: Result<HelperResponse, Error>
                        if let errorObj = object["error"] as? [String: Any] {
                            let message = errorObj["message"] as? String ?? "unknown helper error"
                            result = .failure(PluginProcessHostError(message: message))
                        } else {
                            result = .success(
                                HelperResponse(object: object["result"] as? [String: Any] ?? [:])
                            )
                        }
                        Task {
                            await client.resolvePendingIfCurrent(
                                id: id, generation: generation, result: result
                            )
                        }
                    }
                }
            }
            // EOF: fail anything still waiting so callers don't hang.
            Task { await client.noteHelperExited(generation: generation) }
        }
    }

    private func writeToHelper(_ response: HelperResponse, generation: Int) {
        guard generation == processGeneration,
            let stdinPipe,
            let data = try? JSONSerialization.data(withJSONObject: response.object)
        else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    private func resolvePendingIfCurrent(
        id: Int, generation: Int, result: Result<HelperResponse, Error>
    ) {
        guard generation == processGeneration else { return }
        resolvePending(id: id, result: result)
    }

    private func noteHelperExited(generation: Int) {
        guard generation == processGeneration else { return }
        loaded = false
        failAllPending(message: "plugin helper exited")
    }
}

// MARK: - Reverse-RPC callback handling

/// Serves host-API callbacks from the helper using the same
/// `PluginHostContext` the in-process trampolines use, under the same TLS
/// plugin/agent scope. Synchronous by design: callbacks are string-in /
/// string-out and the context methods are already thread-safe.
enum PluginProcessHostCallbacks {

    /// Returns the response object to write back, or nil for notifications.
    static func handle(pluginId: String, message: [String: Any]) -> [String: Any]? {
        let method = (message["method"] as? String) ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        let agentId = (params["agent_id"] as? String).flatMap(UUID.init(uuidString:))

        func respond(_ value: String?) -> [String: Any]? {
            guard let id = message["id"] else { return nil }
            var result: [String: Any] = [:]
            if let value { result["value"] = value }
            return ["id": id, "result": result]
        }

        guard let ctx = PluginHostContext.getContext(for: pluginId) else {
            // Context torn down (plugin unloading) — answer "no value" so
            // the helper-side trampoline returns NULL instead of timing out.
            return respond(nil)
        }

        return PluginHostContext.withTLSScope(pluginId: pluginId, agentId: agentId) {
            switch method {
            case "host.config_get":
                guard let key = params["key"] as? String else { return respond(nil) }
                return respond(ctx.configGet(key: key))
            case "host.config_set":
                if let key = params["key"] as? String, let value = params["value"] as? String {
                    ctx.configSet(key: key, value: value)
                }
                return respond(nil)
            case "host.config_delete":
                if let key = params["key"] as? String { ctx.configDelete(key: key) }
                return respond(nil)
            case "host.db_exec":
                guard let sql = params["sql"] as? String else { return respond(nil) }
                return respond(ctx.dbExec(sql: sql, paramsJSON: params["params"] as? String))
            case "host.db_query":
                guard let sql = params["sql"] as? String else { return respond(nil) }
                return respond(ctx.dbQuery(sql: sql, paramsJSON: params["params"] as? String))
            case "host.http_request":
                guard let request = params["request"] as? String else { return respond(nil) }
                return respond(ctx.httpRequest(requestJSON: request))
            case "host.log", "host.log_structured":
                let level = params["level"] as? Int ?? 1
                let text = params["message"] as? String ?? ""
                NSLog("[Plugin:%@][helper] [%d] %@", pluginId, level, text)
                return nil  // notification — no response
            default:
                return respond(nil)
            }
        }
    }
}

// MARK: - Manager

/// Process-wide registry of helper clients, one per plugin id. Thread-safe;
/// looked up from `ExternalPlugin.invoke` (arbitrary executor).
public final class PluginProcessHostManager: @unchecked Sendable {
    public static let shared = PluginProcessHostManager()

    private let lock = NSLock()
    private var clients: [String: PluginProcessHostClient] = [:]

    /// Client for `pluginId`, creating one if the feature is enabled and
    /// the helper binary exists. Nil ⇒ caller must run in-process.
    func client(pluginId: String, dylibPath: String) -> PluginProcessHostClient? {
        guard PluginProcessHostMode.isEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[pluginId] { return existing }
        guard let helperURL = PluginProcessHostMode.helperURL() else { return nil }
        let client = PluginProcessHostClient(
            pluginId: pluginId, dylibPath: dylibPath, helperURL: helperURL
        )
        clients[pluginId] = client
        return client
    }

    /// Live client if one was already created (config forwarding — never
    /// spawns a helper just to deliver a config event).
    func existingClient(pluginId: String) -> PluginProcessHostClient? {
        lock.lock()
        defer { lock.unlock() }
        return clients[pluginId]
    }

    /// Shut down and forget the helper for one plugin (unload/reload path).
    public func shutdownClient(pluginId: String) async {
        let client = removeClient(pluginId: pluginId)
        await client?.shutdown()
    }

    public func shutdownAll() async {
        let all = removeAllClients()
        for client in all {
            await client.shutdown()
        }
    }

    private func removeClient(pluginId: String) -> PluginProcessHostClient? {
        lock.withLock { clients.removeValue(forKey: pluginId) }
    }

    private func removeAllClients() -> [PluginProcessHostClient] {
        lock.withLock {
            let all = Array(clients.values)
            clients.removeAll()
            return all
        }
    }
}

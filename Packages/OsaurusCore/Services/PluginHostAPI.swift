//
//  PluginHostAPI.swift
//  osaurus
//
//  Implements the host-side callbacks passed to v2 plugins via osr_host_api.
//  Each plugin gets its own host context with config (Keychain-backed) and
//  database (sandboxed SQLite) access.
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
            log: PluginHostContext.trampolineLog
        )
    }

    /// Removes this context from the global registry and closes the database.
    func teardown() {
        PluginHostContext.contexts.removeValue(forKey: pluginId)
        database.close()
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

    // Returns a C string that the caller must free with free().
    private static func makeCString(_ str: String) -> UnsafePointer<CChar>? {
        let cStr = strdup(str)
        return UnsafePointer(cStr)
    }

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
}

//
//  MockHost.swift
//  OsaurusPluginTestKit
//
//  Builds a `OsrHostAPI` whose callbacks route through Swift `MockHost`
//  instances. Plugin authors instantiate a `MockHost`, hand its
//  `hostAPIPointer` to the plugin's `osaurus_plugin_entry_v2`, and
//  then assert against the recorders to verify the plugin made the
//  expected host calls.
//
//  Why this design (`UnsafeMutableRawPointer` to `Unmanaged`):
//  `@convention(c)` callbacks cannot capture Swift state, so the
//  trampolines recover the `MockHost` instance from a static slot
//  the test installed before the plugin made the call. We use a
//  thread-local install stack so concurrent tests can run their
//  own `MockHost` without clobbering each other's slot.
//

import Foundation

/// Captures and replays host-API interactions a plugin made during a
/// test. Build one per test, install it before running plugin code,
/// and let `Self.deinit` (or an explicit `uninstall()`) restore the
/// previous host. Host-API method overrides are settable closures —
/// override only what your test exercises; the rest behave as
/// "no-op / NULL return" by default.
public final class MockHost: @unchecked Sendable {
    public init() {}

    // MARK: - Recorders

    /// Captures every `config_set` and `config_delete` the plugin made.
    public let configWrites = ConfigWriteRecorder()

    /// Captures every `host->log` call the plugin emitted.
    public let logs = LogRecorder()

    // MARK: - Override hooks

    /// Closure invoked for `config_get(key)`. Returning `nil` mirrors
    /// the real host's behavior when a key is missing. Default returns
    /// `nil` for every key.
    public var onConfigGet: (_ key: String) -> String? = { _ in nil }

    /// Closure invoked for `host->dispatch(json)`. Default returns a
    /// minimal `{"id":"<uuid>","status":"running"}` envelope so plugins
    /// that smoke-test their dispatch wiring without explicit
    /// expectations don't trip on a NULL response.
    public var onDispatch: (_ requestJSON: String) -> String = { _ in
        #"{"id":"\#(UUID().uuidString)","status":"running"}"#
    }

    /// Closure invoked for `host->http_request(json)`. Default returns
    /// a `network_error` envelope so a plugin under test isn't
    /// surprised when its HTTP call lands somewhere.
    public var onHttpRequest: (_ requestJSON: String) -> String = { _ in
        #"{"error":"network_error","message":"no mock handler installed","status":0}"#
    }

    /// Closure invoked for `host->get_active_agent_id`. Returns nil by
    /// default to mimic the "no agent context" frame (init / background
    /// thread). Tests that exercise per-agent code paths should set
    /// this to a UUID string before invoking the plugin callback.
    public var activeAgentId: String? = nil

    // MARK: - Install / uninstall

    /// Builds the C `OsrHostAPI` struct wired to this mock. The pointer
    /// is heap-allocated and lives until `freeHostAPI()` is called or
    /// the mock is deinitialized. Pass to the plugin's entry point.
    ///
    /// IMPORTANT: only one `MockHost` may be installed at a time on a
    /// given thread. Calling `hostAPIPointer` while another host is
    /// installed traps. Use `withInstalled { ... }` for nested or
    /// concurrent tests.
    public func hostAPIPointer() -> UnsafeMutablePointer<OsrHostAPI> {
        precondition(
            Thread.current.threadDictionary[Self.threadKey] == nil,
            "another MockHost is already installed on this thread; nest with `withInstalled`"
        )
        let retain = Unmanaged.passRetained(self)
        Thread.current.threadDictionary[Self.threadKey] = retain.toOpaque()

        let api = OsrHostAPI(
            version: 6,
            configGet: Self.trampolineConfigGet,
            configSet: Self.trampolineConfigSet,
            configDelete: Self.trampolineConfigDelete,
            log: Self.trampolineLog,
            dispatch: Self.trampolineDispatch,
            httpRequest: Self.trampolineHttpRequest,
            getActiveAgentId: Self.trampolineGetActiveAgentId,
            logStructured: Self.trampolineLogStructured,
            freeString: Self.trampolineHostFreeString
        )
        let ptr = UnsafeMutablePointer<OsrHostAPI>.allocate(capacity: 1)
        ptr.initialize(to: api)
        installedPointer = ptr
        return ptr
    }

    /// Frees the heap-allocated `OsrHostAPI` and clears the thread-
    /// local install slot. Idempotent. Call from your test's tearDown
    /// or use `withInstalled` which auto-cleans.
    public func uninstall() {
        if let ptr = installedPointer {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            installedPointer = nil
        }
        if let raw = Thread.current.threadDictionary[Self.threadKey] as? UnsafeMutableRawPointer {
            Unmanaged<MockHost>.fromOpaque(raw).release()
            Thread.current.threadDictionary.removeObject(forKey: Self.threadKey)
        }
    }

    deinit { uninstall() }

    private var installedPointer: UnsafeMutablePointer<OsrHostAPI>?

    // MARK: - Convenience

    /// Installs the mock for the duration of `body`, then restores the
    /// previous state. The closure receives the `OsrHostAPI*` to pass
    /// into `osaurus_plugin_entry_v2`.
    public func withInstalled<R>(
        _ body: (UnsafeMutablePointer<OsrHostAPI>) throws -> R
    ) rethrows -> R {
        let ptr = hostAPIPointer()
        defer { uninstall() }
        return try body(ptr)
    }

    // MARK: - Trampoline plumbing

    private static let threadKey = "ai.osaurus.plugintestkit.mockhost"

    private static func current() -> MockHost? {
        guard let raw = Thread.current.threadDictionary[threadKey] as? UnsafeMutableRawPointer
        else { return nil }
        return Unmanaged<MockHost>.fromOpaque(raw).takeUnretainedValue()
    }

    /// Heap-allocate `s` as a NUL-terminated C string the plugin
    /// is responsible for freeing via `host->free_string` (v6+) or
    /// `libc free()`. Mirrors the production `makeCString` — uses
    /// `withCString` explicitly to keep `strdup` away from the
    /// implicit `String → UnsafePointer<CChar>!` bridge that produced
    /// a heap-corruption abort in production.
    static func makeCString(_ s: String) -> UnsafePointer<CChar>? {
        s.withCString { cStrPtr -> UnsafePointer<CChar>? in
            guard let copy = strdup(cStrPtr) else { return nil }
            return UnsafePointer(copy)
        }
    }

    private static let trampolineConfigGet: OsrConfigGet = { keyPtr in
        guard let host = current(), let keyPtr else { return nil }
        let key = String(cString: keyPtr)
        guard let value = host.onConfigGet(key) else { return nil }
        return makeCString(value)
    }

    private static let trampolineConfigSet: OsrConfigSet = { keyPtr, valuePtr in
        guard let host = current(), let keyPtr, let valuePtr else { return }
        host.configWrites.recordSet(
            key: String(cString: keyPtr),
            value: String(cString: valuePtr)
        )
    }

    private static let trampolineConfigDelete: OsrConfigDelete = { keyPtr in
        guard let host = current(), let keyPtr else { return }
        host.configWrites.recordDelete(key: String(cString: keyPtr))
    }

    private static let trampolineLog: OsrLog = { level, msgPtr in
        guard let host = current(), let msgPtr else { return }
        host.logs.record(level: Int(level), message: String(cString: msgPtr))
    }

    /// Structured-log trampoline (v5). Records the payload alongside
    /// the message via the same `LogRecorder`. NULL payload degrades
    /// to a normal log entry.
    private static let trampolineLogStructured: OsrLogStructured = { level, msgPtr, payloadPtr in
        guard let host = current(), let msgPtr else { return }
        let message = String(cString: msgPtr)
        if let payloadPtr {
            host.logs.record(
                level: Int(level),
                message: "\(message) \(String(cString: payloadPtr))"
            )
        } else {
            host.logs.record(level: Int(level), message: message)
        }
    }

    private static let trampolineDispatch: OsrDispatch = { jsonPtr in
        guard let host = current(), let jsonPtr else { return nil }
        return makeCString(host.onDispatch(String(cString: jsonPtr)))
    }

    private static let trampolineHttpRequest: OsrHttpRequest = { jsonPtr in
        guard let host = current(), let jsonPtr else { return nil }
        return makeCString(host.onHttpRequest(String(cString: jsonPtr)))
    }

    private static let trampolineGetActiveAgentId: OsrGetActiveAgentId = {
        guard let host = current(), let id = host.activeAgentId else { return nil }
        return makeCString(id)
    }

    /// v6 host-side free for host-returned strings. Internally `libc
    /// free()` — same as the production trampoline. Tests that drive
    /// the plugin against this mock can route freed pointers through
    /// `host->free_string` and exercise the same path the real host
    /// uses.
    private static let trampolineHostFreeString: OsrHostFreeString = { ptr in
        guard let ptr else { return }
        free(UnsafeMutableRawPointer(mutating: ptr))
    }
}

// MARK: - Recorders

/// Captures `config_set` and `config_delete` interactions. Lock-
/// protected so a plugin's background thread can write into it
/// without violating Swift 6 strict concurrency.
public final class ConfigWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Write] = []

    public enum Write: Equatable {
        case set(key: String, value: String)
        case delete(key: String)
    }

    public init() {}

    public var writes: [Write] {
        lock.withLock { _writes }
    }

    public var setCount: Int {
        lock.withLock { _writes.reduce(0) { $0 + (Self.isSet($1) ? 1 : 0) } }
    }

    public var deleteCount: Int {
        lock.withLock { _writes.reduce(0) { $0 + (Self.isSet($1) ? 0 : 1) } }
    }

    private static func isSet(_ write: Write) -> Bool {
        if case .set = write { return true }
        return false
    }

    /// Convenience: returns the most recently set value for `key`, or
    /// nil if the plugin never set it. Useful for "did the plugin
    /// actually persist what we expect?" assertions.
    public func lastValue(forKey key: String) -> String? {
        lock.withLock {
            for write in _writes.reversed() {
                if case .set(let k, let v) = write, k == key { return v }
            }
            return nil
        }
    }

    func recordSet(key: String, value: String) {
        lock.withLock { _writes.append(.set(key: key, value: value)) }
    }

    func recordDelete(key: String) {
        lock.withLock { _writes.append(.delete(key: key)) }
    }
}

/// Captures every `host->log(level, msg)` call the plugin made.
public final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [Entry] = []

    public struct Entry: Equatable {
        public let level: Int
        public let message: String
    }

    public init() {}

    public var entries: [Entry] {
        lock.withLock { _entries }
    }

    public var messages: [String] {
        lock.withLock { _entries.map(\.message) }
    }

    /// Convenience: true if any logged message contains `substring`.
    public func contains(_ substring: String) -> Bool {
        lock.withLock { _entries.contains { $0.message.contains(substring) } }
    }

    func record(level: Int, message: String) {
        lock.withLock { _entries.append(Entry(level: level, message: message)) }
    }
}

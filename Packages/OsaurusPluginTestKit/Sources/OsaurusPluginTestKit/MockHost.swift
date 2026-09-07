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
//  trampolines recover the `MockHost` instance from a per-thread slot
//  the test installed before the plugin made the call. The slot is a
//  thread-local install stack: concurrent tests on different threads keep
//  their own `MockHost`, and a `withInstalled { ... }` may nest inside
//  another, restoring the outer host on exit. Host-global callbacks
//  (log / config / dispatch / http) made from a plugin-spawned background
//  thread — which has no slot of its own — fall back to the uniquely
//  installed host so they are still recorded.
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
    /// is heap-allocated and lives until `uninstall()` is called or the
    /// mock is deinitialized. Pass to the plugin's entry point.
    ///
    /// Installs onto this thread's install stack: any host already installed
    /// on the thread is saved and restored when this one is uninstalled, so
    /// a `withInstalled { ... }` may nest inside another. Installing the same
    /// `MockHost` twice without an intervening `uninstall()` traps.
    public func hostAPIPointer() -> UnsafeMutablePointer<OsrHostAPI> {
        precondition(
            !didInstall,
            "this MockHost is already installed; uninstall() it (or use `withInstalled`) before reinstalling"
        )
        let retain = Unmanaged.passRetained(self)
        // Save the host this one displaces so uninstall() can restore it
        // (the install stack), rather than unconditionally clearing the slot.
        previousSlot = Thread.current.threadDictionary[Self.threadKey] as? UnsafeMutableRawPointer
        Thread.current.threadDictionary[Self.threadKey] = retain.toOpaque()
        didInstall = true
        Self.registryLock.withLock {
            Self.installedHosts[ObjectIdentifier(self)] = Unmanaged.passUnretained(self)
        }

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

    /// Frees the heap-allocated `OsrHostAPI`, drops this host's retain, and
    /// restores the host it displaced on this thread's install stack (clearing
    /// the slot if there was none). Idempotent. Call from your test's tearDown
    /// or use `withInstalled` which auto-cleans.
    public func uninstall() {
        if let ptr = installedPointer {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            installedPointer = nil
        }
        Self.registryLock.withLock {
            Self.installedHosts[ObjectIdentifier(self)] = nil
        }
        guard didInstall else { return }
        didInstall = false
        // The install stack must unwind last-in-first-out on the install
        // thread: this host's retained opaque is owned by the thread slot
        // (if it is still the top) or has been moved into the `previousSlot`
        // of whatever host was installed after it. Releasing it while a later
        // host still references it would dangle that host's `previousSlot`, so
        // a non-LIFO (or cross-thread) uninstall is unsupported and traps
        // rather than silently leaking. `withInstalled`'s `defer` guarantees
        // LIFO, so the blessed path never hits this.
        let selfOpaque = Unmanaged.passUnretained(self).toOpaque()
        precondition(
            Thread.current.threadDictionary[Self.threadKey] as? UnsafeMutableRawPointer == selfOpaque,
            "MockHost.uninstall() must run on the install thread and unwind in LIFO order; use `withInstalled` to guarantee this"
        )
        Unmanaged<MockHost>.fromOpaque(selfOpaque).release()
        if let previousSlot {
            Thread.current.threadDictionary[Self.threadKey] = previousSlot
        } else {
            Thread.current.threadDictionary.removeObject(forKey: Self.threadKey)
        }
        previousSlot = nil
    }

    deinit { uninstall() }

    private var installedPointer: UnsafeMutablePointer<OsrHostAPI>?

    /// True between `hostAPIPointer()` and `uninstall()`. Guards against
    /// double-install and makes `uninstall()` idempotent.
    private var didInstall = false

    /// The opaque pointer this host displaced on its install thread, restored
    /// on `uninstall()` so installs nest correctly.
    private var previousSlot: UnsafeMutableRawPointer?

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

    /// Process-wide set of currently-installed hosts, used to attribute a
    /// host-global callback made from a plugin-spawned background thread (which
    /// carries no thread-local install slot). A background callback resolves to
    /// the host here only when exactly one is installed; with two or more the
    /// call is ambiguous and is dropped rather than misrouted.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var installedHosts: [ObjectIdentifier: Unmanaged<MockHost>] = [:]

    /// The host bound to the current per-agent frame (the calling thread's
    /// install slot). Used by `get_active_agent_id`, which must return NULL
    /// outside a per-agent frame — including a background thread — per the
    /// host ABI.
    private static func current() -> MockHost? {
        guard let raw = Thread.current.threadDictionary[threadKey] as? UnsafeMutableRawPointer
        else { return nil }
        return Unmanaged<MockHost>.fromOpaque(raw).takeUnretainedValue()
    }

    /// The host to route a host-global callback (log / config / dispatch /
    /// http) to. Prefers the calling thread's install slot; if there is none
    /// (a plugin-spawned background thread) it falls back to the uniquely
    /// installed host so the call is still recorded. Returns nil when zero or
    /// more-than-one hosts are installed, so an ambiguous background call is
    /// dropped rather than attributed to the wrong recorder.
    private static func recordingHost() -> MockHost? {
        if let host = current() { return host }
        return registryLock.withLock {
            installedHosts.count == 1 ? installedHosts.values.first?.takeUnretainedValue() : nil
        }
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
        guard let host = recordingHost(), let keyPtr else { return nil }
        let key = String(cString: keyPtr)
        guard let value = host.onConfigGet(key) else { return nil }
        return makeCString(value)
    }

    private static let trampolineConfigSet: OsrConfigSet = { keyPtr, valuePtr in
        guard let host = recordingHost(), let keyPtr, let valuePtr else { return }
        host.configWrites.recordSet(
            key: String(cString: keyPtr),
            value: String(cString: valuePtr)
        )
    }

    private static let trampolineConfigDelete: OsrConfigDelete = { keyPtr in
        guard let host = recordingHost(), let keyPtr else { return }
        host.configWrites.recordDelete(key: String(cString: keyPtr))
    }

    private static let trampolineLog: OsrLog = { level, msgPtr in
        guard let host = recordingHost(), let msgPtr else { return }
        host.logs.record(level: Int(level), message: String(cString: msgPtr))
    }

    /// Structured-log trampoline (v5). Records the payload alongside
    /// the message via the same `LogRecorder`. NULL payload degrades
    /// to a normal log entry.
    private static let trampolineLogStructured: OsrLogStructured = { level, msgPtr, payloadPtr in
        guard let host = recordingHost(), let msgPtr else { return }
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
        guard let host = recordingHost(), let jsonPtr else { return nil }
        return makeCString(host.onDispatch(String(cString: jsonPtr)))
    }

    private static let trampolineHttpRequest: OsrHttpRequest = { jsonPtr in
        guard let host = recordingHost(), let jsonPtr else { return nil }
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

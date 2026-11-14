//
//  SandboxInteractiveActivity.swift
//  osaurus
//
//  Unanswered JSON-RPC requests of one long-lived sandbox process (a
//  stdio MCP server). An idle server is not running work, so a pod
//  restart may stop it (its provider reconnects afterwards); a server
//  with a request in flight is, so a restart waits for it.
//

import Foundation

public final class SandboxInteractiveActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Set<String> = []

    public init() {}

    public var isBusy: Bool { lock.withLock { !pending.isEmpty } }

    /// A frame the host sent: a request (has `method` and `id`) opens one.
    public func noteSent(_ frame: Data) {
        guard let message = Self.object(frame), message["method"] != nil, let id = Self.id(message) else { return }
        lock.withLock { _ = pending.insert(id) }
    }

    /// A frame the server sent: a response (has `id`, no `method`) closes one.
    public func noteReceived(_ frame: Data) {
        guard let message = Self.object(frame), message["method"] == nil, let id = Self.id(message) else { return }
        lock.withLock { _ = pending.remove(id) }
    }

    public func reset() { lock.withLock { pending.removeAll() } }

    private static func object(_ frame: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any]
    }

    private static func id(_ message: [String: Any]) -> String? {
        switch message["id"] {
        case let string as String: return "s:\(string)"
        case let number as NSNumber: return "n:\(number.stringValue)"
        default: return nil
        }
    }
}

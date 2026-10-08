//
//  MCPToolProgress.swift
//  osaurus
//
//  `notifications/progress` plumbing for remote MCP tool calls. Each call
//  sends a fresh `progressToken`; the per-client notification handler routes
//  progress back to the waiting call, which (a) treats it as proof of life so
//  a long-running research tool is not killed at the idle timeout, and
//  (b) surfaces the server's message on the chat tool card.
//

import Foundation
import MCP

/// Routes `notifications/progress` to the call that owns the token.
final class MCPProgressRouter: @unchecked Sendable {
    static let shared = MCPProgressRouter()

    typealias Handler = @Sendable (ProgressNotification.Parameters) -> Void

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func register(token: String, handler: @escaping Handler) {
        lock.withLock { handlers[token] = handler }
    }

    func unregister(token: String) {
        lock.withLock { _ = handlers.removeValue(forKey: token) }
    }

    func deliver(_ params: ProgressNotification.Parameters) {
        let handler = lock.withLock { handlers[Self.key(params.progressToken)] }
        handler?(params)
    }

    static func key(_ token: ProgressToken) -> String {
        switch token {
        case .string(let s): return s
        case .integer(let i): return String(i)
        }
    }
}

/// Latest progress text per chat tool-call id, read by the tool card while the
/// call is running.
final class MCPToolProgressRegistry: @unchecked Sendable {
    static let shared = MCPToolProgressRegistry()

    private let lock = NSLock()
    private var messages: [String: String] = [:]

    func message(for toolCallId: String) -> String? {
        lock.withLock { messages[toolCallId] }
    }

    func update(toolCallId: String, params: ProgressNotification.Parameters) {
        guard let text = Self.displayText(params) else { return }
        let changed = lock.withLock { () -> Bool in
            guard messages[toolCallId] != text else { return false }
            messages[toolCallId] = text
            return true
        }
        if changed { post(toolCallId) }
    }

    func clear(toolCallId: String) {
        let removed = lock.withLock { messages.removeValue(forKey: toolCallId) != nil }
        if removed { post(toolCallId) }
    }

    /// Server message plus a percentage when `total` is known, truncated so a
    /// chatty server cannot blow out the collapsed row.
    static func displayText(_ params: ProgressNotification.Parameters) -> String? {
        var parts: [String] = []
        if let message = params.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            parts.append(message.count > 80 ? String(message.prefix(79)) + "…" : message)
        }
        if let total = params.total, total > 0 {
            let percent = Int((min(max(params.progress / total, 0), 1) * 100).rounded())
            parts.append("\(percent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func post(_ toolCallId: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpToolProgressChanged, object: toolCallId)
        }
    }
}

extension Foundation.Notification.Name {
    static let mcpToolProgressChanged = Notification.Name("ai.osaurus.mcpToolProgressChanged")
}

/// Last time the server showed signs of life for one call. While held (the
/// user is answering an elicitation prompt) the call counts as active.
final class MCPActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date
    private var holds = 0

    init(_ now: Date = Date()) { last = now }

    func touch() { lock.withLock { last = Date() } }

    func hold() { lock.withLock { holds += 1 } }

    func release() {
        lock.withLock {
            holds = max(0, holds - 1)
            last = Date()
        }
    }

    var lastActivity: Date { lock.withLock { holds > 0 ? Date() : last } }
}

/// Await `work` until it finishes, the server goes quiet for `idleTimeout`, or
/// `hardCap` elapses since `start` — whichever comes first. Progress touches
/// `clock` and pushes the idle deadline out; the cap bounds a server that
/// reports progress forever.
func valueWithActivityDeadline<T: Sendable>(
    idleTimeout: TimeInterval,
    hardCap: TimeInterval,
    clock: MCPActivityClock,
    operationName: String,
    start: Date = Date(),
    work: Task<T, Error>
) async throws -> T {
    let capDeadline = start.addingTimeInterval(max(hardCap, idleTimeout))
    while true {
        let deadline = min(clock.lastActivity.addingTimeInterval(idleTimeout), capDeadline)
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            work.cancel()
            throw DeadlineExceededError(operationName: operationName, seconds: idleTimeout)
        }
        do {
            return try await valueWithDeadline(seconds: remaining, operationName: operationName) {
                try await work.value
            }
        } catch is DeadlineExceededError {
            continue
        } catch is CancellationError {
            work.cancel()
            throw CancellationError()
        }
    }
}

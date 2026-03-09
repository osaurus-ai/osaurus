//
//  SandboxEventBus.swift
//  osaurus
//
//  Cross-plugin event bus with source tagging.
//  Events from sandbox plugins carry `source: sandbox:{plugin-name}`.
//  Events from native plugins carry `source: native:{plugin-name}`.
//

import Foundation

public final class SandboxEventBus: @unchecked Sendable {
    public static let shared = SandboxEventBus()

    public struct Event: Sendable {
        public let type: String
        public let source: String
        public let payload: String
        public let timestamp: Date

        public init(type: String, source: String, payload: String = "{}") {
            self.type = type
            self.source = source
            self.payload = payload
            self.timestamp = Date()
        }
    }

    public typealias Handler = @Sendable (Event) -> Void

    private struct Subscription {
        let id: UUID
        let eventType: String?
        let handler: Handler
    }

    private let lock = NSLock()
    private var subscriptions: [Subscription] = []
    private var recentEvents: [Event] = []
    private let maxRecentEvents = 100

    private init() {}

    // MARK: - Subscribe

    /// Subscribe to events. Pass nil for eventType to receive all events.
    @discardableResult
    public func subscribe(eventType: String? = nil, handler: @escaping Handler) -> UUID {
        let id = UUID()
        lock.withLock {
            subscriptions.append(Subscription(id: id, eventType: eventType, handler: handler))
        }
        return id
    }

    public func unsubscribe(id: UUID) {
        lock.withLock {
            subscriptions.removeAll { $0.id == id }
        }
    }

    // MARK: - Emit

    public func emit(type: String, source: String, payload: String = "{}") {
        let event = Event(type: type, source: source, payload: payload)

        lock.withLock {
            recentEvents.append(event)
            if recentEvents.count > maxRecentEvents {
                recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
            }
        }

        let subs: [Subscription] = lock.withLock { subscriptions }
        for sub in subs {
            if sub.eventType == nil || sub.eventType == type {
                sub.handler(event)
            }
        }

        // Forward to NotificationCenter for native code
        NotificationCenter.default.post(
            name: Notification.Name("SandboxEvent.\(type)"),
            object: nil,
            userInfo: [
                "source": source,
                "type": type,
                "payload": payload,
                "timestamp": event.timestamp,
            ]
        )
    }

    /// Emit from a sandbox plugin (auto-tags source).
    public func emitFromSandbox(type: String, pluginName: String, payload: String = "{}") {
        emit(type: type, source: "sandbox:\(pluginName)", payload: payload)
    }

    /// Emit from a native plugin (auto-tags source).
    public func emitFromNative(type: String, pluginName: String, payload: String = "{}") {
        emit(type: type, source: "native:\(pluginName)", payload: payload)
    }

    // MARK: - Query

    public func recentEventsOfType(_ type: String) -> [Event] {
        lock.withLock {
            recentEvents.filter { $0.type == type }
        }
    }
}

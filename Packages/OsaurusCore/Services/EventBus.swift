//
//  EventBus.swift
//  osaurus
//
//  Host-side event bus for plugin communication. Plugins subscribe to and emit
//  typed events. Events never flow directly between plugins or VMs — they are
//  always mediated by this bus on the host.
//

import Foundation

public actor EventBus {
    public static let shared = EventBus()

    struct Subscription: Sendable {
        let id: UUID
        let eventType: String
        let pluginId: String
        let handler: @Sendable (String, String) -> Void
    }

    private var subscriptions: [String: [Subscription]] = [:]

    private init() {}

    // MARK: - Subscribe / Unsubscribe

    /// Subscribe to events of a given type. Returns a subscription ID for later removal.
    @discardableResult
    public func subscribe(
        eventType: String,
        pluginId: String,
        handler: @escaping @Sendable (String, String) -> Void
    ) -> UUID {
        let sub = Subscription(id: UUID(), eventType: eventType, pluginId: pluginId, handler: handler)
        subscriptions[eventType, default: []].append(sub)
        return sub.id
    }

    /// Remove a single subscription by ID.
    public func unsubscribe(id: UUID) {
        for (eventType, subs) in subscriptions {
            subscriptions[eventType] = subs.filter { $0.id != id }
            if subscriptions[eventType]?.isEmpty == true {
                subscriptions.removeValue(forKey: eventType)
            }
        }
    }

    /// Remove all subscriptions for a given plugin.
    public func unsubscribeAll(pluginId: String) {
        for (eventType, subs) in subscriptions {
            subscriptions[eventType] = subs.filter { $0.pluginId != pluginId }
            if subscriptions[eventType]?.isEmpty == true {
                subscriptions.removeValue(forKey: eventType)
            }
        }
    }

    // MARK: - Emit

    /// Emit an event to all subscribers of the given type. Handlers are invoked
    /// concurrently in detached tasks so the caller is never blocked.
    public func emit(eventType: String, payload: String) {
        guard let subs = subscriptions[eventType] else { return }
        for sub in subs {
            let handler = sub.handler
            let type = eventType
            Task.detached { handler(type, payload) }
        }
    }
}

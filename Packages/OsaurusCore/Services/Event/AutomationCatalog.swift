//
//  AutomationCatalog.swift
//  osaurus
//
//  The ways a workflow can run on its own, as the Workflows screens offer
//  them: one entry per source kind Add Automation offers, in friendly
//  words, with the named-service webhooks as one "When an app has news"
//  entry. A generic webhook and event streams stay under Advanced in
//  Settings; channel messages and mail belong to Channels.
//

import Foundation

enum AutomationCatalog {
    enum Entry: Hashable, Sendable {
        case kind(EventSourceKind)
        /// A webhook from one of `WebhookProvider.services`.
        case appNews
    }

    struct Item: Hashable, Identifiable, Sendable {
        let entry: Entry
        let title: String
        let example: String
        let icon: String
        var id: Entry { entry }
    }

    /// Kinds that only Settings' Advanced offers.
    static let advancedKinds: Set<EventSourceKind> = [.sse]

    static var items: [Item] {
        EventSourceRegistry.pickerKinds.compactMap { kind -> Item? in
            guard !advancedKinds.contains(kind) else { return nil }
            let descriptor = kind.descriptor
            return Item(
                entry: kind == .webhook ? .appNews : .kind(kind),
                title: descriptor.friendlyTitle, example: descriptor.friendlyExample, icon: descriptor.icon)
        }
    }

    static func entry(for event: OsaurusEvent) -> Entry? {
        switch event.source {
        case .webhook(let webhook): return webhook.provider == .generic ? nil : .appNews
        case .sse, .email, .channelMessage: return nil
        default: return .kind(event.sourceKind)
        }
    }

    /// How many workflows have an automation of this kind that is on.
    static func enabledWorkflowCount(_ entry: Entry, in events: [OsaurusEvent]) -> Int {
        Set(events.filter { $0.isEnabled && self.entry(for: $0) == entry }.compactMap(\.action.workflow?.workflowID)).count
    }
}

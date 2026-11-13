//
//  EventSourceDescriptor.swift
//  osaurus
//
//  Everything static the app knows about one source kind: how it is shown,
//  which payload block it fills, how its runs are labeled and queued, how
//  repeats are detected, and which values it hands to instructions and
//  workflow inputs. `EventSourceRegistry.descriptor(for:)` is the only
//  lookup; adding a kind means adding a descriptor here and an adapter in
//  `EventManager.adapters` (see docs/AUTOMATIONS.md, "Adding a source kind").
//
//  Config-dependent behavior (summaries, sample payloads, config
//  round-trip) stays on the closed `EventSource` enum so the compiler finds
//  every place a new kind must be handled.
//

import Foundation

/// How a kind's repeats are detected.
public enum EventDedupeMode: String, Codable, CaseIterable, Sendable {
    /// Every occurrence runs (folder passes, id-less streams).
    case none
    /// A repeated delivery id inside a time window is a duplicate
    /// (schedule slots, webhook idempotency keys, channel event ids).
    case window
    /// A delivery id is a duplicate forever (mail Message-ID, feed guid):
    /// survives relaunch, cursor resets and ledger pruning.
    case durable
}

/// Whether one source tick yields one occurrence per item or one per batch.
public enum EventEmitMode: String, Codable, CaseIterable, Sendable {
    case perItem = "per_item"
    case perBatch = "per_batch"
}

/// The filter clauses that mean something for a kind; the editor shows
/// only these and drops the rest on save.
public enum EventFilterClause: String, CaseIterable, Sendable {
    case senders
    case keywords
    case pathGlobs
    case conditions
}

protocol EventSourceDescriptor: Sendable {
    var kind: EventSourceKind { get }
    var displayName: String { get }
    var icon: String { get }
    /// One line under the title in "Add Automation".
    var subtitle: String { get }
    /// Top-level payload key this kind fills (`schedule`, `webhook`, …).
    var payloadRoot: String { get }
    /// Runtime session source of the agent runs it starts — what tool and
    /// publish gates see. The session row persists `.automation` plus this
    /// kind (`SessionSource.runtimeSource(automationKind:)`).
    var sessionSource: SessionSource { get }
    /// Insights request source for its activity rows.
    var requestSource: RequestSource { get }
    var defaultDelivery: EventDeliveryPolicy { get }
    var defaultFreshSession: Bool { get }
    var dedupeMode: EventDedupeMode { get }
    var emitMode: EventEmitMode { get }
    /// Connection types an event of this kind points at; empty = none.
    var connectionTypes: [SourceConnectionType] { get }
    /// Offered in the Add Automation picker. Channel rules are added from
    /// Channels instead.
    var isOfferedInPicker: Bool { get }
    /// Group title and subtitle on the Automations list (picker kinds only).
    var listTitle: String { get }
    var listSubtitle: String { get }
    /// Title of the Automations History chip; nil = no chip.
    var historyChipTitle: String? { get }
    var filterClauses: Set<EventFilterClause> { get }
    /// Label of the `{{text}}` trigger value.
    var textLabel: String { get }
    /// A caller-supplied conversation key picks the chat (webhook
    /// `X-Osaurus-Conversation`).
    var usesConversationSessions: Bool { get }
    /// Payload paths the Senders filter matches against.
    var senderPaths: [String] { get }
    /// Kind-specific trigger values (the common `text`, `fired_at` and
    /// `event.name` are appended by `EventTriggerValues.catalog`).
    func triggerValues(sample: JSONValue?) -> [EventTriggerValue]
    /// The binding a workflow input named `field` (lowercased) gets.
    func knownBinding(field: String) -> String?
    /// Content from outside the app that an agent prompt must carry as
    /// untrusted text, with the label the wrapper names; nil for kinds whose
    /// payload is app-authored.
    func untrustedContent(payload: JSONValue, eventName: String) -> (content: String, source: String)?
}

extension EventSourceDescriptor {
    var emitMode: EventEmitMode { .perItem }
    var connectionTypes: [SourceConnectionType] { [] }
    var isOfferedInPicker: Bool { true }
    var listTitle: String { displayName }
    var listSubtitle: String { subtitle }
    var historyChipTitle: String? { displayName }
    var usesConversationSessions: Bool { false }
    var senderPaths: [String] { [] }
    func untrustedContent(payload: JSONValue, eventName: String) -> (content: String, source: String)? { nil }
}

enum EventSourceRegistry {
    static func descriptor(for kind: EventSourceKind) -> any EventSourceDescriptor {
        switch kind {
        case .schedule: ScheduleSourceDescriptor()
        case .folder: FolderSourceDescriptor()
        case .webhook: WebhookSourceDescriptor()
        case .rss: RSSSourceDescriptor()
        case .sse: SSESourceDescriptor()
        case .runFailed: RunFailedSourceDescriptor()
        case .app: AppEventsSourceDescriptor()
        case .email: EmailSourceDescriptor()
        case .channelMessage: ChannelMessageSourceDescriptor()
        }
    }

    static var all: [any EventSourceDescriptor] {
        EventSourceKind.allCases.map(descriptor(for:))
    }

    /// Kinds offered in "Add Automation", in display order.
    static var pickerKinds: [EventSourceKind] {
        EventSourceKind.allCases.filter { descriptor(for: $0).isOfferedInPicker }
    }

    /// Groups in the Automations list: every kind but channel rules, so a
    /// stored automation of a retired kind still shows (and says why).
    static var listKinds: [EventSourceKind] {
        EventSourceKind.allCases.filter { $0 != .channelMessage }
    }

    /// Payload roots every occurrence has, before the kind's own block.
    static let commonPayloadRoots: Set<String> = ["event", "fired_at", "text"]

    static var payloadRoots: Set<String> {
        commonPayloadRoots.union(all.map(\.payloadRoot))
    }
}

// MARK: - Descriptors

struct ScheduleSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .schedule }
    var displayName: String { L("Schedule") }
    var icon: String { "calendar.badge.clock" }
    var subtitle: String { L("At set times or intervals") }
    var listTitle: String { L("Schedules") }
    var listSubtitle: String { L("Run at set times or intervals.") }
    var payloadRoot: String { "schedule" }
    var sessionSource: SessionSource { .schedule }
    var requestSource: RequestSource { .schedule }
    /// A busy schedule skips its slot.
    var defaultDelivery: EventDeliveryPolicy { EventDeliveryPolicy(mode: .serial, maxQueued: 0) }
    var defaultFreshSession: Bool { true }
    var dedupeMode: EventDedupeMode { .window }
    var filterClauses: Set<EventFilterClause> { [] }
    var textLabel: String { L("Main text (empty for schedules)") }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        [.init(path: "schedule.scheduled_for", label: L("Scheduled time"))]
    }

    func knownBinding(field: String) -> String? {
        ["date", "time", "scheduled_for", "when"].contains(field) ? "{{schedule.scheduled_for}}" : nil
    }
}

struct FolderSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .folder }
    var displayName: String { L("Folder") }
    var icon: String { "folder.badge.gearshape" }
    var subtitle: String { L("When files in a folder change") }
    var listTitle: String { L("Folder watchers") }
    var listSubtitle: String { L("Run when files in a folder change.") }
    var payloadRoot: String { "folder" }
    var sessionSource: SessionSource { .watcher }
    var requestSource: RequestSource { .watcher }
    /// A folder converges in one loop; its passes are never repeats.
    var defaultDelivery: EventDeliveryPolicy {
        EventDeliveryPolicy(mode: .serial, maxQueued: 0, dedupe: EventDedupePolicy.none)
    }
    /// Follow-up passes build on the previous one's chat.
    var defaultFreshSession: Bool { false }
    var dedupeMode: EventDedupeMode { .none }
    var emitMode: EventEmitMode { .perBatch }
    var filterClauses: Set<EventFilterClause> { [.pathGlobs] }
    var textLabel: String { L("Main text (changed files, one per line)") }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        [
            .init(path: "folder.changed_paths", label: L("Changed files")),
            .init(path: "folder.path", label: L("Watched folder")),
        ]
    }

    func knownBinding(field: String) -> String? {
        if ["files", "changed_paths", "paths", "changes"].contains(field) { return "{{folder.changed_paths}}" }
        if ["folder", "path", "directory"].contains(field) { return "{{folder.path}}" }
        return nil
    }
}

struct WebhookSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .webhook }
    var displayName: String { L("Webhook") }
    var icon: String { "link" }
    var subtitle: String { L("When a URL is called (local or relay)") }
    var listTitle: String { L("Webhooks") }
    var listSubtitle: String { L("Run when another app calls a URL.") }
    var payloadRoot: String { "webhook" }
    var sessionSource: SessionSource { .webhook }
    var requestSource: RequestSource { .webhook }
    var defaultDelivery: EventDeliveryPolicy { EventDeliveryPolicy(mode: .serial, maxQueued: 20) }
    var defaultFreshSession: Bool { true }
    var dedupeMode: EventDedupeMode { .window }
    var filterClauses: Set<EventFilterClause> { [.keywords, .conditions] }
    var textLabel: String { L("Main text (the body as text)") }
    var usesConversationSessions: Bool { true }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        var values: [EventTriggerValue] = [.init(path: "webhook.body", label: L("Request body"))]
        if let body = sample?.value(atPath: "webhook.body"), case .object = body {
            values += EventTriggerValues.bodyFields(body, prefix: "webhook.body")
        }
        values.append(.init(path: "webhook.query", label: L("Query parameters")))
        values.append(.init(path: "webhook.method", label: L("HTTP method")))
        values.append(.init(path: "webhook.content_type", label: L("Content type")))
        if let type = sample?.value(atPath: "webhook.event_type"), type != .null {
            values.append(.init(path: "webhook.event_type", label: L("Event type")))
        }
        return values
    }

    func knownBinding(field: String) -> String? {
        ["payload", "body", "data", "event"].contains(field) ? "{{webhook.body}}" : nil
    }

    func untrustedContent(payload: JSONValue, eventName: String) -> (content: String, source: String)? {
        let body = payload.value(atPath: "webhook.body") ?? .null
        let content: String
        switch body {
        case .string(let text): content = text
        case .null: content = ""
        default: content = body.prettyJSONString
        }
        let method = payload.value(atPath: "webhook.method")?.stringValue ?? "POST"
        return (content, "Webhook \(method) for event \"\(eventName)\"")
    }
}

struct RSSSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .rss }
    var displayName: String { L("RSS Feed") }
    var icon: String { "dot.radiowaves.up.forward" }
    var subtitle: String { L("When a feed publishes a new item") }
    var listTitle: String { L("Feeds") }
    var listSubtitle: String { L("Run when an RSS, Atom or JSON feed has a new item.") }
    var payloadRoot: String { "feed" }
    var sessionSource: SessionSource { .automation }
    var requestSource: RequestSource { .automation }
    /// Items are worked through one at a time.
    var defaultDelivery: EventDeliveryPolicy { EventDeliveryPolicy(mode: .serial, maxQueued: 50, dedupe: .durable) }
    var defaultFreshSession: Bool { true }
    /// A feed item's guid never runs twice.
    var dedupeMode: EventDedupeMode { .durable }
    var filterClauses: Set<EventFilterClause> { [.keywords, .conditions] }
    var textLabel: String { L("Main text (title, then summary)") }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        [
            .init(path: "feed.item.title", label: L("Item title")),
            .init(path: "feed.item.link", label: L("Item link")),
            .init(path: "feed.item.summary", label: L("Item summary")),
            .init(path: "feed.item.content", label: L("Item content")),
            .init(path: "feed.item.published", label: L("Published")),
            .init(path: "feed.item.author", label: L("Author")),
            .init(path: "feed.item.categories", label: L("Categories")),
            .init(path: "feed.title", label: L("Feed title")),
            .init(path: "feed.url", label: L("Feed URL")),
        ]
    }

    func knownBinding(field: String) -> String? {
        if ["title", "headline", "subject"].contains(field) { return "{{feed.item.title}}" }
        if ["link", "url", "href"].contains(field) { return "{{feed.item.link}}" }
        if ["summary", "content", "body", "description"].contains(field) { return "{{feed.item.summary}}" }
        if ["published", "date", "published_at"].contains(field) { return "{{feed.item.published}}" }
        if ["author", "by"].contains(field) { return "{{feed.item.author}}" }
        return nil
    }

    func untrustedContent(payload: JSONValue, eventName: String) -> (content: String, source: String)? {
        let title = payload.value(atPath: "feed.item.title")?.stringValue ?? ""
        let summary = payload.value(atPath: "feed.item.summary")?.stringValue ?? ""
        let url = payload.value(atPath: "feed.url")?.stringValue ?? ""
        return (summary.isEmpty ? title : "\(title)\n\n\(summary)", "Feed item from \(url) for event \"\(eventName)\"")
    }
}

struct SSESourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .sse }
    var displayName: String { L("Event Stream") }
    var icon: String { "antenna.radiowaves.left.and.right" }
    var subtitle: String { L("When a server-sent events stream sends a message") }
    var listTitle: String { L("Event streams") }
    var listSubtitle: String { L("Run when a server-sent events (SSE) stream sends a message.") }
    var payloadRoot: String { "sse" }
    var sessionSource: SessionSource { .automation }
    var requestSource: RequestSource { .automation }
    var defaultDelivery: EventDeliveryPolicy { EventDeliveryPolicy(mode: .serial, maxQueued: 100) }
    var defaultFreshSession: Bool { true }
    var dedupeMode: EventDedupeMode { .window }
    var filterClauses: Set<EventFilterClause> { [.keywords, .conditions] }
    var textLabel: String { L("Main text (the message data)") }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        var values: [EventTriggerValue] = [.init(path: "sse.data", label: L("Message data"))]
        if let data = sample?.value(atPath: "sse.data"), case .object = data {
            values += EventTriggerValues.bodyFields(data, prefix: "sse.data", labelPrefix: L("Data"))
        }
        values.append(.init(path: "sse.event", label: L("Event name")))
        values.append(.init(path: "sse.id", label: L("Message ID")))
        values.append(.init(path: "sse.url", label: L("Stream URL")))
        return values
    }

    func knownBinding(field: String) -> String? {
        ["data", "payload", "message", "body", "event"].contains(field) ? "{{sse.data}}" : nil
    }

    func untrustedContent(payload: JSONValue, eventName: String) -> (content: String, source: String)? {
        let data = payload.value(atPath: "sse.data") ?? .null
        let content: String
        switch data {
        case .string(let text): content = text
        case .null: content = ""
        default: content = data.prettyJSONString
        }
        let url = payload.value(atPath: "sse.url")?.stringValue ?? ""
        return (content, "Event stream message from \(url) for event \"\(eventName)\"")
    }
}

struct RunFailedSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .runFailed }
    var displayName: String { L("Run Failed") }
    var icon: String { "exclamationmark.triangle" }
    var subtitle: String { L("When a workflow or automation run fails") }
    var listTitle: String { L("Failure handlers") }
    var listSubtitle: String { L("Run when a workflow or automation run fails.") }
    var payloadRoot: String { "failure" }
    var sessionSource: SessionSource { .automation }
    var requestSource: RequestSource { .automation }
    var defaultDelivery: EventDeliveryPolicy { EventDeliveryPolicy(mode: .serial, maxQueued: 20) }
    var defaultFreshSession: Bool { true }
    var dedupeMode: EventDedupeMode { .window }
    var filterClauses: Set<EventFilterClause> { [.conditions] }
    var textLabel: String { L("Main text (the error)") }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        [
            .init(path: "failure.error", label: L("Error")),
            .init(path: "failure.workflow.name", label: L("Workflow name")),
            .init(path: "failure.failed_step.name", label: L("Failed step")),
            .init(path: "failure.automation.name", label: L("Automation that ran it")),
            .init(path: "failure.run_id", label: L("Run ID")),
            .init(path: "failure.kind", label: L("What failed")),
            .init(path: "failure.caller", label: L("Started by")),
            .init(path: "failure.finished_at", label: L("Failed at")),
        ]
    }

    func knownBinding(field: String) -> String? {
        if ["error", "message", "reason", "failure"].contains(field) { return "{{failure.error}}" }
        if ["workflow", "workflow_name"].contains(field) { return "{{failure.workflow.name}}" }
        if ["run_id", "run"].contains(field) { return "{{failure.run_id}}" }
        if ["step", "failed_step"].contains(field) { return "{{failure.failed_step.name}}" }
        return nil
    }
}

struct AppEventsSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .app }
    var displayName: String { L("App Event") }
    var icon: String { "power" }
    var subtitle: String { L("When Osaurus starts, or this automation is turned on or changed") }
    var listTitle: String { L("App events") }
    var listSubtitle: String { L("Run when Osaurus starts, or the automation is turned on or changed.") }
    var payloadRoot: String { "app" }
    var sessionSource: SessionSource { .automation }
    var requestSource: RequestSource { .automation }
    /// A busy automation skips the event.
    var defaultDelivery: EventDeliveryPolicy {
        EventDeliveryPolicy(mode: .serial, maxQueued: 0, dedupe: EventDedupePolicy.none)
    }
    var defaultFreshSession: Bool { true }
    var dedupeMode: EventDedupeMode { .none }
    var filterClauses: Set<EventFilterClause> { [] }
    var textLabel: String { L("Main text (what happened)") }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        [
            .init(path: "app.reason", label: L("What happened")),
            .init(path: "app.app_version", label: L("App version")),
        ]
    }

    func knownBinding(field: String) -> String? {
        if ["reason", "trigger", "why"].contains(field) { return "{{app.reason}}" }
        if ["version", "app_version"].contains(field) { return "{{app.app_version}}" }
        return nil
    }
}

struct EmailSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .email }
    var displayName: String { L("Email") }
    var icon: String { "envelope.badge" }
    var subtitle: String { L("When new mail arrives (Mail app or IMAP)") }
    var listSubtitle: String { L("Run when new mail arrives.") }
    var payloadRoot: String { "email" }
    var sessionSource: SessionSource { .email }
    var requestSource: RequestSource { .email }
    /// Mail is worked through one message at a time.
    var defaultDelivery: EventDeliveryPolicy { EventDeliveryPolicy(mode: .serial, maxQueued: 50, dedupe: .durable) }
    var defaultFreshSession: Bool { true }
    /// A Message-ID never runs twice, however long ago it was seen.
    var dedupeMode: EventDedupeMode { .durable }
    var connectionTypes: [SourceConnectionType] { [.mailApp, .imap] }
    /// Retired: mail is a channel now (Channels → Email).
    var isOfferedInPicker: Bool { false }
    var historyChipTitle: String? { nil }
    var filterClauses: Set<EventFilterClause> { [.senders, .keywords, .conditions] }
    var textLabel: String { L("Main text (subject, then body)") }
    var senderPaths: [String] { ["email.from", "email.from_name"] }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        [
            .init(path: "email.subject", label: L("Subject")),
            .init(path: "email.from", label: L("Sender address")),
            .init(path: "email.from_name", label: L("Sender name")),
            .init(path: "email.body", label: L("Body")),
            .init(path: "email.snippet", label: L("Preview")),
            .init(path: "email.to", label: L("Recipients")),
            .init(path: "email.date", label: L("Date")),
            .init(path: "email.mailbox", label: L("Mailbox")),
            .init(path: "email.attachments", label: L("Attachments")),
            .init(path: "email.message_id", label: L("Message ID")),
        ]
    }

    func knownBinding(field: String) -> String? {
        if ["subject", "title"].contains(field) { return "{{email.subject}}" }
        if ["from", "sender", "author", "email"].contains(field) { return "{{email.from}}" }
        if ["body", "content", "message", "text"].contains(field) { return "{{email.body}}" }
        if ["date", "received", "received_at"].contains(field) { return "{{email.date}}" }
        return nil
    }

    func untrustedContent(payload: JSONValue, eventName: String) -> (content: String, source: String)? {
        let email = payload.value(atPath: "email")
        let subject = email?.value(atPath: "subject")?.stringValue ?? ""
        let body = email?.value(atPath: "body")?.stringValue ?? email?.value(atPath: "snippet")?.stringValue ?? ""
        let from = email?.value(atPath: "from")?.stringValue ?? ""
        return ("Subject: \(subject)\n\n\(body)", "Email from \(from) for event \"\(eventName)\"")
    }
}

struct ChannelMessageSourceDescriptor: EventSourceDescriptor {
    var kind: EventSourceKind { .channelMessage }
    var displayName: String { L("Channel Message") }
    var icon: String { "bubble.left.and.bubble.right.fill" }
    var subtitle: String { L("When a message arrives") }
    var payloadRoot: String { "message" }
    var sessionSource: SessionSource { .channel }
    var requestSource: RequestSource { .channel }
    /// One turn per conversation.
    var defaultDelivery: EventDeliveryPolicy { EventDeliveryPolicy(mode: .perConversation, maxQueued: 20) }
    var defaultFreshSession: Bool { false }
    var dedupeMode: EventDedupeMode { .window }
    var isOfferedInPicker: Bool { false }
    var historyChipTitle: String? { L("Messages") }
    var filterClauses: Set<EventFilterClause> { [.senders, .keywords] }
    var textLabel: String { L("Main text (the message)") }
    var senderPaths: [String] { ["message.sender_id", "message.sender_name"] }

    func triggerValues(sample: JSONValue?) -> [EventTriggerValue] {
        [
            .init(path: "message.text", label: L("Message text")),
            .init(path: "message.sender_name", label: L("Sender name")),
            .init(path: "message.sender_id", label: L("Sender ID")),
            .init(path: "message.room_id", label: L("Room ID")),
            .init(path: "message.thread_id", label: L("Thread ID")),
            .init(path: "message.platform", label: L("Platform")),
        ] + (sample?.value(atPath: "email") == nil ? [] : EmailSourceDescriptor().triggerValues(sample: sample))
    }

    func knownBinding(field: String) -> String? {
        if ["message", "text", "prompt", "query", "question", "content"].contains(field) { return "{{message.text}}" }
        if ["sender", "sender_id", "from", "user"].contains(field) { return "{{message.sender_id}}" }
        if ["room", "room_id", "channel", "chat_id"].contains(field) { return "{{message.room_id}}" }
        return nil
    }
}

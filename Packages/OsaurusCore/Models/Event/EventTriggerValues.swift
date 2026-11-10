//
//  EventTriggerValues.swift
//  osaurus
//
//  The values a trigger hands to what it runs: each one a `{{path}}` into
//  the occurrence payload, with a label a person can pick from and an
//  example. The workflow input editor, the instructions hint, the detail
//  view and the `osaurus_config` schema text all read this one list.
//

import Foundation

public struct EventTriggerValue: Equatable, Sendable, Identifiable {
    /// Payload path, e.g. `webhook.body.issue.title`.
    public let path: String
    public let label: String
    /// The value rendered from a sample payload, when there is one.
    public var example: String?

    public var id: String { path }
    public var template: String { "{{\(path)}}" }
}

public enum EventTriggerValues {
    /// How many levels into a sample webhook body fields are listed.
    static let maxBodyDepth = 3
    static let maxBodyFields = 40

    /// The values `kind` exposes. With a `sample` payload, each value gets
    /// an example and a webhook's JSON body fields are listed one by one.
    public static func catalog(for kind: EventSourceKind, sample: JSONValue? = nil) -> [EventTriggerValue] {
        var values = kind.descriptor.triggerValues(sample: sample)
        values.append(.init(path: "text", label: textLabel(kind)))
        values.append(.init(path: "fired_at", label: L("Time it fired")))
        values.append(.init(path: "event.name", label: L("Automation name")))

        guard let sample else { return values }
        return values.map { value in
            var copy = value
            let rendered = EventTemplate.text(of: sample.value(atPath: value.path))
            copy.example = rendered.isEmpty ? nil : rendered
            return copy
        }
    }

    static func textLabel(_ kind: EventSourceKind) -> String {
        kind.descriptor.textLabel
    }

    /// Leaf fields of a JSON object, `issue.title` style.
    static func bodyFields(
        _ body: JSONValue, prefix: String, root: String? = nil, labelPrefix: String? = nil, depth: Int = 1
    ) -> [EventTriggerValue] {
        guard depth <= maxBodyDepth, let object = body.objectValue else { return [] }
        let root = root ?? prefix
        var out: [EventTriggerValue] = []
        for key in object.keys.sorted() {
            guard isPathSegment(key), let child = object[key] else { continue }
            let path = "\(prefix).\(key)"
            let shown = String(path.dropFirst(root.count + 1))
            if case .object = child, depth < maxBodyDepth {
                out += bodyFields(child, prefix: path, root: root, labelPrefix: labelPrefix, depth: depth + 1)
            } else if let labelPrefix {
                out.append(.init(path: path, label: "\(labelPrefix): \(shown)"))
            } else {
                out.append(.init(path: path, label: L("Body: \(shown)")))
            }
            if out.count >= maxBodyFields { break }
        }
        return Array(out.prefix(maxBodyFields))
    }

    /// Characters the `{{path}}` grammar accepts in one segment.
    static func isPathSegment(_ key: String) -> Bool {
        !key.isEmpty
            && key.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }

    // MARK: - Sample payloads

    /// What one occurrence of `event` would look like, for examples and the
    /// input preview. A webhook uses its sample body.
    public static func samplePayload(for event: OsaurusEvent, now: Date = Date()) -> JSONValue {
        switch event.source {
        case .schedule:
            return EventPayload.schedule(event: event, firedAt: now, scheduledFor: now)
        case .folder(let folder):
            let root = folder.path ?? "~/Folder"
            return EventPayload.folder(
                event: event, firedAt: now, path: root,
                changedPaths: [(root as NSString).appendingPathComponent("example.txt")])
        case .webhook(let webhook):
            let body = webhook.sampleBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return EventPayload.webhook(
                event: event, firedAt: now, method: "POST", headers: [:], query: [:],
                body: Data((body.isEmpty ? "{}" : body).utf8), contentType: "application/json")
        case .rss(let rss):
            return EventPayload.feed(
                event: event, firedAt: now, url: rss.url.isEmpty ? "https://example.com/feed.xml" : rss.url,
                feedTitle: L("Example feed"), item: .example(now: now))
        case .sse(let sse):
            return EventPayload.sse(
                event: event, firedAt: now, url: sse.url.isEmpty ? "https://example.com/stream" : sse.url,
                eventName: sse.eventNames.first ?? "message", id: "1", data: #"{"status":"ok"}"#)
        case .runFailed:
            return EventPayload.failure(
                event: event, firedAt: now,
                failure: EventPayload.Failure(
                    kind: .workflowRun, runId: UUID(), message: L("The HTTP step got a 500 from the server."),
                    workflow: (UUID(), L("Daily report")), failedStep: ("fetch", L("Fetch data"), "http"),
                    automation: nil, caller: "event", startedAt: now.addingTimeInterval(-30), finishedAt: now))
        case .app(let app):
            return EventPayload.app(
                event: event, firedAt: now, reason: app.reasons.first ?? .appLaunched,
                appVersion: EventPayload.appVersion)
        case .email(let email):
            return EventPayload.email(
                event: event, firedAt: now, message: .example(mailbox: email.effectiveMailboxes[0]),
                connectionId: email.connectionId, account: L("Work"), includeBody: email.includeBody)
        case .channelMessage(let channel):
            var extra: [String: JSONValue] = [:]
            if channel.kind == .email {
                let route = channel.roomIds.first.flatMap(EmailChannelConfiguration.parseRoomId)
                extra["email"] = EventPayload.emailFields(
                    message: .example(mailbox: route?.mailbox ?? EmailSourceConfig.inbox),
                    connectionId: route?.connectionId ?? "", account: L("Work"), includeBody: true)
            }
            return EventPayload.message(
                event: event, firedAt: now, text: L("Hello, can you help?"), platform: channel.kind,
                connectionId: channel.connectionId, roomId: channel.roomIds.first ?? "C0123", threadId: nil,
                senderId: "U0123", senderName: L("Alex"), attachments: [], extra: extra)
        }
    }

    /// The webhook sample body, when it is JSON; nil otherwise.
    public static func parsedSampleBody(_ text: String?) -> JSONValue? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return JSONValue.parse(text)
    }
}

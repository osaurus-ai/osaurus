//
//  EventPayload.swift
//  osaurus
//
//  The normalized JSON every occurrence carries, and the `{{path}}` binding
//  language instructions and workflow input mappings use to read it.
//
//  Shape (one source block per occurrence):
//
//      event:    { id, name, source_kind }
//      fired_at: ISO-8601
//      text:     the occurrence's main text (message text, webhook body,
//                changed files) — the same binding works for every source
//      schedule: { scheduled_for }
//      folder:   { path, changed_paths }
//      webhook:  { method, headers, query, body, content_type, event_type? }
//      email:    { message_id, thread_id, subject, from, from_name, to, cc,
//                  date, mailbox, account, connection_id, snippet, body,
//                  attachments: [{ name, size, mime }], is_read }
//      message:  { text, sender_id, sender_name, room_id, thread_id,
//                  connection_id, platform, attachments }
//      feed:     { url, title, item: { id, title, link, published, author,
//                  summary, content, categories } }
//      sse:      { url, event, id, data }
//      failure:  { kind, run_id, workflow: { id, name }, error, failed_step,
//                  automation: { id, name }, caller, started_at, finished_at }
//      app:      { reason, app_version, automation: { id, name } }
//

import Foundation

public enum EventPayload {
    static func base(event: OsaurusEvent, firedAt: Date) -> [String: JSONValue] {
        [
            "event": .object([
                "id": .string(event.id.uuidString),
                "name": .string(event.name),
                "source_kind": .string(event.sourceKind.rawValue),
            ]),
            "fired_at": .string(iso8601(firedAt)),
        ]
    }

    public static func schedule(event: OsaurusEvent, firedAt: Date, scheduledFor: Date?) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        payload["text"] = .string("")
        payload["schedule"] = .object([
            "scheduled_for": scheduledFor.map { .string(iso8601($0)) } ?? .null
        ])
        return .object(payload)
    }

    public static func folder(
        event: OsaurusEvent, firedAt: Date, path: String?, changedPaths: [String]
    ) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        payload["text"] = .string(changedPaths.joined(separator: "\n"))
        payload["folder"] = .object([
            "path": path.map(JSONValue.string) ?? .null,
            "changed_paths": .array(changedPaths.map(JSONValue.string)),
        ])
        return .object(payload)
    }

    public static func webhook(
        event: OsaurusEvent,
        firedAt: Date,
        method: String,
        headers: [String: String],
        query: [String: String],
        body: Data,
        contentType: String?,
        eventType: String? = nil
    ) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        let text = String(decoding: body, as: UTF8.self)
        payload["text"] = .string(text)
        var webhook: [String: JSONValue] = [
            "method": .string(method.uppercased()),
            "headers": .object(redactedHeaders(headers).mapValues(JSONValue.string)),
            "query": .object(query.mapValues(JSONValue.string)),
            "body": parseBody(body, contentType: contentType),
            "content_type": contentType.map(JSONValue.string) ?? .null,
        ]
        // Only providers with an event-type field set it.
        if let eventType { webhook["event_type"] = .string(eventType) }
        payload["webhook"] = .object(webhook)
        return .object(payload)
    }

    /// `body` is dropped unless `includeBody`; `text` is the subject, then
    /// the body (or the preview).
    static func email(
        event: OsaurusEvent, firedAt: Date, message: EmailMessage, connectionId: String, account: String,
        includeBody: Bool
    ) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        let body = includeBody ? message.body : nil
        let content = body ?? message.snippet
        payload["text"] = .string(content.isEmpty ? message.subject : message.subject + "\n\n" + content)
        payload["email"] = emailFields(
            message: message, connectionId: connectionId, account: account, includeBody: includeBody)
        return .object(payload)
    }

    /// The `{{email.*}}` trigger values of one message.
    static func emailFields(
        message: EmailMessage, connectionId: String, account: String, includeBody: Bool
    ) -> JSONValue {
        let body = includeBody ? message.body : nil
        return .object([
            "message_id": .string(message.messageId),
            "thread_id": message.threadId.map(JSONValue.string) ?? .null,
            "subject": .string(message.subject),
            "from": .string(message.from),
            "from_name": message.fromName.map(JSONValue.string) ?? .null,
            "to": .array(message.to.map(JSONValue.string)),
            "cc": .array(message.cc.map(JSONValue.string)),
            "date": message.date.map { .string(iso8601($0)) } ?? .null,
            "mailbox": .string(message.mailbox),
            "account": .string(account),
            "connection_id": .string(connectionId),
            "snippet": .string(message.snippet),
            "body": body.map(JSONValue.string) ?? .null,
            "attachments": .array(
                message.attachments.map { attachment in
                    .object([
                        "name": .string(attachment.name),
                        "size": attachment.size.map { .number(Double($0)) } ?? .null,
                        "mime": attachment.mime.map(JSONValue.string) ?? .null,
                    ])
                }),
            "is_read": .bool(message.isRead),
        ])
    }

    public static func message(
        event: OsaurusEvent,
        firedAt: Date,
        text: String,
        platform: AgentChannelKind,
        connectionId: String,
        roomId: String,
        threadId: String?,
        senderId: String?,
        senderName: String?,
        attachments: [String],
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        payload.merge(extra) { current, _ in current }
        payload["text"] = .string(text)
        payload["message"] = .object([
            "text": .string(text),
            "platform": .string(platform.rawValue),
            "connection_id": .string(connectionId),
            "room_id": .string(roomId),
            "thread_id": threadId.map(JSONValue.string) ?? .null,
            "sender_id": senderId.map(JSONValue.string) ?? .null,
            "sender_name": senderName.map(JSONValue.string) ?? .null,
            "attachments": .array(attachments.map(JSONValue.string)),
        ])
        return .object(payload)
    }

    static func feed(
        event: OsaurusEvent, firedAt: Date, url: String, feedTitle: String, item: FeedItem
    ) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        payload["text"] = .string(item.summary.isEmpty ? item.title : item.title + "\n\n" + item.summary)
        payload["feed"] = .object([
            "url": .string(url),
            "title": .string(feedTitle),
            "item": .object([
                "id": .string(item.id),
                "title": .string(item.title),
                "link": item.link.map(JSONValue.string) ?? .null,
                "published": item.published.map { .string(iso8601($0)) } ?? .null,
                "author": item.author.map(JSONValue.string) ?? .null,
                "summary": .string(item.summary),
                "content": item.content.map(JSONValue.string) ?? .null,
                "categories": .array(item.categories.map(JSONValue.string)),
            ]),
        ])
        return .object(payload)
    }

    /// `data` is its JSON value when it parses, the text otherwise.
    static func sse(
        event: OsaurusEvent, firedAt: Date, url: String, eventName: String, id: String?, data: String
    ) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        payload["text"] = .string(data)
        let parsed: JSONValue =
            data.isEmpty ? .string("") : (try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))) ?? .string(data)
        payload["sse"] = .object([
            "url": .string(url),
            "event": .string(eventName),
            "id": id.map(JSONValue.string) ?? .null,
            "data": parsed,
        ])
        return .object(payload)
    }

    /// What failed, for a `run_failed` automation.
    struct Failure: Sendable {
        enum Kind: String, Sendable { case workflowRun = "workflow_run", automationRun = "automation_run" }

        var kind: Kind
        var runId: UUID
        var message: String
        var workflow: (id: UUID, name: String)?
        var failedStep: (id: String, name: String?, kind: String?)?
        var automation: (id: UUID, name: String)?
        var caller: String
        var startedAt: Date?
        var finishedAt: Date?
    }

    static func failure(event: OsaurusEvent, firedAt: Date, failure: Failure) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        payload["text"] = .string(failure.message)
        payload["failure"] = .object([
            "kind": .string(failure.kind.rawValue),
            "run_id": .string(failure.runId.uuidString),
            "error": .string(failure.message),
            "workflow": failure.workflow.map {
                .object(["id": .string($0.id.uuidString), "name": .string($0.name)])
            } ?? .null,
            "failed_step": failure.failedStep.map { step in
                .object([
                    "id": .string(step.id),
                    "name": step.name.map(JSONValue.string) ?? .null,
                    "kind": step.kind.map(JSONValue.string) ?? .null,
                ])
            } ?? .null,
            "automation": failure.automation.map {
                .object(["id": .string($0.id.uuidString), "name": .string($0.name)])
            } ?? .null,
            "caller": .string(failure.caller),
            "started_at": failure.startedAt.map { .string(iso8601($0)) } ?? .null,
            "finished_at": failure.finishedAt.map { .string(iso8601($0)) } ?? .null,
        ])
        return .object(payload)
    }

    static func app(event: OsaurusEvent, firedAt: Date, reason: AppEventReason, appVersion: String) -> JSONValue {
        var payload = base(event: event, firedAt: firedAt)
        payload["text"] = .string(reason.rawValue)
        payload["app"] = .object([
            "reason": .string(reason.rawValue),
            "app_version": .string(appVersion),
            "automation": .object(["id": .string(event.id.uuidString), "name": .string(event.name)]),
        ])
        return .object(payload)
    }

    /// `CFBundleShortVersionString`, or "dev" outside an app bundle.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// A body parsed by content type: JSON → its value, form-encoded → an
    /// object of fields, anything else → the text.
    static func parseBody(_ body: Data, contentType: String?) -> JSONValue {
        guard !body.isEmpty else { return .null }
        let type = (contentType ?? "").lowercased()
        if type.contains("json") || type.isEmpty,
            let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        {
            return json
        }
        let text = String(decoding: body, as: UTF8.self)
        if type.contains("x-www-form-urlencoded") {
            var fields: [String: JSONValue] = [:]
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                guard let key = parts.first, !key.isEmpty else { continue }
                fields[key] = .string(parts.count > 1 ? parts[1] : "")
            }
            return .object(fields)
        }
        return .string(text)
    }

    /// Credentials never enter the payload (and so never reach a prompt or
    /// workflow input): auth, cookie and signature headers are dropped.
    static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in headers {
            let lowered = key.lowercased()
            if lowered == "authorization" || lowered == "cookie" || lowered.contains("signature")
                || lowered.contains("secret") || lowered.contains("token") || lowered == "x-hub-signature"
            {
                continue
            }
            out[lowered] = value
        }
        return out
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Bindings

public enum EventTemplate {
    // swiftlint:disable:next force_try
    private static let bindingPattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_.\-]+)\s*\}\}"#)

    /// Every `{{path}}` in `template`.
    public static func references(in template: String) -> [String] {
        let range = NSRange(template.startIndex..., in: template)
        return bindingPattern.matches(in: template, range: range).compactMap {
            Range($0.range(at: 1), in: template).map { String(template[$0]) }
        }
    }

    /// The path when `template` is exactly one binding and nothing else.
    public static func singleBinding(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = bindingPattern.firstMatch(in: trimmed, range: range),
            match.range == range,
            let path = Range(match.range(at: 1), in: trimmed)
        else { return nil }
        return String(trimmed[path])
    }

    /// The payload's top-level keys. A `{{…}}` whose first segment is not
    /// one of these is not a binding and is left as written, so instructions
    /// that predate events (or quote a template language) are untouched.
    public static let payloadRoots: Set<String> = EventSourceRegistry.payloadRoots

    static func isPayloadPath(_ path: String) -> Bool {
        let root = path.split(separator: ".", maxSplits: 1).first.map(String.init) ?? path
        return payloadRoots.contains(root)
    }

    /// `template` with every payload binding replaced by its value as text.
    /// Known roots with a missing value render as empty.
    public static func render(_ template: String, payload: JSONValue) -> String {
        let range = NSRange(template.startIndex..., in: template)
        let matches = bindingPattern.matches(in: template, range: range)
        guard !matches.isEmpty else { return template }
        var out = ""
        var cursor = template.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: template), let path = Range(match.range(at: 1), in: template)
            else { continue }
            let binding = String(template[path])
            guard isPayloadPath(binding) else { continue }
            out += template[cursor..<whole.lowerBound]
            out += text(of: payload.value(atPath: binding))
            cursor = whole.upperBound
        }
        out += template[cursor...]
        return out
    }

    /// The JSON value a template produces: the raw payload value for a
    /// single binding, the rendered text otherwise.
    public static func value(_ template: String, payload: JSONValue) -> JSONValue {
        if let path = singleBinding(template), isPayloadPath(path) {
            return payload.value(atPath: path) ?? .null
        }
        return .string(render(template, payload: payload))
    }

    static func text(of value: JSONValue?) -> String {
        switch value {
        case nil, .null?: return ""
        case .string(let s)?: return s
        case .bool(let b)?: return b ? "true" : "false"
        case .number(let n)?:
            if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .array(let items)?:
            if items.allSatisfy({ $0.stringValue != nil }) {
                return items.compactMap(\.stringValue).joined(separator: "\n")
            }
            return JSONValue.array(items).compactJSONString
        case .object(let o)?:
            return JSONValue.object(o).compactJSONString
        }
    }
}

// MARK: - Workflow input

public enum WorkflowInputMapper {
    /// The workflow input an occurrence produces: each mapped field's
    /// template evaluated against the payload, then coerced to the type the
    /// workflow's input schema declares for that field.
    public static func input(mapping: [String: String], payload: JSONValue, schema: JSONValue) -> JSONValue {
        let properties = schema.value(atPath: "properties")?.objectValue ?? [:]
        var out: [String: JSONValue] = [:]
        for (field, template) in mapping {
            let key = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let raw = EventTemplate.value(template, payload: payload)
            let declared = properties[key]?.value(atPath: "type")?.stringValue
            out[key] = coerce(raw, to: declared)
        }
        return .object(out)
    }

    static func coerce(_ value: JSONValue, to type: String?) -> JSONValue {
        guard let type else { return value }
        switch (type, value) {
        case ("string", .string): return value
        case ("string", .null): return value
        case ("string", _): return .string(EventTemplate.text(of: value))
        case ("number", .string(let s)): return Double(s.trimmingCharacters(in: .whitespaces)).map(JSONValue.number) ?? value
        case ("integer", .string(let s)):
            return Int(s.trimmingCharacters(in: .whitespaces)).map { .number(Double($0)) } ?? value
        case ("boolean", .string(let s)):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: return value
            }
        case ("object", .string(let s)), ("array", .string(let s)):
            return JSONValue.parse(s) ?? value
        default:
            return value
        }
    }

    /// A starting mapping for a workflow: every required (or, with none
    /// required, every) input field bound to the source's natural value —
    /// a field named like the source's main value gets it, the first other
    /// string field gets `{{text}}`.
    public static func suggestedMapping(schema: JSONValue, sourceKind: EventSourceKind) -> [String: String] {
        let properties = schema.value(atPath: "properties")?.objectValue ?? [:]
        guard !properties.isEmpty else { return [:] }
        let required = (schema.value(atPath: "required")?.arrayValue ?? []).compactMap(\.stringValue)
        let fields = (required.isEmpty ? Array(properties.keys) : required).sorted()
        var mapping: [String: String] = [:]
        var textAssigned = false
        for field in fields {
            let lowered = field.lowercased()
            if let known = knownBinding(for: lowered, sourceKind: sourceKind) {
                mapping[field] = known
                continue
            }
            let type = properties[field]?.value(atPath: "type")?.stringValue
            if !textAssigned, type == nil || type == "string" {
                mapping[field] = "{{text}}"
                textAssigned = true
            }
        }
        return mapping
    }

    private static func knownBinding(for field: String, sourceKind: EventSourceKind) -> String? {
        sourceKind.descriptor.knownBinding(field: field)
    }
}

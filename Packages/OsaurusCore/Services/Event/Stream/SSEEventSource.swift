//
//  SSEEventSource.swift
//  osaurus
//
//  The event-stream automation: one long-lived `text/event-stream`
//  connection per enabled event, on the source runtime's stream mode
//  (reconnect with backoff, optional heartbeat timeout). Each message is
//  one occurrence; the last event id is kept so a reconnect resumes with
//  `Last-Event-ID`. Comments (`: ping`) count as heartbeats. The server's
//  `retry:` hint is not used: the runtime owns reconnect timing.
//

import Foundation

struct SSEMessage: Equatable, Sendable {
    var event: String
    var data: String
    var id: String?
}

/// Assembles SSE lines into messages (WHATWG "event stream interpretation").
struct SSEFrameParser {
    enum Output: Equatable {
        case message(SSEMessage)
        /// A message over the size limit, dropped; `id` is the last event id.
        case oversized(id: String?)
        case comment
        case retry(Int)
    }

    /// The most a message (its data, or any one line) may hold: the same
    /// bound as a webhook body.
    static let defaultMaxMessageBytes = WebhookSourceConfig.defaultMaxBodyBytes

    let maxMessageBytes: Int
    private var lines = OpenAICompatibleStreamFramer.SSELineParser()
    private var eventName = ""
    private var dataLines: [String] = []
    private var dataBytes = 0
    private var hasData = false
    private var oversized = false
    /// The rest of a line whose start was discarded for being too long.
    private var skippingLine = false
    /// Persists across messages until a message sets another.
    private(set) var lastEventId: String?

    init(lastEventId: String? = nil, maxMessageBytes: Int = SSEFrameParser.defaultMaxMessageBytes) {
        self.lastEventId = lastEventId
        self.maxMessageBytes = maxMessageBytes
    }

    mutating func append(_ chunk: Data) -> [Output] {
        lines.append(chunk)
        let out = drain()
        if lines.pendingByteCount > maxMessageBytes {
            lines.discardPending()
            skippingLine = true
            markOversized()
        }
        return out
    }

    /// Reads a last unterminated line. A message missing its closing blank
    /// line is dropped, as the spec requires.
    mutating func finish() -> [Output] {
        lines.flushPending()
        return drain()
    }

    private mutating func drain() -> [Output] {
        var out: [Output] = []
        while let line = lines.nextLine() {
            if skippingLine {
                skippingLine = false
                continue
            }
            if let output = process(String(decoding: line, as: UTF8.self)) { out.append(output) }
        }
        return out
    }

    private mutating func markOversized() {
        oversized = true
        dataLines = []
        dataBytes = 0
        hasData = false
    }

    private mutating func process(_ line: String) -> Output? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return .comment }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event":
            eventName = String(value)
        case "data":
            guard !oversized else { break }
            dataBytes += value.utf8.count + 1
            if dataBytes > maxMessageBytes {
                markOversized()
            } else {
                dataLines.append(String(value))
                hasData = true
            }
        case "id":
            if !value.contains("\u{0}") { lastEventId = value.isEmpty ? nil : String(value) }
        case "retry":
            if let ms = Int(value), ms >= 0 { return .retry(ms) }
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> Output? {
        defer {
            eventName = ""
            dataLines = []
            dataBytes = 0
            hasData = false
            oversized = false
        }
        if oversized { return .oversized(id: lastEventId) }
        guard hasData else { return nil }
        return .message(
            SSEMessage(
                event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"),
                id: lastEventId))
    }
}

protocol SSEConnecting: Sendable {
    /// Opens the stream; the sequence yields body chunks until it ends.
    func connect(_ url: URL, headers: [String: String], idleTimeout: TimeInterval) async throws
        -> AsyncThrowingStream<Data, Error>
}

enum SSEConnectError: LocalizedError, Equatable {
    case httpStatus(Int)
    case notAnEventStream(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): L("The stream answered HTTP \(code).")
        case .notAnEventStream(let type): L("The URL answered \(type), not text/event-stream.")
        }
    }
}

struct URLSessionSSEConnector: SSEConnecting {
    func connect(_ url: URL, headers: [String: String], idleTimeout: TimeInterval) async throws
        -> AsyncThrowingStream<Data, Error>
    {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SSEConnectError.httpStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw SSEConnectError.httpStatus(http.statusCode) }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.lowercased().contains("text/event-stream") else {
            throw SSEConnectError.notAnEventStream(type.isEmpty ? L("no content type") : type)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct SSEStreamState: Codable, Equatable, Sendable {
    var lastEventId: String?
}

@MainActor
final class SSEEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .sse
    nonisolated static let ownerPrefix = "sse:"
    private unowned let manager: EventManager
    var connector: any SSEConnecting = URLSessionSSEConnector()

    init(manager: EventManager) {
        self.manager = manager
    }

    nonisolated static func scopeKey(_ eventId: UUID) -> String {
        ownerPrefix + eventId.uuidString.lowercased()
    }

    static var invalidURLMessage: String { L("Enter the stream's http or https URL.") }

    func stop() {}

    func reconcile(_ events: [OsaurusEvent]) async {
        guard manager.isStarted else { return }
        var scopes: [SourceRuntimeScope] = []
        for event in events where event.isEnabled {
            guard let config = event.source.sse else { continue }
            guard let url = config.streamURL else {
                manager.setSourceStatus(event.id) {
                    $0.phase = .paused
                    $0.lastError = Self.invalidURLMessage
                }
                continue
            }
            let id = event.id
            scopes.append(
                SourceRuntimeScope(
                    key: Self.scopeKey(id),
                    mode: .stream(
                        forcedReconnect: nil, heartbeatTimeout: config.heartbeatTimeoutSeconds.map(TimeInterval.init)),
                    driver: SSEScopeDriver(
                        event: event, config: config, url: url, connector: connector,
                        onReport: { [weak self] report in await self?.apply(report, eventId: id) },
                        onCursor: { [weak self] cursor in await self?.setCursor(cursor, eventId: id) },
                        onDrop: { [weak self] message in await self?.noteDrop(message, eventId: id) })))
        }
        await manager.runtime.register(scopes, owner: Self.ownerPrefix)
    }

    func forget(_ eventId: UUID) {
        manager.setSourceState(nil, scope: Self.scopeKey(eventId))
    }

    func cancel(_ eventId: UUID) {}

    func status(_ eventId: UUID) -> EventSourceStatus {
        manager.sourceStatus[eventId] ?? EventSourceStatus()
    }

    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        let now = Date()
        let payload =
            sample.flatMap { $0.value(atPath: "sse") != nil ? $0 : nil }
            ?? EventTriggerValues.samplePayload(for: event, now: now)
        return manager.submit(
            EventOccurrence(
                eventId: event.id, firedAt: now, payload: payload, trigger: .manual, isExternal: true,
                loadIntent: .interactive, summary: Self.summary(payload)))
    }

    private func apply(_ report: SourceRuntimeReport, eventId: UUID) {
        manager.setSourceStatus(eventId) { $0.apply(report) }
    }

    private func setCursor(_ cursor: String, eventId: UUID) {
        manager.setSourceStatus(eventId) { $0.cursor = cursor }
    }

    private func noteDrop(_ message: String, eventId: UUID) {
        manager.setSourceStatus(eventId) { $0.lastError = message }
    }

    nonisolated static func summary(_ payload: JSONValue) -> [String: String] {
        var summary: [String: String] = [:]
        if let name = payload.value(atPath: "sse.event")?.stringValue { summary["sse_event"] = String(name.prefix(120)) }
        if let id = payload.value(atPath: "sse.id")?.stringValue { summary["sse_id"] = String(id.prefix(120)) }
        if let text = payload.value(atPath: "text")?.stringValue { summary["data_bytes"] = String(text.utf8.count) }
        return summary
    }
}

struct SSEScopeDriver: SourceRuntimeDriver {
    let event: OsaurusEvent
    let config: SSESourceConfig
    let url: URL
    let connector: any SSEConnecting
    let onReport: @Sendable (SourceRuntimeReport) async -> Void
    let onCursor: @Sendable (String) async -> Void
    /// A message was dropped; the stream stays connected.
    var onDrop: @Sendable (String) async -> Void = { _ in }

    /// Without a heartbeat timeout a quiet stream is fine for a day.
    var idleTimeout: TimeInterval {
        config.heartbeatTimeoutSeconds.map { TimeInterval($0) + 30 } ?? 86_400
    }

    func stream(_ context: SourceStreamContext) async throws {
        let saved = try? context.state?.decoded(as: SSEStreamState.self)
        var headers = config.headers
        if let last = saved?.lastEventId { headers["Last-Event-ID"] = last }
        let chunks = try await connector.connect(url, headers: headers, idleTimeout: idleTimeout)
        context.heartbeat()
        var parser = SSEFrameParser(lastEventId: saved?.lastEventId)
        for try await chunk in chunks {
            context.heartbeat()
            try await handle(parser.append(chunk), context: context)
        }
        try await handle(parser.finish(), context: context)
    }

    private func handle(_ outputs: [SSEFrameParser.Output], context: SourceStreamContext) async throws {
        for output in outputs {
            if case .oversized(let id) = output {
                if let id { await context.emit([], try JSONValue(encoding: SSEStreamState(lastEventId: id))) }
                await onDrop(L("Skipped a message larger than \(SSEFrameParser.defaultMaxMessageBytes / 1024) KB."))
                continue
            }
            guard case .message(let message) = output else { continue }
            let state = try JSONValue(encoding: SSEStreamState(lastEventId: message.id))
            guard wants(message.event) else {
                if message.id != nil { await context.emit([], state) }
                continue
            }
            let now = Date()
            let payload = EventPayload.sse(
                event: event, firedAt: now, url: config.url, eventName: message.event, id: message.id,
                data: message.data)
            let occurrence = EventOccurrence(
                eventId: event.id, firedAt: now, payload: payload, dedupeKey: message.id.map { "sse:" + $0 },
                isExternal: true, loadIntent: .background, summary: SSEEventSource.summary(payload))
            await context.emit([occurrence], message.id == nil ? nil : state)
            if let id = message.id { await onCursor(L("Last event ID: \(id)")) }
        }
    }

    func wants(_ name: String) -> Bool {
        config.eventNames.isEmpty || config.eventNames.contains(name)
    }

    func report(_ report: SourceRuntimeReport, scope: String) async {
        await onReport(report)
    }
}

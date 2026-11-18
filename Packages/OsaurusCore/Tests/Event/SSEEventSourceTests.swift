//
//  SSEEventSourceTests.swift
//  osaurusTests
//
//  The event-stream automation: SSE framing (multi-line data, ids that
//  persist, comments, retry, CRLF, chunks split mid-line), the
//  Last-Event-ID resume, the event-name filter, and the payload.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SSEFrameParserTests {
    private func messages(_ outputs: [SSEFrameParser.Output]) -> [SSEMessage] {
        outputs.compactMap { if case .message(let m) = $0 { m } else { nil } }
    }

    @Test func assemblesMessages() {
        var parser = SSEFrameParser()
        let out = parser.append(
            Data(
                """
                : hello
                event: update
                id: 1
                data: {"a":
                data: 1}

                data: plain

                retry: 3000

                """.utf8))
        #expect(out.first == .comment)
        #expect(out.contains(.retry(3000)))
        let got = messages(out)
        #expect(got.count == 2)
        #expect(got[0] == SSEMessage(event: "update", data: "{\"a\":\n1}", id: "1"))
        #expect(got[1] == SSEMessage(event: "message", data: "plain", id: "1"), "the last id carries over")
        #expect(parser.lastEventId == "1")
    }

    @Test func handlesCRLFAndSplitChunks() {
        var parser = SSEFrameParser()
        var out = parser.append(Data("id: 9\r\nda".utf8))
        out += parser.append(Data("ta: x\r".utf8))
        out += parser.append(Data("\n\r\n".utf8))
        #expect(messages(out) == [SSEMessage(event: "message", data: "x", id: "9")])
    }

    @Test func ignoresEmptyMessagesAndDropsAnUnterminatedOne() {
        var parser = SSEFrameParser(lastEventId: "5")
        var out = parser.append(Data("event: ping\n\nid\ndata: tail".utf8))
        out += parser.finish()
        #expect(messages(out).isEmpty)
        #expect(parser.lastEventId == nil, "an empty id field resets it")
    }

    @Test func dropsAMessageWhoseDataIsTooLarge() {
        var parser = SSEFrameParser(maxMessageBytes: 16)
        let out = parser.append(
            Data("id: big\ndata: 0123456789\ndata: 0123456789\n\nid: small\ndata: ok\n\n".utf8))
        #expect(out.first == .oversized(id: "big"))
        #expect(messages(out) == [SSEMessage(event: "message", data: "ok", id: "small")])
        #expect(parser.lastEventId == "small")
    }

    @Test func dropsAMessageWithOneOverlongLineAcrossChunks() {
        var parser = SSEFrameParser(maxMessageBytes: 16)
        var out = parser.append(Data("id: 7\ndata: ".utf8))
        out += parser.append(Data(String(repeating: "x", count: 40).utf8))
        out += parser.append(Data(String(repeating: "y", count: 40).utf8))
        out += parser.append(Data("zz\n\ndata: next\n\n".utf8))
        #expect(out.first == .oversized(id: "7"))
        #expect(messages(out) == [SSEMessage(event: "message", data: "next", id: "7")])
    }

    @Test func theDefaultLimitIsTheWebhookBodyLimit() {
        #expect(SSEFrameParser().maxMessageBytes == WebhookSourceConfig.defaultMaxBodyBytes)
    }

    @Test func reconnectingClearsTheRetryTime() {
        var status = EventSourceStatus()
        status.apply(.disconnected(error: "gone", retryAt: Date()))
        #expect(status.nextTickAt != nil)
        status.apply(.connected)
        #expect(status.nextTickAt == nil)
        #expect(status.lastError == nil)
    }
}

actor SSEEmissions {
    private(set) var occurrences: [EventOccurrence] = []
    private(set) var states: [JSONValue?] = []

    func record(_ occurrences: [EventOccurrence], _ state: JSONValue?) {
        self.occurrences += occurrences
        states.append(state)
    }
}

final class FakeSSEConnector: SSEConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let body: String
    private var _headers: [String: String] = [:]

    init(_ body: String) {
        self.body = body
    }

    var headers: [String: String] { lock.withLock { _headers } }

    func connect(_ url: URL, headers: [String: String], idleTimeout: TimeInterval) async throws
        -> AsyncThrowingStream<Data, Error>
    {
        lock.withLock { _headers = headers }
        let chunks = body.split(separator: "\n", omittingEmptySubsequences: false).map { Data(($0 + "\n").utf8) }
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

@MainActor
struct SSEEventSourceTests {
    private func run(
        _ config: SSESourceConfig, body: String, state: JSONValue? = nil
    ) async throws -> (SSEEmissions, FakeSSEConnector, OsaurusEvent) {
        let event = OsaurusEvent(name: "Stream", source: .sse(config), action: EventPipelineFixtures.agentAction())
        let connector = FakeSSEConnector(body)
        let emissions = SSEEmissions()
        let driver = SSEScopeDriver(
            event: event, config: config, url: config.streamURL!, connector: connector, onReport: { _ in },
            onCursor: { _ in })
        try await driver.stream(
            SourceStreamContext(
                scope: "sse:test", state: state, emit: { await emissions.record($0, $1) }, heartbeat: {}))
        return (emissions, connector, event)
    }

    @Test func resumesFromTheLastEventIdAndEmitsJSONData() async throws {
        let config = SSESourceConfig(url: "https://example.com/events", headers: ["X-Team": "ops"])
        let state = try JSONValue(encoding: SSEStreamState(lastEventId: "41"))
        let (emissions, connector, event) = try await run(
            config, body: "id: 42\nevent: update\ndata: {\"status\":\"ok\"}\n\n", state: state)
        #expect(connector.headers["Last-Event-ID"] == "41")
        #expect(connector.headers["X-Team"] == "ops")
        let occurrence = try #require(await emissions.occurrences.first)
        #expect(occurrence.eventId == event.id)
        #expect(occurrence.dedupeKey == "sse:42")
        #expect(occurrence.isExternal)
        #expect(occurrence.payload.value(atPath: "sse.data.status")?.stringValue == "ok")
        #expect(occurrence.payload.value(atPath: "sse.event")?.stringValue == "update")
        #expect(occurrence.payload.value(atPath: "sse.id")?.stringValue == "42")
        let saved = try #require(await emissions.states.last ?? nil)
        #expect(try saved.decoded(as: SSEStreamState.self).lastEventId == "42")
    }

    @Test func filtersByEventNameButStillAdvancesTheId() async throws {
        let config = SSESourceConfig(url: "https://example.com/events", eventNames: ["update"])
        let (emissions, _, _) = try await run(
            config, body: "id: 1\nevent: ping\ndata: x\n\nid: 2\nevent: update\ndata: hello\n\n")
        let occurrences = await emissions.occurrences
        #expect(occurrences.map(\.dedupeKey) == ["sse:2"])
        #expect(occurrences.first?.payload.value(atPath: "sse.data")?.stringValue == "hello")
        let states = await emissions.states.compactMap { $0 }
        #expect(try states.map { try $0.decoded(as: SSEStreamState.self).lastEventId } == ["1", "2"])
    }

    @Test func messagesWithoutIdsHaveNoDedupeKeyAndKeepTheState() async throws {
        let (emissions, _, _) = try await run(
            SSESourceConfig(url: "https://example.com/events"), body: "data: one\n\ndata: two\n\n")
        #expect(await emissions.occurrences.map(\.dedupeKey) == [nil, nil])
        #expect(await emissions.states.allSatisfy { $0 == nil })
    }

    @Test func anOversizedMessageIsReportedSkippedAndPassedOver() async throws {
        let config = SSESourceConfig(url: "https://example.com/events")
        let event = OsaurusEvent(name: "Stream", source: .sse(config), action: EventPipelineFixtures.agentAction())
        let huge = String(repeating: "x", count: SSEFrameParser.defaultMaxMessageBytes + 1)
        let connector = FakeSSEConnector("id: 1\ndata: \(huge)\n\nid: 2\ndata: fine\n\n")
        let emissions = SSEEmissions()
        let drops = SSEEmissions()
        let driver = SSEScopeDriver(
            event: event, config: config, url: config.streamURL!, connector: connector, onReport: { _ in },
            onCursor: { _ in }, onDrop: { _ in await drops.record([], nil) })
        try await driver.stream(
            SourceStreamContext(
                scope: "sse:test", state: nil, emit: { await emissions.record($0, $1) }, heartbeat: {}))
        #expect(await drops.states.count == 1)
        #expect(await emissions.occurrences.map(\.dedupeKey) == ["sse:2"])
        let states = await emissions.states.compactMap { $0 }
        #expect(try states.map { try $0.decoded(as: SSEStreamState.self).lastEventId } == ["1", "2"])
    }

    @Test func configNormalizesHeadersAndHeartbeat() {
        let config = SSESourceConfig(
            url: " https://example.com/s ", headers: [" X-A ": "1", "": "dropped"], eventNames: ["a", "a", " b "],
            heartbeatTimeoutSeconds: 1)
        #expect(config.url == "https://example.com/s")
        #expect(config.headers == ["X-A": "1"])
        #expect(config.eventNames == ["a", "b"])
        #expect(config.heartbeatTimeoutSeconds == SSESourceConfig.heartbeatTimeoutRange.lowerBound)
        #expect(SSESourceConfig(url: "file:///tmp/x").streamURL == nil)
    }
}

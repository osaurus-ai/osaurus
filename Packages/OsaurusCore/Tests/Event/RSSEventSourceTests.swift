//
//  RSSEventSourceTests.swift
//  osaurusTests
//
//  The RSS automation over a fake fetcher: the first check is a baseline,
//  later checks hand on unseen items oldest first under the per-check cap,
//  validators are sent back, 304 is quiet, items are durable-deduped
//  through the pipeline, and Run Now uses the newest item.
//

import Foundation
import Testing

@testable import OsaurusCore

actor FakeFeedFetcher: FeedFetching {
    struct Request: Equatable {
        var url: URL
        var etag: String?
        var lastModified: String?
    }

    private var responses: [FeedFetchResponse]
    private(set) var requests: [Request] = []

    init(_ responses: [FeedFetchResponse]) {
        self.responses = responses
    }

    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResponse {
        requests.append(Request(url: url, etag: etag, lastModified: lastModified))
        return responses.count > 1 ? responses.removeFirst() : responses[0]
    }

    static func rss(_ items: [(id: String, title: String)], etag: String? = nil) -> FeedFetchResponse {
        let body = items.map { "<item><title>\($0.title)</title><guid>\($0.id)</guid></item>" }.joined()
        let xml = "<rss version=\"2.0\"><channel><title>Feed</title>\(body)</channel></rss>"
        return FeedFetchResponse(
            data: Data(xml.utf8), contentType: "application/rss+xml", etag: etag, lastModified: "Mon, 12 Oct 2026")
    }
}

@MainActor
struct RSSEventSourceTests {
    private let url = URL(string: "https://example.com/feed.xml")!

    private func event(maxItems: Int = 20) -> OsaurusEvent {
        OsaurusEvent(
            name: "News", source: .rss(RSSSourceConfig(url: url.absoluteString, maxItemsPerTick: maxItems)),
            action: EventPipelineFixtures.agentAction())
    }

    private func driver(_ event: OsaurusEvent, _ fetcher: FakeFeedFetcher) -> RSSScopeDriver {
        RSSScopeDriver(
            event: event, config: event.source.rss!, url: url, fetcher: fetcher, onReport: { _ in }, onCursor: { _ in })
    }

    private func tick(_ driver: RSSScopeDriver, state: JSONValue?) async throws -> SourceTickResult {
        try await driver.tick(SourceTickContext(scope: "rss:test", state: state, isFirstTick: state == nil))
    }

    @Test func firstCheckIsABaselineThenNewItemsRunOldestFirst() async throws {
        let fetcher = FakeFeedFetcher([
            FakeFeedFetcher.rss([("b", "B"), ("a", "A")], etag: "v1"),
            FakeFeedFetcher.rss([("d", "D"), ("c", "C"), ("b", "B"), ("a", "A")], etag: "v2"),
        ])
        let event = event()
        let driver = driver(event, fetcher)

        let first = try await tick(driver, state: nil)
        #expect(first.occurrences.isEmpty, "turning a feed on does not replay its back catalog")
        let baseline = try #require(first.state)
        #expect(try baseline.decoded(as: RSSFeedState.self).seenIds == ["b", "a"])

        let second = try await tick(driver, state: baseline)
        #expect(second.occurrences.map(\.dedupeKey) == ["rss:c", "rss:d"])
        let occurrence = try #require(second.occurrences.first)
        #expect(occurrence.isExternal)
        #expect(occurrence.eventId == event.id)
        #expect(occurrence.payload.value(atPath: "feed.item.title")?.stringValue == "C")
        #expect(occurrence.payload.value(atPath: "feed.title")?.stringValue == "Feed")
        #expect(occurrence.payload.value(atPath: "feed.url")?.stringValue == url.absoluteString)
        #expect(occurrence.payload.value(atPath: "text")?.stringValue == "C")

        let requests = await fetcher.requests
        #expect(requests[0].etag == nil)
        #expect(requests[1].etag == "v1", "the stored validator is sent back")
        #expect(requests[1].lastModified == "Mon, 12 Oct 2026")
    }

    @Test func notModifiedIsQuietAndKeepsTheState() async throws {
        let fetcher = FakeFeedFetcher([FeedFetchResponse(data: nil, etag: "v1")])
        let state = try JSONValue(encoding: RSSFeedState(etag: "v1", seenIds: ["a"]))
        let result = try await tick(driver(event(), fetcher), state: state)
        #expect(result.occurrences.isEmpty)
        #expect(result.state == nil)
    }

    @Test func aBurstIsCappedToTheNewestItems() async throws {
        let items = (1 ... 6).reversed().map { (id: "i\($0)", title: "Item \($0)") }
        let fetcher = FakeFeedFetcher([FakeFeedFetcher.rss(items)])
        let state = try JSONValue(encoding: RSSFeedState(seenIds: ["i0"]))
        let result = try await tick(driver(event(maxItems: 2), fetcher), state: state)
        #expect(result.occurrences.map(\.dedupeKey) == ["rss:i5", "rss:i6"])
        let next = try #require(result.state).decoded(as: RSSFeedState.self)
        #expect(Set(next.seenIds).isSuperset(of: ["i1", "i2", "i3", "i4", "i5", "i6", "i0"]))
    }

    @Test func seenIdsAreCapped() {
        let items = (0 ..< 600).map {
            FeedItem(id: "n\($0)", title: "", link: nil, published: nil, author: nil, summary: "", content: nil, categories: [])
        }
        let (_, state) = RSSFeedState.advance(
            RSSFeedState(seenIds: ["old"]), feed: FeedDocument(title: "", items: items), limit: 10, etag: nil,
            lastModified: nil)
        #expect(state.seenIds.count == RSSFeedState.maxSeenIds)
        #expect(state.seenIds.first == "n0")
    }

    @Test func anItemRunsOnceEvenWhenDeliveredAgain() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let event = manager.create(event())
        #expect(event.delivery.dedupe == .durable)
        let payload = EventPayload.feed(
            event: event, firedAt: Date(), url: url.absoluteString, feedTitle: "Feed", item: FeedItem.example(now: Date()))
        let occurrence = EventOccurrence(
            eventId: event.id, payload: payload, dedupeKey: "rss:item-1", isExternal: true, loadIntent: .background)
        let first = manager.submit(occurrence)
        #expect(first.accepted)
        _ = await EventPipelineFixtures.settled(manager, first.runId)
        let again = manager.submit(occurrence)
        #expect(again.status == .duplicate)
        #expect(runner.fired.count == 1)
    }

    @Test func runNowUsesTheNewestItem() async throws {
        let (manager, runner) = try EventPipelineFixtures.manager()
        let source = try #require(manager.adapter(for: .rss) as? RSSEventSource)
        source.fetcher = FakeFeedFetcher([FakeFeedFetcher.rss([("2", "Newest"), ("1", "Older")])])
        let event = manager.create(event())
        let result = await manager.fireNow(event.id)
        #expect(result.accepted)
        await runner.waitForFires(1)
        #expect(runner.fired.first?.payload.value(atPath: "feed.item.title")?.stringValue == "Newest")
        #expect(runner.fired.first?.trigger == .manual)
    }

    @Test func invalidURLPausesWithAnError() async throws {
        let (manager, _) = try EventPipelineFixtures.manager()
        manager.start()
        await manager.awaitLoaded()
        defer { manager.stop() }
        let broken = manager.create(
            OsaurusEvent(
                name: "Broken", source: .rss(RSSSourceConfig(url: "ftp://nope")), action: EventPipelineFixtures.agentAction()))
        for _ in 0 ..< 100 where manager.status(of: broken.id).lastError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(manager.status(of: broken.id).lastError == RSSEventSource.invalidURLMessage)
    }
}

struct FeedBodyLimitTests {
    private func bytes(_ count: Int) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for _ in 0 ..< count { continuation.yield(0x61) }
            continuation.finish()
        }
    }

    @Test func aBodyAtTheLimitIsRead() async throws {
        let data = try await URLSessionFeedFetcher.read(bytes(64), expectedLength: -1, limit: 64)
        #expect(data.count == 64)
    }

    @Test func aBodyPastTheLimitStopsReading() async {
        await #expect(throws: FeedFetchError.tooLarge) {
            _ = try await URLSessionFeedFetcher.read(bytes(65), expectedLength: -1, limit: 64)
        }
    }

    @Test func aDeclaredLengthPastTheLimitIsRefusedUpFront() async {
        await #expect(throws: FeedFetchError.tooLarge) {
            _ = try await URLSessionFeedFetcher.read(bytes(0), expectedLength: 65, limit: 64)
        }
    }
}

//
//  RSSEventSource.swift
//  osaurus
//
//  The RSS automation: one poll scope per enabled event on the source
//  runtime. Each tick fetches the feed (conditionally, with the last
//  ETag / Last-Modified), and hands on the items it has not seen, oldest
//  first. The first check of a new feed only records what is there, so
//  turning one on does not replay its back catalog. Seen ids are capped;
//  the durable dedupe keys catch an item that falls out of the cap and
//  comes back.
//

import Foundation

struct FeedFetchResponse: Sendable {
    /// nil on 304 Not Modified.
    var data: Data?
    var contentType: String?
    var etag: String?
    var lastModified: String?
}

protocol FeedFetching: Sendable {
    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResponse
}

enum FeedFetchError: LocalizedError, Equatable {
    case httpStatus(Int)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): L("The feed answered HTTP \(code).")
        case .tooLarge: L("The feed is larger than 5 MB.")
        }
    }
}

struct URLSessionFeedFetcher: FeedFetching {
    static let maxBytes = 5 * 1024 * 1024

    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(
            "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, */*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue("Osaurus/\(EventPayload.appVersion) (feed automation)", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedFetchError.httpStatus(0) }
        if http.statusCode == 304 {
            return FeedFetchResponse(data: nil, etag: etag, lastModified: lastModified)
        }
        guard (200..<300).contains(http.statusCode) else { throw FeedFetchError.httpStatus(http.statusCode) }
        let data = try await Self.read(bytes, expectedLength: http.expectedContentLength)
        return FeedFetchResponse(
            data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"),
            etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    /// The body, refused as soon as it passes `maxBytes` (a declared
    /// length over the limit is refused before reading).
    static func read<S: AsyncSequence>(_ bytes: S, expectedLength: Int64, limit: Int = maxBytes) async throws -> Data
    where S.Element == UInt8 {
        guard expectedLength <= Int64(limit) else { throw FeedFetchError.tooLarge }
        var data = Data()
        if expectedLength > 0 { data.reserveCapacity(Int(expectedLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw FeedFetchError.tooLarge }
            data.append(byte)
        }
        return data
    }
}

/// What a feed scope remembers between checks.
struct RSSFeedState: Codable, Equatable, Sendable {
    var etag: String?
    var lastModified: String?
    /// Most recent first.
    var seenIds: [String]
    var feedTitle: String?

    static let maxSeenIds = 500

    /// The items to hand on (oldest first, at most `limit`) and the state
    /// after them. No previous state is a baseline: nothing is handed on.
    static func advance(
        _ previous: RSSFeedState?, feed: FeedDocument, limit: Int, etag: String?, lastModified: String?
    ) -> (items: [FeedItem], state: RSSFeedState) {
        let ordered = oldestFirst(feed.items)
        let current = feed.items.map(\.id)
        let fresh: [FeedItem]
        if let previous {
            let seen = Set(previous.seenIds)
            var picked = Set<String>()
            fresh = ordered.filter { !seen.contains($0.id) && picked.insert($0.id).inserted }
        } else {
            fresh = []
        }
        var seenNext: [String] = []
        var included = Set<String>()
        for id in current + (previous?.seenIds ?? []) where included.insert(id).inserted {
            seenNext.append(id)
            if seenNext.count >= maxSeenIds { break }
        }
        let state = RSSFeedState(
            etag: etag, lastModified: lastModified, seenIds: seenNext,
            feedTitle: feed.title.isEmpty ? previous?.feedTitle : feed.title)
        return (Array(fresh.suffix(max(1, limit))), state)
    }

    /// By published date when every item has one; otherwise the reverse
    /// of document order (feeds list newest first).
    static func oldestFirst(_ items: [FeedItem]) -> [FeedItem] {
        if !items.isEmpty, items.allSatisfy({ $0.published != nil }) {
            return items.enumerated().sorted { lhs, rhs in
                let l = lhs.element.published!, r = rhs.element.published!
                return l == r ? lhs.offset > rhs.offset : l < r
            }.map(\.element)
        }
        return items.reversed()
    }
}

@MainActor
final class RSSEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .rss
    nonisolated static let ownerPrefix = "rss:"
    private unowned let manager: EventManager
    var fetcher: any FeedFetching = URLSessionFeedFetcher()

    init(manager: EventManager) {
        self.manager = manager
    }

    nonisolated static func scopeKey(_ eventId: UUID) -> String {
        ownerPrefix + eventId.uuidString.lowercased()
    }

    static var invalidURLMessage: String { L("Enter the feed's http or https URL.") }

    func stop() {}

    func reconcile(_ events: [OsaurusEvent]) async {
        guard manager.isStarted else { return }
        var scopes: [SourceRuntimeScope] = []
        for event in events where event.isEnabled {
            guard let config = event.source.rss else { continue }
            guard let url = config.feedURL else {
                manager.setSourceStatus(event.id) {
                    $0.phase = .paused
                    $0.lastError = Self.invalidURLMessage
                }
                continue
            }
            let id = event.id
            scopes.append(
                SourceRuntimeScope(
                    key: Self.scopeKey(id), mode: .poll(interval: TimeInterval(config.pollIntervalSeconds)),
                    catchUp: config.catchUp,
                    driver: RSSScopeDriver(
                        event: event, config: config, url: url, fetcher: fetcher,
                        onReport: { [weak self] report in await self?.apply(report, eventId: id) },
                        onCursor: { [weak self] cursor in await self?.setCursor(cursor, eventId: id) })))
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

    /// The feed's newest item as a payload, for Run Now.
    func sample(for event: OsaurusEvent) async -> JSONValue? {
        guard let config = event.source.rss, let url = config.feedURL,
            let response = try? await fetcher.fetch(url, etag: nil, lastModified: nil),
            let data = response.data,
            let feed = try? FeedParser.parse(data, contentType: response.contentType),
            let newest = RSSFeedState.oldestFirst(feed.items).last
        else { return nil }
        return EventPayload.feed(event: event, firedAt: Date(), url: config.url, feedTitle: feed.title, item: newest)
    }

    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        let now = Date()
        let payload =
            sample.flatMap { $0.value(atPath: "feed") != nil ? $0 : nil }
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

    nonisolated static func summary(_ payload: JSONValue) -> [String: String] {
        var summary: [String: String] = [:]
        if let id = payload.value(atPath: "feed.item.id")?.stringValue { summary["item_id"] = String(id.prefix(200)) }
        if let link = payload.value(atPath: "feed.item.link")?.stringValue { summary["item_link"] = String(link.prefix(300)) }
        return summary
    }
}

struct RSSScopeDriver: SourceRuntimeDriver {
    let event: OsaurusEvent
    let config: RSSSourceConfig
    let url: URL
    let fetcher: any FeedFetching
    let onReport: @Sendable (SourceRuntimeReport) async -> Void
    let onCursor: @Sendable (String) async -> Void

    func tick(_ context: SourceTickContext) async throws -> SourceTickResult {
        let previous = try? context.state?.decoded(as: RSSFeedState.self)
        let response = try await fetcher.fetch(url, etag: previous?.etag, lastModified: previous?.lastModified)
        guard let data = response.data else { return SourceTickResult() }
        let feed = try FeedParser.parse(data, contentType: response.contentType)
        let (items, state) = RSSFeedState.advance(
            previous, feed: feed, limit: config.maxItemsPerTick, etag: response.etag,
            lastModified: response.lastModified)
        let now = Date()
        let occurrences = items.map { item in
            let payload = EventPayload.feed(event: event, firedAt: now, url: config.url, feedTitle: feed.title, item: item)
            return EventOccurrence(
                eventId: event.id, firedAt: now, payload: payload, dedupeKey: "rss:" + item.id, isExternal: true,
                loadIntent: .background, summary: RSSEventSource.summary(payload))
        }
        if let newest = RSSFeedState.oldestFirst(feed.items).last {
            await onCursor(L("Newest: \(newest.title.isEmpty ? newest.id : newest.title)"))
        }
        return SourceTickResult(occurrences: occurrences, state: try JSONValue(encoding: state))
    }

    func report(_ report: SourceRuntimeReport, scope: String) async {
        await onReport(report)
    }
}

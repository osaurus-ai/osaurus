//
//  AnnouncementsServiceTests.swift
//  osaurusTests
//
//  Contract tests for the router-served announcements feed: decoding of the
//  documented payload, eligibility (server order, renderability, seen
//  flags), the launch/activation throttles, 429 backoff, and the "any
//  failure means no announcement" rule.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Router announcements service", .serialized)
@MainActor
struct AnnouncementsServiceTests {

    // MARK: - Decoding

    /// The sample payload from `docs/osaurus-integration.md` in osaurus-router.
    private static let docSample = #"""
        {
          "server_time": "2026-10-02T10:00:00.000Z",
          "announcements": [
            {
              "id": "9b1c2d3e-0000-4000-8000-000000000001",
              "slug": "raptor-launch-2026-10",
              "title": "Raptor is live on Product Hunt",
              "body": "We launched **Raptor** today.\n\n- Faster agent loop\n- Workspaces",
              "body_format": "markdown",
              "image_url": "https://cdn.osaurus.ai/announcements/raptor.png",
              "ctas": [
                { "label": "Upvote on Product Hunt", "kind": "external_url", "url": "https://www.producthunt.com/posts/osaurus", "style": "primary" },
                { "label": "Open Credits", "kind": "deeplink", "url": "osaurus://settings?tab=credits", "style": "secondary" }
              ],
              "starts_at": "2026-10-02T07:00:00.000Z",
              "ends_at": "2026-10-03T07:00:00.000Z",
              "priority": 100
            },
            {
              "id": "9b1c2d3e-0000-4000-8000-000000000002",
              "slug": "community-call",
              "title": "Community call Friday",
              "body": "Join us at 10am PT.",
              "ctas": [],
              "priority": 10
            }
          ]
        }
        """#

    @Test func decodesDocumentedSample() throws {
        let response = try JSONDecoder().decode(
            OsaurusRouterAnnouncementsResponse.self, from: Data(Self.docSample.utf8))
        #expect(response.serverTime == "2026-10-02T10:00:00.000Z")
        #expect(response.announcements.map(\.slug) == ["raptor-launch-2026-10", "community-call"])

        let raptor = try #require(response.announcements.first)
        #expect(raptor.title == "Raptor is live on Product Hunt")
        #expect(raptor.bodyFormat == "markdown")
        #expect(raptor.isRenderable)
        #expect(raptor.priority == 100)
        #expect(raptor.startsAt == "2026-10-02T07:00:00.000Z")
        #expect(raptor.endsAt == "2026-10-03T07:00:00.000Z")
        #expect(raptor.resolvedImageURL == URL(string: "https://cdn.osaurus.ai/announcements/raptor.png"))
        #expect(raptor.ctas.count == 2)
        #expect(raptor.ctas[0].isExternalURL && raptor.ctas[0].isPrimary)
        #expect(raptor.ctas[1].isDeepLink && !raptor.ctas[1].isPrimary)
        #expect(raptor.ctas[1].resolvedURL == URL(string: "osaurus://settings?tab=credits"))

        // Optional fields default: no body_format → markdown, no image, no dates.
        let call = response.announcements[1]
        #expect(call.bodyFormat == "markdown")
        #expect(call.imageURL == nil)
        #expect(call.resolvedImageURL == nil)
        #expect(call.ctas.isEmpty)
        #expect(call.startsAt == nil && call.endsAt == nil)
    }

    @Test func decoding_dropsMalformedEntriesNotTheFeed() throws {
        let body = #"{"announcements":[{"id":"x"},{"id":"ok","slug":"ok","title":"T","body":"B"},42,null]}"#
        let response = try JSONDecoder().decode(OsaurusRouterAnnouncementsResponse.self, from: Data(body.utf8))
        #expect(response.announcements.map(\.slug) == ["ok"])
        #expect(response.serverTime == nil)
    }

    @Test func unknownBodyFormat_isNotRenderable() {
        let html = OsaurusRouterAnnouncement(id: "1", slug: "html", title: "T", body: "<b>B</b>", bodyFormat: "html")
        #expect(!html.isRenderable)
        let blankTitle = OsaurusRouterAnnouncement(id: "2", slug: "blank", title: "", body: "B")
        #expect(!blankTitle.isRenderable)
        let md = OsaurusRouterAnnouncement(id: "3", slug: "md", title: "T", body: "B")
        #expect(md.isRenderable)
    }

    /// Only `https` external links and `osaurus://` deep links are acted on;
    /// everything else (http, file, javascript, scheme/kind mismatch,
    /// unknown kind, blank label) is dropped, and at most three survive.
    @Test func ctas_invalidSchemesDroppedAndCappedAtThree() {
        typealias CTA = OsaurusRouterAnnouncement.CTA
        let a = OsaurusRouterAnnouncement(
            id: "1", slug: "ctas", title: "T", body: "B",
            ctas: [
                CTA(label: "http", kind: "external_url", url: "http://insecure.example"),
                CTA(label: "file", kind: "external_url", url: "file:///etc/passwd"),
                CTA(label: "js", kind: "external_url", url: "javascript:alert(1)"),
                CTA(label: "mismatch", kind: "deeplink", url: "https://osaurus.ai"),
                CTA(label: "mismatch2", kind: "external_url", url: "osaurus://settings"),
                CTA(label: "unknown", kind: "in_app_tab", url: "https://osaurus.ai"),
                CTA(label: "", kind: "external_url", url: "https://osaurus.ai/blank"),
                CTA(label: "ok1", kind: "external_url", url: "https://osaurus.ai/1", style: "primary"),
                CTA(label: "ok2", kind: "deeplink", url: "osaurus://settings?tab=credits"),
                CTA(label: "ok3", kind: "external_url", url: "HTTPS://osaurus.ai/3"),
                CTA(label: "ok4", kind: "external_url", url: "https://osaurus.ai/4"),
            ]
        )
        #expect(a.actionableCTAs.map(\.label) == ["ok1", "ok2", "ok3"])
        #expect(a.resolvedImageURL == nil)

        let badImage = OsaurusRouterAnnouncement(
            id: "2", slug: "img", title: "T", body: "B", imageURL: "http://cdn.example/x.png")
        #expect(badImage.resolvedImageURL == nil)
    }

    // MARK: - Harness

    /// A scripted feed: each call pops the next result (or repeats the last).
    private final class FeedScript: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<OsaurusRouterAnnouncementsResponse, Error>]
        private(set) var calls = 0
        private(set) var appVersions: [String?] = []

        init(_ results: [Result<OsaurusRouterAnnouncementsResponse, Error>]) {
            self.results = results
        }

        func next(_ appVersion: String?) throws -> OsaurusRouterAnnouncementsResponse {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            appVersions.append(appVersion)
            let result = results.count > 1 ? results.removeFirst() : results[0]
            return try result.get()
        }
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private struct Harness {
        let service: AnnouncementsService
        let script: FeedScript
        let clock: Clock
        let defaults: UserDefaults
        let suite: String

        func tearDown() { defaults.removePersistentDomain(forName: suite) }
    }

    private func makeHarness(
        _ results: [Result<OsaurusRouterAnnouncementsResponse, Error>],
        routerEnabled: @escaping () -> Bool = { true },
        appVersion: String? = "1.42.0"
    ) -> Harness {
        let suite = "announcements-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
        let script = FeedScript(results)
        let service = AnnouncementsService(
            defaults: defaults,
            now: { clock.now },
            fetch: { try script.next($0) },
            appVersion: { appVersion },
            isRouterEnabled: routerEnabled
        )
        return Harness(service: service, script: script, clock: clock, defaults: defaults, suite: suite)
    }

    private func feed(_ announcements: [OsaurusRouterAnnouncement], serverTime: String? = "2026-10-02T10:00:00Z")
        -> Result<OsaurusRouterAnnouncementsResponse, Error>
    {
        .success(OsaurusRouterAnnouncementsResponse(serverTime: serverTime, announcements: announcements))
    }

    private func ann(_ slug: String, bodyFormat: String = "markdown", priority: Int = 0) -> OsaurusRouterAnnouncement {
        OsaurusRouterAnnouncement(
            id: "id-\(slug)", slug: slug, title: "Title \(slug)", body: "Body \(slug)",
            bodyFormat: bodyFormat, priority: priority)
    }

    // MARK: - Eligibility

    @Test func eligible_isFirstUnseenRenderableInServerOrder() async {
        let h = makeHarness([feed([ann("html", bodyFormat: "html", priority: 100), ann("first", priority: 50), ann("second", priority: 10)])])
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 1)
        #expect(h.script.appVersions == ["1.42.0"])
        #expect(h.service.serverTime == "2026-10-02T10:00:00Z")
        // Server order is trusted as-is (no local re-sort); non-renderable skipped.
        #expect(h.service.eligibleAnnouncement?.slug == "first")

        // Presenting marks it seen immediately and blocks a second dialog.
        h.service.willPresent(h.service.eligibleAnnouncement!)
        #expect(h.service.eligibleAnnouncement == nil)
        #expect(h.service.hasSeen("first"))
        #expect(h.defaults.bool(forKey: "ai.osaurus.announcement.first.seen"))

        // After dismissal, the next unseen one is eligible.
        h.service.didDismiss()
        #expect(h.service.eligibleAnnouncement?.slug == "second")
        h.service.markSeen("second")
        #expect(h.service.eligibleAnnouncement == nil)
    }

    @Test func seenFlag_persistsAcrossServiceInstancesAndFetches() async {
        let h = makeHarness([feed([ann("raptor")])])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .launch)
        h.service.willPresent(h.service.eligibleAnnouncement!)
        h.service.didDismiss()

        // Fresh instance over the same defaults (a relaunch): still seen,
        // even though the router keeps serving the slug while live.
        let clock = h.clock
        let script = h.script
        let relaunched = AnnouncementsService(
            defaults: h.defaults, now: { clock.now }, fetch: { try script.next($0) },
            appVersion: { "1.42.0" }, isRouterEnabled: { true })
        await relaunched.refreshIfDue(trigger: .launch)
        #expect(relaunched.hasSeen("raptor"))
        #expect(relaunched.eligibleAnnouncement == nil)
    }

    // MARK: - Throttles

    @Test func launchFetch_respectsMinimumSpacing() async {
        let h = makeHarness([feed([])])
        defer { h.tearDown() }

        #expect(h.service.isFetchDue(trigger: .launch))
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 1)

        // A second launch-grade trigger inside 60 s is dropped…
        h.clock.advance(30)
        #expect(!h.service.isFetchDue(trigger: .launch))
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 1)

        // …and allowed once the floor has passed.
        h.clock.advance(AnnouncementsService.minimumFetchSpacing)
        #expect(h.service.isFetchDue(trigger: .launch))
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 2)
    }

    @Test func activationFetch_atMostOncePerThirtyMinutes() async {
        let h = makeHarness([feed([])])
        defer { h.tearDown() }
        #expect(AnnouncementsService.activationRefreshInterval == 30 * 60)

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 1)

        // Cmd-Tab storm over 29 minutes: zero requests.
        for _ in 0..<29 {
            h.clock.advance(60)
            await h.service.refreshIfDue(trigger: .activation)
        }
        #expect(h.script.calls == 1)

        h.clock.advance(61)
        #expect(h.service.isFetchDue(trigger: .activation))
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.calls == 2)

        // The activation window is measured from the last *successful*
        // fetch; a launch fetch in between resets it too.
        h.clock.advance(10 * 60)
        #expect(!h.service.isFetchDue(trigger: .activation))
    }

    @Test func activationThrottle_measuredFromSuccessNotFromFailedAttempts() async {
        let h = makeHarness([
            feed([ann("one")]),
            .failure(OsaurusRouterAPIError.transport("offline")),
            feed([ann("one")]),
        ])
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 1)

        // Failed attempt after the activation window: it only spaces
        // retries by the 60 s floor, not by 30 min.
        h.clock.advance(31 * 60)
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.calls == 2)
        #expect(h.service.announcements.map(\.slug) == ["one"])  // kept

        h.clock.advance(30)
        #expect(!h.service.isFetchDue(trigger: .activation))  // 60 s floor
        h.clock.advance(31)
        #expect(h.service.isFetchDue(trigger: .activation))  // still outside the 30 min window
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.calls == 3)
    }

    @Test func debugTrigger_bypassesThrottlesButNotRateLimit() async {
        let h = makeHarness([
            feed([]),
            .failure(OsaurusRouterAPIError.rateLimited(retryAfter: "90")),
            feed([ann("later")]),
        ])
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.service.isFetchDue(trigger: .debug))
        await h.service.refreshIfDue(trigger: .debug)
        #expect(h.script.calls == 2)

        // 429 just landed: even debug waits for retry-after.
        #expect(!h.service.isFetchDue(trigger: .debug))
        h.clock.advance(89)
        #expect(!h.service.isFetchDue(trigger: .debug))
        h.clock.advance(2)
        #expect(h.service.isFetchDue(trigger: .debug))
        await h.service.refreshIfDue(trigger: .debug)
        #expect(h.service.eligibleAnnouncement?.slug == "later")
    }

    @Test func concurrentCallers_shareOneRequest() async {
        let h = makeHarness([feed([ann("one")])])
        defer { h.tearDown() }

        let service = h.service
        async let a: Void = service.refreshIfDue(trigger: .launch)
        async let b: Void = service.refreshIfDue(trigger: .activation)
        async let c: Void = service.refreshIfDue(trigger: .launch)
        _ = await (a, b, c)
        #expect(h.script.calls == 1)
        #expect(h.service.eligibleAnnouncement?.slug == "one")
    }

    // MARK: - Rate limit and failures

    @Test func rateLimited_honorsRetryAfterSeconds() async {
        let h = makeHarness([
            .failure(OsaurusRouterAPIError.rateLimited(retryAfter: "120")),
            feed([ann("after")]),
        ])
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 1)
        #expect(h.service.announcements.isEmpty)
        #expect(h.service.retryNotBefore == h.clock.now.addingTimeInterval(120))

        h.clock.advance(119)
        #expect(!h.service.isFetchDue(trigger: .launch))
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 1)

        h.clock.advance(2)
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.calls == 2)
        #expect(h.service.retryNotBefore == nil)
        #expect(h.service.eligibleAnnouncement?.slug == "after")
    }

    @Test func rateLimited_backoffParsing() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(AnnouncementsService.backoffInterval(retryAfter: "45", now: now) == 45)
        #expect(AnnouncementsService.backoffInterval(retryAfter: " 7 ", now: now) == 7)
        #expect(
            AnnouncementsService.backoffInterval(retryAfter: nil, now: now)
                == AnnouncementsService.defaultRateLimitBackoff)
        #expect(
            AnnouncementsService.backoffInterval(retryAfter: "soon", now: now)
                == AnnouncementsService.defaultRateLimitBackoff)
        #expect(
            AnnouncementsService.backoffInterval(retryAfter: "0", now: now)
                == AnnouncementsService.defaultRateLimitBackoff)
        // HTTP-date form: relative to the injected clock.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let httpDate = formatter.string(from: now.addingTimeInterval(300))
        #expect(abs(AnnouncementsService.backoffInterval(retryAfter: httpDate, now: now) - 300) < 1)
        // A date in the past still yields a positive pause.
        let past = formatter.string(from: now.addingTimeInterval(-300))
        #expect(AnnouncementsService.backoffInterval(retryAfter: past, now: now) == 1)
    }

    @Test func failures_meanNoAnnouncementAndKeepPreviousList() async {
        let h = makeHarness([
            .failure(OsaurusRouterAPIError.server(code: "INTERNAL", message: "boom", status: 500)),
            .failure(URLError(.notConnectedToInternet)),
            .failure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "malformed"))),
            feed([ann("live")]),
            .failure(OsaurusRouterAPIError.server(code: "UNAVAILABLE", message: "down", status: 503)),
        ])
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)  // 500
        #expect(h.service.eligibleAnnouncement == nil)
        #expect(h.service.lastFetchedAt == nil)
        #expect(h.service.retryNotBefore == nil)  // only 429 sets a backoff

        h.clock.advance(61)
        await h.service.refreshIfDue(trigger: .launch)  // transport
        #expect(h.service.eligibleAnnouncement == nil)

        h.clock.advance(61)
        await h.service.refreshIfDue(trigger: .launch)  // malformed
        #expect(h.service.eligibleAnnouncement == nil)
        #expect(h.script.calls == 3)

        h.clock.advance(61)
        await h.service.refreshIfDue(trigger: .launch)  // success
        #expect(h.service.eligibleAnnouncement?.slug == "live")
        #expect(h.service.lastFetchedAt == h.clock.now)

        // A later outage must not hide the live announcement.
        h.clock.advance(61)
        await h.service.refreshIfDue(trigger: .launch)  // 503
        #expect(h.service.announcements.map(\.slug) == ["live"])
        #expect(h.service.eligibleAnnouncement?.slug == "live")
    }

    @Test func routerDisabled_neverFetches() async {
        let h = makeHarness([feed([ann("one")])], routerEnabled: { false })
        defer { h.tearDown() }

        #expect(!h.service.isFetchDue(trigger: .launch))
        #expect(!h.service.isFetchDue(trigger: .debug))
        await h.service.refreshIfDue(trigger: .launch)
        await h.service.refreshIfDue(trigger: .activation)
        await h.service.refreshIfDue(trigger: .debug)
        #expect(h.script.calls == 0)
        #expect(h.service.eligibleAnnouncement == nil)
    }

    @Test func appVersion_omittedWhenUnknown() async {
        let h = makeHarness([feed([])], appVersion: nil)
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.appVersions == [nil])
    }

    @Test func seenDefaultsKey_matchesContract() {
        #expect(AnnouncementsService.seenDefaultsKey(for: "raptor-launch-2026-10")
            == "ai.osaurus.announcement.raptor-launch-2026-10.seen")
    }
}

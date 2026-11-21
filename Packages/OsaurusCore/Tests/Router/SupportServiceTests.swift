//
//  SupportServiceTests.swift
//  osaurusTests
//
//  Contract tests for Help (bug reports and the team's replies): the request
//  budget (who may fetch, when, and how often), the open-report flag that
//  gates background fetches, unread counting behind the Help badge, the
//  "a failed refresh keeps what we had" rule, Mark as Resolved, and images.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Help support service", .serialized)
@MainActor
struct SupportServiceTests {

    // MARK: - Harness

    /// A scripted router: list results pop in order (the last one repeats);
    /// every call is counted so the budget is asserted, not assumed.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var lists: [Result<OsaurusRouterSupportThreadsResponse, Error>]
        private var _listCalls = 0
        private var _created: [OsaurusRouterSupportReportBody] = []
        private var _detailCalls: [String] = []
        private var _replies: [(id: String, body: String, attachments: [OsaurusRouterSupportAttachmentUpload])] = []
        private var _readCalls: [String] = []
        private var _closeCalls: [String] = []
        private var _attachmentCalls: [String] = []

        var createResult: Result<OsaurusRouterSupportThread, Error>?
        var detailResult: Result<OsaurusRouterSupportThread, Error>?
        var replyResult: Result<OsaurusRouterSupportThread, Error>?
        var readResult: Result<OsaurusRouterSupportThread, Error>?
        var closeResult: Result<OsaurusRouterSupportThread, Error>?
        var attachmentResult: Result<OsaurusRouterSupportAttachmentData, Error>?

        init(_ lists: [Result<OsaurusRouterSupportThreadsResponse, Error>]) {
            self.lists = lists
        }

        var listCalls: Int { lock.withLock { _listCalls } }
        var created: [OsaurusRouterSupportReportBody] { lock.withLock { _created } }
        var detailCalls: [String] { lock.withLock { _detailCalls } }
        var replies: [(id: String, body: String, attachments: [OsaurusRouterSupportAttachmentUpload])] {
            lock.withLock { _replies }
        }
        var readCalls: [String] { lock.withLock { _readCalls } }
        var closeCalls: [String] { lock.withLock { _closeCalls } }
        var attachmentCalls: [String] { lock.withLock { _attachmentCalls } }

        func list() throws -> OsaurusRouterSupportThreadsResponse {
            let result: Result<OsaurusRouterSupportThreadsResponse, Error> = lock.withLock {
                _listCalls += 1
                return lists.count > 1 ? lists.removeFirst() : lists[0]
            }
            return try result.get()
        }

        func create(_ body: OsaurusRouterSupportReportBody) throws -> OsaurusRouterSupportThread {
            lock.withLock { _created.append(body) }
            return try unwrap(createResult)
        }

        func detail(_ id: String) throws -> OsaurusRouterSupportThread {
            lock.withLock { _detailCalls.append(id) }
            return try unwrap(detailResult)
        }

        func reply(_ id: String, _ body: String, _ attachments: [OsaurusRouterSupportAttachmentUpload]) throws
            -> OsaurusRouterSupportThread
        {
            lock.withLock { _replies.append((id, body, attachments)) }
            return try unwrap(replyResult)
        }

        func close(_ id: String) throws -> OsaurusRouterSupportThread {
            lock.withLock { _closeCalls.append(id) }
            return try unwrap(closeResult)
        }

        func attachment(_ threadId: String, _ attachmentId: String) throws -> OsaurusRouterSupportAttachmentData {
            lock.withLock { _attachmentCalls.append(attachmentId) }
            guard let attachmentResult else { throw OsaurusRouterAPIError.invalidResponse }
            return try attachmentResult.get()
        }

        func markRead(_ id: String) throws -> OsaurusRouterSupportThread {
            lock.withLock { _readCalls.append(id) }
            return try unwrap(readResult)
        }

        private func unwrap(_ result: Result<OsaurusRouterSupportThread, Error>?) throws
            -> OsaurusRouterSupportThread
        {
            guard let result else { throw OsaurusRouterAPIError.invalidResponse }
            return try result.get()
        }
    }

    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private struct Harness {
        let service: SupportService
        let script: Script
        let clock: Clock
        let defaults: UserDefaults
        let suite: String
        let routerEnabled: Flag
        let hasIdentity: Flag

        /// A second service on the same defaults: what a relaunch sees.
        @MainActor
        func relaunched() -> SupportService {
            let script = script
            let clock = clock
            let routerEnabled = routerEnabled
            let hasIdentity = hasIdentity
            return SupportService(
                defaults: defaults,
                now: { clock.now },
                api: SupportServiceTests.api(script),
                isRouterEnabled: { routerEnabled.value },
                hasIdentity: { hasIdentity.value }
            )
        }

        func tearDown() { defaults.removePersistentDomain(forName: suite) }
    }

    private static func api(_ script: Script) -> SupportService.API {
        SupportService.API(
            list: { try script.list() },
            create: { try script.create($0) },
            detail: { try script.detail($0) },
            reply: { try script.reply($0, $1, $2) },
            markRead: { try script.markRead($0) },
            close: { try script.close($0) },
            attachment: { try script.attachment($0, $1) }
        )
    }

    private func makeHarness(
        _ lists: [Result<OsaurusRouterSupportThreadsResponse, Error>],
        hasOpenThreads: Bool = false,
        routerEnabled: Bool = true,
        hasIdentity: Bool = true
    ) -> Harness {
        let suite = "support-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if hasOpenThreads {
            defaults.set(true, forKey: SupportService.hasOpenThreadsDefaultsKey)
        }
        let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
        let script = Script(lists)
        let router = Flag(routerEnabled)
        let identity = Flag(hasIdentity)
        let service = SupportService(
            defaults: defaults,
            now: { clock.now },
            api: Self.api(script),
            isRouterEnabled: { router.value },
            hasIdentity: { identity.value }
        )
        return Harness(
            service: service, script: script, clock: clock, defaults: defaults, suite: suite,
            routerEnabled: router, hasIdentity: identity)
    }

    private func thread(
        _ id: String,
        status: String = "open",
        unread: Bool = false,
        staffAt: String? = nil,
        messages: [OsaurusRouterSupportMessage]? = nil
    ) -> OsaurusRouterSupportThread {
        OsaurusRouterSupportThread(
            id: id, subject: "Subject \(id)", statusRaw: status, unread: unread,
            lastUserMessageAt: "2026-11-13T10:00:00.000Z", lastStaffMessageAt: staffAt,
            createdAt: "2026-11-13T10:00:00.000Z", updatedAt: "2026-11-13T10:00:00.000Z",
            messages: messages)
    }

    private func list(_ threads: [OsaurusRouterSupportThread])
        -> Result<OsaurusRouterSupportThreadsResponse, Error>
    {
        .success(
            OsaurusRouterSupportThreadsResponse(data: threads, unreadCount: threads.filter(\.unread).count))
    }

    private static let report = SupportReport(
        app: .init(version: "1.2.3", build: "456", osVersion: "macOS test"),
        hardware: .init(model: "MacBook Air", chip: "M4", memoryGB: 24),
        diagnostics: .object(["schemaVersion": .number(1)]),
        diagnosticsBytes: 19
    )

    private static func draft(_ description: String, category: SupportCategory? = .bug) -> SupportReportDraft {
        var draft = SupportReportDraft()
        draft.category = category
        draft.description = description
        return draft
    }

    private static func image(_ byte: UInt8 = 1) -> SupportImageAttachment {
        SupportImageAttachment(id: UUID(), data: Data([0xFF, 0xD8, byte]), mimeType: "image/jpeg", width: 4, height: 3)
    }

    // MARK: - Decoding

    /// The list sample from `docs/osaurus-integration.md` in osaurus-router.
    @Test func decodesDocumentedListAndDetail() throws {
        let listBody = #"""
            {"data":[{"id":"7d0f0c2e-0000-4000-8000-000000000001","subject":"Chat freezes when I attach a PDF",
              "status":"answered","unread":true,"last_user_message_at":"2026-11-13T21:22:28.955Z",
              "last_staff_message_at":"2026-11-13T22:01:10.120Z","created_at":"2026-11-13T21:22:28.955Z",
              "updated_at":"2026-11-13T22:01:10.120Z"}],"unread_count":1}
            """#
        let response = try JSONDecoder().decode(
            OsaurusRouterSupportThreadsResponse.self, from: Data(listBody.utf8))
        #expect(response.unreadCount == 1)
        let summary = try #require(response.data.first)
        #expect(summary.status == .answered)
        #expect(summary.unread)
        #expect(summary.isOpen)
        #expect(summary.messages == nil)
        #expect(summary.lastActivityDate == OsaurusRouterSupportDate.parse("2026-11-13T22:01:10.120Z"))

        let detailBody = #"""
            {"id":"t1","subject":"S","status":"closed","unread":false,
             "last_user_message_at":"2026-11-13T21:22:28Z","last_staff_message_at":null,
             "created_at":"2026-11-13T21:22:28Z","updated_at":"2026-11-13T21:22:28Z",
             "messages":[{"id":"m1","author":"user","body":"Hello","created_at":"2026-11-13T21:22:28Z"},
                         {"id":"m2","author":"staff","body":"Hi","created_at":"2026-11-13T21:30:00Z"}]}
            """#
        let detail = try JSONDecoder().decode(OsaurusRouterSupportThread.self, from: Data(detailBody.utf8))
        #expect(detail.status == .closed)
        #expect(!detail.isOpen)
        #expect(detail.messages?.map(\.isFromUser) == [true, false])
        #expect(detail.createdDate != nil)
    }

    /// Category and images, as the router sends them since categories and
    /// attachments; an unknown category reads as none.
    @Test func decodesCategoryAndAttachments() throws {
        let body = #"""
            {"id":"t1","subject":"S","status":"open","category":"workflow","unread":false,
             "last_user_message_at":"2026-11-13T21:22:28Z","last_staff_message_at":null,
             "created_at":"2026-11-13T21:22:28Z","updated_at":"2026-11-13T21:22:28Z",
             "messages":[{"id":"m1","author":"user","body":"Hello","created_at":"2026-11-13T21:22:28Z",
               "attachments":[{"id":"a1","mime_type":"image/png","width":640,"height":480,"byte_size":1234}]}]}
            """#
        let detail = try JSONDecoder().decode(OsaurusRouterSupportThread.self, from: Data(body.utf8))
        #expect(detail.category == .workflow)
        #expect(detail.summary.category == .workflow)
        #expect(detail.withUnread(true).categoryRaw == "workflow")
        let attachment = try #require(detail.messages?.first?.attachments.first)
        #expect(attachment == OsaurusRouterSupportAttachment(id: "a1", mimeType: "image/png", width: 640, height: 480, byteSize: 1234))

        let unknown = #"""
            {"id":"t2","subject":"S","status":"open","category":"billing","unread":false,
             "last_user_message_at":"2026-11-13T21:22:28Z","created_at":"2026-11-13T21:22:28Z",
             "updated_at":"2026-11-13T21:22:28Z"}
            """#
        let other = try JSONDecoder().decode(OsaurusRouterSupportThread.self, from: Data(unknown.utf8))
        #expect(other.categoryRaw == "billing")
        #expect(other.category == nil)
    }

    /// Reports from before categories and images: no `category`, messages
    /// without `attachments`.
    @Test func decoding_toleratesMissingCategoryAndAttachments() throws {
        let body = #"""
            {"id":"t1","subject":"S","status":"open","unread":false,
             "last_user_message_at":"2026-11-13T21:22:28Z","created_at":"2026-11-13T21:22:28Z",
             "updated_at":"2026-11-13T21:22:28Z",
             "messages":[{"id":"m1","author":"user","body":"Hello","created_at":"2026-11-13T21:22:28Z"}]}
            """#
        let detail = try JSONDecoder().decode(OsaurusRouterSupportThread.self, from: Data(body.utf8))
        #expect(detail.category == nil)
        #expect(detail.messages?.first?.attachments == [])
    }

    /// A status this build has never heard of must not fail the whole list,
    /// and a missing `unread_count` is derived from the rows.
    @Test func decoding_toleratesUnknownStatusAndMissingCount() throws {
        let body = #"""
            {"data":[{"id":"a","subject":"S","status":"escalated","unread":true,
              "last_user_message_at":"2026-11-13T21:22:28Z","created_at":"2026-11-13T21:22:28Z",
              "updated_at":"2026-11-13T21:22:28Z"}]}
            """#
        let response = try JSONDecoder().decode(OsaurusRouterSupportThreadsResponse.self, from: Data(body.utf8))
        #expect(response.data[0].status == .open)
        #expect(response.data[0].isOpen)
        #expect(response.unreadCount == 1)
    }

    // MARK: - Request budget

    /// Someone who never sent a report costs the router nothing: no launch
    /// call, no activation call.
    @Test func neverReported_backgroundTriggersMakeNoRequests() async {
        let h = makeHarness([list([])])
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        h.clock.advance(3600)
        await h.service.refreshIfDue(trigger: .activation)

        #expect(h.script.listCalls == 0)
        #expect(!h.service.hasLoaded)
    }

    @Test func openingHelp_alwaysFetchesAndRecordsOpenReports() async {
        let h = makeHarness([list([thread("a", status: "answered", unread: true), thread("b", status: "closed")])])
        defer { h.tearDown() }
        #expect(!h.service.hasOpenThreads)

        await h.service.refreshIfDue(trigger: .helpOpened)

        #expect(h.script.listCalls == 1)
        #expect(h.service.hasLoaded)
        #expect(h.service.threads.map(\.id) == ["a", "b"])
        #expect(h.service.unreadCount == 1)
        #expect(h.service.openThreadCount == 1)
        #expect(h.service.hasOpenThreads)
        #expect(h.defaults.bool(forKey: "ai.osaurus.support.hasOpenThreads"))

        // No spacing floor for an explicit open: the user asked.
        await h.service.refreshIfDue(trigger: .helpOpened)
        #expect(h.script.listCalls == 2)
    }

    @Test func openReport_launchFetchesAndActivationIsThrottledTo5Minutes() async {
        let h = makeHarness([list([thread("a")])], hasOpenThreads: true)
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 1)

        h.clock.advance(2 * 60)
        await h.service.refreshIfDue(trigger: .activation)
        h.clock.advance(2 * 60)
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.listCalls == 1)

        h.clock.advance(61)
        #expect(h.service.isFetchDue(trigger: .activation))
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.listCalls == 2)
    }

    /// The in-front poll is how a reply reaches the rail's Help dot while
    /// the user stays in the app: once per 5 minutes, only with an open
    /// report, and never with the Router off.
    @Test func poll_findsANewReplyEvery5MinutesWhileAReportIsOpen() async {
        let h = makeHarness(
            [list([thread("a")]), list([thread("a", status: "answered", unread: true)])],
            hasOpenThreads: true)
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.service.unreadCount == 0)

        for _ in 0 ..< 4 {
            h.clock.advance(60)
            await h.service.refreshIfDue(trigger: .poll)
        }
        #expect(h.script.listCalls == 1)

        h.clock.advance(60)
        await h.service.refreshIfDue(trigger: .poll)
        #expect(h.script.listCalls == 2)
        #expect(h.service.unreadCount == 1)

        h.routerEnabled.value = false
        h.clock.advance(3600)
        await h.service.refreshIfDue(trigger: .poll)
        #expect(h.script.listCalls == 2)
    }

    @Test func poll_neverReported_makesNoRequests() async {
        let h = makeHarness([list([])])
        defer { h.tearDown() }

        for _ in 0 ..< 10 {
            h.clock.advance(5 * 60)
            await h.service.refreshIfDue(trigger: .poll)
        }
        #expect(h.script.listCalls == 0)
    }

    /// The flag survives a relaunch, which is the only way a launch can know
    /// to ask without asking.
    @Test func openFlag_persistsAcrossRelaunch() async {
        let h = makeHarness([list([thread("a")])])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .helpOpened)

        let relaunched = h.relaunched()
        #expect(relaunched.hasOpenThreads)
        h.clock.advance(120)
        await relaunched.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 2)
    }

    @Test func allReportsClosed_stopsBackgroundFetches() async {
        let h = makeHarness([list([thread("a", status: "closed")])], hasOpenThreads: true)
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 1)
        #expect(!h.service.hasOpenThreads)

        h.clock.advance(2 * 3600)
        await h.service.refreshIfDue(trigger: .activation)
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 1)
    }

    /// With Use Osaurus Router off, nothing is fetched in the background,
    /// but the Help page still works.
    @Test func routerOff_suppressesBackgroundButNotHelp() async {
        let h = makeHarness([list([thread("a")])], hasOpenThreads: true, routerEnabled: false)
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        h.clock.advance(3600)
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.listCalls == 0)

        await h.service.refreshIfDue(trigger: .helpOpened)
        #expect(h.script.listCalls == 1)

        h.routerEnabled.value = true
        h.clock.advance(3600)
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.listCalls == 2)
    }

    @Test func noIdentity_neverFetches() async {
        let h = makeHarness([list([thread("a")])], hasOpenThreads: true, hasIdentity: false)
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        await h.service.refreshIfDue(trigger: .activation)
        await h.service.refreshIfDue(trigger: .helpOpened)

        #expect(h.script.listCalls == 0)
        #expect(!h.service.isFetchDue(trigger: .helpOpened))
    }

    /// A failed attempt still counts toward the 60 s floor, so a router that
    /// is down is not hammered by app switching.
    @Test func failure_keepsPreviousListAndSpacesRetries() async {
        let h = makeHarness(
            [
                list([thread("a", status: "answered", unread: true)]),
                .failure(OsaurusRouterAPIError.transport("offline")),
                list([thread("a", status: "answered", unread: true), thread("b")]),
            ], hasOpenThreads: true)
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.service.refreshError == nil)

        h.clock.advance(31 * 60)
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.listCalls == 2)
        #expect(h.service.threads.map(\.id) == ["a"])
        #expect(h.service.unreadCount == 1)
        #expect(h.service.refreshError != nil)
        #expect(h.service.hasOpenThreads)

        h.clock.advance(30)
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 2)

        h.clock.advance(31)
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 3)
        #expect(h.service.threads.map(\.id) == ["a", "b"])
        #expect(h.service.refreshError == nil)
    }

    @Test func rateLimited_backgroundWaitsForRetryAfter() async {
        let h = makeHarness(
            [.failure(OsaurusRouterAPIError.rateLimited(retryAfter: "900")), list([thread("a")])],
            hasOpenThreads: true)
        defer { h.tearDown() }

        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 1)

        h.clock.advance(600)
        #expect(!h.service.isFetchDue(trigger: .launch))
        #expect(!h.service.isFetchDue(trigger: .activation))
        await h.service.refreshIfDue(trigger: .launch)
        #expect(h.script.listCalls == 1)

        h.clock.advance(301)
        await h.service.refreshIfDue(trigger: .activation)
        #expect(h.script.listCalls == 2)
        #expect(h.service.isFetchDue(trigger: .launch) == false)  // 60 s floor after the success
    }

    @Test func concurrentCallers_shareOneRequest() async {
        let h = makeHarness([list([thread("a")])], hasOpenThreads: true)
        defer { h.tearDown() }

        let service = h.service
        async let first: Void = service.refreshIfDue(trigger: .helpOpened)
        async let second: Void = service.refreshIfDue(trigger: .helpOpened)
        async let third: Void = service.refreshIfDue(trigger: .launch)
        _ = await (first, second, third)

        #expect(h.script.listCalls == 1)
        #expect(!h.service.isRefreshing)
    }

    // MARK: - Sending

    /// A sent report is sent with consent, shows up at the top of the list
    /// without a second request, and turns background checks on.
    @Test func submit_sendsConsentAndStartsWatchingForReplies() async throws {
        let h = makeHarness([list([])])
        defer { h.tearDown() }
        h.script.createResult = .success(
            thread(
                "new",
                messages: [
                    .init(id: "m1", author: "user", body: "It broke", createdAt: "2026-11-13T10:00:00Z")
                ]))

        var draft = Self.draft("  It broke when I did X  ", category: .model)
        draft.model = SupportPick(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B")
        draft.problemId = "load"
        draft.images = [Self.image()]
        let extras = JSONValue.object(["model": .object(["id": .string("mlx-community/Qwen3-8B-4bit")])])
        let created = try await h.service.submit(draft: draft, report: Self.report, extras: extras)

        #expect(created.id == "new")
        let body = try #require(h.script.created.first)
        #expect(body.consent)
        #expect(body.description == "It broke when I did X")
        #expect(body.category == "model")
        #expect(body.details == .object(["model": .string("mlx-community/Qwen3-8B-4bit"), "problem": .string("load")]))
        #expect(body.attachments == [draft.images[0].upload])
        #expect(body.attachments[0].dataBase64 == Data([0xFF, 0xD8, 1]).base64EncodedString())
        #expect(body.app.version == "1.2.3")
        #expect(body.hardware.memoryGB == 24)
        #expect(body.diagnostics == .object(["schemaVersion": .number(1), "extras": extras]))

        #expect(h.script.listCalls == 0)
        #expect(h.service.threads.map(\.id) == ["new"])
        #expect(h.service.threads[0].messages == nil)
        #expect(h.service.conversations["new"]?.messages?.count == 1)
        #expect(h.service.hasOpenThreads)
        #expect(h.service.isFetchDue(trigger: .launch))
    }

    @Test func submit_failureLeavesStateUntouched() async {
        let h = makeHarness([list([])])
        defer { h.tearDown() }
        h.script.createResult = .failure(
            OsaurusRouterAPIError.server(code: "INVALID_STATE", message: "too many open threads", status: 409))

        await #expect(throws: OsaurusRouterAPIError.self) {
            try await h.service.submit(draft: Self.draft("It broke when I did X"), report: Self.report, extras: nil)
        }
        #expect(h.service.threads.isEmpty)
        #expect(!h.service.hasOpenThreads)
    }

    /// Writing on a closed report reopens it, which must turn the
    /// background check back on.
    @Test func reply_updatesConversationAndReopens() async throws {
        let h = makeHarness([list([thread("a", status: "closed")])])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .helpOpened)
        #expect(!h.service.hasOpenThreads)

        h.script.replyResult = .success(
            thread(
                "a", status: "open",
                messages: [
                    .init(id: "m1", author: "user", body: "First", createdAt: "2026-11-13T10:00:00Z"),
                    .init(id: "m2", author: "user", body: "Still broken", createdAt: "2026-11-13T11:00:00Z"),
                ]))
        let image = Self.image()
        try await h.service.reply(threadId: "a", body: "Still broken", images: [image])

        #expect(h.script.replies.map(\.body) == ["Still broken"])
        #expect(h.script.replies.first?.attachments == [image.upload])
        #expect(h.service.threads.map(\.status) == [.open])
        #expect(h.service.conversations["a"]?.messages?.count == 2)
        #expect(h.service.hasOpenThreads)
    }

    // MARK: - Mark as Resolved

    /// Resolving frees an open slot and, with nothing else open, stops the
    /// background checks; writing again reopens it.
    @Test func close_resolvesTheReportAndStopsWatching() async throws {
        let h = makeHarness([list([thread("a", status: "answered")])])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .helpOpened)
        #expect(h.service.openThreadCount == 1)
        #expect(h.service.hasOpenThreads)

        h.script.closeResult = .success(
            thread(
                "a", status: "closed",
                messages: [.init(id: "m1", author: "user", body: "Hello", createdAt: "2026-11-13T10:00:00Z")]))
        try await h.service.close(threadId: "a")

        #expect(h.script.closeCalls == ["a"])
        #expect(h.service.threads.map(\.status) == [.closed])
        #expect(h.service.openThreadCount == 0)
        #expect(!h.service.hasOpenThreads)
        #expect(h.service.conversations["a"]?.messages?.count == 1)
        #expect(h.script.listCalls == 1)
    }

    @Test func close_failureLeavesTheReportOpen() async {
        let h = makeHarness([list([thread("a")])])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .helpOpened)
        h.script.closeResult = .failure(OsaurusRouterAPIError.transport("offline"))

        await #expect(throws: OsaurusRouterAPIError.self) { try await h.service.close(threadId: "a") }
        #expect(h.service.threads.map(\.status) == [.open])
        #expect(h.service.hasOpenThreads)
    }

    // MARK: - Images

    /// An image is fetched once; reopening the conversation reads memory.
    @Test func attachmentData_isFetchedOnceAndCached() async throws {
        let h = makeHarness([list([])])
        defer { h.tearDown() }
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        h.script.attachmentResult = .success(
            OsaurusRouterSupportAttachmentData(mimeType: "image/png", dataBase64: bytes.base64EncodedString()))

        #expect(try await h.service.attachmentData(threadId: "t", attachmentId: "a1") == bytes)
        #expect(try await h.service.attachmentData(threadId: "t", attachmentId: "a1") == bytes)
        #expect(h.script.attachmentCalls == ["a1"])
    }

    @Test func attachmentData_rejectsBadBase64AndDoesNotCacheIt() async {
        let h = makeHarness([list([])])
        defer { h.tearDown() }
        h.script.attachmentResult = .success(
            OsaurusRouterSupportAttachmentData(mimeType: "image/png", dataBase64: "not base64!"))

        await #expect(throws: OsaurusRouterAPIError.self) {
            try await h.service.attachmentData(threadId: "t", attachmentId: "a1")
        }
        await #expect(throws: OsaurusRouterAPIError.self) {
            try await h.service.attachmentData(threadId: "t", attachmentId: "a1")
        }
        #expect(h.script.attachmentCalls == ["a1", "a1"])
    }

    // MARK: - Unread

    @Test func markRead_clearsBadgeAndTellsRouterOnce() async {
        let h = makeHarness([
            list([thread("a", status: "answered", unread: true), thread("b", status: "answered", unread: true)])
        ])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .helpOpened)
        #expect(h.service.unreadCount == 2)
        h.script.readResult = .success(thread("a", status: "answered", unread: false))

        await h.service.markRead(threadId: "a")
        #expect(h.service.unreadCount == 1)
        #expect(h.script.readCalls == ["a"])
        #expect(h.service.threads.first { $0.id == "a" }?.unread == false)

        // Already read: no request.
        await h.service.markRead(threadId: "a")
        await h.service.markRead(threadId: "missing")
        #expect(h.script.readCalls == ["a"])
    }

    /// The badge drops even when the call fails; the next list refresh is
    /// the authority and brings it back if the router still says unread.
    @Test func markRead_failureIsOptimisticUntilNextRefresh() async {
        let unread = [thread("a", status: "answered", unread: true)]
        let h = makeHarness([list(unread), list(unread)])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .helpOpened)
        h.script.readResult = .failure(OsaurusRouterAPIError.transport("offline"))

        await h.service.markRead(threadId: "a")
        #expect(h.service.unreadCount == 0)

        await h.service.refreshIfDue(trigger: .helpOpened)
        #expect(h.service.unreadCount == 1)
    }

    @Test func loadConversation_cachesMessagesAndDropsThemWhenTheReportIsGone() async throws {
        let h = makeHarness([list([thread("a")]), list([])])
        defer { h.tearDown() }
        await h.service.refreshIfDue(trigger: .helpOpened)
        h.script.detailResult = .success(
            thread(
                "a", status: "answered", unread: true, staffAt: "2026-11-13T12:00:00Z",
                messages: [
                    .init(id: "m1", author: "user", body: "Hello", createdAt: "2026-11-13T10:00:00Z"),
                    .init(id: "m2", author: "staff", body: "Hi", createdAt: "2026-11-13T12:00:00Z"),
                ]))

        try await h.service.loadConversation(id: "a")
        #expect(h.script.detailCalls == ["a"])
        #expect(h.service.conversations["a"]?.messages?.map(\.author) == ["user", "staff"])
        // The detail is newer than the list row; the row follows it.
        #expect(h.service.threads[0].status == .answered)
        #expect(h.service.unreadCount == 1)

        await h.service.refreshIfDue(trigger: .helpOpened)
        #expect(h.service.conversations.isEmpty)
        #expect(h.service.unreadCount == 0)
    }

    // MARK: - Messages

    /// Router error text is written for logs. The page shows its own
    /// sentences and never the raw message.
    @Test func userMessage_neverEchoesRouterText() {
        let raw = "too many open threads for wallet 0xabc"
        let cases: [Error] = [
            OsaurusRouterAPIError.server(code: "INVALID_STATE", message: raw, status: 409),
            OsaurusRouterAPIError.server(code: "PAYLOAD_TOO_LARGE", message: raw, status: 413),
            OsaurusRouterAPIError.server(code: "NOT_FOUND", message: raw, status: 404),
            OsaurusRouterAPIError.server(code: "INTERNAL", message: raw, status: 500),
            OsaurusRouterAPIError.server(code: "VALIDATION", message: raw, status: 400),
            OsaurusRouterAPIError.transport(raw),
            OsaurusRouterAPIError.rateLimited(retryAfter: "60"),
            OsaurusRouterAPIError.noIdentity,
            OsaurusRouterAPIError.unauthorized,
            OsaurusRouterAPIError.accountFrozen,
            URLError(.timedOut),
        ]
        let messages = cases.map(SupportService.userMessage(for:))
        for message in messages {
            #expect(!message.isEmpty)
            #expect(!message.contains(raw))
            #expect(!message.contains("0xabc"))
        }
        // Distinct situations get distinct sentences.
        #expect(Set(messages.prefix(4)).count == 4)
    }
}

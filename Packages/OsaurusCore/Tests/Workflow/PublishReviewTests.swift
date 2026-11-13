//
//  PublishReviewTests.swift
//  OsaurusCoreTests
//
//  Store review end to end without a registry: review and `listed` decode
//  from every answer (and are absent from a registry that predates
//  review), records written before review still load, a Public submission
//  reads as unlisted until approved, the first review a Mac learns of
//  isn't announced while a later decision is, the watcher long-polls with
//  its token and cursor, announces one decision, drops a rejected token,
//  backs off, and stops once nothing is pending, and signed calls fetch a
//  watch token only while something waits for review.
//

import Foundation
import Testing

@testable import OsaurusCore

private let base = URL(string: "https://registry.test")!
private let registryID = "c8b28fcf-d167-4121-b1ac-a1a9368603d5"
private let templateID = UUID(uuidString: "5B0B4D2A-3C8E-4C47-9F57-0D4F8C7C2C11")!

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try WorkflowsRegistryAPIClient.dateDecoder.decode(T.self, from: Data(json.utf8))
}

private func reviewJSON(
    _ status: String, version: Int = 1, message: String? = nil, decided: String? = nil, hours: Int? = 24
) -> String {
    """
    {"status":"\(status)","version":\(version),"message":\(message.map { "\"\($0)\"" } ?? "null"),\
    "submitted_at":"2026-10-22T10:00:00.000Z","decided_at":\(decided.map { "\"\($0)\"" } ?? "null"),\
    "expected_within_hours":\(hours.map(String.init) ?? "null")}
    """
}

private func record(
    visibility: WorkflowVisibility = .public, review: WorkflowsRegistryReview? = nil, live: Int? = nil,
    latest: Int = 1, listed: Bool? = nil, id: UUID = templateID
) -> WorkflowRegistryRecord {
    var r = WorkflowRegistryRecord(
        templateID: id, registryID: registryID, slug: "client-intake", version: latest,
        contentHash: "sha256:00", url: URL(string: "https://web.test/w/client-intake")!,
        rawURL: URL(string: "https://registry.test/raw")!, deepLink: URL(string: "osaurus://templates-import")!,
        address: "0xabc", registry: WorkflowRegistryRecordStore.registryKey(base),
        sharedAt: Date(timeIntervalSince1970: 1_800_000_000), visibility: visibility)
    r.registryLatestVersion = latest
    r.liveVersion = live
    r.listed = listed
    r.applyReview(review)
    return r
}

private func review(
    _ status: WorkflowsRegistryReview.Status, version: Int = 1, message: String? = nil, decidedAt: Date? = nil
) -> WorkflowsRegistryReview {
    WorkflowsRegistryReview(
        status: status, version: version, message: message, submittedAt: submitted, decidedAt: decidedAt,
        expectedWithinHours: 24)
}

/// When `reviewJSON` says the version was submitted.
private let submitted = ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z")!

// MARK: - Decoding and records

struct PublishReviewDecodingTests {
    @Test
    func watchAnswersDecode_andSkipStatusesThisBuildDoesntKnow() throws {
        let json = """
            {"cursor":"abc","changed":true,"items":[\
            {"id":"\(registryID)","template_id":"\(templateID.uuidString)","slug":"client-intake","kind":"workflow",\
            "visibility":"public","status":"active","removed_by":null,"latest_version":2,"live_version":1,\
            "listed":true,"review":\(reviewJSON("rejected", version: 2, message: "Rename the steps.", decided: "2026-10-22T11:00:00Z", hours: nil))},\
            {"id":"x","template_id":"\(UUID().uuidString)","slug":"other","kind":"workflow","visibility":"public",\
            "status":"active","removed_by":null,"latest_version":1,"live_version":1,"review":\(reviewJSON("escalated"))}]}
            """
        let watch = try decode(WorkflowsRegistryReviewWatch.self, json)
        #expect(watch.cursor == "abc" && watch.changed)
        #expect(watch.items.count == 1, "an unknown review status is skipped, not fatal")
        let item = try #require(watch.items.first)
        #expect(item.templateID == templateID)
        #expect(item.listed == true && item.liveVersion == 1 && item.latestVersion == 2)
        #expect(item.review.status == .rejected && item.review.note == "Rename the steps.")
        #expect(item.review.expectedWithinHours == nil)
    }

    @Test
    func aRecordWrittenBeforeReviewStillLoads() throws {
        let old = """
            {"template_id":"\(templateID.uuidString)","registry_id":"\(registryID)","slug":"client-intake",\
            "version":3,"content_hash":"sha256:00","url":"https://web.test/w/client-intake",\
            "raw_url":"https://registry.test/raw","deep_link":"osaurus://templates-import","address":"0xabc",\
            "registry":"registry.test","shared_at":"2026-10-01T00:00:00Z","visibility":"public"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(WorkflowRegistryRecord.self, from: Data(old.utf8))
        #expect(loaded.review == nil && loaded.liveVersion == nil && loaded.listed == nil && loaded.reviewSeenAt == nil)
        #expect(loaded.isListed, "a Public listing from before review is in the store")
        #expect(PublishReviewState(record: loaded).phase == .listed)
        #expect(!loaded.hasUnseenDecision)
    }

    @Test
    func theFirstReviewLearnedIsSeen_aLaterDecisionIsNot() {
        let decided = submitted.addingTimeInterval(3600)
        // Learned already decided: not news.
        let approvedLongAgo = record(review: review(.approved, decidedAt: decided))
        #expect(!approvedLongAgo.hasUnseenDecision)

        // Learned pending, then decided: news until opened.
        var pending = record(review: review(.pending))
        #expect(!pending.hasUnseenDecision)
        pending.applyReview(review(.rejected, message: "Rename the steps.", decidedAt: decided))
        #expect(pending.hasUnseenDecision)
        pending.markReviewSeen()
        #expect(!pending.hasUnseenDecision)
    }

    @Test
    func aWatchedItemFoldsIntoTheRecord_includingAnAdminRemoval() throws {
        var r = record(review: review(.pending))
        let json = """
            {"id":"\(registryID)","template_id":"\(templateID.uuidString)","slug":"client-intake","kind":"workflow",\
            "visibility":"public","status":"removed","removed_by":"admin","latest_version":1,"live_version":1,\
            "listed":false,"review":\(reviewJSON("withdrawn", decided: "2026-10-22T11:00:00Z"))}
            """
        r.apply(try decode(WorkflowsRegistryWatchedReview.self, json))
        #expect(r.removedByAdmin && !r.takenDown && r.listed == false)
        #expect(PublishReviewState(record: r).phase == .removed)
    }
}

// MARK: - State and copy

struct PublishReviewStateTests {
    @Test
    func aPublicSubmissionIsUnlistedUntilApproved() {
        let state = PublishReviewState(record: record(review: review(.pending), live: 1, listed: false))
        #expect(state.phase == .inReview)
        #expect(state.isUnlistedUntilApproved && state.listedVersion == nil)
        #expect(state.headline == "In review · Unlisted until approved")
        #expect(state.detail().contains("Anyone with the link can open it now"))
        let steps = state.steps(uploadedVersion: 1)
        #expect(steps.map(\.state) == [.done, .done, .waiting, .upcoming])
        #expect(steps.last?.detail == "Unlisted until approved")
    }

    @Test
    func withoutTheFlag_aFirstSubmissionStillReadsUnlisted() {
        // A registry answer that carried live_version but not listed.
        let state = PublishReviewState(record: record(review: review(.pending), live: 1))
        #expect(state.isUnlistedUntilApproved)
    }

    @Test
    func anUpdateWaitsWhileTheApprovedVersionStaysListed() {
        let state = PublishReviewState(record: record(review: review(.pending, version: 3), live: 2, latest: 3))
        #expect(state.phase == .inReview && !state.isUnlistedUntilApproved)
        #expect(state.listedVersion == 2)
        #expect(state.detail().hasPrefix("Version 2 stays in the store until version 3 is approved."))
        #expect(state.steps(uploadedVersion: 3).last?.state == .done)
    }

    @Test
    func changesRequestedAndApproval() {
        let rejected = PublishReviewState(
            record: record(review: review(.rejected, message: "Rename the steps."), live: 1, listed: false))
        #expect(rejected.phase == .changesRequested && rejected.chipText == "Changes requested")
        #expect(rejected.steps(uploadedVersion: 1)[2].state == .attention)

        let approved = PublishReviewState(record: record(review: review(.approved), live: 1, listed: true))
        #expect(approved.phase == .listed && approved.listedVersion == 1 && approved.chipText == nil)
    }

    @Test
    func unlistedAndPasswordSkipReview() {
        let state = PublishReviewState(record: record(visibility: .hidden, live: 1, listed: false))
        #expect(state.phase == .linkOnly && state.chipText == nil)
        #expect(state.steps(uploadedVersion: 1).suffix(2).map(\.state) == [.skipped, .skipped])
    }

    @Test
    func publishButtonsSayWhatHappens() {
        #expect(WorkflowShareCopy.publishLabel(version: nil, record: nil, visibility: .public) == "Submit for Review")
        #expect(WorkflowShareCopy.publishLabel(version: nil, record: nil, visibility: .hidden) == "Publish")
        let listed = record(review: review(.approved), live: 1, listed: true)
        #expect(WorkflowShareCopy.publishLabel(version: 2, record: listed) == "Submit Version 2 for Review")
        let rejected = record(review: review(.rejected), live: 1, listed: false)
        #expect(WorkflowShareCopy.publishLabel(version: 2, record: rejected, short: true) == "Resubmit v2")
        let unlisted = record(visibility: .hidden, live: 1)
        #expect(WorkflowShareCopy.publishLabel(version: 2, record: unlisted) == "Publish Version 2")
    }

    @Test
    func statusReadsUnlistedUntilApproved() {
        let pending = record(review: review(.pending), live: 1, listed: false)
        #expect(WorkflowShareCopy.status(pending) == "Live · Unlisted until approved · In review")
        #expect(WorkflowShareCopy.status(pending, includesReview: false) == "Live · Unlisted until approved")
    }

    @Test
    func theReviseBriefQuotesTheReviewer() {
        let message = PublishReviewBrief.message(
            name: "Client Intake", review: review(.rejected, version: 2, message: "Rename the steps.\nAdd an example."))
        #expect(message.contains("version 2 of “Client Intake”"))
        #expect(message.contains("> Rename the steps.\n> Add an example."))
        let silent = PublishReviewBrief.message(name: "Client Intake", review: review(.rejected, version: 2))
        #expect(silent.contains("without a note"))
        #expect(PublishReviewBrief.note(name: "Client Intake", review: review(.rejected, version: 2)).contains("(no message)"))
    }
}

// MARK: - HTTP

/// One per test, found by the header its session sends, so suites running
/// side by side never answer each other's requests.
private final class ReviewStub: @unchecked Sendable {
    static let header = "X-Review-Stub"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: [String: ReviewStub] = [:]

    let id = UUID().uuidString
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) -> (Int, String)
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.handler = handler
        Self.lock.withLock { Self.live[id] = self }
    }

    static func respond(_ request: URLRequest) -> (Int, String) {
        let stub = lock.withLock { request.value(forHTTPHeaderField: header).flatMap { live[$0] } }
        guard let stub else { return (500, "{}") }
        stub.lock.withLock { stub.recorded.append(request) }
        return stub.handler(request)
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func client() -> WorkflowsRegistryAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewStubProtocol.self]
        config.httpAdditionalHeaders = [Self.header: id]
        return WorkflowsRegistryAPIClient(baseURL: base, session: URLSession(configuration: config))
    }
}

private final class ReviewStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, json) = ReviewStub.respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func watchJSON(cursor: String, changed: Bool, review: String?, listed: Bool = false) -> String {
    guard changed, let review else { return #"{"cursor":"\#(cursor)","changed":false,"items":[]}"# }
    return """
        {"cursor":"\(cursor)","changed":true,"items":[{"id":"\(registryID)","template_id":"\(templateID.uuidString)",\
        "slug":"client-intake","kind":"workflow","visibility":"public","status":"active","removed_by":null,\
        "latest_version":1,"live_version":1,"listed":\(listed),"review":\(review)}]}
        """
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 250 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
private func withRecords(_ body: @MainActor @Sendable (WorkflowRegistryRecordStore) async throws -> Void) async throws {
    try await StoragePathsTestLock.shared.run { @MainActor in
        let previous = OsaurusPaths.overrideRoot
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = previous
            try? FileManager.default.removeItem(at: root)
        }
        try await body(WorkflowRegistryRecordStore())
    }
}

@Suite(.serialized)
@MainActor
struct RegistryReviewWatcherTests {
    @Test
    func longPollsWithTokenAndCursor_announcesOneDecision_thenStops() async throws {
        let pending = reviewJSON("pending")
        let rejected = reviewJSON("rejected", message: "Rename the steps.", decided: "2026-10-22T11:00:00Z", hours: nil)
        let stub = ReviewStub { request in
            switch query(request)["since"] {
            case nil: return (200, watchJSON(cursor: "c1", changed: true, review: pending))
            case "c1": return (200, watchJSON(cursor: "c2", changed: true, review: rejected))
            default: return (200, watchJSON(cursor: "c2", changed: false, review: nil))
            }
        }
        try await withRecords { records in
            records.set(record(review: review(.pending), live: 1, listed: false))
            let tokens = RegistryReviewWatchTokens(usesKeychain: false)
            tokens.set("rwt_test", for: base)
            var decisions: [PublishReviewDecision] = []
            let watcher = RegistryReviewWatcher(
                api: stub.client(), records: records, tokens: tokens, onDecision: { decisions.append($0) })
            watcher.start()
            #expect(watcher.isWatching)

            #expect(await eventually { !decisions.isEmpty })
            #expect(await eventually { !watcher.isWatching }, "nothing pending: the loop stops")
            watcher.stop()

            #expect(decisions.count == 1)
            let decision = try #require(decisions.first)
            #expect(decision.changesRequested && decision.body == "Rename the steps.")
            #expect(decision.title == "Changes requested: client-intake")
            let stored = try #require(records.record(for: templateID, registry: base))
            #expect(stored.review?.status == .rejected && stored.hasUnseenDecision)

            let requests = stub.requests
            #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer rwt_test" })
            #expect(requests.allSatisfy { $0.url?.path == "/me/reviews" })
            #expect(query(requests[0])["wait"] == "0", "the first read answers at once")
            #expect(query(requests[1]) == ["since": "c1", "wait": "25"])
        }
    }

    @Test
    func anApprovalAlreadySeen_staysQuietOnEveryLaunch() async throws {
        // The registry's decision time carries milliseconds; records saved
        // before the store kept them hold the whole second.
        let approved = reviewJSON("approved", decided: "2026-10-22T22:24:59.482Z", hours: nil)
        let stub = ReviewStub { request in
            query(request)["since"] == nil
                ? (200, watchJSON(cursor: "c1", changed: true, review: approved, listed: true))
                : (200, watchJSON(cursor: "c1", changed: false, review: nil))
        }
        let wholeSecond = try #require(ISO8601DateFormatter().date(from: "2026-10-22T22:24:59Z"))
        try await withRecords { records in
            records.set(record(review: review(.approved, decidedAt: wholeSecond), live: 1, listed: true))
            // Another listing still waits, so the watcher runs at launch.
            records.set(record(review: review(.pending), live: 1, listed: false, id: UUID()))
            let tokens = RegistryReviewWatchTokens(usesKeychain: false)
            tokens.set("rwt_test", for: base)

            for launch in 1 ... 2 {
                let reloaded = WorkflowRegistryRecordStore()
                var decisions: [PublishReviewDecision] = []
                let watcher = RegistryReviewWatcher(
                    api: stub.client(), records: reloaded, tokens: tokens, onDecision: { decisions.append($0) })
                let before = stub.requests.count
                watcher.start()
                #expect(await eventually { stub.requests.count >= before + 2 })
                watcher.stop()
                #expect(decisions.isEmpty, "launch \(launch) announced an approval already seen")
                let stored = try #require(reloaded.record(for: templateID, registry: base))
                #expect(!stored.hasUnseenDecision)
            }

            let saved = try #require(WorkflowRegistryRecordStore().record(for: templateID, registry: base))
            let decided = try #require(saved.review?.decidedAt)
            #expect(abs(decided.timeIntervalSince(wholeSecond) - 0.482) < 0.001, "fractional seconds survive a save")
        }
    }

    @Test
    func aRejectedTokenIsDropped_andTheLoopWaitsForTheNextSignedCall() async throws {
        let stub = ReviewStub { _ in (401, #"{"error":"invalid_watch_token"}"#) }
        try await withRecords { records in
            records.set(record(review: review(.pending), live: 1, listed: false))
            let tokens = RegistryReviewWatchTokens(usesKeychain: false)
            tokens.set("rwt_revoked", for: base)
            let watcher = RegistryReviewWatcher(
                api: stub.client(), records: records, tokens: tokens, onDecision: { _ in })
            watcher.start()
            #expect(await eventually { tokens.token(for: base) == nil })
            #expect(await eventually { !watcher.isWatching })
            watcher.stop()
            #expect(stub.requests.count == 1)
        }
    }

    @Test
    func failuresBackOff_thenTheLoopCarriesOn() async throws {
        let failures = Counter()
        let stub = ReviewStub { request in
            if failures.next() < 2 { return (503, #"{"error":"unavailable"}"#) }
            return (200, watchJSON(cursor: "c1", changed: false, review: nil))
        }
        try await withRecords { records in
            records.set(record(review: review(.pending), live: 1, listed: false))
            let tokens = RegistryReviewWatchTokens(usesKeychain: false)
            tokens.set("rwt_test", for: base)
            let slept = Recorder()
            let watcher = RegistryReviewWatcher(
                api: stub.client(), records: records, tokens: tokens, onDecision: { _ in },
                sleep: { duration in slept.append(duration) })
            watcher.start()
            #expect(await eventually { stub.requests.count >= 4 })
            watcher.stop()
            #expect(Array(slept.values.prefix(2)) == [.seconds(2), .seconds(4)])
            #expect(watcher.lastHeardAt != nil)
        }
    }

    @Test
    func withoutAPendingReviewOrAToken_nothingRuns() async throws {
        let stub = ReviewStub { _ in (200, watchJSON(cursor: "c", changed: false, review: nil)) }
        try await withRecords { records in
            records.set(record(review: review(.approved), live: 1, listed: true))
            let tokens = RegistryReviewWatchTokens(usesKeychain: false)
            tokens.set("rwt_test", for: base)
            let watcher = RegistryReviewWatcher(
                api: stub.client(), records: records, tokens: tokens, onDecision: { _ in })
            watcher.start()
            #expect(!watcher.isWatching)

            tokens.remove(for: base)
            records.set(record(review: review(.pending), live: 1, listed: false))
            try await Task.sleep(for: .milliseconds(100))
            #expect(!watcher.isWatching, "a pending review without a token waits for a signed call")
            watcher.stop()
            #expect(stub.requests.isEmpty)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    func append(_ d: Duration) { lock.withLock { recorded.append(d) } }
    var values: [Duration] { lock.withLock { recorded } }
}

// MARK: - Watch token issuance

@Suite(.serialized)
@MainActor
struct ReviewWatchTokenIssuanceTests {
    nonisolated private static func publishedJSON(review: String?) -> String {
        let raw = "https://registry.test/workflows/\(registryID)/versions/1/template.json"
        let deepLink =
            "osaurus://templates-import?url=" + raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return """
            {"id":"\(registryID)","slug":"client-intake","version":1,"content_hash":"sha256:00","created":true,\
            "url":"https://web.test/w/client-intake","raw_url":"\(raw)","deep_link":"\(deepLink)",\
            "visibility":"public","live_version":1,"listed":false,"review":\(review ?? "null")}
            """
    }

    private func share(review: String?) async throws -> (
        requests: [URLRequest], token: String?, record: WorkflowRegistryRecord?
    ) {
        let stub = ReviewStub { request in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"\#(String(repeating: "a", count: 64))","expires_in":60}"#)
            case "/workflows": return (201, Self.publishedJSON(review: review))
            case "/me/review-watch": return (201, #"{"token":"rwt_issued","address":"0xabc"}"#)
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        var result: (requests: [URLRequest], token: String?, record: WorkflowRegistryRecord?) = ([], nil, nil)
        try await withRecords { records in
            let tokens = RegistryReviewWatchTokens(usesKeychain: false)
            let service = WorkflowShareService(
                api: stub.client(), records: records, readKey: { TestKeys.alicePrivateKey },
                readReceiptKey: { TestKeys.alicePrivateKey }, identityExists: { true },
                knownTemplateIDs: { [] }, isBuiltIn: { _ in false },
                now: { Date(timeIntervalSince1970: 1_800_000_000) }, watchTokens: tokens)
            let template = WF.template(WF.intake()).sealed()
            _ = try await service.share(template, authorName: nil, visibility: .public)
            result = (
                stub.requests, tokens.token(for: base),
                records.record(for: template.id, registry: base)
            )
        }
        return result
    }

    @Test
    func aSubmissionFetchesAWatchTokenWhileTheKeyIsRead() async throws {
        let shared = try await share(review: reviewJSON("pending"))
        #expect(shared.requests.map(\.url?.path) == ["/auth/challenge", "/workflows", "/auth/challenge", "/me/review-watch"])
        #expect(shared.token == "rwt_issued")
        let stored = try #require(shared.record)
        #expect(stored.review?.status == .pending && stored.listed == false)
        #expect(PublishReviewState(record: stored).isUnlistedUntilApproved)
        let issue = try #require(shared.requests.last)
        let signed = WorkflowShareService.reviewWatchMessage(
            address: issue.value(forHTTPHeaderField: "X-Agent-Address") ?? "",
            nonce: String(repeating: "a", count: 64), timestamp: 1_800_000_000)
        #expect(signed.hasPrefix("osaurus-review-watch:0x"))
        #expect(issue.value(forHTTPHeaderField: "X-Signature")?.hasPrefix("0x") == true)
    }

    @Test
    func nothingToReview_noToken() async throws {
        let shared = try await share(review: nil)
        #expect(shared.requests.map(\.url?.path) == ["/auth/challenge", "/workflows"])
        #expect(shared.token == nil)
    }
}

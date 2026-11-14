//
//  SupportLiveRouterTests.swift
//  osaurusTests
//
//  Help end to end against a REAL osaurus-router: the app's own API client,
//  `SupportService` and `SupportReportBuilder` on one side, the router's
//  admin API (what the admin console calls) on the other. Gated because it
//  needs a router to talk to and writes rows into its database, so point it
//  at a local or staging router, never production.
//
//  It proves what the unit suites cannot: that the two repositories agree on
//  the signed paths, the empty-body `/read` call, the JSON shapes in both
//  directions, and the unread / reopen / open-limit rules.
//
//  Run with a router whose `ADMIN_WALLETS` contains the admin key's address:
//    OSAURUS_SUPPORT_LIVE_ROUTER_URL=http://127.0.0.1:8791 \
//    OSAURUS_SUPPORT_LIVE_ADMIN_KEY=<64 hex chars> \
//    OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
//    OSAURUS_TEST_ROOT=/tmp/osaurus-test \
//    OSU_MODELS_DIR=/tmp/osaurus-test-models \
//    swift test --package-path Packages/OsaurusCore --filter SupportLiveRouterTests
//
//  When the router sets ADMIN_EMAILS, also set OSAURUS_SUPPORT_LIVE_ADMIN_EMAIL
//  to an allowlisted address; staff writes are refused without one.
//
//  Optional: OSAURUS_SUPPORT_LIVE_REDEEM_CODE, a first-time redeem code on
//  that router, to prove a report does not use up the account's first action.
//
//  The user is a fresh random wallet on every run, signed with the same
//  `OsaurusRouterAuthSigner.signHeaders` the app uses; only the Keychain read
//  is replaced.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Where the live suite points. Kept outside the suite so the `@Suite`
/// condition does not refer to the type it is attached to.
private enum SupportLiveRouter {
    static let env = ProcessInfo.processInfo.environment

    static var baseURL: URL? {
        env["OSAURUS_SUPPORT_LIVE_ROUTER_URL"].flatMap(URL.init(string:))
    }

    static var adminKey: Data? {
        env["OSAURUS_SUPPORT_LIVE_ADMIN_KEY"]
            .flatMap { Data(hexEncoded: $0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0) }
            .flatMap { $0.count == 32 ? $0 : nil }
    }

    static var adminEmail: String {
        env["OSAURUS_SUPPORT_LIVE_ADMIN_EMAIL"].flatMap { $0.isEmpty ? nil : $0 } ?? "live-test@osaurus.ai"
    }

    static var isConfigured: Bool { baseURL != nil && adminKey != nil }
}

@Suite("Help live router", .enabled(if: SupportLiveRouter.isConfigured), .serialized)
@MainActor
struct SupportLiveRouterTests {
    // MARK: - Signing

    private nonisolated static func sign(_ request: inout URLRequest, body: Data?, key: Data) throws {
        let url = try #require(request.url)
        let headers = try OsaurusRouterAuthSigner.signHeaders(
            method: request.httpMethod ?? "GET",
            pathAndQuery: OsaurusRouterAuthSigner.pathAndQuery(for: url),
            body: body ?? request.httpBody ?? Data(),
            timestamp: Int(Date().timeIntervalSince1970),
            privateKey: key
        )
        for (name, value) in headers.values {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private nonisolated static func randomKey() -> Data {
        Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
    }

    /// The app's client, signing as `key` instead of the Keychain identity.
    private func userClient(key: Data) throws -> OsaurusRouterAPIClient {
        OsaurusRouterAPIClient(
            baseURL: try #require(SupportLiveRouter.baseURL),
            session: URLSession(configuration: .ephemeral),
            authOverride: { request, body in try Self.sign(&request, body: body, key: key) }
        )
    }

    /// The service the Help page uses, on top of that client.
    private func service(client: OsaurusRouterAPIClient, defaults: UserDefaults) -> SupportService {
        SupportService(
            defaults: defaults,
            api: .init(
                list: { try await client.supportThreads() },
                create: { try await client.createSupportThread($0) },
                detail: { try await client.supportThread(id: $0) },
                reply: { try await client.replyToSupportThread(id: $0, body: $1) },
                markRead: { try await client.markSupportThreadRead(id: $0) }
            ),
            isRouterEnabled: { true },
            hasIdentity: { true }
        )
    }

    // MARK: - Admin side (what the admin console sends)

    private func admin(_ method: String, _ path: String, body: [String: JSONValue]? = nil) async throws
        -> (status: Int, json: [String: JSONValue])
    {
        let base = try #require(SupportLiveRouter.baseURL)
        let key = try #require(SupportLiveRouter.adminKey)
        var request = URLRequest(url: try #require(URL(string: path, relativeTo: base)?.absoluteURL))
        request.httpMethod = method
        var data: Data?
        if let body {
            var fields = body
            fields["admin_email"] = .string(SupportLiveRouter.adminEmail)
            fields["admin_name"] = .string("Live Test Operator")
            data = try JSONEncoder.osaurusCanonical().encode(JSONValue.object(fields))
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try Self.sign(&request, body: data, key: key)
        let (payload, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: payload) else {
            return (status, [:])
        }
        return (status, fields)
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let fields)? = value { return fields }
        return [:]
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items)? = value { return items }
        return []
    }

    private func report() -> SupportReport {
        let bundle = SupportDiagnosticsBundleBuilder.make(
            generatedAt: Date(),
            app: .init(name: "Osaurus", version: "9.9.9", build: "999", osVersion: "Version 26.5 (Build 25F71)"),
            sessionId: "live-session-raw-id",
            agentName: "Research",
            modelId: "provider/model",
            registeredTools: [SupportDiagnosticsToolInput(name: "web_search", enabled: true)],
            logs: [
                RequestLog(
                    source: .chatUI, method: "POST", path: "/v1/chat/completions", statusCode: 500,
                    durationMs: 250, requestBody: "PRIVATE PROMPT do-not-store", model: "provider/model",
                    errorMessage: "PRIVATE ERROR do-not-store")
            ]
        )
        return SupportReportBuilder.make(
            bundle: bundle, profile: MacProfile(modelName: "MacBook Air", chip: "M4", memoryGB: 24))
    }

    // MARK: - Scenario

    @Test func reportReplyReadAnswerCloseReopenAndOpenLimit() async throws {
        let suite = "support-live-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let userKey = Self.randomKey()
        let wallet = try OsaurusRouterAuthSigner.evmAddress(privateKey: userKey).lowercased()
        let client = try userClient(key: userKey)
        let support = service(client: client, defaults: defaults)
        let marker = "live-\(UUID().uuidString.prefix(8))"

        // A wallet the router has never seen: nothing to show, nothing open.
        await support.refreshIfDue(trigger: .helpOpened)
        #expect(support.refreshError == nil)
        #expect(support.hasLoaded)
        #expect(support.threads.isEmpty)
        #expect(!support.hasOpenThreads)

        // 1. The user sends a report.
        let sent = report()
        let description = "Chat freezes when I attach a PDF (\(marker)).\nSecond line with more detail."
        let created = try await support.submit(description: description, report: sent)
        #expect(created.status == .open)
        #expect(created.subject == "Chat freezes when I attach a PDF (\(marker)).")
        #expect(created.messages?.map(\.body) == [description])
        #expect(created.messages?.first?.isFromUser == true)
        #expect(support.hasOpenThreads)
        #expect(support.openThreadCount == 1)

        // 2. Staff see it in the queue with what the app attached, and nothing more.
        let queue = try await admin("GET", "/admin/support/threads?status=open&wallet=\(wallet)")
        #expect(queue.status == 200)
        let row = object(array(queue.json["data"]).first)
        #expect(row["id"] == .string(created.id))
        #expect(row["wallet_address"] == .string(wallet))
        #expect(row["app_version"] == .string("9.9.9"))
        #expect(row["app_build"] == .string("999"))
        #expect(row["os_version"] == .string("Version 26.5 (Build 25F71)"))
        #expect(
            row["hardware"]
                == .object(["model": .string("MacBook Air"), "chip": .string("M4"), "memory_gb": .number(24)]))

        let adminDetail = try await admin("GET", "/admin/support/threads/\(created.id)")
        #expect(adminDetail.status == 200)
        // The diagnostics the router stored are the value the user previewed.
        #expect(adminDetail.json["diagnostics"] == sent.diagnostics)
        let stored = String(decoding: try JSONEncoder.osaurusCanonical().encode(JSONValue.object(adminDetail.json)), as: UTF8.self)
        #expect(!stored.contains("do-not-store"))
        #expect(!stored.contains("live-session-raw-id"))
        #expect(stored.contains("web_search"))

        // 3. Staff reply. The app learns about it on its next refresh.
        let replied = try await admin(
            "POST", "/admin/support/threads/\(created.id)/messages",
            body: ["body": .string("Thanks. Which PDF viewer exported it?")])
        #expect(replied.status == 201 || replied.status == 200)

        await support.refreshIfDue(trigger: .helpOpened)
        #expect(support.unreadCount == 1)
        #expect(support.threads.first?.status == .answered)
        #expect(support.threads.first?.unread == true)

        // 4. Opening the thread shows the reply, with nothing about who wrote it.
        let conversation = try await support.loadConversation(id: created.id)
        #expect(conversation.messages?.map(\.author) == ["user", "staff"])
        #expect(conversation.messages?.last?.body == "Thanks. Which PDF viewer exported it?")
        // Fetching alone does not clear unread; the explicit call does.
        #expect(support.unreadCount == 1)
        await support.markRead(threadId: created.id)
        #expect(support.unreadCount == 0)
        await support.refreshIfDue(trigger: .helpOpened)
        #expect(support.unreadCount == 0, "the router did not accept the app's empty-body /read call")
        #expect(support.threads.first?.status == .answered)

        // 5. The user answers: back in the team's queue.
        let answered = try await support.reply(threadId: created.id, body: "It was exported from Preview.")
        #expect(answered.status == .open)
        #expect(answered.messages?.map(\.author) == ["user", "staff", "user"])

        // 6. Staff close it: no open report left, so background checks stop.
        let closed = try await admin(
            "POST", "/admin/support/threads/\(created.id)/status",
            body: ["status": .string("closed"), "reason": .string("resolved in live test")])
        #expect(closed.status == 200)
        await support.refreshIfDue(trigger: .helpOpened)
        #expect(support.threads.first?.status == .closed)
        #expect(!support.hasOpenThreads)
        #expect(!support.isFetchDue(trigger: .launch))

        // 7. Writing on a closed report reopens it.
        let reopened = try await support.reply(threadId: created.id, body: "It happened again today.")
        #expect(reopened.status == .open)
        #expect(support.hasOpenThreads)

        // 8. The open-report limit: three open, the fourth is refused with
        //    the sentence the page shows.
        _ = try await support.submit(description: "Second problem for the limit check (\(marker)).", report: sent)
        _ = try await support.submit(description: "Third problem for the limit check (\(marker)).", report: sent)
        #expect(support.openThreadCount == OsaurusRouterSupportLimits.maxOpenThreads)
        do {
            _ = try await support.submit(
                description: "Fourth problem for the limit check (\(marker)).", report: sent)
            Issue.record("the router accepted a fourth open report")
        } catch {
            #expect(
                SupportService.userMessage(for: error)
                    == L("You already have 3 open reports. Add to one of them, or wait until one is closed."))
        }
        await support.refreshIfDue(trigger: .helpOpened)
        #expect(support.threads.count == 3)

        // 9. A report is not the account's first action: a first-time code
        //    still redeems afterwards.
        if let code = SupportLiveRouter.env["OSAURUS_SUPPORT_LIVE_REDEEM_CODE"], !code.isEmpty {
            let redeemed = try await client.redeemCode(code)
            #expect(redeemed.redeemed)
            #expect(redeemed.campaignKind == "first_time")
        }
    }

    /// Another wallet cannot see, answer or mark someone else's report.
    @Test func anotherWalletCannotReachTheReport() async throws {
        let owner = try userClient(key: Self.randomKey())
        let stranger = try userClient(key: Self.randomKey())
        let thread = try await owner.createSupportThread(
            report().body(description: "Private report for the isolation check."))

        await #expect(throws: OsaurusRouterAPIError.self) { _ = try await stranger.supportThread(id: thread.id) }
        await #expect(throws: OsaurusRouterAPIError.self) {
            _ = try await stranger.replyToSupportThread(id: thread.id, body: "Let me in")
        }
        await #expect(throws: OsaurusRouterAPIError.self) {
            _ = try await stranger.markSupportThreadRead(id: thread.id)
        }
        let listed = try await stranger.supportThreads()
        #expect(listed.data.isEmpty)
    }

    /// The router refuses a report without consent, whatever else it carries.
    @Test func consentIsEnforcedByTheRouter() async throws {
        let client = try userClient(key: Self.randomKey())
        let sent = report()
        let withoutConsent = OsaurusRouterSupportReportBody(
            description: "This report was never agreed to.", consent: false,
            app: sent.app, hardware: sent.hardware, diagnostics: sent.diagnostics)

        await #expect(throws: OsaurusRouterAPIError.self) {
            _ = try await client.createSupportThread(withoutConsent)
        }
        let listed = try await client.supportThreads()
        #expect(listed.data.isEmpty)
    }
}

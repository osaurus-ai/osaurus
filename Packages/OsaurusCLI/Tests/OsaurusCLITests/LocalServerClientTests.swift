import Foundation
import XCTest

@testable import OsaurusCLICore

/// Answers requests from a closure instead of the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Collects what the client writes to stderr.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

final class LocalServerClientTests: XCTestCase {
    private var directory: URL!
    private var store: CLITokenStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-cli-token-\(UUID().uuidString)", isDirectory: true)
        store = CLITokenStore(fileURL: directory.appendingPathComponent("cli/access-token"))
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(
        accessKey: AccessKeyCredential? = nil,
        interactive: Bool,
        noticeDelay: Duration = .milliseconds(500),
        log: LogLines = LogLines()
    ) -> LocalServerClient {
        LocalServerClient(
            port: 1337,
            accessKey: accessKey,
            commandLabel: "list",
            tokenStore: store,
            interactive: interactive,
            session: StubURLProtocol.session(),
            approvalNoticeDelay: noticeDelay,
            log: { log.append($0) }
        )
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Token store

    func testTokenIsStoredOwnerOnly() throws {
        try store.save("osc_abc")
        XCTAssertEqual(store.load(), "osc_abc")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let parent = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual((parent[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        try store.save("osc_def")
        XCTAssertEqual(store.load(), "osc_def")
        store.clear()
        XCTAssertNil(store.load())
    }

    func testStoreIgnoresSomethingThatIsNotAToken() throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("osk-not-a-cli-token".utf8).write(to: store.fileURL)
        XCTAssertNil(store.load())
    }

    // MARK: - Credentials

    func testSendsKeyAndStoredToken() throws {
        try store.save("osc_saved")
        let client = client(accessKey: AccessKeyCredential(token: "osk-v1.key", source: "--access-key"), interactive: false)
        var request = client.request("/models")
        client.authorize(&request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer osk-v1.key")
        XCTAssertEqual(request.value(forHTTPHeaderField: LocalServerClient.tokenHeaderName), "osc_saved")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1337/models")
    }

    func testSendsNothingWithoutCredentials() {
        let client = client(interactive: false)
        var request = client.request("/models")
        client.authorize(&request)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: LocalServerClient.tokenHeaderName))
    }

    // MARK: - 401 recovery

    func testInteractiveCallerIsApprovedOnceAndRetried() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/cli/access" {
                return (200, self.json(["ok": true, "token": "osc_new"]))
            }
            let token = request.value(forHTTPHeaderField: LocalServerClient.tokenHeaderName)
            return token == "osc_new" ? (200, Data(#"{"data":[]}"#.utf8)) : (401, Data())
        }
        let client = client(interactive: true)
        let (_, response) = try await client.data(for: client.request("/models"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(store.load(), "osc_new")
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url!.path }, ["/models", "/cli/access", "/models"])

        let accessRequest = StubURLProtocol.requests[1]
        XCTAssertEqual(accessRequest.httpMethod, "POST")
        XCTAssertNil(accessRequest.value(forHTTPHeaderField: LocalServerClient.tokenHeaderName))
    }

    func testStaleTokenIsDroppedWithoutPromptingWhenNotInteractive() async throws {
        try store.save("osc_revoked")
        StubURLProtocol.handler = { _ in (401, Data()) }
        let client = client(interactive: false)
        let (_, response) = try await client.data(for: client.request("/models"))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertNil(store.load())
        XCTAssertFalse(client.hasToken)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url!.path }, ["/models"])
        XCTAssertTrue(client.unauthorizedHint.contains("click Allow"))
    }

    func testExplicitKeyIsNeverReplacedByAPrompt() async throws {
        StubURLProtocol.handler = { _ in (401, Data()) }
        let client = client(accessKey: AccessKeyCredential(token: "osk-v1.bad", source: "OSAURUS_API_KEY"), interactive: true)
        let (_, response) = try await client.data(for: client.request("/models"))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(client.unauthorizedHint, "The access key from OSAURUS_API_KEY was rejected.")
    }

    func testDeniedApprovalIsNotRetried() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/cli/access" {
                return (403, self.json(["ok": false, "message": "Osaurus did not allow the command-line tool."]))
            }
            return (401, Data())
        }
        let client = client(interactive: true)
        let (_, response) = try await client.data(for: client.request("/models"))
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertNil(store.load())
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url!.path }, ["/models", "/cli/access"])
    }

    func testOlderAppWithoutApprovalPointsAtTheKey() async {
        StubURLProtocol.handler = { _ in (404, Data()) }
        let result = await client(interactive: true).requestApproval()
        guard case .refused(let message) = result else { return XCTFail("expected refusal") }
        XCTAssertTrue(message.contains("--access-key"), message)
    }

    func testApprovalWithoutATokenIsRefused() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"ok":true}"#.utf8)) }
        let result = await client(interactive: true).requestApproval()
        XCTAssertEqual(result, .refused("Osaurus did not return an approval token."))
        XCTAssertNil(store.load())
    }

    func testRequireTokenAsksOnlyWhenNeeded() async throws {
        try store.save("osc_saved")
        let saved = await client(interactive: true).requireToken()
        XCTAssertTrue(saved)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)

        store.clear()
        let unattended = await client(accessKey: AccessKeyCredential(token: "osk-v1.k", source: "--access-key"), interactive: false)
            .requireToken()
        XCTAssertFalse(unattended, "a key is not a token, and nobody can answer")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)

        StubURLProtocol.handler = { _ in (200, self.json(["ok": true, "token": "osc_fresh"])) }
        let asked = await client(interactive: true).requireToken()
        XCTAssertTrue(asked)
        XCTAssertEqual(store.load(), "osc_fresh")
    }

    func testCooldownIsNotPrecededByClickAllow() async {
        StubURLProtocol.handler = { _ in
            (429, self.json(["ok": false, "message": "Access was just denied. Try again in 30 seconds."]))
        }
        let log = LogLines()
        let approved = await client(interactive: true, noticeDelay: .seconds(5), log: log).requireToken()
        XCTAssertFalse(approved)
        XCTAssertEqual(log.lines, ["Access was just denied. Try again in 30 seconds."])
    }

    func testAPromptLeftOpenTellsTheOwnerToClickAllow() async {
        StubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return (200, self.json(["ok": true, "token": "osc_slow"]))
        }
        let log = LogLines()
        let approved = await client(interactive: true, noticeDelay: .milliseconds(50), log: log).requireToken()
        XCTAssertTrue(approved)
        XCTAssertEqual(
            log.lines,
            ["Osaurus needs to approve this command-line tool. Click Allow in Osaurus on this Mac…", "Approved."]
        )
    }

    func testHeaderNameMatchesTheServer() {
        // CLIAccessStore.headerName / tokenPrefix in OsaurusCore.
        XCTAssertEqual(LocalServerClient.tokenHeaderName, "X-Osaurus-CLI-Token")
        XCTAssertEqual(LocalServerClient.tokenPrefix, "osc_")
    }
}

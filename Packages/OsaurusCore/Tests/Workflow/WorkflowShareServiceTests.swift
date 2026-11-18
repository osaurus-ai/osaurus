//
//  WorkflowShareServiceTests.swift
//  OsaurusCoreTests
//
//  Publishing to the store registry: the uploaded file hashes the way
//  the registry recomputes it (pinned against the registry's own
//  fixtures), request messages and headers match the contract, registry
//  links are the only links accepted, errors map to what the user is
//  told, visibility rides on publish and PUT /visibility, the background
//  stats read never touches the identity key while the dashboard's
//  owner read does, taking down keeps the record, and the install
//  receipt is signed, quiet, and skipped without an Osaurus ID.
//

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import OsaurusCore

// MARK: - Registry canonical hash (port of the registry's swift_canonical_hash.swift)

private enum RawJSON: Codable {
    case string(String), number(Double), bool(Bool), object([String: RawJSON]), array([RawJSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([RawJSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: RawJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// The content hash the registry recomputes from the raw file: the tree
/// with `content_hash` set to "" and `author.signature` removed, sorted
/// keys, compact, slashes unescaped.
private func registryCanonicalHash(_ data: Data) throws -> String {
    guard case .object(var root) = try JSONDecoder().decode(RawJSON.self, from: data) else {
        throw TemplateError.empty
    }
    root["content_hash"] = .string("")
    if case .object(var author)? = root["author"] {
        author["signature"] = nil
        root["author"] = .object(author)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonical = try encoder.encode(RawJSON.object(root))
    return "sha256:" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
}

private enum RegistryFixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("RegistryFixtures", isDirectory: true)
    }

    static func expectedHashes() throws -> [String: String] {
        try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: directory.appendingPathComponent("expected_hashes.json")))
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

// MARK: - Pure contract

struct WorkflowRegistryContractTests {
    @Test
    func theCanonicalHashPortReproducesTheRegistrysFixtureHashes() throws {
        let expected = try RegistryFixtures.expectedHashes()
        #expect(expected.count == 6)
        for (name, hash) in expected {
            #expect(try registryCanonicalHash(RegistryFixtures.data(name)) == hash, "\(name)")
        }
    }

    @Test
    func aSharedFileHashesTheWayTheRegistryRecomputesIt() throws {
        let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey)
        for name in try RegistryFixtures.expectedHashes().keys.sorted() {
            let template = try Template.parse(String(decoding: try RegistryFixtures.data(name), as: UTF8.self))
            let signed = try TemplateSigner.signed(
                TemplateExportSanitizer.sanitized(template), privateKey: TestKeys.alicePrivateKey, authorName: nil)
            let body = try TemplateFileExport.exportData(signed)

            #expect(try registryCanonicalHash(body) == signed.contentHash, "\(name)")
            let reread = try Template.parse(String(decoding: body, as: UTF8.self))
            #expect(reread.contentHash == signed.contentHash, "\(name)")
            #expect(
                TemplateSigner.status(of: reread, knownAgent: { _ in nil })
                    == .signed(address: alice, knownAgentID: nil), "\(name)")
        }
    }

    @Test
    func requestMessagesFollowTheContract() {
        #expect(
            WorkflowShareService.publishMessage(address: "0xabc", bodyHash: "ff", nonce: "n1", timestamp: 1700)
                == "osaurus-workflow:0xabc:ff:n1:1700")
        #expect(
            WorkflowShareService.deleteMessage(address: "0xabc", registryID: "id-1", nonce: "n2", timestamp: 1701)
                == "osaurus-workflow-delete:0xabc:id-1:n2:1701")
        #expect(
            WorkflowShareService.installMessage(
                address: "0xabc", registryID: "id-1", version: 3, nonce: "n3", timestamp: 1702)
                == "osaurus-workflow-install:0xabc:id-1:3:n3:1702")
        #expect(
            WorkflowShareService.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func visibilityAndOwnerReadMessagesFollowTheContract() throws {
        #expect(
            WorkflowShareService.visibilityMessage(
                address: "0xabc", registryID: "id-1", bodyHash: "ff", nonce: "n4", timestamp: 1703)
                == "osaurus-workflow-visibility:0xabc:id-1:ff:n4:1703")
        #expect(
            WorkflowShareService.readMessage(address: "0xabc", registryID: "id-1", nonce: "n5", timestamp: 1704)
                == "osaurus-workflow-read:0xabc:id-1:n5:1704")
        #expect(
            WorkflowShareService.listMessage(address: "0xabc", nonce: "n6", timestamp: 1705)
                == "osaurus-workflow-list:0xabc:n6:1705")

        // The PUT body is sorted and compact so its hash is reproducible.
        #expect(
            String(decoding: try WorkflowsRegistryAPIClient.visibilityBody(.password, password: "hunter22"), as: UTF8.self)
                == #"{"password":"hunter22","visibility":"password"}"#)
        #expect(
            String(decoding: try WorkflowsRegistryAPIClient.visibilityBody(.hidden, password: "ignored"), as: UTF8.self)
                == #"{"visibility":"hidden"}"#, "a password only travels with .password")
        #expect(
            String(decoding: try WorkflowsRegistryAPIClient.visibilityBody(.public, password: nil), as: UTF8.self)
                == #"{"visibility":"public"}"#)
    }

    @Test
    func visibilityVocabularyAndPasswordRulesMatchTheRegistry() {
        #expect(WorkflowVisibility.allCases.map(\.rawValue) == ["public", "hidden", "password", "workspace"])
        #expect(WorkflowVisibility.maxWorkspaces == 20, "the registry's MAX_SHARED_WORKSPACES")
        #expect(WorkflowVisibility.hidden.title == "Unlisted", "the registry says hidden; people read Unlisted")
        #expect(WorkflowVisibility.passwordLength == 6...128)
        #expect(!WorkflowVisibility.isValidPassword("12345"))
        #expect(WorkflowVisibility.isValidPassword("123456"))
        #expect(WorkflowVisibility.isValidPassword(String(repeating: "x", count: 128)))
        #expect(!WorkflowVisibility.isValidPassword(String(repeating: "x", count: 129)))
        #expect(WorkflowVisibility.isValidPassword("      "), "length is the registry's only rule; the app matches it")
    }

    @Test
    func installLinksMayCarryOneAccessToken() {
        let prod = WorkflowsRegistryAPIClient.productionBaseURL
        let id = "e2f1832f-93d5-4456-a9ca-ae02348ddde1"
        let base = "https://api.store.osaurus.ai/workflows/\(id)/versions/2/template.json"
        func accepted(_ query: String) -> Bool {
            WorkflowsRegistryAPIClient.isRegistryTemplateURL(URL(string: base + query)!, registry: prod)
        }
        #expect(accepted(""))
        #expect(accepted("?access=tok_abc123"), "a password-protected page's install link")
        #expect(!accepted("?access="), "an empty token is no token")
        #expect(!accepted("?access=a&access=b"))
        #expect(!accepted("?access=a&download=1"))
        #expect(!accepted("?token=a"))
        #expect(
            WorkflowsRegistryAPIClient.registryWorkflowID(from: URL(string: base + "?access=tok")!, registry: prod)
                == UUID(uuidString: id))
    }

    @Test
    func aRecordWrittenBeforeVisibilityExistedStillLoads() throws {
        let json = """
            {"template_id":"E2F1832F-93D5-4456-A9CA-AE02348DDDE1","registry_id":"r-1","slug":"intake","version":2,\
            "content_hash":"sha256:00","url":"https://web.test/w/intake",\
            "raw_url":"https://registry.test/workflows/r-1/versions/2/template.json",\
            "deep_link":"osaurus://templates-import?url=x","address":"0xabc","registry":"https://registry.test",\
            "shared_at":"2026-01-02T03:04:05Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WorkflowRegistryRecord.self, from: Data(json.utf8))
        #expect(record.visibility == .public)
        #expect(record.installCount == nil)
        #expect(record.registryLatestVersion == nil)
        #expect(record.authorHandle == nil)
        #expect(record.takenDown == false && record.removedByAdmin == false)
        #expect(record.isLive)
        #expect(record.kind == .workflow, "records from before agent publishing were all workflows")

        // And a round trip keeps the new fields.
        var edited = record
        edited.visibility = .password
        edited.installCount = 14
        edited.takenDown = true
        edited.kind = .agent
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reread = try decoder.decode(WorkflowRegistryRecord.self, from: try encoder.encode(edited))
        #expect(reread == edited)
        #expect(!reread.isLive)
    }

    @Test
    func theRegistrysDetailDecodesWithAndWithoutTheOwnerOnlyFields() throws {
        let publicJSON = """
            {"id":"r-1","slug":"intake","name":"Client Intake","summary":"Sorts leads.",\
            "template_id":"e2f1832f-93d5-4456-a9ca-ae02348ddde1",\
            "author":{"address":"0xabcdef0123456789abcdef0123456789abcdef01","osaurus_id":"alice","display_name":"Alice"},\
            "visibility":"public","latest_version":3,"install_count":14,\
            "created_at":"2026-01-02T03:04:05.123Z","updated_at":"2026-02-03T04:05:06Z",\
            "url":"https://web.test/w/intake",\
            "versions":[{"version":3,"changelog":"Faster","created_at":"2026-02-03T04:05:06Z"},\
            {"version":2,"changelog":"","created_at":"2026-01-10T00:00:00Z"}]}
            """
        let detail = try WorkflowsRegistryAPIClient.decode(WorkflowsRegistryDetail.self, from: Data(publicJSON.utf8))
        #expect(detail.templateID == UUID(uuidString: "e2f1832f-93d5-4456-a9ca-ae02348ddde1"))
        #expect(detail.author.handle == "@alice")
        #expect(detail.visibility == .public && detail.status == "active" && !detail.isRemoved)
        #expect(detail.latestVersion == 3 && detail.installCount == 14)
        #expect(abs(detail.createdAt.timeIntervalSince1970 - 1_767_323_045.123) < 0.001, "fractional seconds")
        #expect(detail.updatedAt == Date(timeIntervalSince1970: 1_770_091_506), "and without")
        #expect(detail.versions.map(\.version) == [3, 2])
        #expect(detail.rawURL == nil && detail.deepLink == nil)
        #expect(detail.kind == .workflow, "a registry without the kind column only had workflows")

        let ownerJSON = """
            {"id":"r-2","slug":"old","name":"Old","kind":"agent","template_id":"E2F1832F-93D5-4456-A9CA-AE02348DDDE2",\
            "author":{"address":"0xabcdef0123456789abcdef0123456789abcdef01"},\
            "visibility":"password","status":"removed","removal":{"by":"admin","reason":"spam","at":"2026-03-01T00:00:00Z"},\
            "latest_version":1,"created_at":"2026-01-02T03:04:05Z","updated_at":"2026-03-01T00:00:00Z",\
            "url":"https://web.test/w/old","raw_url":"https://registry.test/workflows/r-2/versions/1/template.json",\
            "deep_link":"osaurus://templates-import?url=x"}
            """
        let owner = try WorkflowsRegistryAPIClient.decode(WorkflowsRegistryDetail.self, from: Data(ownerJSON.utf8))
        #expect(owner.author.handle == "0xabcd…ef01", "no claimed id: the short address")
        #expect(owner.summary == "" && owner.installCount == 0 && owner.versions.isEmpty)
        #expect(owner.isRemoved && owner.removedByAdmin && owner.removal?.reason == "spam")
        #expect(owner.rawURL != nil && owner.deepLink != nil)
        #expect(owner.kind == .agent)

        var record = WorkflowRegistryRecord(
            templateID: owner.templateID, registryID: "r-2", slug: "x", version: 1, contentHash: "", url: owner.url,
            rawURL: owner.rawURL!, deepLink: owner.deepLink!, address: "0xabc", registry: "r", sharedAt: .distantPast)
        record.apply(owner, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(record.removedByAdmin && !record.takenDown && !record.isLive)
        #expect(record.visibility == .password && record.slug == "old" && record.authorHandle == "0xabcd…ef01")
        #expect(record.statsFetchedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(record.kind == .agent, "the registry's kind wins")
    }

    @Test
    func onlyVersionedTemplateFilesOnTheRegistryAreAccepted() {
        let prod = WorkflowsRegistryAPIClient.productionBaseURL
        let staging = WorkflowsRegistryAPIClient.stagingBaseURL
        let id = "e2f1832f-93d5-4456-a9ca-ae02348ddde1"
        func url(_ s: String) -> URL { URL(string: s)! }

        let good = url("https://api.store.osaurus.ai/workflows/\(id)/versions/2/template.json")
        #expect(WorkflowsRegistryAPIClient.isRegistryTemplateURL(good, registry: prod))
        #expect(WorkflowsRegistryAPIClient.registryWorkflowID(from: good, registry: prod) == UUID(uuidString: id))
        let source = RegistryImportSource(templateURL: good, registry: prod)
        #expect(source == RegistryImportSource(workflowID: UUID(uuidString: id)!, version: 2, origin: prod))
        #expect(!WorkflowsRegistryAPIClient.isRegistryTemplateURL(good, registry: staging), "another registry's host")
        #expect(
            WorkflowsRegistryAPIClient.isRegistryTemplateURL(
                url("https://osaurus-registry.fly.dev/workflows/\(id)/versions/1/template.json"), registry: staging))

        let rejected = [
            "http://api.store.osaurus.ai/workflows/\(id)/versions/2/template.json",
            "https://example.com/workflows/\(id)/versions/2/template.json",
            "https://api.store.osaurus.ai.evil.com/workflows/\(id)/versions/2/template.json",
            "https://api.store.osaurus.ai:8443/workflows/\(id)/versions/2/template.json",
            "https://user@api.store.osaurus.ai/workflows/\(id)/versions/2/template.json",
            "https://api.store.osaurus.ai/workflows/\(id)/template.json",
            "https://api.store.osaurus.ai/workflows/social-post-writer/versions/2/template.json",
            "https://api.store.osaurus.ai/workflows/\(id)/versions/0/template.json",
            "https://api.store.osaurus.ai/workflows/\(id)/versions/2/template.json?download=1",
            "https://api.store.osaurus.ai/workflows/\(id)/versions/2/template.json/../../x",
            "https://api.store.osaurus.ai/users/0xabc/workflows",
            "file:///workflows/\(id)/versions/2/template.json",
        ]
        for raw in rejected {
            #expect(!WorkflowsRegistryAPIClient.isRegistryTemplateURL(url(raw), registry: prod), "\(raw)")
        }

        let local = url("http://localhost:8787")
        #expect(
            WorkflowsRegistryAPIClient.isRegistryTemplateURL(
                url("http://localhost:8787/workflows/\(id)/versions/1/template.json"), registry: local),
            "plain http only for a loopback development registry")
        #expect(
            !WorkflowsRegistryAPIClient.isRegistryTemplateURL(
                url("http://10.0.0.5/workflows/\(id)/versions/1/template.json"), registry: url("http://10.0.0.5")))
    }

    @Test
    func registryReadsNeverComeFromACache() {
        // Public reads carry `Cache-Control: public, max-age=30`; the app
        // reads right after it writes, and the signed owner read shares its
        // URL with the public one.
        let session = WorkflowsRegistryAPIClient.makeSession()
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func releaseBuildsDefaultToProduction() {
        #if !DEBUG
            #expect(WorkflowsRegistryAPIClient.defaultBaseURL == WorkflowsRegistryAPIClient.productionBaseURL)
        #endif
        #expect(WorkflowsRegistryAPIClient.productionBaseURL.absoluteString == "https://api.store.osaurus.ai")
        #expect(WorkflowsRegistryAPIClient.stagingBaseURL.absoluteString == "https://osaurus-registry.fly.dev")
    }

    @Test
    func errorCodesMapToWhatTheUserIsTold() {
        func map(_ code: String, latest: Int? = nil) -> WorkflowsRegistryAPIError {
            .from(code: code, message: nil, status: 400, latestVersion: latest, issues: [])
        }
        #expect(map("address_banned") == .addressBanned)
        #expect(map("address_banned").errorDescription == "This Osaurus ID can't publish workflows.")
        #expect(map("workflow_removed_by_admin") == .workflowRemovedByAdmin)
        #expect(map("quota_exceeded") == .quotaExceeded)
        #expect(map("version_not_newer", latest: 3) == .versionNotNewer(latest: 3))
        #expect(map("concurrent_publish_retry") == .concurrentPublish)
        #expect(map("invalid_nonce") == .invalidNonce)
        #expect(map("timestamp_out_of_window").errorDescription == "Check your Mac's clock and try again.")
        #expect(map("rate_limited").errorDescription == "Too many shares in a row. Try again in a few minutes.")
        #expect(map("signature_verification_failed") == .authRejected(code: "signature_verification_failed"))
        for code in ["invalid_template", "content_hash_mismatch", "author_signature_invalid"] {
            #expect(map(code) == .templateRejected(code: code, issues: []))
            #expect(map(code).errorDescription == "Osaurus couldn't prepare this workflow for sharing.")
        }
        #expect(map("something_new") == .server(code: "something_new", message: nil, status: 400))

        #expect(WorkflowShareError(.versionNotNewer(latest: 4)).isVersionNotNewer(4))
        #expect(!WorkflowShareError(.versionNotNewer(latest: nil)).isVersionNotNewer(4))
    }

    @Test
    func importsFromFilesCarryNoRegistrySource() {
        let pending = PendingTemplateImport(text: "{}", kind: .workflow)
        #expect(pending.registryWorkflowID == nil)
        let id = UUID()
        let linked = PendingTemplateImport(
            text: "{}", kind: .workflow,
            registry: RegistryImportSource(
                workflowID: id, version: 1, origin: WorkflowsRegistryAPIClient.stagingBaseURL))
        #expect(linked.registryWorkflowID == id)
    }
}

extension WorkflowShareError {
    fileprivate func isVersionNotNewer(_ latest: Int) -> Bool {
        if case .versionNotNewer(let v) = self { return v == latest }
        return false
    }
}

// MARK: - HTTP stub

private final class RegistryStub: @unchecked Sendable {
    struct Call {
        let request: URLRequest
        let body: Data?
    }

    static let shared = RegistryStub()
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest, Data?) throws -> (Int, String))?
    private var recorded: [Call] = []

    func reset(_ handler: @escaping @Sendable (URLRequest, Data?) throws -> (Int, String)) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    var calls: [Call] { lock.withLock { recorded } }

    func respond(_ request: URLRequest, body: Data?) throws -> (Int, String) {
        let handler = lock.withLock { () -> (@Sendable (URLRequest, Data?) throws -> (Int, String))? in
            recorded.append(Call(request: request, body: body))
            return self.handler
        }
        guard let handler else { throw URLError(.badServerResponse) }
        return try handler(request, body)
    }
}

private final class RegistryStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        do {
            let (status, json) = try RegistryStub.shared.respond(request, body: body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - Service and client over HTTP

@Suite(.serialized)
@MainActor
struct WorkflowShareServiceHTTPTests {
    nonisolated private static let base = URL(string: "https://registry.test")!
    nonisolated private static let registryID = "c8b28fcf-d167-4121-b1ac-a1a9368603d5"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func client() -> WorkflowsRegistryAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistryStubProtocol.self]
        return WorkflowsRegistryAPIClient(baseURL: base, session: URLSession(configuration: config))
    }

    nonisolated private static func publishedJSON(version: Int, created: Bool, kind: String? = nil) -> String {
        let raw = "https://registry.test/workflows/\(registryID)/versions/\(version)/template.json"
        let deepLink =
            "osaurus://templates-import?url="
            + raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return """
            {"id":"\(registryID)","slug":"client-intake","version":\(version),"content_hash":"sha256:00",\
            "created":\(created),"url":"https://web.test/\(kind == "agent" ? "a" : "w")/client-intake",\
            "raw_url":"\(raw)","deep_link":"\(deepLink)"\(kind.map { #","kind":"\#($0)""# } ?? "")}
            """
    }

    /// Runs `body` with a fresh library root, a record store on it, and a
    /// service that signs with Alice's key.
    private func withService(
        hasIdentity: Bool = true,
        readKey: @escaping @MainActor () throws -> Data = { TestKeys.alicePrivateKey },
        knownTemplateIDs: @escaping @MainActor () -> Set<UUID> = { [] },
        isBuiltIn: @escaping @MainActor (UUID) -> Bool = { _ in false },
        workspaceAttestation: @escaping WorkflowShareService.AttestationMinter = { "att-\($0)" },
        _ body: @MainActor @Sendable (WorkflowShareService, WorkflowRegistryRecordStore) async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let previous = OsaurusPaths.overrideRoot
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("workflow-share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: root)
            }
            let records = WorkflowRegistryRecordStore()
            let service = WorkflowShareService(
                api: Self.client(), records: records, readKey: readKey,
                readReceiptKey: { TestKeys.alicePrivateKey }, identityExists: { hasIdentity },
                knownTemplateIDs: knownTemplateIDs, isBuiltIn: isBuiltIn, now: { Self.now },
                workspaceAttestation: workspaceAttestation)
            try await body(service, records)
        }
    }

    private static func template() -> Template { WF.template(WF.intake()).sealed() }

    private static func path(_ call: RegistryStub.Call) -> String { call.request.url?.path ?? "" }

    @Test
    func sharingSignsTheExactBytesItUploads_andRemembersTheLink() async throws {
        RegistryStub.shared.reset { request, _ in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"\#(String(repeating: "a", count: 64))","expires_in":60}"#)
            case "/workflows": return (201, Self.publishedJSON(version: 1, created: true))
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, records in
            let template = Self.template()
            let outcome = try await service.share(template, authorName: "Alice")
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()

            let calls = RegistryStub.shared.calls
            #expect(calls.map(Self.path) == ["/auth/challenge", "/workflows"])
            let challenge = try JSONSerialization.jsonObject(with: calls[0].body ?? Data()) as? [String: String]
            #expect(challenge?["address"] == alice)

            let publish = calls[1]
            let body = try #require(publish.body)
            let headers = publish.request.allHTTPHeaderFields ?? [:]
            #expect(publish.request.httpMethod == "POST")
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["X-Agent-Address"] == alice)
            #expect(headers["X-Nonce"] == String(repeating: "a", count: 64))
            #expect(headers["X-Timestamp"] == "1800000000")

            let message = WorkflowShareService.publishMessage(
                address: alice, bodyHash: WorkflowShareService.sha256Hex(body),
                nonce: String(repeating: "a", count: 64), timestamp: 1_800_000_000)
            let signatureHex = try #require(headers["X-Signature"])
            #expect(signatureHex.hasPrefix("0x") && signatureHex.count == 132)
            let recovered = try recoverAddress(
                payload: Data(message.utf8), signature: try #require(Data(hexEncoded: String(signatureHex.dropFirst(2)))),
                domainPrefix: "Ethereum Signed Message")
            #expect(recovered.lowercased() == alice)

            let uploaded = try Template.parse(String(decoding: body, as: UTF8.self))
            #expect(uploaded.author?.address?.lowercased() == alice, "the file's author is the uploader")
            #expect(uploaded.author?.name == "Alice")
            #expect(try registryCanonicalHash(body) == uploaded.contentHash)
            #expect(
                TemplateSigner.status(of: uploaded, knownAgent: { _ in nil })
                    == .signed(address: try deriveOsaurusId(from: TestKeys.alicePrivateKey), knownAgentID: nil))

            #expect(outcome.published.version == 1 && outcome.published.created)
            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.registryID == Self.registryID)
            #expect(record.url.absoluteString == "https://web.test/w/client-intake")
            #expect(record.address == alice)
            #expect(records.record(for: template.id, registry: WorkflowsRegistryAPIClient.productionBaseURL) == nil)

            let reloaded = WorkflowRegistryRecordStore()
            #expect(reloaded.record(for: template.id, registry: Self.base) == record, "persists across launches")
        }
    }

    @Test
    func aSpentNonceStartsOverFromTheChallengeOnce() async throws {
        let attempts = Counter()
        RegistryStub.shared.reset { request, _ in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"n\#(attempts.value)","expires_in":60}"#)
            case "/workflows":
                attempts.increment()
                return attempts.value == 1
                    ? (401, #"{"error":"invalid_nonce"}"#) : (200, Self.publishedJSON(version: 1, created: false))
            default: return (404, "{}")
            }
        }
        try await withService { service, _ in
            _ = try await service.share(Self.template())
            #expect(
                RegistryStub.shared.calls.map(Self.path)
                    == ["/auth/challenge", "/workflows", "/auth/challenge", "/workflows"])
        }
    }

    @Test
    func aVersionTheRegistryAlreadyHasOffersTheNextOne() async throws {
        RegistryStub.shared.reset { request, _ in
            request.url?.path == "/auth/challenge"
                ? (200, #"{"nonce":"n","expires_in":60}"#)
                : (409, #"{"error":"version_not_newer","latest_version":3,"message":"Version 3 is not newer."}"#)
        }
        try await withService { service, records in
            let template = Self.template()
            do {
                _ = try await service.share(template)
                Issue.record("expected version_not_newer")
            } catch let error as WorkflowShareError {
                guard case .versionNotNewer(let latest) = error else {
                    Issue.record("unexpected \(error)")
                    return
                }
                #expect(latest == 3)
            }
            #expect(records.record(for: template.id, registry: Self.base) == nil)
        }
    }

    @Test
    func aRejectedTemplateKeepsTheIssuesForTheFootnote() async throws {
        RegistryStub.shared.reset { request, _ in
            request.url?.path == "/auth/challenge"
                ? (200, #"{"nonce":"n","expires_in":60}"#)
                : (422, #"{"error":"invalid_template","issues":[{"path":"workflow.nodes[0].kind","message":"bad"}]}"#)
        }
        try await withService { service, _ in
            do {
                _ = try await service.share(Self.template())
                Issue.record("expected invalid_template")
            } catch let error as WorkflowShareError {
                #expect(error.errorDescription == "Osaurus couldn't prepare this workflow for sharing.")
                #expect(error.diagnosticHint?.contains("workflow.nodes[0].kind: bad") == true)
            }
        }
    }

    /// Recovers the signer of a request from its headers against `message`.
    private static func signer(of call: RegistryStub.Call, message: String) throws -> String {
        let headers = call.request.allHTTPHeaderFields ?? [:]
        let signatureHex = try #require(headers["X-Signature"])
        return try recoverAddress(
            payload: Data(message.utf8), signature: try #require(Data(hexEncoded: String(signatureHex.dropFirst(2)))),
            domainPrefix: "Ethereum Signed Message"
        ).lowercased()
    }

    nonisolated private static func detailJSON(
        id: String = registryID, templateID: UUID, version: Int = 1, installs: Int = 14,
        visibility: String = "public", status: String = "active", removedBy: String? = nil, osaurusID: String? = "alice",
        withLinks: Bool = true, kind: String? = nil
    ) -> String {
        let raw = "https://registry.test/workflows/\(id)/versions/\(version)/template.json"
        let links =
            withLinks
            ? #","raw_url":"\#(raw)","deep_link":"osaurus://templates-import?url=\#(raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)""#
            : ""
        let removal = removedBy.map { #","removal":{"by":"\#($0)","at":"2026-03-01T00:00:00Z"}"# } ?? ""
        let claimed = osaurusID.map { #","osaurus_id":"\#($0)""# } ?? ""
        let kindField = kind.map { #""kind":"\#($0)","# } ?? ""
        return """
            {"id":"\(id)","slug":"client-intake","name":"Client Intake","summary":"Sorts leads.",\(kindField)\
            "template_id":"\(templateID.uuidString.lowercased())",\
            "author":{"address":"0xabcdef0123456789abcdef0123456789abcdef01"\(claimed)},\
            "visibility":"\(visibility)","status":"\(status)"\(removal),"latest_version":\(version),\
            "install_count":\(installs),"created_at":"2026-01-02T03:04:05Z","updated_at":"2026-02-03T04:05:06Z",\
            "url":"https://web.test/w/client-intake"\(links),\
            "versions":[{"version":\(version),"changelog":"First","created_at":"2026-01-02T03:04:05Z"}]}
            """
    }

    @Test
    func publishingUnlistedSendsTheVisibilityHeader_publicDoesNot() async throws {
        RegistryStub.shared.reset { request, _ in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"n","expires_in":60}"#)
            case "/workflows":
                let hidden = request.value(forHTTPHeaderField: "X-Workflow-Visibility") == "hidden"
                return (
                    201,
                    Self.publishedJSON(version: 1, created: true)
                        .replacingOccurrences(of: "\"created\":true", with: "\"created\":true,\"visibility\":\"\(hidden ? "hidden" : "public")\"")
                )
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            let template = Self.template()
            let unlisted = try await service.share(template, visibility: .hidden)
            let publish = try #require(RegistryStub.shared.calls.last)
            #expect(publish.request.value(forHTTPHeaderField: "X-Workflow-Visibility") == "hidden")
            #expect(unlisted.published.visibility == .hidden)
            #expect(unlisted.record.visibility == .hidden)
            #expect(unlisted.visibilityError == nil)
            #expect(records.record(for: template.id, registry: Self.base)?.visibility == .hidden)

            let other = WF.template(WF.intake()).sealed()
            _ = try await service.share(other, visibility: .public)
            let publicPublish = try #require(RegistryStub.shared.calls.last)
            #expect(publicPublish.request.value(forHTTPHeaderField: "X-Workflow-Visibility") == nil)
            #expect(records.record(for: other.id, registry: Self.base)?.visibility == .public)
        }
    }

    @Test
    func publishingWithAPasswordPublishesUnlistedThenSetsThePassword() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"p1","expires_in":60}"#)
            case ("POST", "/workflows"):
                return (
                    201,
                    Self.publishedJSON(version: 1, created: true)
                        .replacingOccurrences(of: "\"created\":true", with: "\"created\":true,\"visibility\":\"hidden\"")
                )
            case ("PUT", "/workflows/\(Self.registryID)/visibility"):
                return (200, #"{"ok":true,"id":"\#(Self.registryID)","visibility":"password"}"#)
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            let template = Self.template()
            let outcome = try await service.share(template, visibility: .password, password: "hunter22")
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()

            let calls = RegistryStub.shared.calls
            #expect(
                calls.map(Self.path)
                    == ["/auth/challenge", "/workflows", "/auth/challenge", "/workflows/\(Self.registryID)/visibility"])
            #expect(calls[1].request.value(forHTTPHeaderField: "X-Workflow-Visibility") == "hidden",
                "a password page is unlisted until the password lands")

            let put = calls[3]
            let body = try #require(put.body)
            #expect(put.request.httpMethod == "PUT")
            #expect(put.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(String(decoding: body, as: UTF8.self) == #"{"password":"hunter22","visibility":"password"}"#)
            let message = WorkflowShareService.visibilityMessage(
                address: alice, registryID: Self.registryID, bodyHash: WorkflowShareService.sha256Hex(body),
                nonce: "p1", timestamp: 1_800_000_000)
            #expect(try Self.signer(of: put, message: message) == alice)

            #expect(outcome.visibilityError == nil)
            #expect(outcome.record.visibility == .password)
            #expect(records.record(for: template.id, registry: Self.base)?.visibility == .password)
        }
    }

    @Test
    func aPasswordThatDoesNotSaveLeavesThePageLiveAndUnlisted() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"p","expires_in":60}"#)
            case ("POST", "/workflows"):
                return (
                    201,
                    Self.publishedJSON(version: 1, created: true)
                        .replacingOccurrences(of: "\"created\":true", with: "\"created\":true,\"visibility\":\"hidden\"")
                )
            case ("PUT", _): return (400, #"{"error":"invalid_password","min_length":6,"max_length":128}"#)
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            let template = Self.template()
            let outcome = try await service.share(template, visibility: .password, password: "hunter22")
            #expect(outcome.published.version == 1, "the publish itself succeeded")
            #expect(outcome.visibilityError == .api(.invalidPassword(min: 6, max: 128)))
            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.visibility == .hidden && record.isLive)
        }
    }

    @Test
    func aShortPasswordIsRefusedBeforeAnythingIsSent() async throws {
        RegistryStub.shared.reset { _, _ in (500, "{}") }
        try await withService { service, records in
            let template = Self.template()
            await #expect(throws: WorkflowShareError.invalidPassword) {
                try await service.share(template, visibility: .password, password: "12345")
            }
            await #expect(throws: WorkflowShareError.invalidPassword) {
                try await service.share(template, visibility: .password, password: nil)
            }
            #expect(RegistryStub.shared.calls.isEmpty)
            #expect(records.record(for: template.id, registry: Self.base) == nil)

            await #expect(throws: WorkflowShareError.notShared) {
                try await service.setVisibility(templateID: template.id, visibility: .public)
            }
        }
    }

    @Test
    func changingVisibilityLaterSignsTheNewBody_andMapsTheRegistrysRefusals() async throws {
        let answer = Locked(#"{"ok":true,"visibility":"public"}"#)
        let status = Locked(200)
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"v1","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            case ("PUT", "/workflows/\(Self.registryID)/visibility"): return (status.value, answer.value)
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            let template = Self.template()
            _ = try await service.share(template)
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()

            // Public → Unlisted: no password in the body.
            answer.value = #"{"ok":true,"visibility":"hidden"}"#
            let hidden = try await service.setVisibility(templateID: template.id, visibility: .hidden, password: "x")
            #expect(hidden.visibility == .hidden)
            let put = try #require(RegistryStub.shared.calls.last)
            let body = try #require(put.body)
            #expect(String(decoding: body, as: UTF8.self) == #"{"visibility":"hidden"}"#)
            #expect(
                try Self.signer(
                    of: put,
                    message: WorkflowShareService.visibilityMessage(
                        address: alice, registryID: Self.registryID, bodyHash: WorkflowShareService.sha256Hex(body),
                        nonce: "v1", timestamp: 1_800_000_000)) == alice)
            #expect(records.record(for: template.id, registry: Self.base)?.visibility == .hidden)
            #expect(records.record(for: template.id, registry: Self.base)?.updatedAt == Self.now)

            // The registry's refusals reach the user by name.
            status.value = 400
            answer.value = #"{"error":"invalid_visibility"}"#
            await #expect(throws: WorkflowShareError.api(.invalidVisibility(code: "invalid_visibility"))) {
                try await service.setVisibility(templateID: template.id, visibility: .public)
            }
            answer.value = #"{"error":"password_missing"}"#
            await #expect(throws: WorkflowShareError.api(.invalidVisibility(code: "password_missing"))) {
                try await service.setVisibility(templateID: template.id, visibility: .public)
            }
            #expect(records.record(for: template.id, registry: Self.base)?.visibility == .hidden, "unchanged on failure")
        }
    }

    @Test
    func newErrorCodesMapToWhatTheUserIsTold() {
        func map(_ code: String, bounds: (Int?, Int?) = (nil, nil)) -> WorkflowsRegistryAPIError {
            .from(code: code, message: nil, status: 400, latestVersion: nil, issues: [], passwordBounds: bounds)
        }
        #expect(map("invalid_visibility") == .invalidVisibility(code: "invalid_visibility"))
        #expect(map("not_password_protected") == .invalidVisibility(code: "not_password_protected"))
        #expect(map("body_must_be_object") == .invalidVisibility(code: "body_must_be_object"))
        #expect(map("invalid_password", bounds: (6, 128)) == .invalidPassword(min: 6, max: 128))
        #expect(map("invalid_password", bounds: (6, 128)).errorDescription?.contains("6") == true)
        #expect(map("password_required") == .passwordRequired)
        #expect(map("quota_exceeded").errorDescription == "You've published the maximum number of workflows. Take one down first.")
    }

    @Test
    func unpublishSignsADeleteWithNoBody_andMarksItTakenDown() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"n9","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            case ("DELETE", "/workflows/\(Self.registryID)"): return (200, #"{"ok":true,"status":"removed"}"#)
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            let template = Self.template()
            _ = try await service.share(template)
            try await service.unpublish(templateID: template.id)

            let delete = try #require(RegistryStub.shared.calls.last)
            let headers = delete.request.allHTTPHeaderFields ?? [:]
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()
            #expect(delete.request.httpMethod == "DELETE")
            #expect(delete.body == nil || delete.body?.isEmpty == true)
            #expect(headers["X-Agent-Address"] == alice)
            #expect(headers["X-Nonce"] == "n9")
            let message = WorkflowShareService.deleteMessage(
                address: alice, registryID: Self.registryID, nonce: "n9", timestamp: 1_800_000_000)
            let recovered = try recoverAddress(
                payload: Data(message.utf8),
                signature: try #require(Data(hexEncoded: String((headers["X-Signature"] ?? "").dropFirst(2)))),
                domainPrefix: "Ethereum Signed Message")
            #expect(recovered.lowercased() == alice)
            // The record stays so the card reads Taken down and can Publish Again.
            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.takenDown && !record.removedByAdmin && !record.isLive)
            #expect(record.updatedAt == Self.now)
            #expect(records.liveRecords(registry: Self.base).isEmpty)
            #expect(records.records(registry: Self.base).count == 1)

            // Publishing again clears it and keeps the same link.
            _ = try await service.share(template, visibility: .hidden)
            let again = try #require(records.record(for: template.id, registry: Self.base))
            #expect(again.isLive && again.registryID == Self.registryID)

            service.forget(templateID: template.id)
            #expect(records.record(for: template.id, registry: Self.base) == nil)
        }
    }

    @Test
    func unpublishingSomethingAlreadyGoneStillMarksItTakenDown() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"n","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            default: return (410, #"{"error":"workflow_removed","removed_by":"owner"}"#)
            }
        }
        try await withService { service, records in
            let template = Self.template()
            _ = try await service.share(template)
            try await service.unpublish(templateID: template.id)
            #expect(records.record(for: template.id, registry: Self.base)?.takenDown == true)
        }
    }

    @Test
    func theBackgroundStatsReadNeverTouchesTheKey_andHonorsFreshness() async throws {
        let template = Self.template()
        let installs = Locked(14)
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"n","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            case ("GET", "/workflows/\(Self.registryID)"):
                return (200, Self.detailJSON(templateID: template.id, version: 2, installs: installs.value))
            default: return (404, "{}")
            }
        }
        let keyReads = Counter()
        try await withService(readKey: {
            keyReads.increment()
            return TestKeys.alicePrivateKey
        }) { service, records in
            _ = try await service.share(template)
            #expect(keyReads.value == 1, "the publish")

            #expect(await service.refreshStats(templateID: template.id) == true)
            let read = try #require(RegistryStub.shared.calls.last)
            #expect(read.request.httpMethod == "GET")
            #expect(read.request.value(forHTTPHeaderField: "X-Signature") == nil, "the public read")
            #expect(read.request.value(forHTTPHeaderField: "X-Agent-Address") == nil)
            #expect(keyReads.value == 1, "no key read, so no authentication prompt")

            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.installCount == 14)
            #expect(record.registryLatestVersion == 2, "another Mac published v2")
            #expect(record.version == 1, "what this Mac published stays")
            #expect(record.authorHandle == "@alice")
            #expect(record.publishedAt == Date(timeIntervalSince1970: 1_767_323_045))
            #expect(record.statsFetchedAt == Self.now)

            // Fresh numbers are not fetched again; force does.
            installs.value = 15
            let before = RegistryStub.shared.calls.count
            #expect(await service.refreshStats(templateID: template.id) == false)
            #expect(RegistryStub.shared.calls.count == before)
            #expect(await service.refreshStats(templateID: template.id, force: true) == true)
            #expect(records.record(for: template.id, registry: Self.base)?.installCount == 15)

            // A password page is left to the owner read.
            records.update(templateID: template.id, registry: Self.base) { $0.visibility = .password }
            let count = RegistryStub.shared.calls.count
            #expect(await service.refreshStats(templateID: template.id, force: true) == false)
            await service.refreshAllStats(force: true)
            #expect(RegistryStub.shared.calls.count == count)
            #expect(keyReads.value == 1)
        }
    }

    @Test
    func theBackgroundStatsReadLearnsOfTakeDownsAndPasswords() async throws {
        let template = Self.template()
        let answer = Locked((410, #"{"error":"workflow_removed","removed_by":"owner"}"#))
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"n","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            case ("GET", "/workflows/\(Self.registryID)"): return answer.value
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            _ = try await service.share(template)
            #expect(await service.refreshStats(templateID: template.id, force: true) == true)
            #expect(records.record(for: template.id, registry: Self.base)?.takenDown == true)
            #expect(await service.refreshStats(templateID: template.id, force: true) == false, "not live: skipped")

            records.update(templateID: template.id, registry: Self.base) { $0.takenDown = false }
            answer.value = (403, #"{"error":"password_required"}"#)
            #expect(await service.refreshStats(templateID: template.id, force: true) == true)
            #expect(records.record(for: template.id, registry: Self.base)?.visibility == .password)

            records.update(templateID: template.id, registry: Self.base) { $0.visibility = .public; $0.installCount = 3 }
            answer.value = (500, #"{"error":"boom"}"#)
            #expect(await service.refreshStats(templateID: template.id, force: true) == false)
            #expect(records.record(for: template.id, registry: Self.base)?.installCount == 3, "a miss keeps the numbers")
        }
    }

    @Test
    func theDashboardReadIsSigned_andReconcilesWhatThisIDOwns() async throws {
        let template = Self.template()
        let otherKnown = UUID()  // in the library, published from another Mac
        let otherUnknown = UUID()  // owned on the registry, not in this library
        let otherID = "7e0b8f61-6a4c-4a71-9d3d-0f0c1c9f5a11"
        let unknownID = "1a7d2c54-30c3-4a4e-9f3c-6f0c4c4b2b22"
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"o1","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            case ("GET", "/workflows/\(Self.registryID)"):
                guard request.value(forHTTPHeaderField: "X-Signature") != nil else {
                    return (403, #"{"error":"password_required"}"#)
                }
                return (200, Self.detailJSON(templateID: template.id, installs: 21, visibility: "password"))
            case ("GET", "/me/workflows"):
                let items = [
                    Self.detailJSON(templateID: template.id, installs: 21, visibility: "password"),
                    Self.detailJSON(
                        id: otherID, templateID: otherKnown, version: 4, installs: 2, visibility: "hidden",
                        status: "removed", removedBy: "owner"),
                    Self.detailJSON(id: unknownID, templateID: otherUnknown, installs: 0),
                ]
                return (
                    200,
                    #"{"author":{"address":"0xabcdef0123456789abcdef0123456789abcdef01","osaurus_id":"alice"},"banned":false,"items":[\#(items.joined(separator: ","))],"total":3,"offset":0,"limit":200,"next_offset":null}"#
                )
            default: return (404, "{}")
            }
        }
        try await withService(knownTemplateIDs: { [template.id, otherKnown] }) { service, records in
            _ = try await service.share(template)
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()

            let refresh = try await service.refreshOwned(templateID: template.id)
            let calls = RegistryStub.shared.calls
            #expect(
                calls.map(Self.path).suffix(4)
                    == ["/auth/challenge", "/workflows/\(Self.registryID)", "/auth/challenge", "/me/workflows"])
            let read = calls[calls.count - 3]
            #expect(
                try Self.signer(
                    of: read,
                    message: WorkflowShareService.readMessage(
                        address: alice, registryID: Self.registryID, nonce: "o1", timestamp: 1_800_000_000)) == alice)
            let list = calls[calls.count - 1]
            #expect(list.request.url?.query == "offset=0&limit=200")
            #expect(
                try Self.signer(
                    of: list,
                    message: WorkflowShareService.listMessage(address: alice, nonce: "o1", timestamp: 1_800_000_000))
                    == alice)

            #expect(refresh.detail.installCount == 21)
            #expect(refresh.authorHandle == "@alice" && refresh.banned == false)
            #expect(refresh.record.visibility == .password && refresh.record.installCount == 21)

            // The other Mac's workflow, whose template is in this library, now has a record.
            let other = try #require(records.record(for: otherKnown, registry: Self.base))
            #expect(other.registryID == otherID && other.version == 4 && other.registryLatestVersion == 4)
            #expect(other.takenDown && !other.removedByAdmin && other.visibility == .hidden)
            #expect(other.contentHash == "" && other.address == alice)
            #expect(other.rawURL.absoluteString == "https://registry.test/workflows/\(otherID)/versions/4/template.json")
            // One this library has never seen stays off the cards.
            #expect(records.record(for: otherUnknown, registry: Self.base) == nil)
            #expect(records.records(registry: Self.base).count == 2)
        }
    }

    @Test
    func anAgentTemplatePublishesLikeAWorkflow_andItsRecordKnowsItsKind() async throws {
        let text = String(decoding: try RegistryFixtures.data("agent-template-inbox-desk.json"), as: UTF8.self)
        let agent = try Template.parse(text)
        RegistryStub.shared.reset { request, _ in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"a1","expires_in":60}"#)
            case "/workflows": return (201, Self.publishedJSON(version: 3, created: true, kind: "agent"))
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, records in
            let outcome = try await service.share(agent)
            let body = try #require(RegistryStub.shared.calls.last?.body)
            let uploaded = try Template.parse(String(decoding: body, as: UTF8.self))
            #expect(uploaded.kind == .agent && uploaded.bundled.count == 1, "bundled workflows go with it")
            #expect(try registryCanonicalHash(body) == uploaded.contentHash)
            #expect(outcome.published.kind == .agent)

            let record = try #require(records.record(for: agent.id, registry: Self.base))
            #expect(record.kind == .agent && record.url.path == "/a/client-intake")
            #expect(records.liveRecords(registry: Self.base, kind: .agent).map(\.templateID) == [agent.id])
            #expect(records.liveRecords(registry: Self.base, kind: .workflow).isEmpty, "the Workflows page leaves agents out")
            #expect(WorkflowRegistryRecordStore().record(for: agent.id, registry: Self.base)?.kind == .agent)
        }
    }

    // MARK: Agent cascade

    private static func workflow(_ name: String, version: Int = 1) -> Template {
        var t = WF.template(WF.intake(), name: name)
        t.version = version
        return t.sealed()
    }

    private static func agent(bundling workflows: [Template]) -> Template {
        var agent = AgentTemplate(
            name: "Desk", agent: AgentEntry(name: "Desk"),
            workflows: workflows.map { WorkflowReference(id: $0.id, minVersion: $0.version) })
        agent.bundled = workflows
        return agent.sealed()
    }

    /// A publish answer named after the uploaded template, so each upload
    /// gets its own listing.
    nonisolated private static func published(_ body: Data?, visibility: String = "public") throws -> String {
        let t = try Template.parse(String(decoding: body ?? Data(), as: UTF8.self))
        let id = t.id.uuidString.lowercased()
        let raw = "https://registry.test/workflows/\(id)/versions/\(t.version)/template.json"
        let deepLink =
            "osaurus://templates-import?url=" + raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let segment = t.kind == .agent ? "a" : "w"
        return """
            {"id":"\(id)","slug":"\(id)","version":\(t.version),"content_hash":"sha256:00","created":true,\
            "url":"https://web.test/\(segment)/\(id)","raw_url":"\(raw)","deep_link":"\(deepLink)",\
            "visibility":"\(visibility)","kind":"\(t.kind.rawValue)"}
            """
    }

    nonisolated private static func uploaded(_ calls: [RegistryStub.Call]) -> [Template] {
        calls.filter { $0.request.httpMethod == "POST" && $0.request.url?.path == "/workflows" }
            .compactMap { $0.body.flatMap { try? Template.parse(String(decoding: $0, as: UTF8.self)) } }
    }

    @Test
    func publishingAnAgentPublishesItsOwnWorkflowsFirst_withItsVisibility() async throws {
        let intake = Self.workflow("Client Intake")
        let agent = Self.agent(bundling: [intake])
        RegistryStub.shared.reset { request, body in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"c1","expires_in":60}"#)
            case "/workflows": return (201, try Self.published(body, visibility: "hidden"))
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, records in
            let outcome = try await service.shareAgent(agent, authorName: "@alice", visibility: .hidden)
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()

            let uploads = Self.uploaded(RegistryStub.shared.calls)
            #expect(uploads.map(\.id) == [intake.id, agent.id], "the workflow's page exists before the agent's")
            #expect(uploads[0].kind == .workflow && uploads[0].author?.address?.lowercased() == alice)
            #expect(uploads[1].bundled.map(\.id) == [intake.id], "the agent still carries it")
            let posts = RegistryStub.shared.calls.filter { $0.request.httpMethod == "POST" && $0.request.url?.path == "/workflows" }
            #expect(posts.map { $0.request.value(forHTTPHeaderField: "X-Workflow-Visibility") } == ["hidden", "hidden"])

            let workflowRecord = try #require(records.record(for: intake.id, registry: Self.base))
            #expect(workflowRecord.publishedWith == agent.id && workflowRecord.kind == .workflow)
            #expect(records.record(for: agent.id, registry: Self.base)?.publishedWith == nil)
            #expect(records.records(publishedWith: agent.id, registry: Self.base).map(\.templateID) == [intake.id])
            #expect(outcome.cascade == [TemplateCascadeResult(templateID: intake.id, name: "Client Intake", status: .published(workflowRecord))])
            #expect(WorkflowRegistryRecordStore().record(for: intake.id, registry: Self.base)?.publishedWith == agent.id)

            // Publishing the agent again leaves a live workflow alone.
            let again = try await service.shareAgent(agent, visibility: .hidden)
            #expect(Self.uploaded(RegistryStub.shared.calls).count == 3)
            #expect(again.cascade.map(\.status) == [.alreadyPublished(workflowRecord)])
        }
    }

    @Test
    func aPasswordProtectedAgentKeepsItsWorkflowsBundledOnly() async throws {
        let intake = Self.workflow("Client Intake")
        let agent = Self.agent(bundling: [intake])
        RegistryStub.shared.reset { request, body in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"c2","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, try Self.published(body, visibility: "hidden"))
            case ("PUT", _):
                return (200, #"{"ok":true,"id":"\#(agent.id.uuidString.lowercased())","visibility":"password"}"#)
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, records in
            let outcome = try await service.shareAgent(agent, visibility: .password, password: "hunter22")
            #expect(Self.uploaded(RegistryStub.shared.calls).map(\.id) == [agent.id])
            #expect(records.record(for: intake.id, registry: Self.base) == nil)
            #expect(outcome.record.visibility == .password)
            #expect(outcome.cascade.map(\.status) == [.bundledOnly(.passwordProtected)])
        }
    }

    @Test
    func someoneElsesWorkflowIsNeverRepublished_andAFailedOneDoesntStopTheAgent() async throws {
        let bobs = try TemplateSigner.signed(Self.workflow("Bob's Digest"), privateKey: TestKeys.bobPrivateKey, authorName: "Bob")
        let live = Self.workflow("Already Live", version: 2)
        let builtIn = Self.workflow("Built In")
        let broken = Self.workflow("Broken")
        let agent = Self.agent(bundling: [bobs, live, builtIn, broken])
        let brokenID = broken.id
        RegistryStub.shared.reset { request, body in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"c3","expires_in":60}"#)
            case "/workflows":
                let t = try Template.parse(String(decoding: body ?? Data(), as: UTF8.self))
                if t.id == brokenID { return (500, #"{"error":"internal"}"#) }
                return (201, try Self.published(body))
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService(isBuiltIn: { $0 == builtIn.id }) { service, records in
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()
            var existing = WorkflowRegistryRecord(
                templateID: live.id, registryID: "r-live", slug: "already-live", version: 2, contentHash: "",
                url: URL(string: "https://web.test/w/already-live")!,
                rawURL: URL(string: "https://registry.test/workflows/r-live/versions/2/template.json")!,
                deepLink: URL(string: "osaurus://templates-import?url=x")!, address: alice,
                registry: WorkflowRegistryRecordStore.registryKey(Self.base), sharedAt: Self.now)
            existing.registryLatestVersion = 2
            records.set(existing)

            let outcome = try await service.shareAgent(agent)
            let bob = try deriveOsaurusId(from: TestKeys.bobPrivateKey).lowercased()
            #expect(
                outcome.cascade.map(\.status).prefix(3)
                    == [.linkedToAuthor(address: bob), .alreadyPublished(existing), .bundledOnly(.builtIn)])
            guard case .failed = outcome.cascade.last?.status else {
                Issue.record("the broken workflow is reported, got \(String(describing: outcome.cascade.last))")
                return
            }
            // Only the broken workflow was tried, then the agent went live anyway.
            let tried = RegistryStub.shared.calls
                .filter { $0.request.httpMethod == "POST" && $0.request.url?.path == "/workflows" }
                .compactMap { $0.body.flatMap { try? Template.parse(String(decoding: $0, as: UTF8.self)).id } }
            #expect(tried == [broken.id, agent.id])
            #expect(records.record(for: agent.id, registry: Self.base)?.isLive == true)
            #expect(records.record(for: bobs.id, registry: Self.base) == nil)
        }
    }

    @Test
    func changingAnAgentsVisibilityMovesTheWorkflowsPublishedWithIt() async throws {
        let first = Self.workflow("First")
        let second = Self.workflow("Second")
        let agent = Self.agent(bundling: [first, second])
        let secondID = second.id.uuidString.lowercased()
        RegistryStub.shared.reset { request, body in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"v","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, try Self.published(body))
            case ("PUT", let path?):
                if path.contains(secondID) { return (500, #"{"error":"internal"}"#) }
                let id = path.split(separator: "/")[1]
                return (200, #"{"ok":true,"id":"\#(id)","visibility":"hidden"}"#)
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, records in
            _ = try await service.shareAgent(agent)
            let failed = try await service.setAgentVisibility(
                templateID: agent.id, visibility: .hidden, workflowIDs: [first.id, second.id, UUID()])
            #expect(records.record(for: agent.id, registry: Self.base)?.visibility == .hidden)
            #expect(records.record(for: first.id, registry: Self.base)?.visibility == .hidden)
            #expect(records.record(for: second.id, registry: Self.base)?.visibility == .public)
            #expect(Array(failed.keys) == [second.id], "a failed workflow is reported, the rest go on")
            let puts = RegistryStub.shared.calls.filter { $0.request.httpMethod == "PUT" }.map(Self.path)
            #expect(puts.count == 3, "the agent, then each workflow; an unknown id sends nothing")
            #expect(puts.first?.contains(agent.id.uuidString.lowercased()) == true)

            // A password-protected agent leaves its workflows alone.
            RegistryStub.shared.reset { request, _ in
                switch (request.httpMethod, request.url?.path) {
                case (_, "/auth/challenge"): return (200, #"{"nonce":"v","expires_in":60}"#)
                case ("PUT", _):
                    return (200, #"{"ok":true,"id":"\#(agent.id.uuidString.lowercased())","visibility":"password"}"#)
                default: return (404, #"{"error":"not_found"}"#)
                }
            }
            _ = try await service.setAgentVisibility(
                templateID: agent.id, visibility: .password, password: "hunter22", workflowIDs: [first.id])
            #expect(RegistryStub.shared.calls.filter { $0.request.httpMethod == "PUT" }.count == 1)
            #expect(records.record(for: first.id, registry: Self.base)?.visibility == .hidden)
        }
    }

    @Test
    func aRateLimitStopsTheCascade_andSaysHowManyWorkflowsWentLive() async throws {
        let first = Self.workflow("First")
        let second = Self.workflow("Second")
        let third = Self.workflow("Third")
        let agent = Self.agent(bundling: [first, second, third])
        let firstID = first.id
        RegistryStub.shared.reset { request, body in
            switch request.url?.path {
            case "/auth/challenge": return (200, #"{"nonce":"c4","expires_in":60}"#)
            case "/workflows":
                let t = try Template.parse(String(decoding: body ?? Data(), as: UTF8.self))
                if t.id == firstID { return (201, try Self.published(body)) }
                return (429, #"{"error":"rate_limited"}"#)
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, records in
            await #expect(throws: WorkflowShareError.rateLimited(publishedWorkflows: 1)) {
                try await service.shareAgent(agent)
            }
            #expect(Self.uploaded(RegistryStub.shared.calls).map(\.id) == [first.id, second.id], "no request after the 429")
            #expect(records.record(for: first.id, registry: Self.base)?.isLive == true)
            #expect(records.record(for: agent.id, registry: Self.base) == nil)
        }
        #expect(
            WorkflowShareError.rateLimited(publishedWorkflows: 1).errorDescription
                == "1 of its workflows published, then the registry paused: too many publishes in a row. Try again in a few minutes; the ones already published won't publish twice."
        )
        #expect(WorkflowShareError(.rateLimited) == .rateLimited(publishedWorkflows: 0))
    }

    @Test
    func reconcilingRebuildsAgentListingsWithTheirKind() async throws {
        let workflow = Self.template()
        let agentTemplateID = UUID()
        let agentID = "5b0c7e2a-1f3d-4c8e-9a6b-2d4e6f8a0c33"
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"o2","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            case ("GET", "/workflows/\(Self.registryID)"): return (200, Self.detailJSON(templateID: workflow.id))
            case ("GET", "/me/workflows"):
                let items = [
                    Self.detailJSON(templateID: workflow.id, kind: "workflow"),
                    Self.detailJSON(id: agentID, templateID: agentTemplateID, version: 2, installs: 5, kind: "agent"),
                ]
                return (
                    200,
                    #"{"author":{"address":"0xabcdef0123456789abcdef0123456789abcdef01","osaurus_id":"alice"},"banned":false,"items":[\#(items.joined(separator: ","))],"total":2,"offset":0,"limit":200,"next_offset":null}"#
                )
            default: return (404, "{}")
            }
        }
        try await withService(knownTemplateIDs: { [workflow.id, agentTemplateID] }) { service, records in
            _ = try await service.share(workflow)
            _ = try await service.refreshOwned(templateID: workflow.id)

            let agent = try #require(records.record(for: agentTemplateID, registry: Self.base))
            #expect(agent.kind == .agent && agent.registryID == agentID && agent.installCount == 5)
            #expect(records.record(for: workflow.id, registry: Self.base)?.kind == .workflow)
            #expect(records.totalInstalls(registry: Self.base, kind: .workflow) == 14 && records.totalInstalls(registry: Self.base, kind: .agent) == 5)
            #expect(records.records(registry: Self.base).count == 2)
        }
    }

    @Test
    func theDashboardReadSurfacesAnAdminRemoval_andAMissingWorkflow() async throws {
        let template = Self.template()
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"o","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            case ("GET", "/workflows/\(Self.registryID)"):
                return (200, Self.detailJSON(templateID: template.id, status: "removed", removedBy: "admin"))
            case ("GET", "/me/workflows"): return (500, #"{"error":"boom"}"#)
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            _ = try await service.share(template)
            let refresh = try await service.refreshOwned(templateID: template.id)
            #expect(refresh.detail.removedByAdmin)
            #expect(refresh.record.removedByAdmin && !refresh.record.takenDown && !refresh.record.isLive)
            #expect(refresh.authorHandle == "@alice", "from the detail when the list fails")
            #expect(records.record(for: template.id, registry: Self.base)?.removedByAdmin == true)
        }

        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"o","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.publishedJSON(version: 1, created: true))
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, _ in
            _ = try await service.share(template)
            await #expect(throws: WorkflowShareError.api(.notFound)) {
                try await service.refreshOwned(templateID: template.id)
            }
            await #expect(throws: WorkflowShareError.notShared) {
                try await service.refreshOwned(templateID: UUID())
            }
        }
    }

    @Test
    func anAgentInstallCreditsTheWorkflowPagesItLinksTo() async throws {
        let linked = Self.workflow("Linked", version: 2)
        let unlinked = Self.workflow("Unlinked")
        let newer = Self.workflow("Newer than its page", version: 5)
        let linkedPage = "11111111-1111-4111-8111-111111111111"
        let newerPage = "22222222-2222-4222-8222-222222222222"
        let agentTemplateID = UUID()
        let links = """
            "workflows":[\
            {"template_id":"\(linked.id.uuidString.lowercased())","min_version":2,"name":"Linked",\
            "listing":{"id":"\(linkedPage)","latest_version":3}},\
            {"template_id":"\(unlinked.id.uuidString.lowercased())","min_version":1,"name":"Unlinked","listing":null},\
            {"template_id":"\(newer.id.uuidString.lowercased())","min_version":5,"name":"Newer",\
            "listing":{"id":"\(newerPage)","latest_version":4}}]
            """
        let detail = String(Self.detailJSON(templateID: agentTemplateID, kind: "agent").dropLast()) + ",\(links)}"
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"r","expires_in":60}"#)
            case ("GET", "/workflows/\(Self.registryID)"): return (200, detail)
            case ("POST", _): return (200, #"{"ok":true,"counted":true,"version":1}"#)
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
        try await withService { service, _ in
            let counted = await service.recordAgentInstall(Self.installSource(), bundled: [linked, unlinked, newer])
            #expect(counted.count == 3)
            #expect(counted[UUID(uuidString: Self.registryID)!] == true)
            #expect(counted[UUID(uuidString: linkedPage)!] == true)
            #expect(counted[UUID(uuidString: newerPage)!] == true)

            let receipts = RegistryStub.shared.calls.filter { Self.path($0).hasSuffix("/installs") }
            #expect(
                receipts.map(Self.path) == [
                    "/workflows/\(Self.registryID)/installs", "/workflows/\(linkedPage)/installs",
                    "/workflows/\(newerPage)/installs",
                ])
            let versions = try receipts.map {
                try JSONSerialization.jsonObject(with: try #require($0.body)) as? [String: Int]
            }
            #expect(versions == [["version": 2], ["version": 2], ["version": 4]], "a page's newest when the copy is newer")
        }

        // Without the agent's page the agent still counts; nothing else is sent.
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"r","expires_in":60}"#)
            case ("POST", _): return (200, #"{"ok":true,"counted":true,"version":2}"#)
            default: return (403, #"{"error":"password_required"}"#)
            }
        }
        try await withService { service, _ in
            let counted = await service.recordAgentInstall(Self.installSource(), bundled: [linked])
            #expect(counted == [UUID(uuidString: Self.registryID)!: true])
        }
    }

    private static func installSource(version: Int = 2, origin: URL = base) -> RegistryImportSource {
        RegistryImportSource(workflowID: UUID(uuidString: registryID)!, version: version, origin: origin)
    }

    @Test
    func theInstallReceiptIsSignedForTheLinkedVersion() async throws {
        RegistryStub.shared.reset { request, _ in
            request.url?.path == "/auth/challenge"
                ? (200, #"{"nonce":"r1","expires_in":60}"#)
                : (201, #"{"ok":true,"counted":true,"version":2}"#)
        }
        try await withService { service, _ in
            #expect(await service.recordInstall(Self.installSource()) == true)

            let calls = RegistryStub.shared.calls
            #expect(calls.map(Self.path) == ["/auth/challenge", "/workflows/\(Self.registryID)/installs"])
            let receipt = calls[1]
            let headers = receipt.request.allHTTPHeaderFields ?? [:]
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()
            #expect(receipt.request.httpMethod == "POST")
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["X-Agent-Address"] == alice)
            #expect(headers["X-Nonce"] == "r1")
            #expect(headers["X-Timestamp"] == "1800000000")
            let body = try JSONSerialization.jsonObject(with: try #require(receipt.body)) as? [String: Int]
            #expect(body == ["version": 2])

            let message = WorkflowShareService.installMessage(
                address: alice, registryID: Self.registryID, version: 2, nonce: "r1", timestamp: 1_800_000_000)
            let recovered = try recoverAddress(
                payload: Data(message.utf8),
                signature: try #require(Data(hexEncoded: String((headers["X-Signature"] ?? "").dropFirst(2)))),
                domainPrefix: "Ethereum Signed Message")
            #expect(recovered.lowercased() == alice)
        }
    }

    @Test
    func aRepeatReceiptLandsOnTheSameInstall() async throws {
        RegistryStub.shared.reset { request, _ in
            request.url?.path == "/auth/challenge"
                ? (200, #"{"nonce":"r","expires_in":60}"#) : (200, #"{"ok":true,"counted":false,"version":3}"#)
        }
        try await withService { service, _ in
            #expect(await service.recordInstall(Self.installSource(version: 3)) == false)
        }
    }

    @Test
    func noOsaurusIDOrAnotherRegistrySendsNothing() async throws {
        RegistryStub.shared.reset { _, _ in (200, #"{"ok":true,"counted":true,"version":2}"#) }
        try await withService(hasIdentity: false) { service, _ in
            #expect(await service.recordInstall(Self.installSource()) == nil)
        }
        try await withService { service, _ in
            #expect(
                await service.recordInstall(Self.installSource(origin: WorkflowsRegistryAPIClient.productionBaseURL))
                    == nil)
        }
        #expect(RegistryStub.shared.calls.isEmpty)
    }

    @Test
    func aFailedReceiptIsQuietAndNotRetried() async throws {
        RegistryStub.shared.reset { request, _ in
            request.url?.path == "/auth/challenge"
                ? (200, #"{"nonce":"r","expires_in":60}"#) : (401, #"{"error":"invalid_nonce"}"#)
        }
        try await withService { service, _ in
            #expect(await service.recordInstall(Self.installSource()) == nil)
            #expect(RegistryStub.shared.calls.count == 2, "one challenge, one receipt, no retry")
        }

        RegistryStub.shared.reset { request, _ in
            request.url?.path == "/auth/challenge"
                ? (200, #"{"nonce":"r","expires_in":60}"#) : (410, #"{"error":"workflow_removed"}"#)
        }
        try await withService { service, _ in
            #expect(await service.recordInstall(Self.installSource()) == nil)
        }

        RegistryStub.shared.reset { _, _ in throw URLError(.notConnectedToInternet) }
        try await withService { service, _ in
            #expect(await service.recordInstall(Self.installSource()) == nil)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// A value a stub handler reads and a test rewrites between requests.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Listing edits

/// In the HTTP suite so the shared stub stays serialized.
extension WorkflowShareServiceHTTPTests {
    nonisolated private static let listingNonce = String(repeating: "b", count: 64)

    /// A registry that publishes, then answers the listing follow-ups.
    nonisolated private static func listingRoutes(
        tags: (Int, String) = (200, #"{"ok":true,"tags":["writing","coding"]}"#),
        image: (Int, String)? = nil,
        listing: String = #"{"ok":true,"name":"Refund Helper","summary":"Answers refunds.","edited":true}"#
    ) -> @Sendable (URLRequest, Data?) throws -> (Int, String) {
        { request, body in
            let id = registryID
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"\#(listingNonce)","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, publishedJSON(version: 1, created: true))
            case ("PUT", "/workflows/\(id)/listing"): return (200, listing)
            case ("PUT", "/workflows/\(id)/tags"): return tags
            case ("POST", "/workflows/\(id)/examples/images"):
                if let image { return image }
                let sha = WorkflowShareService.sha256Hex(body ?? Data())
                return (
                    200,
                    #"{"path":"\#(id)/\#(sha).png","url":"https://media.test/\#(id)/\#(sha).png","mime":"image/png","size":\#(body?.count ?? 0),"width":null,"height":null}"#
                )
            case ("PUT", "/workflows/\(id)/examples"):
                return (
                    200,
                    #"{"ok":true,"examples":[{"id":"e1","title":"Refund","status":"succeeded","input":{"email":"Hi"},"output":"Of course","images":[]}]}"#
                )
            default: return (404, #"{"error":"not_found"}"#)
            }
        }
    }

    /// A small PNG carrying a location, the way a phone photo would.
    private static func pngWithLocation() throws -> URL {
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("listing-\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func exampleDraft(image: URL?) -> ListingExampleDraft {
        ListingExampleDraft(
            source: .run(UUID()), title: "Refund", templateVersion: 1, status: .succeeded, durationMs: 4200,
            input: .object(["email": .string("Hi")]), output: .string("Of course"), error: nil,
            images: image.map { [ListingExampleDraft.ImageDraft(id: "a", filename: "cover.png", fileURL: $0)] } ?? [],
            date: now)
    }

    private static func route(_ call: RegistryStub.Call) -> String {
        "\(call.request.httpMethod ?? "") \(path(call))"
    }

    @Test
    func publishingWithListingEditsSignsEachFollowUp_andRecordsThem() async throws {
        let imageURL = try Self.pngWithLocation()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        RegistryStub.shared.reset(Self.listingRoutes())
        try await withService { service, records in
            let template = Self.template()
            let edits = ListingEdits(
                details: .set(name: "Refund Helper", summary: "Answers refunds."), topics: [.coding, .writing],
                examples: [Self.exampleDraft(image: imageURL)])
            let outcome = try await service.share(template, listing: edits)
            let listing = try #require(outcome.listing)
            #expect(!listing.hasFailures)
            #expect(listing.savedExamples?.count == 1)

            let id = Self.registryID
            let calls = RegistryStub.shared.calls.filter { Self.path($0) != "/auth/challenge" }
            #expect(
                calls.map(Self.route) == [
                    "POST /workflows", "PUT /workflows/\(id)/listing", "PUT /workflows/\(id)/tags",
                    "POST /workflows/\(id)/examples/images", "PUT /workflows/\(id)/examples",
                ])
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()
            let ts = 1_800_000_000

            let listingBody = try #require(calls[1].body)
            #expect(String(decoding: listingBody, as: UTF8.self) == #"{"name":"Refund Helper","summary":"Answers refunds."}"#)
            #expect(
                try Self.signer(
                    of: calls[1],
                    message: WorkflowShareService.listingMessage(
                        address: alice, registryID: id, bodyHash: WorkflowShareService.sha256Hex(listingBody),
                        nonce: Self.listingNonce, timestamp: ts)) == alice)

            let tagsBody = try #require(calls[2].body)
            #expect(String(decoding: tagsBody, as: UTF8.self) == #"{"tags":["writing","coding"]}"#, "vocabulary order")
            #expect(
                try Self.signer(
                    of: calls[2],
                    message: WorkflowShareService.tagsMessage(
                        address: alice, registryID: id, bodyHash: WorkflowShareService.sha256Hex(tagsBody),
                        nonce: Self.listingNonce, timestamp: ts)) == alice)

            let imageBody = try #require(calls[3].body)
            let imageHash = WorkflowShareService.sha256Hex(imageBody)
            #expect(calls[3].request.value(forHTTPHeaderField: "Content-Type") == "image/png")
            #expect(
                try Self.signer(
                    of: calls[3],
                    message: WorkflowShareService.exampleImageMessage(
                        address: alice, registryID: id, imageHash: imageHash, nonce: Self.listingNonce, timestamp: ts))
                    == alice)
            let source = try #require(CGImageSourceCreateWithData(imageBody as CFData, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            #expect(props[kCGImagePropertyGPSDictionary] == nil, "the location never leaves the Mac")

            let examplesBody = try #require(calls[4].body)
            #expect(
                try Self.signer(
                    of: calls[4],
                    message: WorkflowShareService.examplesMessage(
                        address: alice, registryID: id, bodyHash: WorkflowShareService.sha256Hex(examplesBody),
                        nonce: Self.listingNonce, timestamp: ts)) == alice)
            let sent = try #require(
                (try JSONSerialization.jsonObject(with: examplesBody) as? [String: Any])?["examples"] as? [[String: Any]])
            #expect(sent.count == 1)
            #expect(sent[0]["title"] as? String == "Refund")
            #expect(sent[0]["duration_ms"] as? Int == 4200)
            #expect(sent[0]["template_version"] as? Int == 1)
            #expect((sent[0]["input"] as? [String: String]) == ["email": "Hi"])
            let images = try #require(sent[0]["images"] as? [[String: Any]])
            #expect(images.first?["path"] as? String == "\(id)/\(imageHash).png")
            #expect(images.first?["width"] as? Int == 64, "dimensions the encoder knows fill what the registry didn't say")

            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.listingName == "Refund Helper")
            #expect(record.listingSummary == "Answers refunds.")
            #expect(record.tags == ["writing", "coding"])
            #expect(record.exampleCount == 1)
        }
    }

    @Test
    func aListingPartThatFailsLeavesThePublishAndTheOtherParts() async throws {
        RegistryStub.shared.reset(
            Self.listingRoutes(tags: (400, #"{"error":"invalid_tags","allowed":["writing"],"max":3}"#)))
        try await withService { service, records in
            let template = Self.template()
            let outcome = try await service.share(
                template,
                listing: ListingEdits(
                    details: .set(name: "Refund Helper", summary: "Answers refunds."), topics: [.fun],
                    examples: [Self.exampleDraft(image: nil)]))
            let listing = try #require(outcome.listing)
            #expect(listing.topicsError == "Pick up to 3 topics from the list.")
            #expect(listing.detailsError == nil && listing.examplesError == nil)
            #expect(outcome.published.version == 1)
            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.tags == [] && record.listingName == "Refund Helper" && record.exampleCount == 1)

            let retry = ListingEdits(details: .reset, topics: [.fun]).failed(in: listing)
            #expect(retry == ListingEdits(topics: [.fun]))
        }
    }

    @Test
    func withoutImageStorageTheExamplesSaveWithoutTheirImages() async throws {
        let imageURL = try Self.pngWithLocation()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        RegistryStub.shared.reset(Self.listingRoutes(image: (503, #"{"error":"media_unavailable"}"#)))
        try await withService { service, _ in
            let outcome = try await service.share(
                Self.template(),
                listing: ListingEdits(examples: [Self.exampleDraft(image: imageURL), Self.exampleDraft(image: imageURL)]))
            let listing = try #require(outcome.listing)
            #expect(!listing.hasFailures)
            #expect(listing.imagesSkipped)
            let calls = RegistryStub.shared.calls
            #expect(calls.filter { Self.path($0).hasSuffix("/examples/images") }.count == 1, "stops asking after a 503")
            let put = try #require(calls.last { Self.path($0).hasSuffix("/examples") })
            let sent = try #require(
                (try JSONSerialization.jsonObject(with: put.body ?? Data()) as? [String: Any])?["examples"] as? [[String: Any]])
            #expect(sent.count == 2)
            #expect(sent.allSatisfy { ($0["images"] as? [Any])?.isEmpty == true })
        }
    }

    @Test
    func resettingTheListingSendsResetAndForgetsTheOwnName() async throws {
        RegistryStub.shared.reset(Self.listingRoutes())
        try await withService { service, records in
            let template = Self.template()
            _ = try await service.share(
                template, listing: ListingEdits(details: .set(name: "Refund Helper", summary: "Answers refunds.")))
            #expect(records.record(for: template.id, registry: Self.base)?.listingName == "Refund Helper")

            RegistryStub.shared.reset(
                Self.listingRoutes(listing: #"{"ok":true,"name":"Client Intake","summary":"Sorts leads.","edited":false}"#))
            let result = try await service.applyListingEdits(templateID: template.id, ListingEdits(details: .reset))
            #expect(!result.hasFailures)
            let put = try #require(RegistryStub.shared.calls.last)
            #expect(Self.path(put) == "/workflows/\(Self.registryID)/listing")
            #expect(String(decoding: put.body ?? Data(), as: UTF8.self) == #"{"reset":true}"#)
            #expect(records.record(for: template.id, registry: Self.base)?.listingName == nil)
        }
    }

    @Test
    func listingEditsOnAnUnpublishedTemplateAreRefusedBeforeAnyRequest() async throws {
        RegistryStub.shared.reset(Self.listingRoutes())
        try await withService { service, _ in
            await #expect(throws: WorkflowShareError.notShared) {
                _ = try await service.applyListingEdits(templateID: UUID(), ListingEdits(topics: [.fun]))
            }
            #expect(RegistryStub.shared.calls.isEmpty)
        }
    }

    @Test
    func aDetailWithListingFieldsFoldsIntoTheRecord_andAnOldRecordStillLoads() throws {
        let templateID = UUID()
        let json = Self.detailJSON(templateID: templateID).replacingOccurrences(
            of: #""versions":["#,
            with: #""tags":["writing","fun"],"listing_edited_at":"2026-03-01T00:00:00Z","examples":[{"id":"e1","title":"Refund","template_version":1,"status":"failed","duration_ms":10,"input":null,"output":null,"error":"No email.","images":[{"path":"x/y.png","url":"https://media.test/x/y.png","mime":"image/png","size":3,"width":1,"height":1,"caption":null}],"created_at":"2026-03-01T00:00:00Z"}],"versions":["#)
        let detail = try WorkflowsRegistryAPIClient.decode(WorkflowsRegistryDetail.self, from: Data(json.utf8))
        #expect(detail.tags == ["writing", "fun"])
        #expect(detail.listingEdited)
        #expect(detail.exampleCount == 1)
        let example = try #require(detail.examples.first)
        #expect(example.status == .failed && example.input == .null && example.output == nil)
        #expect(example.images.first?.url?.absoluteString == "https://media.test/x/y.png")

        let old = """
            {"template_id":"\(templateID.uuidString)","registry_id":"\(Self.registryID)","slug":"client-intake",\
            "version":1,"content_hash":"sha256:00","url":"https://web.test/w/client-intake",\
            "raw_url":"https://registry.test/raw","deep_link":"osaurus://x","address":"0xabc",\
            "registry":"https://registry.test","shared_at":"2026-01-02T03:04:05Z"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var record = try decoder.decode(WorkflowRegistryRecord.self, from: Data(old.utf8))
        #expect(record.tags == [] && record.listingName == nil && record.exampleCount == nil)

        record.apply(detail, at: Self.now)
        #expect(record.listingName == "Client Intake" && record.listingSummary == "Sorts leads.")
        #expect(record.topics == [.writing, .fun])
        #expect(record.exampleCount == 1)

        let plain = try WorkflowsRegistryAPIClient.decode(
            WorkflowsRegistryDetail.self, from: Data(Self.detailJSON(templateID: templateID).utf8))
        #expect(plain.tags == [] && plain.examples == [] && plain.exampleCount == nil && !plain.listingEdited)
        record.apply(plain, at: Self.now)
        #expect(record.listingName == nil, "the listing shows the template's own again")
        #expect(record.exampleCount == 1, "a registry that doesn't say keeps the last count")
    }
}

// MARK: - Workspace sharing

extension WorkflowShareServiceHTTPTests {
    nonisolated private static let workspaceA = "11111111-1111-4111-8111-111111111111"
    nonisolated private static let workspaceB = "22222222-2222-4222-8222-222222222222"

    nonisolated private static func hiddenPublishJSON() -> String {
        publishedJSON(version: 1, created: true)
            .replacingOccurrences(of: "\"created\":true", with: "\"created\":true,\"visibility\":\"hidden\"")
    }

    @Test
    func workspaceMessagesAndBodiesFollowTheContract() throws {
        #expect(
            WorkflowShareService.unshareMessage(
                address: "0xabc", registryID: "id-1", workspaceID: "ws-1", nonce: "n", timestamp: 1703)
                == "osaurus-workflow-unshare:0xabc:id-1:ws-1:n:1703")
        let body = try WorkflowsRegistryAPIClient.visibilityBody(
            .workspace, password: "ignored", workspaceAttestations: ["a", "b"])
        #expect(String(decoding: body, as: UTF8.self) == #"{"visibility":"workspace","workspace_attestations":["a","b"]}"#)
        let hidden = try WorkflowsRegistryAPIClient.visibilityBody(.hidden, password: nil, workspaceAttestations: ["a"])
        #expect(String(decoding: hidden, as: UTF8.self) == #"{"visibility":"hidden"}"#)

        #expect(WorkflowVisibility.isValidWorkspaceSelection(["a"]))
        #expect(!WorkflowVisibility.isValidWorkspaceSelection([]))
        #expect(!WorkflowVisibility.isValidWorkspaceSelection((0 ... 20).map { "w\($0)" }))
        #expect(WorkflowVisibility.workspace.rawValue == "workspace")
    }

    @Test
    func theRegistrysWorkspaceErrorsMapToWhatTheUserIsTold() {
        func code(_ c: String, _ status: Int) -> WorkflowsRegistryAPIError {
            .from(code: c, message: nil, status: status, latestVersion: nil, issues: [])
        }
        #expect(code("workspace_required", 403) == .workspaceRequired)
        #expect(code("workspace_suspended", 409) == .workspaceSuspended)
        #expect(code("workspace_role", 403) == .workspaceRole)
        #expect(code("invalid_workspace_attestation", 400) == .workspaceAttestationRejected(code: "invalid_workspace_attestation"))
        #expect(code("attestation_not_signer", 403) == .workspaceAttestationRejected(code: "attestation_not_signer"))
        #expect(code("workspace_attestations_missing", 400) == .invalidVisibility(code: "workspace_attestations_missing"))
    }

    @Test
    func anOlderRegistrysFormatRejectionSaysTheStoreIsBehind() {
        let tooNew = WorkflowsRegistryAPIError.from(
            code: "invalid_template", message: nil, status: 422, latestVersion: nil,
            issues: [.init(path: "format_version", message: "4 is newer than this registry understands")])
        #expect(tooNew == .storeOutdated(.newerFormat))
        let bundled = WorkflowsRegistryAPIError.from(
            code: "invalid_template", message: nil, status: 422, latestVersion: nil,
            issues: [.init(path: "bundled[0].format_version", message: "4 is newer than this registry understands")])
        #expect(bundled == .storeOutdated(.newerFormat))
        let other = WorkflowsRegistryAPIError.from(
            code: "invalid_template", message: nil, status: 422, latestVersion: nil,
            issues: [.init(path: "name", message: "must be a non-empty string")])
        guard case .templateRejected = other else {
            Issue.record("a real template problem stays a template problem: \(other)")
            return
        }
        #expect(tooNew.errorDescription?.contains("agent steps") == true)
    }

    @Test
    func aWorkspaceShareAgainstAnOlderRegistryLeavesThePageUnlistedAndSaysWhy() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"o1","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.hiddenPublishJSON())
            case ("PUT", "/workflows/\(Self.registryID)/visibility"): return (400, #"{"error":"invalid_visibility"}"#)
            default: return (404, "{}")
            }
        }
        try await withService(workspaceAttestation: { "att-\($0)" }) { service, records in
            let template = Self.template()
            let outcome = try await service.share(template, visibility: .workspace, workspaceIDs: [Self.workspaceA])
            #expect(outcome.visibilityError == .api(.storeOutdated(.workspaces)))
            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.visibility == .hidden && record.workspaceIDs.isEmpty)
        }
    }

    @Test
    func aPasswordRejectionIsNotMistakenForAnOlderRegistry() {
        let body = try? WorkflowsRegistryAPIClient.visibilityBody(.password, password: "secret1")
        #expect(body.map(WorkflowsRegistryAPIClient.requestsWorkspace) == false)
        let workspace = try? WorkflowsRegistryAPIClient.visibilityBody(.workspace, password: nil, workspaceAttestations: ["a"])
        #expect(workspace.map(WorkflowsRegistryAPIClient.requestsWorkspace) == true)
    }

    @Test
    func anOlderRegistryWithoutWorkspaceRoutesSaysTheStoreIsBehind() async throws {
        for (status, body) in [(404, #"{"error":"not_found"}"#), (405, #"{"error":"method_not_allowed"}"#)] {
            RegistryStub.shared.reset { _, _ in (status, body) }
            await #expect(throws: WorkflowsRegistryAPIError.storeOutdated(.workspaces)) {
                _ = try await Self.client().fetchWorkspaceWorkflows(workspaceID: Self.workspaceA, attestation: "att")
            }
        }
    }

    @Test
    func publishingToWorkspacesPublishesUnlistedThenSendsOneAttestationPerWorkspace() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"w1","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.hiddenPublishJSON())
            case ("PUT", "/workflows/\(Self.registryID)/visibility"):
                return (
                    200,
                    #"{"ok":true,"visibility":"workspace","workspace_ids":["\#(Self.workspaceA)","\#(Self.workspaceB)"]}"#
                )
            default: return (404, "{}")
            }
        }
        let minted = MintLog()
        try await withService(workspaceAttestation: { id in
            await minted.note(id)
            return "att-\(id)"
        }) { service, records in
            let template = Self.template()
            let outcome = try await service.share(
                template, visibility: .workspace, workspaceIDs: [Self.workspaceA, Self.workspaceB, Self.workspaceA])
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()

            let calls = RegistryStub.shared.calls
            #expect(
                calls.map(Self.path)
                    == ["/auth/challenge", "/workflows", "/auth/challenge", "/workflows/\(Self.registryID)/visibility"])
            #expect(calls[1].request.value(forHTTPHeaderField: "X-Workflow-Visibility") == "hidden",
                "a workspace page is unlisted until the workspaces land")
            let put = calls[3]
            let body = try #require(put.body)
            #expect(
                String(decoding: body, as: UTF8.self)
                    == #"{"visibility":"workspace","workspace_attestations":["att-\#(Self.workspaceA)","att-\#(Self.workspaceB)"]}"#)
            #expect(put.request.url?.query == nil, "attestations never ride in a URL")
            let message = WorkflowShareService.visibilityMessage(
                address: alice, registryID: Self.registryID, bodyHash: WorkflowShareService.sha256Hex(body),
                nonce: "w1", timestamp: 1_800_000_000)
            #expect(try Self.signer(of: put, message: message) == alice)
            #expect(await minted.ids == [Self.workspaceA, Self.workspaceB], "one mint per workspace, deduplicated")

            #expect(outcome.visibilityError == nil)
            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.visibility == .workspace)
            #expect(record.workspaceIDs == [Self.workspaceA, Self.workspaceB])
            #expect(!record.isListed)
        }
    }

    @Test
    func aWorkspaceShareIsRefusedBeforeAnythingIsSent_withoutAWorkspace() async throws {
        RegistryStub.shared.reset { _, _ in (500, "{}") }
        try await withService { service, _ in
            await #expect(throws: WorkflowShareError.invalidWorkspaces) {
                try await service.share(Self.template(), visibility: .workspace, workspaceIDs: [])
            }
            #expect(RegistryStub.shared.calls.isEmpty)
        }
    }

    @Test
    func anAttestationThatCantBeMintedLeavesThePageLiveAndUnlisted() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"w","expires_in":60}"#)
            case ("POST", "/workflows"): return (201, Self.hiddenPublishJSON())
            default: return (500, "{}")
            }
        }
        try await withService(workspaceAttestation: { _ in throw WorkspaceAttestationMintError.suspended }) {
            service, records in
            let template = Self.template()
            let outcome = try await service.share(template, visibility: .workspace, workspaceIDs: [Self.workspaceA])
            #expect(
                outcome.visibilityError
                    == .workspaceAttestation(WorkspaceAttestationMintError.suspended.localizedDescription))
            #expect(!RegistryStub.shared.calls.contains { $0.request.httpMethod == "PUT" })
            let record = try #require(records.record(for: template.id, registry: Self.base))
            #expect(record.visibility == .hidden && record.isLive && record.workspaceIDs.isEmpty)
        }
    }

    @Test
    func theWorkspaceCatalogIsReadWithTheAttestationHeader() async throws {
        let templateID = UUID()
        RegistryStub.shared.reset { request, _ in
            guard request.url?.path == "/workspaces/\(Self.workspaceA)/workflows" else { return (404, "{}") }
            let raw = "https://registry.test/workflows/\(Self.registryID)/versions/2/template.json"
            return (
                200,
                """
                {"workspace_id":"\(Self.workspaceA)","items":[{"id":"\(Self.registryID)","kind":"agent",\
                "slug":"client-intake","name":"Client Intake","summary":"Sorts leads.",\
                "template_id":"\(templateID.uuidString.lowercased())",\
                "author":{"address":"0xABCDEF0123456789abcdef0123456789abcdef01","osaurus_id":"alice"},\
                "visibility":"workspace","latest_version":2,"shared_at":"2026-03-01T00:00:00.000Z",\
                "raw_url":"\(raw)","deep_link":"osaurus://templates-import?url=x"},{"id":"broken"}],\
                "total":2,"next_offset":null}
                """
            )
        }
        try await withService { service, _ in
            let items = try await service.workspaceWorkflows(workspaceID: Self.workspaceA)
            #expect(items.count == 1, "an unreadable row is skipped, not fatal")
            let item = try #require(items.first)
            #expect(item.kind == .agent && item.templateID == templateID && item.latestVersion == 2)
            #expect(item.author.handle == "@alice")
            let call = try #require(RegistryStub.shared.calls.last)
            #expect(call.request.value(forHTTPHeaderField: "X-Workspace-Attestation") == "att-\(Self.workspaceA)")
            #expect(call.request.value(forHTTPHeaderField: "X-Signature") == nil, "reading needs no key")
            let query = call.request.url?.query ?? ""
            #expect(query.contains("att-") == false)
        }
    }

    @Test
    func takingAListingOutOfAWorkspaceIsSigned_andModeratorsAddTheirAttestation() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"u1","expires_in":60}"#)
            case ("DELETE", "/workspaces/\(Self.workspaceA)/workflows/\(Self.registryID)"):
                return (200, #"{"ok":true,"removed":true,"workspace_ids":["\#(Self.workspaceB)"]}"#)
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            let template = Self.template()
            var record = WorkflowRegistryRecord(
                templateID: template.id, registryID: Self.registryID, slug: "client-intake", version: 1,
                contentHash: "sha256:00", url: URL(string: "https://web.test/w/client-intake")!,
                rawURL: URL(string: "https://registry.test/raw")!, deepLink: URL(string: "osaurus://x")!,
                address: "0xabc", registry: WorkflowRegistryRecordStore.registryKey(Self.base), sharedAt: Self.now,
                visibility: .workspace)
            record.workspaceIDs = [Self.workspaceA, Self.workspaceB]
            records.set(record)
            let alice = try deriveOsaurusId(from: TestKeys.alicePrivateKey).lowercased()

            let remaining = try await service.unshare(registryID: Self.registryID, fromWorkspace: Self.workspaceA)
            #expect(remaining == [Self.workspaceB])
            let delete = try #require(RegistryStub.shared.calls.last)
            #expect(delete.request.value(forHTTPHeaderField: "X-Workspace-Attestation") == nil, "the author needs none")
            let message = WorkflowShareService.unshareMessage(
                address: alice, registryID: Self.registryID, workspaceID: Self.workspaceA, nonce: "u1",
                timestamp: 1_800_000_000)
            #expect(try Self.signer(of: delete, message: message) == alice)
            #expect(records.record(for: template.id, registry: Self.base)?.workspaceIDs == [Self.workspaceB])

            _ = try await service.unshare(
                registryID: Self.registryID, fromWorkspace: Self.workspaceA, moderating: true)
            #expect(
                RegistryStub.shared.calls.last?.request.value(forHTTPHeaderField: "X-Workspace-Attestation")
                    == "att-\(Self.workspaceA)")
        }
    }

    @Test
    func leavingAWorkspaceTakesOnlyTheListingsSharedThereOut() async throws {
        RegistryStub.shared.reset { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/auth/challenge"): return (200, #"{"nonce":"l","expires_in":60}"#)
            case ("DELETE", _): return (200, #"{"ok":true,"removed":true,"workspace_ids":[]}"#)
            default: return (404, "{}")
            }
        }
        try await withService { service, records in
            @MainActor func record(_ id: String, _ visibility: WorkflowVisibility, _ workspaces: [String])
                -> WorkflowRegistryRecord
            {
                var r = WorkflowRegistryRecord(
                    templateID: UUID(), registryID: id, slug: id, version: 1, contentHash: "", url: Self.base,
                    rawURL: Self.base, deepLink: Self.base, address: "0xabc",
                    registry: WorkflowRegistryRecordStore.registryKey(Self.base), sharedAt: Self.now,
                    visibility: visibility)
                r.workspaceIDs = workspaces
                return r
            }
            let shared = record("in-a", .workspace, [Self.workspaceA])
            records.set(shared)
            records.set(record("in-b", .workspace, [Self.workspaceB]))
            records.set(record("public", .public, []))

            let failed = await service.unshareAll(fromWorkspace: Self.workspaceA.uppercased())
            #expect(failed.isEmpty)
            let deletes = RegistryStub.shared.calls.filter { $0.request.httpMethod == "DELETE" }.map(Self.path)
            #expect(deletes == ["/workspaces/\(Self.workspaceA)/workflows/in-a"])
            #expect(records.record(for: shared.templateID, registry: Self.base)?.workspaceIDs == [])
        }
    }

    @Test
    func anOwnerListRowCarriesItsWorkspaces_andAnyOtherVisibilityClearsThem() throws {
        let templateID = UUID()
        let workspaceRow = Self.detailJSON(templateID: templateID, visibility: "workspace")
            .replacingOccurrences(of: "\"versions\":", with: "\"workspace_ids\":[\"\(Self.workspaceA)\"],\"versions\":")
        let detail = try WorkflowsRegistryAPIClient.decode(WorkflowsRegistryDetail.self, from: Data(workspaceRow.utf8))
        #expect(detail.visibility == .workspace && detail.workspaceIDs == [Self.workspaceA])

        var record = WorkflowRegistryRecord(
            templateID: templateID, registryID: Self.registryID, slug: "client-intake", version: 1, contentHash: "",
            url: Self.base, rawURL: Self.base, deepLink: Self.base, address: "0xabc", registry: "https://registry.test",
            sharedAt: Self.now)
        record.apply(detail, at: Self.now)
        #expect(record.workspaceIDs == [Self.workspaceA])

        let silent = try WorkflowsRegistryAPIClient.decode(
            WorkflowsRegistryDetail.self, from: Data(Self.detailJSON(templateID: templateID, visibility: "workspace").utf8))
        record.apply(silent, at: Self.now)
        #expect(record.workspaceIDs == [Self.workspaceA], "an answer that doesn't say keeps the last set")

        let unlisted = try WorkflowsRegistryAPIClient.decode(
            WorkflowsRegistryDetail.self, from: Data(Self.detailJSON(templateID: templateID, visibility: "hidden").utf8))
        record.apply(unlisted, at: Self.now)
        #expect(record.workspaceIDs.isEmpty)

        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(WorkflowRegistryRecord.self, from: encoded).workspaceIDs.isEmpty)
    }
}

private actor MintLog {
    private(set) var ids: [String] = []
    func note(_ id: String) { ids.append(id) }
}

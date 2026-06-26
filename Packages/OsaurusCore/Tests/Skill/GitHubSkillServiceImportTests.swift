//
//  GitHubSkillServiceImportTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct GitHubSkillServiceImportTests {
    @Test func authenticatedRequestsPreferExplicitToken() async throws {
        let log = RequestLog()
        let service = makeService(
            log: log,
            tokenProvider: GitHubImportTokenProvider(
                explicitToken: { "explicit-token" },
                environment: { ["GH_TOKEN": "env-token"] }
            )
        ) { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(githubImportMarketplaceJSON)
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        _ = try await service.fetchMarketplaceCatalog(from: "acme/widgets")

        let requests = log.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer explicit-token" })
    }

    @Test func unauthenticatedRequestsOmitAuthorizationHeader() async throws {
        let log = RequestLog()
        let service = makeService(
            log: log,
            tokenProvider: GitHubImportTokenProvider(
                explicitToken: { nil },
                environment: { [:] }
            )
        ) { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(githubImportMarketplaceJSON)
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        _ = try await service.fetchMarketplaceCatalog(from: "acme/widgets")

        #expect(log.requests().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func rateLimitDiagnosticsCover403And429() async throws {
        let reset = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let authenticated = makeService(
            tokenProvider: GitHubImportTokenProvider(explicitToken: { "token" })
        ) { _ in
            .init(
                status: 403,
                body: Data(),
                headers: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": "\(reset)",
                ]
            )
        }
        defer { authenticated.invalidateForTests() }

        do {
            _ = try await authenticated.fetchMarketplaceCatalog(from: "acme/widgets")
            Issue.record("Expected authenticated 403 rate limit")
        } catch let error as GitHubSkillError {
            guard case .rateLimited(let resetAt, _, let isAuthenticated) = error else {
                Issue.record("Expected rateLimited, got \(error)")
                return
            }
            #expect(isAuthenticated)
            #expect(resetAt != nil)
            #expect(error.localizedDescription.contains("Authenticated GitHub API"))
        }

        let throttled = makeService { _ in
            .init(
                status: 429,
                body: Data(),
                headers: ["Retry-After": "17"]
            )
        }
        defer { throttled.invalidateForTests() }

        do {
            _ = try await throttled.fetchMarketplaceCatalog(from: "acme/widgets")
            Issue.record("Expected 429 rate limit")
        } catch let error as GitHubSkillError {
            guard case .rateLimited(_, let retryAfter, let isAuthenticated) = error else {
                Issue.record("Expected rateLimited, got \(error)")
                return
            }
            #expect(!isAuthenticated)
            #expect(retryAfter == 17)
            #expect(error.localizedDescription.contains("17 seconds"))
        }
    }

    @Test func truncatedRecursiveTreeStopsImport() async throws {
        let service = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(
                    #"""
                    {"name":"fixture","plugins":[{"name":"one","source":"./one"}]}
                    """#
                )
            case "/repos/acme/widgets/git/trees/main":
                return .json(#"{"sha":"root","truncated":true,"tree":[]}"#)
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        do {
            _ = try await service.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected tree truncation error")
        } catch let error as GitHubSkillError {
            guard case .treeTruncated(let repo) = error else {
                Issue.record("Expected treeTruncated, got \(error)")
                return
            }
            #expect(repo == "acme/widgets")
            #expect(error.localizedDescription.contains("partial plugin"))
        }
    }

    @Test func resumesFromManifestCheckpointAndDeletesItAfterSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-github-import-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = GitHubImportCheckpointStore(directory: directory)
        let repo = GitHubRepo(owner: "acme", name: "widgets", branch: "main")
        let cached = ClaudePluginManifest(
            name: "one",
            description: "cached",
            source: "one",
            sourceRepo: repo,
            skills: [ClaudeSkillEntry(path: "one/skills/alpha")]
        )
        let checkpointMarketplace = GitHubMarketplace(
            name: "fixture",
            owner: nil,
            metadata: nil,
            plugins: [
                MarketplacePlugin(name: "one", source: .localDirectory("./one")),
                MarketplacePlugin(name: "two", source: .localDirectory("./two")),
            ]
        )
        store.save(
            GitHubImportCheckpoint(
                repo: repo,
                marketplacePluginNames: ["one", "two"],
                marketplaceFingerprint: GitHubImportCheckpoint.fingerprint(for: checkpointMarketplace),
                manifests: [cached]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let log = RequestLog()
        let service = makeService(log: log, checkpointStore: store) { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(
                    #"""
                    {
                      "name": "fixture",
                      "plugins": [
                        {"name": "one", "source": "./one"},
                        {"name": "two", "source": "./two"}
                      ]
                    }
                    """#
                )
            case "/repos/acme/widgets/git/trees/main":
                return .json(
                    #"""
                    {
                      "sha": "rootsha",
                      "truncated": false,
                      "tree": [
                        {"path":"two","type":"tree","sha":"two-sha"},
                        {"path":"two/skills","type":"tree","sha":"skills-sha"},
                        {"path":"two/skills/beta","type":"tree","sha":"beta-sha"},
                        {"path":"two/skills/beta/SKILL.md","type":"blob","size":42,"sha":"skill-sha"}
                      ]
                    }
                    """#
                )
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        let result = try await service.fetchPlugins(from: "acme/widgets")

        #expect(result.plugins.map(\.name) == ["one", "two"])
        #expect(result.plugins[0].skills.map(\.path) == ["one/skills/alpha"])
        #expect(result.plugins[1].skills.map(\.path) == ["two/skills/beta"])
        #expect(store.load(repo: repo) == nil)
        #expect(log.requests().filter { $0.url?.path == "/repos/acme/widgets/git/trees/main" }.count == 1)
    }

    @Test func checkpointCompatibilityRejectsChangedMarketplaceSources() {
        let repo = GitHubRepo(owner: "acme", name: "widgets", branch: "main")
        let original = GitHubMarketplace(
            name: "fixture",
            owner: nil,
            metadata: nil,
            plugins: [
                MarketplacePlugin(name: "one", source: .localDirectory("./one")),
                MarketplacePlugin(name: "two", source: .localDirectory("./two")),
            ]
        )
        let changed = GitHubMarketplace(
            name: "fixture",
            owner: nil,
            metadata: nil,
            plugins: [
                MarketplacePlugin(name: "one", source: .localDirectory("./renamed-one")),
                MarketplacePlugin(name: "two", source: .localDirectory("./two")),
            ]
        )
        let checkpoint = GitHubImportCheckpoint(
            repo: repo,
            marketplacePluginNames: original.plugins.map(\.name),
            marketplaceFingerprint: GitHubImportCheckpoint.fingerprint(for: original),
            manifests: []
        )

        #expect(checkpoint.isCompatible(repo: repo, marketplace: original))
        #expect(!checkpoint.isCompatible(repo: repo, marketplace: changed))
    }

    @Test func redactsGitHubTokensAndSecretBearingURLs() {
        let raw =
            "Authorization: Bearer github_pat_1234567890abcdef1234567890 https://api.github.com/x?access_token=ghp_1234567890abcdef1234567890&ok=1"
        let redacted = GitHubSecretRedactor.redact(raw)

        #expect(!redacted.contains("github_pat_"))
        #expect(!redacted.contains("ghp_"))
        #expect(redacted.contains("[REDACTED]"))

        let error = GitHubSkillError.invalidURL(
            "https://example.com/import?token=ghp_1234567890abcdef1234567890"
        )
        #expect(!(error.localizedDescription).contains("ghp_"))
    }

    private func makeService(
        log: RequestLog = RequestLog(),
        tokenProvider: any GitHubAuthTokenProviding = GitHubImportTokenProvider(
            explicitToken: { nil },
            environment: { [:] }
        ),
        checkpointStore: GitHubImportCheckpointStore = GitHubImportCheckpointStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-github-import-empty-\(UUID().uuidString)",
                isDirectory: true
            )
        ),
        handler: @escaping @Sendable (URLRequest) throws -> GitHubImportResponse
    ) -> GitHubSkillService {
        GitHubImportURLProtocol.handler = { request in
            log.append(request)
            return try handler(request)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubImportURLProtocol.self]
        let session = URLSession(configuration: config)
        return GitHubSkillService(
            session: session,
            tokenProvider: tokenProvider,
            checkpointStore: checkpointStore,
            limits: GitHubImportLimits(
                maxTreeEntries: 100,
                maxImportFilesPerPlugin: 20,
                maxFileBytes: 1024 * 1024,
                maxTotalBytesPerPlugin: 1024 * 1024,
                maxDepthBelowPluginRoot: 6
            )
        )
    }
}

private let githubImportMarketplaceJSON =
    #"""
    {"name":"fixture","plugins":[]}
    """#

private struct GitHubImportResponse: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]

    static func json(_ body: String, status: Int = 200) -> GitHubImportResponse {
        GitHubImportResponse(
            status: status,
            body: Data(body.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }

    static func text(_ body: String, status: Int = 200) -> GitHubImportResponse {
        GitHubImportResponse(
            status: status,
            body: Data(body.utf8),
            headers: ["Content-Type": "text/plain; charset=utf-8"]
        )
    }

    static func notFound() -> GitHubImportResponse {
        GitHubImportResponse(status: 404, body: Data(), headers: [:])
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class GitHubImportURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> GitHubImportResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let response = try handler(request)
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension GitHubSkillService {
    func invalidateForTests() {
        GitHubImportURLProtocol.handler = nil
    }
}

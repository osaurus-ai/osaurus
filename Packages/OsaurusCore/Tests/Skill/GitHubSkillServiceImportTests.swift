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

    @Test func rejectsAmbiguousOrNonGitHubImportURLs() throws {
        let service = makeService { _ in .notFound() }
        defer { service.invalidateForTests() }

        for raw in [
            "https://github.com.evil.test/acme/widgets",
            "https://evil.test/github.com/acme/widgets",
            "http://github.com/acme/widgets",
            "https://user:pass@github.com/acme/widgets",
            "https://github.com/acme/widgets?tab=readme",
            "https://github.com/acme/widgets#fragment",
            "https://github.com/acme/widgets/tree/main/plugin",
        ] {
            #expect(throws: GitHubSkillError.self) {
                try service.parseGitHubURL(raw)
            }
        }

        let repoURL = URL(string: "https://github.com/acme/widgets")!.absoluteString
        let repo = try service.parseGitHubURL(repoURL)
        #expect(repo.slug == "acme/widgets")
    }

    @Test func rejectsExternalMarketplaceSourcesThatAreNotGitHub() throws {
        let raw = #"""
            {
              "name": "fixture",
              "plugins": [
                {
                  "name": "evil",
                  "source": {
                    "source": "url",
                    "url": "https://github.com.evil.test/acme/plugin"
                  }
                }
              ]
            }
            """#
        let marketplace = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(raw.utf8)
        )

        #expect(marketplace.plugins.isEmpty)
    }

    @Test func rejectsMarketplaceSourcePathTraversalBeforeTreeFetch() async throws {
        let log = RequestLog()
        let service = makeService(log: log) { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(
                    #"""
                    {"name":"fixture","plugins":[{"name":"escape","source":"../escape"}]}
                    """#
                )
            case "/repos/acme/widgets/git/trees/main":
                Issue.record("Importer fetched the tree after rejecting source traversal")
                return .json(#"{"sha":"root","truncated":false,"tree":[]}"#)
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        do {
            _ = try await service.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected invalid source path")
        } catch let error as GitHubSkillError {
            guard case .invalidURL(let rejected) = error else {
                Issue.record("Expected invalidURL, got \(error)")
                return
            }
            #expect(rejected.contains(".."))
        }

        #expect(!log.requests().contains { $0.url?.path.contains("/git/trees/") == true })
    }

    @Test func rejectsInvalidGitRefBeforeSourceSHAFetch() async {
        let log = RequestLog()
        let service = makeService(log: log) { _ in
            Issue.record("Invalid refs must fail before network fetch")
            return .notFound()
        }
        defer { service.invalidateForTests() }

        let sha = await service.fetchSourceSHANonIsolated(
            owner: "acme",
            repo: "widgets",
            branch: "bad?ref",
            path: nil
        )

        #expect(sha == nil)
        #expect(log.requests().isEmpty)
    }

    @Test func percentEncodesGitRefWhenFetchingSourceSHA() async {
        let log = RequestLog()
        let service = makeService(log: log) { request in
            #expect(request.url?.path == "/repos/acme/widgets/commits")
            #expect(request.url?.fragment == nil)
            #expect(request.url?.query?.contains("sha=feature%2Ffoo%23bar") == true)
            return .json(#"[{"sha":"abc123"}]"#)
        }
        defer { service.invalidateForTests() }

        let sha = await service.fetchSourceSHANonIsolated(
            owner: "acme",
            repo: "widgets",
            branch: "feature/foo#bar",
            path: nil
        )

        #expect(sha == "abc123")
        #expect(log.requests().count == 1)
    }

    @Test func rejectsMarketplaceExternalRefWithInvalidGitRefBeforeTreeFetch() async throws {
        let log = RequestLog()
        let service = makeService(log: log) { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(
                    #"""
                    {
                      "name": "fixture",
                      "plugins": [
                        {
                          "name": "external",
                          "source": {
                            "source": "url",
                            "url": "https://github.com/acme/plugin.git",
                            "ref": "bad?ref"
                          }
                        }
                      ]
                    }
                    """#
                )
            case "/repos/acme/plugin/git/trees/bad":
                Issue.record("Invalid external refs must fail before tree fetch")
                return .notFound()
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        do {
            _ = try await service.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected invalid external ref")
        } catch let error as GitHubSkillError {
            guard case .invalidURL(let rejected) = error else {
                Issue.record("Expected invalidURL, got \(error)")
                return
            }
            #expect(rejected == "acme/plugin")
        }

        #expect(!log.requests().contains { $0.url?.path.contains("/repos/acme/plugin/git/trees") == true })
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

    @Test func duplicateRecursiveTreePathsStopImportWithoutTrapping() async throws {
        let service = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(#"{"name":"fixture","plugins":[{"name":"one","source":"./one"}]}"#)
            case "/repos/acme/widgets/git/trees/main":
                return .json(
                    #"""
                    {
                      "sha": "root",
                      "truncated": false,
                      "tree": [
                        {"path":"one","type":"tree","sha":"one-a"},
                        {"path":"one","type":"tree","sha":"one-b"}
                      ]
                    }
                    """#
                )
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        do {
            _ = try await service.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected duplicate tree path to stop import")
        } catch let error as GitHubSkillError {
            guard case .importTooLarge(let reason) = error else {
                Issue.record("Expected importTooLarge, got \(error)")
                return
            }
            #expect(reason.contains("duplicate tree path"))
        }
    }

    @Test func importBoundsRejectTooManyTreeEntries() async throws {
        let entries = (0..<101)
            .map { #"{"path":"one/file\#($0).md","type":"blob","size":1,"sha":"s\#($0)"}"# }
            .joined(separator: ",")
        let service = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(#"{"name":"fixture","plugins":[{"name":"one","source":"./one"}]}"#)
            case "/repos/acme/widgets/git/trees/main":
                return .json(#"{"sha":"root","truncated":false,"tree":[\#(entries)]}"#)
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        do {
            _ = try await service.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected tree entry bound to stop import")
        } catch let error as GitHubSkillError {
            guard case .importTooLarge(let reason) = error else {
                Issue.record("Expected importTooLarge, got \(error)")
                return
            }
            #expect(reason.contains("101 tree entries"))
        }
    }

    @Test func importBoundsRejectTooManyPluginFiles() async throws {
        let files = (0..<21)
            .map { #"{"path":"one/file\#($0).md","type":"blob","size":1,"sha":"s\#($0)"}"# }
            .joined(separator: ",")
        let service = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(#"{"name":"fixture","plugins":[{"name":"one","source":"./one"}]}"#)
            case "/repos/acme/widgets/git/trees/main":
                return .json(#"{"sha":"root","truncated":false,"tree":[{"path":"one","type":"tree","sha":"one-sha"},\#(files)]}"#)
            default:
                return .notFound()
            }
        }
        defer { service.invalidateForTests() }

        do {
            _ = try await service.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected file-count bound to stop import")
        } catch let error as GitHubSkillError {
            guard case .importTooLarge(let reason) = error else {
                Issue.record("Expected importTooLarge, got \(error)")
                return
            }
            #expect(reason.contains("21 files"))
        }
    }

    @Test func importBoundsRejectUnknownAndExcessiveDeclaredSizes() async throws {
        let unknownSizeService = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(#"{"name":"fixture","plugins":[{"name":"one","source":"./one"}]}"#)
            case "/repos/acme/widgets/git/trees/main":
                return .json(
                    #"""
                    {
                      "sha":"root",
                      "truncated":false,
                      "tree":[
                        {"path":"one","type":"tree","sha":"one-sha"},
                        {"path":"one/skills","type":"tree","sha":"skills-sha"},
                        {"path":"one/skills/alpha","type":"tree","sha":"alpha-sha"},
                        {"path":"one/skills/alpha/SKILL.md","type":"blob","sha":"skill-sha"}
                      ]
                    }
                    """#
                )
            default:
                return .notFound()
            }
        }
        defer { unknownSizeService.invalidateForTests() }

        do {
            _ = try await unknownSizeService.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected unknown file size to stop import")
        } catch let error as GitHubSkillError {
            guard case .importTooLarge(let reason) = error else {
                Issue.record("Expected importTooLarge, got \(error)")
                return
            }
            #expect(reason.contains("unknown sizes"))
        }

        let overTotalService = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(#"{"name":"fixture","plugins":[{"name":"one","source":"./one"}]}"#)
            case "/repos/acme/widgets/git/trees/main":
                return .json(
                    #"""
                    {
                      "sha":"root",
                      "truncated":false,
                      "tree":[
                        {"path":"one","type":"tree","sha":"one-sha"},
                        {"path":"one/skills","type":"tree","sha":"skills-sha"},
                        {"path":"one/skills/alpha","type":"tree","sha":"alpha-sha"},
                        {"path":"one/skills/alpha/SKILL.md","type":"blob","size":700000,"sha":"skill-sha"},
                        {"path":"one/references/manual.md","type":"blob","size":700000,"sha":"manual-sha"}
                      ]
                    }
                    """#
                )
            default:
                return .notFound()
            }
        }
        defer { overTotalService.invalidateForTests() }

        do {
            _ = try await overTotalService.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected total byte bound to stop import")
        } catch let error as GitHubSkillError {
            guard case .importTooLarge(let reason) = error else {
                Issue.record("Expected importTooLarge, got \(error)")
                return
            }
            #expect(reason.contains("declares 1400000 bytes"))
        }
    }

    @Test func importBoundsRejectDeepPluginTreesAndLargeFetchedFiles() async throws {
        let deepTreeService = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(#"{"name":"fixture","plugins":[{"name":"one","source":"./one"}]}"#)
            case "/repos/acme/widgets/git/trees/main":
                return .json(
                    #"""
                    {
                      "sha":"root",
                      "truncated":false,
                      "tree":[
                        {"path":"one","type":"tree","sha":"one-sha"},
                        {"path":"one/a/b/c/d/e/f/g/file.md","type":"blob","size":1,"sha":"deep-sha"}
                      ]
                    }
                    """#
                )
            default:
                return .notFound()
            }
        }
        defer { deepTreeService.invalidateForTests() }

        do {
            _ = try await deepTreeService.fetchPlugins(from: "acme/widgets")
            Issue.record("Expected tree-depth bound to stop import")
        } catch let error as GitHubSkillError {
            guard case .importTooLarge(let reason) = error else {
                Issue.record("Expected importTooLarge, got \(error)")
                return
            }
            #expect(reason.contains("levels deep"))
        }

        let largeFileService = makeService { request in
            switch request.url?.path {
            case "/repos/acme/widgets/contents/one/skills/alpha/SKILL.md":
                return .init(
                    status: 200,
                    body: Data(repeating: UInt8(ascii: "a"), count: 1_048_577),
                    headers: ["Content-Type": "text/plain; charset=utf-8"]
                )
            default:
                return .notFound()
            }
        }
        defer { largeFileService.invalidateForTests() }

        do {
            _ = try await largeFileService.fetchFileContent(
                from: GitHubRepo(owner: "acme", name: "widgets", branch: "main"),
                path: "one/skills/alpha/SKILL.md"
            )
            Issue.record("Expected max file byte bound to stop fetch")
        } catch let error as GitHubSkillError {
            guard case .importTooLarge(let reason) = error else {
                Issue.record("Expected importTooLarge, got \(error)")
                return
            }
            #expect(reason.contains("1048577 bytes"))
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
                sourceFingerprints: ["one": "acme/widgets@main:one:one-sha"],
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
                        {"path":"one","type":"tree","sha":"one-sha"},
                        {"path":"one/skills","type":"tree","sha":"one-skills-sha"},
                        {"path":"one/skills/alpha","type":"tree","sha":"alpha-sha"},
                        {"path":"one/skills/alpha/SKILL.md","type":"blob","size":42,"sha":"alpha-skill-sha"},
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

    @Test func staleCheckpointIsIgnoredWhenSourceTreeChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-github-import-stale-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = GitHubImportCheckpointStore(directory: directory)
        let repo = GitHubRepo(owner: "acme", name: "widgets", branch: "main")
        let marketplace = GitHubMarketplace(
            name: "fixture",
            owner: nil,
            metadata: nil,
            plugins: [MarketplacePlugin(name: "one", source: .localDirectory("./one"))]
        )
        store.save(
            GitHubImportCheckpoint(
                repo: repo,
                marketplacePluginNames: ["one"],
                marketplaceFingerprint: GitHubImportCheckpoint.fingerprint(for: marketplace),
                sourceFingerprints: ["one": "acme/widgets@main:one:old-sha"],
                manifests: [
                    ClaudePluginManifest(
                        name: "one",
                        description: "cached",
                        source: "one",
                        sourceRepo: repo,
                        skills: [ClaudeSkillEntry(path: "one/skills/stale")]
                    )
                ]
            )
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let service = makeService(checkpointStore: store) { request in
            switch request.url?.path {
            case "/repos/acme/widgets":
                return .json(#"{"default_branch":"main"}"#)
            case "/repos/acme/widgets/contents/.claude-plugin/marketplace.json":
                return .text(#"{"name":"fixture","plugins":[{"name":"one","source":"./one"}]}"#)
            case "/repos/acme/widgets/git/trees/main":
                return .json(
                    #"""
                    {
                      "sha": "rootsha",
                      "truncated": false,
                      "tree": [
                        {"path":"one","type":"tree","sha":"new-sha"},
                        {"path":"one/skills","type":"tree","sha":"skills-sha"},
                        {"path":"one/skills/fresh","type":"tree","sha":"fresh-sha"},
                        {"path":"one/skills/fresh/SKILL.md","type":"blob","size":42,"sha":"skill-sha"}
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

        #expect(result.plugins.map(\.name) == ["one"])
        #expect(result.plugins[0].skills.map(\.path) == ["one/skills/fresh"])
        #expect(store.load(repo: repo) == nil)
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
        let legacyPAT = String(repeating: "a", count: 40)
        let raw =
            "Authorization: Bearer github_pat_1234567890abcdef1234567890 Bearer \(legacyPAT) https://api.github.com/x?access_token=ghp_1234567890abcdef1234567890&ok=1"
        let redacted = GitHubSecretRedactor.redact(raw)

        #expect(!redacted.contains("github_pat_"))
        #expect(!redacted.contains("ghp_"))
        #expect(!redacted.contains(legacyPAT))
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

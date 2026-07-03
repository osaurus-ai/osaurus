//
//  GitHubSkillServiceTokenTests.swift
//  OsaurusCoreTests
//
//  Covers the #1719 token-resolution helper: precedence, trimming, and
//  blank-handling over an explicit environment (no process-env mutation).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct GitHubSkillServiceTokenTests {
    private let keychainAvailable: @Sendable () -> Bool = { false }
    private let keychainUnavailable: @Sendable () -> Bool = { true }
    private let inMemoryStore: @Sendable () -> Bool = { true }

    @Test func returnsNilWhenNeitherKeySet() {
        #expect(GitHubSkillService.gitHubToken(from: [:]) == nil)
        #expect(GitHubSkillService.gitHubToken(from: ["UNRELATED": "x"]) == nil)
    }

    @Test func readsGitHubToken() {
        #expect(GitHubSkillService.gitHubToken(from: ["GITHUB_TOKEN": "ghp_abc"]) == "ghp_abc")
    }

    @Test func fallsBackToGhToken() {
        #expect(GitHubSkillService.gitHubToken(from: ["GH_TOKEN": "ghp_xyz"]) == "ghp_xyz")
    }

    @Test func ghTokenWinsOverGitHubToken() {
        let env = ["GITHUB_TOKEN": "primary", "GH_TOKEN": "secondary"]
        #expect(GitHubSkillService.gitHubToken(from: env) == "secondary")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(GitHubSkillService.gitHubToken(from: ["GITHUB_TOKEN": "  ghp_trim\n"]) == "ghp_trim")
    }

    @Test func blankValuesAreTreatedAsAbsent() {
        #expect(GitHubSkillService.gitHubToken(from: ["GITHUB_TOKEN": ""]) == nil)
        #expect(GitHubSkillService.gitHubToken(from: ["GITHUB_TOKEN": "   \t \n"]) == nil)
    }

    @Test func blankPrimaryFallsThroughToSecondary() {
        let env = ["GH_TOKEN": "   ", "GITHUB_TOKEN": "fallback-token"]
        #expect(GitHubSkillService.gitHubToken(from: env) == "fallback-token")
    }

    @Test func controlCharacterTokensAreIgnored() {
        #expect(GitHubImportTokenKeychain.normalizedToken("line\nbreak") == nil)
        #expect(GitHubImportTokenKeychain.normalizedToken("carriage\rreturn") == nil)
        #expect(GitHubImportTokenKeychain.normalizedToken("tab\tchar") == nil)

        let env = ["GH_TOKEN": "bad\nvalue", "GITHUB_TOKEN": "fallback-token"]
        #expect(GitHubSkillService.gitHubToken(from: env) == "fallback-token")
    }

    @Test func tokenProviderPrecedenceIsExplicitSavedThenEnvironment() {
        let explicit = GitHubImportTokenProvider(
            explicitToken: { " explicit-token " },
            savedToken: { "saved-token" },
            environment: { ["GH_TOKEN": "env-token"] }
        ).token()
        #expect(explicit?.value == "explicit-token")
        #expect(explicit?.source == .explicit)

        let saved = GitHubImportTokenProvider(
            explicitToken: { nil },
            savedToken: { " saved-token " },
            environment: { ["GH_TOKEN": "env-token"] }
        ).token()
        #expect(saved?.value == "saved-token")
        #expect(saved?.source == .savedKeychain)

        let env = GitHubImportTokenProvider(
            explicitToken: { nil },
            savedToken: { nil },
            environment: { ["GITHUB_TOKEN": "github-env", "GH_TOKEN": "gh-env"] }
        ).token()
        #expect(env?.value == "gh-env")
        #expect(env?.source == .environment)
    }

    @Test func invalidExplicitTokenFallsThroughWithoutUsingBadValue() {
        let token = GitHubImportTokenProvider(
            explicitToken: { "bad\nexplicit" },
            savedToken: { "saved-token" },
            environment: { ["GH_TOKEN": "env-token"] }
        ).token()

        #expect(token?.value == "saved-token")
        #expect(token?.source == .savedKeychain)
    }

    @Test func importerKeychainRoundTripsWithoutPrefillingOrLeakingInvalidSaves() {
        _ = GitHubImportTokenKeychain.clearToken(
            keychainDisabled: keychainAvailable,
            useInMemoryStore: inMemoryStore
        )

        #expect(
            GitHubImportTokenKeychain.saveToken(
                "  saved-token\n",
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == .saved
        )
        #expect(
            GitHubImportTokenKeychain.getToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == "saved-token"
        )

        #expect(
            GitHubImportTokenKeychain.saveToken(
                "   ",
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == .ignoredBlank
        )
        #expect(
            GitHubImportTokenKeychain.getToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == "saved-token"
        )

        #expect(
            GitHubImportTokenKeychain.saveToken(
                "bad\r\nvalue",
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == .rejectedInvalid
        )
        #expect(
            GitHubImportTokenKeychain.getToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == "saved-token"
        )

        #expect(
            GitHubImportTokenKeychain.clearToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            )
        )
        #expect(
            GitHubImportTokenKeychain.getToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == nil
        )
    }

    @Test func disabledKeychainReturnsNilAndNoOpsWithoutTouchingStoredValue() {
        _ = GitHubImportTokenKeychain.clearToken(
            keychainDisabled: keychainAvailable,
            useInMemoryStore: inMemoryStore
        )
        defer {
            _ = GitHubImportTokenKeychain.clearToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            )
        }
        #expect(
            GitHubImportTokenKeychain.saveToken(
                "stored-token",
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == .saved
        )

        #expect(
            GitHubImportTokenKeychain.saveToken(
                "disabled-token",
                keychainDisabled: keychainUnavailable,
                useInMemoryStore: inMemoryStore
            ) == .unavailable
        )
        #expect(
            GitHubImportTokenKeychain.getToken(
                keychainDisabled: keychainUnavailable,
                useInMemoryStore: inMemoryStore
            ) == nil
        )
        #expect(
            GitHubImportTokenKeychain.clearToken(
                keychainDisabled: keychainUnavailable,
                useInMemoryStore: inMemoryStore
            )
        )
        #expect(
            GitHubImportTokenKeychain.getToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == "stored-token"
        )
    }

    @Test func importerTokenStorageIsScopedAwayFromOtherSecretServices() {
        #expect(GitHubImportTokenKeychain.keychainService != "ai.osaurus.tools")
        #expect(GitHubImportTokenKeychain.keychainService != "ai.osaurus.mcp")
        #expect(GitHubImportTokenKeychain.keychainService != "ai.osaurus.remote")
        #expect(GitHubImportTokenKeychain.keychainService != "ai.osaurus.agent-secrets")

        _ = GitHubImportTokenKeychain.saveToken(
            "saved-token",
            keychainDisabled: keychainAvailable,
            useInMemoryStore: inMemoryStore
        )
        #expect(
            GitHubImportTokenKeychain.clearToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            )
        )
        #expect(
            GitHubImportTokenKeychain.getToken(
                keychainDisabled: keychainAvailable,
                useInMemoryStore: inMemoryStore
            ) == nil
        )
    }

    @Test func checkpointAndErrorsDoNotSerializeResolvedTokenValue() throws {
        let sentinel = "sentinel-token-not-matched-by-redactor-\(UUID().uuidString)"
        let provider = GitHubImportTokenProvider(
            explicitToken: { nil },
            savedToken: { sentinel },
            environment: { [:] }
        )
        #expect(provider.token()?.value == sentinel)

        let repo = GitHubRepo(owner: "acme", name: "widgets", branch: "main")
        let checkpoint = GitHubImportCheckpoint(
            repo: repo,
            marketplacePluginNames: ["one"],
            marketplaceFingerprint: "fingerprint",
            sourceFingerprints: ["one": "acme/widgets@main:one:one-sha"],
            manifests: [
                ClaudePluginManifest(
                    name: "one",
                    description: "fixture",
                    source: "one",
                    sourceRepo: repo
                )
            ]
        )
        let encoded = try JSONEncoder().encode(checkpoint)
        let json = String(decoding: encoded, as: UTF8.self)
        let invalidURL = ["https:", "", "example.com", "not-github"].joined(separator: "/")

        #expect(!json.contains(sentinel))
        #expect(!GitHubSkillError.invalidURL(invalidURL).localizedDescription.contains(sentinel))
        #expect(
            !GitHubSkillError.rateLimited(
                resetAt: nil,
                retryAfter: nil,
                authenticated: true
            ).localizedDescription.contains(sentinel)
        )
    }

    // MARK: - resolveToken precedence (in-app keychain token vs env vars)

    @Test func storedTokenWinsOverEnvironment() {
        let env = ["GITHUB_TOKEN": "from_env"]
        #expect(GitHubSkillService.resolveToken(stored: "ghp_stored", environment: env) == "ghp_stored")
    }

    @Test func fallsBackToEnvironmentWhenNoStoredToken() {
        let env = ["GITHUB_TOKEN": "from_env"]
        #expect(GitHubSkillService.resolveToken(stored: nil, environment: env) == "from_env")
    }

    @Test func blankStoredTokenFallsBackToEnvironment() {
        let env = ["GH_TOKEN": "from_env"]
        #expect(GitHubSkillService.resolveToken(stored: "   \n", environment: env) == "from_env")
    }

    @Test func trimsStoredTokenThatWins() {
        #expect(GitHubSkillService.resolveToken(stored: "  ghp_stored\n", environment: [:]) == "ghp_stored")
    }

    @Test func returnsNilWhenNeitherStoredNorEnvironment() {
        #expect(GitHubSkillService.resolveToken(stored: nil, environment: [:]) == nil)
        #expect(GitHubSkillService.resolveToken(stored: "  ", environment: [:]) == nil)
    }
}

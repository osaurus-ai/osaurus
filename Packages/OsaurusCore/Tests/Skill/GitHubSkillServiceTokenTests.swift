//
//  GitHubSkillServiceTokenTests.swift
//  OsaurusCoreTests
//
//  Covers GitHub token resolution without mutating process environment or
//  reading the user's Keychain.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GitHubSkillServiceTokenTests {
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

    @Test func gitHubTokenWinsOverGhToken() {
        let env = ["GITHUB_TOKEN": "primary", "GH_TOKEN": "secondary"]
        #expect(GitHubSkillService.gitHubToken(from: env) == "primary")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(GitHubSkillService.gitHubToken(from: ["GITHUB_TOKEN": "  ghp_trim\n"]) == "ghp_trim")
    }

    @Test func blankValuesAreTreatedAsAbsent() {
        #expect(GitHubSkillService.gitHubToken(from: ["GITHUB_TOKEN": ""]) == nil)
        #expect(GitHubSkillService.gitHubToken(from: ["GITHUB_TOKEN": "   \t \n"]) == nil)
    }

    @Test func blankPrimaryFallsThroughToSecondary() {
        let env = ["GITHUB_TOKEN": "   ", "GH_TOKEN": "ghp_fallback"]
        #expect(GitHubSkillService.gitHubToken(from: env) == "ghp_fallback")
    }

    @Test func controlCharacterPrimaryFallsThroughToSecondary() {
        let env = ["GITHUB_TOKEN": "invalid\nvalue", "GH_TOKEN": "ghp_fallback"]
        #expect(GitHubSkillService.gitHubToken(from: env) == "ghp_fallback")
    }

    @Test func rejectsEmbeddedControlCharacters() {
        #expect(GitHubSkillService.normalizedAuthToken("ghp_line\nbreak") == nil)
        #expect(GitHubSkillService.normalizedAuthToken("ghp_carriage\rreturn") == nil)
        #expect(GitHubSkillService.normalizedAuthToken("ghp_tab\tcharacter") == nil)
        #expect(GitHubSkillService.normalizedAuthToken("ghp_null\0character") == nil)
    }

    @Test func providerPrefersConfiguredTokenOverEnvironment() throws {
        let provider = GitHubImportTokenProvider(
            explicitToken: { " configured " },
            environment: { ["GITHUB_TOKEN": "environment"] }
        )
        let token = try #require(provider.token())
        #expect(token.value == "configured")
        #expect(token.source == .explicit)
    }

    @Test func providerFallsBackWhenConfiguredTokenIsInvalid() throws {
        let provider = GitHubImportTokenProvider(
            explicitToken: { "invalid\tvalue" },
            environment: { ["GITHUB_TOKEN": "environment"] }
        )
        let token = try #require(provider.token())
        #expect(token.value == "environment")
        #expect(token.source == .environment)
    }

    @Test func storedTokenWinsOverEnvironment() {
        let env = ["GITHUB_TOKEN": "from_env"]
        #expect(GitHubSkillService.resolveToken(stored: "ghp_stored", environment: env) == "ghp_stored")
    }

    @Test func fallsBackToEnvironmentWhenNoStoredToken() {
        let env = ["GITHUB_TOKEN": "from_env"]
        #expect(GitHubSkillService.resolveToken(stored: nil, environment: env) == "from_env")
    }

    @Test func invalidStoredTokenFallsBackToEnvironment() {
        let env = ["GITHUB_TOKEN": "from_env"]
        #expect(GitHubSkillService.resolveToken(stored: "invalid\tvalue", environment: env) == "from_env")
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

    @Test func checkpointAndErrorsDoNotSerializeResolvedTokenValue() throws {
        let sentinel = "sentinel-token-not-matched-by-redactor-\(UUID().uuidString)"
        let provider = GitHubImportTokenProvider(
            explicitToken: { sentinel },
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
        let json = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
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
}

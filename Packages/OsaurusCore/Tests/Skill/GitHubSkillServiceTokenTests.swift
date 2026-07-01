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
}

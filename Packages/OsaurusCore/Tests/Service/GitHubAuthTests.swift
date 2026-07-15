//
//  GitHubAuthTests.swift
//  OsaurusCoreTests
//
//  Covers `GitHubAuth.normalize`: the pure trimming / blank-handling rule
//  shared by the token read and write paths, tested without the keychain.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GitHubAuthTests {
    @Test func keepsNonBlankToken() {
        #expect(GitHubAuth.normalize("ghp_abc") == "ghp_abc")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(GitHubAuth.normalize("  ghp_trim\n") == "ghp_trim")
        #expect(GitHubAuth.normalize("\tghp_tab ") == "ghp_tab")
    }

    @Test func treatsNilAsAbsent() {
        #expect(GitHubAuth.normalize(nil) == nil)
    }

    @Test func treatsEmptyAsAbsent() {
        #expect(GitHubAuth.normalize("") == nil)
    }

    @Test func treatsWhitespaceOnlyAsAbsent() {
        #expect(GitHubAuth.normalize("   ") == nil)
        #expect(GitHubAuth.normalize("\t \n") == nil)
    }
}

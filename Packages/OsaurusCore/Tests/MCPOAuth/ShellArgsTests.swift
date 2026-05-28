//
//  ShellArgsTests.swift
//  osaurus
//
//  Round-trip + edge-case coverage for `ShellArgs.split` / `.join` /
//  `.quote`. The editor save/load path depends on these being a true
//  inverse pair so a user can paste `--root '/path with spaces'`,
//  re-open the provider, and not have the path silently split into
//  two args.
//

import Foundation
import XCTest

@testable import OsaurusCore

final class ShellArgsTests: XCTestCase {

    // MARK: - Split

    func testSplitsOnWhitespace() throws {
        XCTAssertEqual(ShellArgs.split("a b c"), ["a", "b", "c"])
    }

    func testCollapsesRepeatedWhitespace() throws {
        XCTAssertEqual(ShellArgs.split("  a   b  "), ["a", "b"])
    }

    func testReturnsEmptyForBlankInput() throws {
        XCTAssertEqual(ShellArgs.split(""), [])
        XCTAssertEqual(ShellArgs.split("   "), [])
    }

    func testPreservesSingleQuotedSpaces() throws {
        XCTAssertEqual(
            ShellArgs.split("--root '/Users/me/long path'"),
            ["--root", "/Users/me/long path"]
        )
    }

    func testPreservesDoubleQuotedSpaces() throws {
        XCTAssertEqual(
            ShellArgs.split("--root \"/Users/me/long path\""),
            ["--root", "/Users/me/long path"]
        )
    }

    func testHonorsBackslashEscapeOutsideQuotes() throws {
        XCTAssertEqual(ShellArgs.split("a\\ b c"), ["a b", "c"])
    }

    func testAdjacentQuotedAndUnquotedConcatenate() throws {
        XCTAssertEqual(ShellArgs.split("foo'bar baz'"), ["foobar baz"])
    }

    func testEmptyQuotedStringYieldsEmptyArg() throws {
        XCTAssertEqual(ShellArgs.split("a '' b"), ["a", "", "b"])
    }

    /// POSIX double-quote rule: `\` is only an escape before `"`, `\`,
    /// `$`, backtick, or newline. Anything else keeps the backslash
    /// literal — important so `--regex "\d+"` round-trips cleanly.
    func testDoubleQuoteKeepsLiteralBackslashForNonEscapeChars() throws {
        XCTAssertEqual(ShellArgs.split("--regex \"\\d+\""), ["--regex", "\\d+"])
    }

    func testDoubleQuoteEscapesDoubleQuoteAndBackslash() throws {
        XCTAssertEqual(ShellArgs.split("\"a\\\"b\\\\c\""), ["a\"b\\c"])
    }

    func testTrailingBackslashIsLiteral() throws {
        XCTAssertEqual(ShellArgs.split("foo \\"), ["foo", "\\"])
    }

    // MARK: - Join / quote

    func testQuoteLeavesBareSafeTokensAlone() throws {
        XCTAssertEqual(ShellArgs.quote("npx"), "npx")
        XCTAssertEqual(ShellArgs.quote("--root"), "--root")
        XCTAssertEqual(ShellArgs.quote("/usr/local/bin/uvx"), "/usr/local/bin/uvx")
    }

    func testQuoteWrapsSpacesInSingleQuotes() throws {
        XCTAssertEqual(ShellArgs.quote("/path with spaces"), "'/path with spaces'")
    }

    func testQuoteEscapesEmbeddedSingleQuotes() throws {
        XCTAssertEqual(ShellArgs.quote("it's fine"), "'it'\\''s fine'")
    }

    func testQuoteHandlesEmptyString() throws {
        XCTAssertEqual(ShellArgs.quote(""), "''")
    }

    func testJoinRoundTripsThroughSplit() throws {
        let original = [
            "npx",
            "-y",
            "@scope/server-foo",
            "--root",
            "/Users/me/long path",
            "--flag=value with spaces",
        ]
        let joined = ShellArgs.join(original)
        XCTAssertEqual(ShellArgs.split(joined), original)
    }

    func testJoinRoundTripsThroughSplitWithSingleQuotes() throws {
        let original = ["echo", "it's working"]
        let joined = ShellArgs.join(original)
        XCTAssertEqual(ShellArgs.split(joined), original)
    }
}

final class MCPStdioTransportErrorTests: XCTestCase {

    /// The marker constant must appear verbatim in the localized
    /// description; ProviderCard's "Edit" hint relies on this round-trip.
    func testCommandNotFoundDescriptionContainsMarker() throws {
        let err = MCPStdioTransportError.commandNotFound(
            command: "npx",
            searchedPath: "/usr/bin"
        )
        let description = err.errorDescription ?? ""
        XCTAssertTrue(description.contains(MCPStdioTransportError.commandNotFoundMarker))
        XCTAssertTrue(MCPStdioTransportError.isCommandNotFoundMessage(description))
    }

    func testOtherErrorsDoNotMatchCommandNotFound() throws {
        let err = MCPStdioTransportError.processSpawnFailed("boom")
        let description = err.errorDescription ?? ""
        XCTAssertFalse(MCPStdioTransportError.isCommandNotFoundMessage(description))
    }
}

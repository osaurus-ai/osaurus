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
import Testing

@testable import OsaurusCore

struct ShellArgsTests {

    // MARK: - Split

    @Test func splitsOnWhitespace() throws {
        #expect(ShellArgs.split("a b c") == ["a", "b", "c"])
    }

    @Test func collapsesRepeatedWhitespace() throws {
        #expect(ShellArgs.split("  a   b  ") == ["a", "b"])
    }

    @Test func returnsEmptyForBlankInput() throws {
        #expect(ShellArgs.split("") == [])
        #expect(ShellArgs.split("   ") == [])
    }

    @Test func preservesSingleQuotedSpaces() throws {
        #expect(
            ShellArgs.split("--root '/Users/me/long path'")
                == ["--root", "/Users/me/long path"]
        )
    }

    @Test func preservesDoubleQuotedSpaces() throws {
        #expect(
            ShellArgs.split("--root \"/Users/me/long path\"")
                == ["--root", "/Users/me/long path"]
        )
    }

    @Test func honorsBackslashEscapeOutsideQuotes() throws {
        #expect(ShellArgs.split("a\\ b c") == ["a b", "c"])
    }

    @Test func adjacentQuotedAndUnquotedConcatenate() throws {
        #expect(ShellArgs.split("foo'bar baz'") == ["foobar baz"])
    }

    @Test func emptyQuotedStringYieldsEmptyArg() throws {
        #expect(ShellArgs.split("a '' b") == ["a", "", "b"])
    }

    /// POSIX double-quote rule: `\` is only an escape before `"`, `\`,
    /// `$`, backtick, or newline. Anything else keeps the backslash
    /// literal — important so `--regex "\d+"` round-trips cleanly.
    @Test func doubleQuoteKeepsLiteralBackslashForNonEscapeChars() throws {
        #expect(ShellArgs.split("--regex \"\\d+\"") == ["--regex", "\\d+"])
    }

    @Test func doubleQuoteEscapesDoubleQuoteAndBackslash() throws {
        #expect(ShellArgs.split("\"a\\\"b\\\\c\"") == ["a\"b\\c"])
    }

    @Test func trailingBackslashIsLiteral() throws {
        #expect(ShellArgs.split("foo \\") == ["foo", "\\"])
    }

    // MARK: - Join / quote

    @Test func quoteLeavesBareSafeTokensAlone() throws {
        #expect(ShellArgs.quote("npx") == "npx")
        #expect(ShellArgs.quote("--root") == "--root")
        #expect(ShellArgs.quote("/usr/local/bin/uvx") == "/usr/local/bin/uvx")
    }

    @Test func quoteWrapsSpacesInSingleQuotes() throws {
        #expect(ShellArgs.quote("/path with spaces") == "'/path with spaces'")
    }

    @Test func quoteEscapesEmbeddedSingleQuotes() throws {
        #expect(ShellArgs.quote("it's fine") == "'it'\\''s fine'")
    }

    @Test func quoteHandlesEmptyString() throws {
        #expect(ShellArgs.quote("") == "''")
    }

    @Test func joinRoundTripsThroughSplit() throws {
        let original = [
            "npx",
            "-y",
            "@scope/server-foo",
            "--root",
            "/Users/me/long path",
            "--flag=value with spaces",
        ]
        let joined = ShellArgs.join(original)
        #expect(ShellArgs.split(joined) == original)
    }

    @Test func joinRoundTripsThroughSplitWithSingleQuotes() throws {
        let original = ["echo", "it's working"]
        let joined = ShellArgs.join(original)
        #expect(ShellArgs.split(joined) == original)
    }
}

struct MCPStdioTransportErrorTests {

    /// The marker constant must appear verbatim in the localized
    /// description; ProviderCard's "Edit" hint relies on this round-trip.
    @Test func commandNotFoundDescriptionContainsMarker() throws {
        let err = MCPStdioTransportError.commandNotFound(
            command: "npx",
            searchedPath: "/usr/bin"
        )
        let description = err.errorDescription ?? ""
        #expect(description.contains(MCPStdioTransportError.commandNotFoundMarker))
        #expect(MCPStdioTransportError.isCommandNotFoundMessage(description))
    }

    @Test func otherErrorsDoNotMatchCommandNotFound() throws {
        let err = MCPStdioTransportError.processSpawnFailed("boom")
        let description = err.errorDescription ?? ""
        #expect(!MCPStdioTransportError.isCommandNotFoundMessage(description))
    }
}

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

#if canImport(Darwin)
    final class MCPStdioHostRunnerPathTests: XCTestCase {
        func testHostSearchPathAppendsCommonLocalBinFallbacks() throws {
            let searchPath = MCPStdioHostRunner.executableSearchPathForTesting(
                env: ["PATH": "/custom/bin:/usr/bin"]
            )
            let entries = searchPath.split(separator: ":").map(String.init)

            XCTAssertEqual(entries.first, "/custom/bin")
            XCTAssertTrue(entries.contains("/opt/homebrew/bin"))
            XCTAssertTrue(entries.contains("/usr/local/bin"))
            XCTAssertTrue(entries.contains("/usr/bin"))
            XCTAssertEqual(entries.filter { $0 == "/usr/bin" }.count, 1)
        }

        func testHostResolverFindsExecutableOnPath() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-mcp-path-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("fake-mcp")
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )

            let resolved = try MCPStdioHostRunner.resolveExecutablePathForTesting(
                command: "fake-mcp",
                env: ["PATH": root.path]
            )

            XCTAssertEqual(resolved, executable.path)
        }

        func testHostResolverExpandsUserPaths() throws {
            let home = FileManager.default.homeDirectoryForCurrentUser.path

            XCTAssertEqual(
                MCPStdioHostRunner.expandUserPathForTesting("~/bin/mcp-server"),
                "\(home)/bin/mcp-server"
            )
            XCTAssertEqual(MCPStdioHostRunner.expandUserPathForTesting("~"), home)
            XCTAssertEqual(
                MCPStdioHostRunner.expandUserPathForTesting("/usr/local/bin/mcp-server"),
                "/usr/local/bin/mcp-server"
            )
        }

        func testHostEnvironmentAcceptsOrdinaryProviderValues() throws {
            let merged = try MCPStdioHostRunner.mergedEnvironmentForTesting(
                inherited: ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"],
                provider: ["MCP_LOG_LEVEL": "debug", "MCP_TOKEN": "canary"]
            )

            XCTAssertEqual(merged["PATH"], "/usr/bin")
            XCTAssertEqual(merged["MCP_LOG_LEVEL"], "debug")
            XCTAssertEqual(merged["MCP_TOKEN"], "canary")
        }

        func testHostEnvironmentRejectsProcessControlOverrides() throws {
            for key in ["PATH", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "OBJC_PRINT_LOAD_METHODS"] {
                XCTAssertThrowsError(
                    try MCPStdioHostRunner.mergedEnvironmentForTesting(
                        inherited: ["PATH": "/usr/bin"],
                        provider: [key: "canary"]
                    )
                ) { error in
                    XCTAssertEqual(error as? MCPStdioTransportError, .unsafeEnvironmentKey(key))
                    XCTAssertFalse(error.localizedDescription.contains("canary"))
                }
            }
        }
    }
#endif

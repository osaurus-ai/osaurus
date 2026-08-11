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
import OsaurusRepository
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
        private func makePrivateTestRoot() throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-mcp-parent-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            return root.standardizedFileURL.resolvingSymlinksInPath()
        }

        func testExplicitlyIsolatedParentDropsAmbientValuesAndPreservesProviderConfiguration() throws {
            let parentRoot = try makePrivateTestRoot()
            defer { try? FileManager.default.removeItem(at: parentRoot) }
            let environment = MCPStdioHostRunner.buildEnvironmentForTesting(
                parentEnvironment: [
                    ProcessDataRootPolicy.testRootEnvironmentKey: parentRoot.path,
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                    "PARENT_SETTING": "inherited",
                    "GITHUB_TOKEN": "ambient-secret",
                ],
                providerEnvironment: [
                    "TOOL_SETTING": "retained",
                    ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/provider-root",
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "0",
                    ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
                    ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                        "36CFBE8B-39DB-47DB-BA95-1742165D2657",
                ],
                parentRecognizedTestHost: false
            )

            XCTAssertEqual(
                environment[ProcessDataRootPolicy.testRootEnvironmentKey],
                parentRoot.path
            )
            XCTAssertEqual(
                environment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey],
                "1"
            )
            XCTAssertEqual(environment["TOOL_SETTING"], "retained")
            XCTAssertNil(environment["PARENT_SETTING"])
            XCTAssertNil(environment["GITHUB_TOKEN"])
            XCTAssertNil(environment[ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey])
            XCTAssertNil(
                environment[ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey]
            )
        }

        func testProviderCannotEnableIsolationMarkersForProductionHost() throws {
            let environment = MCPStdioHostRunner.buildEnvironmentForTesting(
                parentEnvironment: ["PATH": "/usr/bin"],
                providerEnvironment: [
                    "TOOL_SETTING": "retained",
                    ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/provider-root",
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                ],
                parentRecognizedTestHost: false
            )

            XCTAssertEqual(environment["PATH"], "/usr/bin")
            XCTAssertEqual(environment["TOOL_SETTING"], "retained")
            XCTAssertNil(environment[ProcessDataRootPolicy.testRootEnvironmentKey])
            XCTAssertNil(
                environment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey]
            )
        }

        func testRecognizedTestHostDoesNotInheritAmbientCredentials() throws {
            let parentRoot = try makePrivateTestRoot()
            defer { try? FileManager.default.removeItem(at: parentRoot) }
            let environment = MCPStdioHostRunner.buildEnvironmentForTesting(
                parentEnvironment: [
                    "PATH": "/usr/bin",
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "C",
                    "GITHUB_TOKEN": "ambient-github-secret",
                    "AWS_SECRET_ACCESS_KEY": "ambient-aws-secret",
                    "HOME": "/Users/production",
                    ProcessDataRootPolicy.testRootEnvironmentKey: parentRoot.path,
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                ],
                providerEnvironment: [
                    "PROVIDER_SETTING": "explicit-value",
                    "PROVIDER_SECRET": "explicit-secret",
                    "HOME": "/Users/provider-override",
                    "TMPDIR": "/Users/provider-temp-override",
                    ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/provider-root",
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "0",
                    ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
                ],
                parentRecognizedTestHost: true
            )

            XCTAssertEqual(environment["PATH"], "/usr/bin")
            XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
            XCTAssertEqual(environment["LC_ALL"], "C")
            XCTAssertEqual(environment["PROVIDER_SETTING"], "explicit-value")
            XCTAssertEqual(environment["PROVIDER_SECRET"], "explicit-secret")
            XCTAssertNil(environment["GITHUB_TOKEN"])
            XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
            XCTAssertEqual(environment["HOME"], parentRoot.path)
            XCTAssertEqual(environment["TMPDIR"], parentRoot.path)
            XCTAssertEqual(
                environment[ProcessDataRootPolicy.testRootEnvironmentKey],
                parentRoot.path
            )
            XCTAssertEqual(
                environment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey],
                "1"
            )
            XCTAssertNil(environment[ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey])
        }

        func testMarkerOnlyIsolationKeepsAmbientSecretOutOfLaunchedChild() throws {
            let ambientCanary = "ambient-canary-\(UUID().uuidString)"
            let providerValue = "provider-value-\(UUID().uuidString)"
            let environment = MCPStdioHostRunner.buildEnvironmentForTesting(
                parentEnvironment: [
                    "PATH": "/usr/bin:/bin",
                    "AMBIENT_SECRET_CANARY": ambientCanary,
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                ],
                providerEnvironment: ["PROVIDER_EXPLICIT_VALUE": providerValue],
                parentRecognizedTestHost: false
            )
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.environment = environment
            process.standardOutput = output
            process.standardError = Pipe()

            try process.run()
            process.waitUntilExit()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            let rendered = try XCTUnwrap(String(data: bytes, encoding: .utf8))

            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertFalse(rendered.contains(ambientCanary))
            XCTAssertFalse(rendered.contains("AMBIENT_SECRET_CANARY="))
            XCTAssertTrue(rendered.contains("PROVIDER_EXPLICIT_VALUE=\(providerValue)"))
            XCTAssertEqual(
                environment["HOME"],
                environment[ProcessDataRootPolicy.testRootEnvironmentKey]
            )
            XCTAssertEqual(
                environment["TMPDIR"],
                environment[ProcessDataRootPolicy.testRootEnvironmentKey]
            )
        }

        func testIsolatedHomeControlsShellAndPythonExpansion() throws {
            let parentRoot = try makePrivateTestRoot()
            defer { try? FileManager.default.removeItem(at: parentRoot) }
            let environment = MCPStdioHostRunner.buildEnvironmentForTesting(
                parentEnvironment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    ProcessDataRootPolicy.testRootEnvironmentKey: parentRoot.path,
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                ],
                providerEnvironment: ["HOME": "/Users/provider-override"],
                parentRecognizedTestHost: false
            )

            let shell = try runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' ~"],
                environment: environment
            )
            XCTAssertEqual(shell.status, 0, shell.stderr)
            XCTAssertEqual(shell.stdout, parentRoot.path)

            let python = try runProcess(
                executable: "/usr/bin/python3",
                arguments: ["-c", "import pathlib; print(pathlib.Path.home(), end='')"],
                environment: environment
            )
            XCTAssertEqual(python.status, 0, python.stderr)
            XCTAssertEqual(python.stdout, parentRoot.path)
        }

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

        private func runProcess(
            executable: String,
            arguments: [String],
            environment: [String: String],
            workingDirectory: URL? = nil
        ) throws -> (status: Int32, stdout: String, stderr: String) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(
                    data: stdout.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "",
                String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
            )
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
            let environment = ["HOME": home]

            XCTAssertEqual(
                MCPStdioHostRunner.expandUserPathForTesting(
                    "~/bin/mcp-server",
                    env: environment
                ),
                "\(home)/bin/mcp-server"
            )
            XCTAssertEqual(
                MCPStdioHostRunner.expandUserPathForTesting("~", env: environment),
                home
            )
            XCTAssertEqual(
                MCPStdioHostRunner.expandUserPathForTesting(
                    "/usr/local/bin/mcp-server",
                    env: environment
                ),
                "/usr/local/bin/mcp-server"
            )
        }

        func testIsolatedLaunchUsesChildHomeForTildeCommandAndWorkingDirectory() throws {
            let isolatedRoot = try makePrivateTestRoot()
            defer { try? FileManager.default.removeItem(at: isolatedRoot) }
            let bin = isolatedRoot.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
            let executable = bin.appendingPathComponent("tilde-mcp")
            try "#!/bin/sh\nprintf '%s\\n%s\\n%s' \"$0\" \"$PWD\" \"$HOME\"\n".write(
                to: executable,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
            let environment = MCPStdioHostRunner.buildEnvironmentForTesting(
                parentEnvironment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    ProcessDataRootPolicy.testRootEnvironmentKey: isolatedRoot.path,
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                ],
                providerEnvironment: [:],
                parentRecognizedTestHost: false
            )

            let resolvedExecutable = try MCPStdioHostRunner.resolveExecutablePathForTesting(
                command: "~/bin/tilde-mcp",
                env: environment
            )
            let resolvedWorkingDirectory = MCPStdioHostRunner.expandUserPathForTesting(
                "~",
                env: environment
            )
            let result = try runProcess(
                executable: resolvedExecutable,
                arguments: [],
                environment: environment,
                workingDirectory: URL(fileURLWithPath: resolvedWorkingDirectory)
            )

            XCTAssertEqual(result.status, 0, result.stderr)
            let outputLines = result.stdout.split(separator: "\n").map(String.init)
            XCTAssertEqual(outputLines.count, 3)
            XCTAssertEqual(outputLines[0], executable.path)
            XCTAssertEqual(
                URL(fileURLWithPath: outputLines[1]).resolvingSymlinksInPath().path,
                isolatedRoot.resolvingSymlinksInPath().path
            )
            XCTAssertEqual(outputLines[2], isolatedRoot.path)
        }

        func testIsolatedSearchPathRejectsParentHomeAndSymlinkedHomeExecutables() throws {
            let parentHome = try makePrivateTestRoot()
            let isolatedRoot = try makePrivateTestRoot()
            let linkedParentBin = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-mcp-linked-home-\(UUID().uuidString)",
                isDirectory: true
            )
            defer {
                try? FileManager.default.removeItem(at: linkedParentBin)
                try? FileManager.default.removeItem(at: isolatedRoot)
                try? FileManager.default.removeItem(at: parentHome)
            }
            let parentBin = parentHome.appendingPathComponent("bin", isDirectory: true)
            let isolatedBin = isolatedRoot.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: parentBin, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: isolatedBin, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: linkedParentBin,
                withDestinationURL: parentBin
            )
            for (url, marker) in [
                (parentBin.appendingPathComponent("fake-mcp"), "parent"),
                (isolatedBin.appendingPathComponent("fake-mcp"), "isolated"),
            ] {
                try "#!/bin/sh\nprintf '%s' '\(marker)'\n".write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: url.path
                )
            }

            let environment = MCPStdioHostRunner.buildEnvironmentForTesting(
                parentEnvironment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": parentHome.path,
                    ProcessDataRootPolicy.testRootEnvironmentKey: isolatedRoot.path,
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                ],
                providerEnvironment: [
                    "PATH": [
                        parentBin.path,
                        linkedParentBin.path,
                        ".",
                        isolatedBin.path,
                        "/usr/bin",
                        "/bin",
                    ].joined(separator: ":"),
                ],
                parentRecognizedTestHost: false
            )
            let resolved = try MCPStdioHostRunner.resolveExecutablePathForTesting(
                command: "fake-mcp",
                env: environment
            )
            let result = try runProcess(
                executable: resolved,
                arguments: [],
                environment: environment
            )

            XCTAssertFalse(environment["PATH", default: ""].contains(parentHome.path))
            XCTAssertFalse(environment["PATH", default: ""].contains(linkedParentBin.path))
            XCTAssertFalse(environment["PATH", default: ""].split(separator: ":").contains("."))
            XCTAssertEqual(resolved, isolatedBin.appendingPathComponent("fake-mcp").path)
            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertEqual(result.stdout, "isolated")
        }
    }
#endif

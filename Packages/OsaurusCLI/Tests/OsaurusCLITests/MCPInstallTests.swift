import Foundation
import XCTest

@testable import OsaurusCLICore

final class MCPInstallTests: XCTestCase {
    private let command = "/usr/local/bin/osaurus"
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-install-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Parsing

    func testParsesInstallOptions() throws {
        let options = try MCPInstall.parse(
            ["--client", "cursor", "--tools", "osaurus_*", "--workflows", "--force"], uninstall: false)
        XCTAssertEqual(options.client, .cursor)
        XCTAssertEqual(options.tools, "osaurus_*")
        XCTAssertEqual(options.workflows, "*", "a bare --workflows means all")
        XCTAssertTrue(options.force)
        XCTAssertEqual(
            MCPInstall.serverArguments(options), ["mcp", "--tools", "osaurus_*", "--workflows", "*"])
        XCTAssertEqual(try MCPInstall.parse(["codex", "--workflows", "brief"], uninstall: false).workflows, "brief")
        XCTAssertEqual(try MCPInstall.parse(["-c", "Claude-Desktop", "--print"], uninstall: true).client, .claudeDesktop)
    }

    func testRejectsBadInstallArguments() {
        XCTAssertThrowsError(try MCPInstall.parse([], uninstall: false))
        XCTAssertThrowsError(try MCPInstall.parse(["--client", "vim"], uninstall: false))
        XCTAssertThrowsError(try MCPInstall.parse(["--client"], uninstall: false))
        XCTAssertThrowsError(try MCPInstall.parse(["--client", "cursor", "--tools", "x"], uninstall: true))
        XCTAssertThrowsError(try MCPInstall.parse(["--client", "cursor", "--bogus"], uninstall: false))
    }

    func testCLIPathIsAbsoluteAndKeepsTheStableLink() {
        XCTAssertEqual(MCPInstall.cliPath(argv0: "/usr/local/bin/osaurus"), "/usr/local/bin/osaurus")
        XCTAssertEqual(MCPInstall.cliPath(argv0: "./bin/../osaurus", currentDirectory: "/tmp/x"), "/tmp/x/osaurus")
        XCTAssertEqual(
            MCPInstall.cliPath(
                argv0: "osaurus", environment: ["PATH": "/nope:/opt/homebrew/bin"],
                isExecutable: { $0 == "/opt/homebrew/bin/osaurus" }),
            "/opt/homebrew/bin/osaurus")
    }

    // MARK: JSON clients

    func testJSONMergeKeepsOtherServersAndRefusesADifferentEntry() throws {
        let entry = MCPInstall.entry(command: command, serverArgs: ["mcp"])
        guard case .write(let fresh) = try MCPInstall.mergeJSON(existing: nil, entry: entry, force: false) else {
            return XCTFail("expected a write")
        }
        XCTAssertEqual(
            (try object(fresh)["mcpServers"] as? [String: Any])?["osaurus"] as? NSDictionary, entry as NSDictionary)

        let existing = Data(
            #"""
            {
              // Cursor tolerates comments
              "mcpServers": { "github": { "command": "gh-mcp" } },
              "other": true
            }
            """#.utf8)
        guard case .write(let merged) = try MCPInstall.mergeJSON(existing: existing, entry: entry, force: false) else {
            return XCTFail("expected a write")
        }
        let root = try object(merged)
        XCTAssertEqual(root["other"] as? Bool, true)
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["github", "osaurus"])
        XCTAssertFalse(String(decoding: merged, as: UTF8.self).contains("\\/"), "paths stay readable")

        XCTAssertEqual(try MCPInstall.mergeJSON(existing: merged, entry: entry, force: false), .unchanged)
        let different = MCPInstall.entry(command: command, serverArgs: ["mcp", "--workflows", "*"])
        XCTAssertEqual(try MCPInstall.mergeJSON(existing: merged, entry: different, force: false), .conflict)
        guard case .write(let forced) = try MCPInstall.mergeJSON(existing: merged, entry: different, force: true) else {
            return XCTFail("--force replaces")
        }
        XCTAssertEqual(
            ((try object(forced)["mcpServers"] as? [String: Any])?["osaurus"] as? [String: Any])?["args"] as? [String],
            ["mcp", "--workflows", "*"])

        guard case .write(let removed) = try MCPInstall.mergeJSON(existing: forced, entry: nil, force: false) else {
            return XCTFail("uninstall writes")
        }
        XCTAssertEqual(Set((try object(removed)["mcpServers"] as? [String: Any])?.keys ?? [:].keys), ["github"])
        XCTAssertEqual(try MCPInstall.mergeJSON(existing: removed, entry: nil, force: false), .unchanged)

        XCTAssertThrowsError(try MCPInstall.mergeJSON(existing: Data("[1]".utf8), entry: entry, force: false))
        XCTAssertThrowsError(
            try MCPInstall.mergeJSON(existing: Data(#"{"mcpServers": []}"#.utf8), entry: entry, force: false))
    }

    func testJSONClientWritesABackupAndRoundTrips() throws {
        let config = directory.appendingPathComponent("mcp.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(#"{"mcpServers":{"github":{"command":"gh-mcp"}}}"#.utf8)
        try original.write(to: config)
        let options = try MCPInstall.parse(["--client", "cursor"], uninstall: false)

        let added = try MCPInstall.jsonClient(options, command: command, serverArgs: ["mcp"], configURL: config)
        XCTAssertTrue(added.contains("Added Osaurus to Cursor"))
        XCTAssertEqual(try Data(contentsOf: MCPInstall.backupURL(for: config)), original)
        let again = try MCPInstall.jsonClient(options, command: command, serverArgs: ["mcp"], configURL: config)
        XCTAssertTrue(again.contains("already runs"))

        let uninstall = try MCPInstall.parse(["--client", "cursor"], uninstall: true)
        _ = try MCPInstall.jsonClient(uninstall, command: command, serverArgs: ["mcp"], configURL: config)
        XCTAssertEqual(
            NSDictionary(dictionary: try object(Data(contentsOf: config))),
            NSDictionary(dictionary: try object(original)))

        var printOnly = options
        printOnly.printOnly = true
        let missing = directory.appendingPathComponent("nested/never.json")
        let snippet = try MCPInstall.jsonClient(printOnly, command: command, serverArgs: ["mcp"], configURL: missing)
        XCTAssertTrue(snippet.contains(#""command" : "/usr/local/bin/osaurus""#))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "--print writes nothing")
    }

    func testEntryNeverCarriesAnAccessKey() {
        let entry = MCPInstall.entry(command: command, serverArgs: MCPInstall.serverArguments(
            MCPInstall.Options(client: .cursor, tools: "osaurus_*", workflows: "*")))
        XCTAssertNil(entry["env"])
        XCTAssertFalse((entry["args"] as? [String] ?? []).contains("--access-key"))
    }

    // MARK: Codex

    func testCodexBlockAppendsReplacesAndRemoves() {
        let block = MCPInstall.codexBlock(command: command, serverArgs: ["mcp", "--workflows", "*"])
        XCTAssertTrue(block.contains("[mcp_servers.osaurus]"))
        XCTAssertTrue(block.contains(#"command = "/usr/local/bin/osaurus""#))
        XCTAssertTrue(block.contains(#"args = ["mcp", "--workflows", "*"]"#))
        XCTAssertTrue(block.contains("tool_timeout_sec = 900"))

        let user = "model = \"gpt-5\"\n\n[mcp_servers.github]\ncommand = \"gh\""
        guard case .write(let added) = MCPInstall.mergeCodex(existing: user, block: block) else {
            return XCTFail("expected append")
        }
        XCTAssertTrue(added.hasPrefix(user + "\n\n" + MCPInstall.codexBlockBegin))
        XCTAssertEqual(MCPInstall.mergeCodex(existing: added, block: block), .unchanged)

        let narrower = MCPInstall.codexBlock(command: command, serverArgs: ["mcp"])
        guard case .write(let replaced) = MCPInstall.mergeCodex(existing: added + "\n[profiles.x]\n", block: narrower)
        else { return XCTFail("expected replace") }
        XCTAssertTrue(replaced.contains(#"args = ["mcp"]"#))
        XCTAssertTrue(replaced.hasSuffix("[profiles.x]\n"), "text after the block is kept")
        XCTAssertEqual(replaced.components(separatedBy: MCPInstall.codexBlockBegin).count, 2)

        guard case .write(let removed) = MCPInstall.mergeCodex(existing: added, block: nil) else {
            return XCTFail("expected removal")
        }
        XCTAssertEqual(removed.trimmingCharacters(in: .newlines), user)
        XCTAssertEqual(MCPInstall.mergeCodex(existing: user, block: nil), .unchanged)
    }

    func testCodexRefusesAnUnmanagedOsaurusServer() {
        let block = MCPInstall.codexBlock(command: command, serverArgs: ["mcp"])
        for existing in [
            "[mcp_servers.osaurus]\ncommand = \"x\"",
            "[mcp_servers.\"osaurus\".env]\nA = \"b\"",
            "mcp_servers.osaurus.command = \"x\"",
        ] {
            XCTAssertEqual(MCPInstall.mergeCodex(existing: existing, block: block), .conflict, existing)
        }
        XCTAssertNotEqual(
            MCPInstall.mergeCodex(existing: "[mcp_servers.osaurus_two]\n# [mcp_servers.osaurus]", block: block),
            .conflict)
    }

    func testCodexConfigFollowsCodexHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(MCPInstall.codexConfigURL(environment: [:], home: home).path, "/Users/me/.codex/config.toml")
        XCTAssertEqual(
            MCPInstall.codexConfigURL(environment: ["CODEX_HOME": "/tmp/codex"], home: home).path,
            "/tmp/codex/config.toml")
    }

    // MARK: Claude

    func testClaudeCodeCommand() throws {
        let options = try MCPInstall.parse(["--client", "claude-code", "--tools", "osaurus_*"], uninstall: false)
        let arguments = MCPInstall.claudeCodeArguments(
            options, command: command, serverArgs: MCPInstall.serverArguments(options))
        XCTAssertEqual(
            arguments, ["mcp", "add", "--scope", "user", "osaurus", "--", command, "mcp", "--tools", "osaurus_*"])
        XCTAssertEqual(
            MCPInstall.shellQuoted(arguments),
            "mcp add --scope user osaurus -- /usr/local/bin/osaurus mcp --tools 'osaurus_*'")
        let remove = try MCPInstall.parse(["--client", "claude-code"], uninstall: true)
        XCTAssertEqual(
            MCPInstall.claudeCodeArguments(remove, command: command, serverArgs: []),
            ["mcp", "remove", "--scope", "user", "osaurus"])
        XCTAssertEqual(
            MCPInstall.jsonConfigURL(.claudeDesktop, home: URL(fileURLWithPath: "/Users/me"))?.path,
            "/Users/me/Library/Application Support/Claude/claude_desktop_config.json")
    }
}

//
//  OsaurusBundleTests.swift
//  OsaurusRepository
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class OsaurusBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ToolsPaths.overrideRoot = nil
    }

    // MARK: Fixture

    private func write(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func manifest(_ overrides: [String: Any] = [:], drop: [String] = []) throws {
        var object: [String: Any] = [
            "format": "osaurus.bundle",
            "format_version": 1,
            "id": "com.example.starter",
            "name": "Example Starter",
            "version": "1.0.0",
            "skills": [["name": "release-notes", "path": "skills/release-notes"]],
            "mcp_servers": [
                [
                    "name": "Tickets", "transport": "http", "url": "https://mcp.example.com/mcp",
                    "auth": "bearer", "token_ref": "keychain:com.example.starter/tickets-token",
                ],
                [
                    "name": "Files", "transport": "stdio", "command": "npx",
                    "args": ["-y", "@example/files-mcp"],
                    "secret_env_refs": ["FILES_KEY": "keychain:com.example.starter/files-key"],
                ],
            ],
            "agents": [["path": "agents/support.json"], ["path": "agents/writer.json"]],
        ]
        for (key, value) in overrides { object[key] = value }
        for key in drop { object.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try write(String(decoding: data, as: UTF8.self), to: "osaurus-bundle.json")
    }

    private func writeFixture() throws {
        try manifest()
        try write(
            "---\nname: release-notes\ndescription: Write release notes.\n---\n\n# Release notes\n",
            to: "skills/release-notes/SKILL.md")
        try write(
            #"""
            {"format":"osaurus.template","format_version":1,"name":"Support",
             "agent":{"name":"Support","skills":["release-notes"],
                      "mcp_servers":{"enabled":["Tickets"]}}}
            """#, to: "agents/support.json")
        try write(
            #"{"name":"Writer","capabilities":{"computer_use_enabled":true}}"#, to: "agents/writer.json")
    }

    private func issues(_ body: () throws -> Void) -> [String] {
        do {
            try body()
            return []
        } catch let error as OsaurusBundleError {
            return error.issues
        } catch {
            return ["\(error)"]
        }
    }

    // MARK: Loading

    func testLoadsValidBundle() throws {
        try writeFixture()
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertEqual(bundle.id, "com.example.starter")
        XCTAssertEqual(bundle.skills.map(\.name), ["release-notes"])
        XCTAssertEqual(bundle.agents.map(\.name), ["Support", "Writer"])
        XCTAssertEqual(bundle.agent(named: "support")?.skills, ["release-notes"])
        XCTAssertEqual(bundle.agent(named: "Support")?.mcpServers, ["Tickets"])
        XCTAssertEqual(bundle.agent(named: "Writer")?.highRiskCapabilities, ["computer_use_enabled"])
        XCTAssertTrue(bundle.warnings.isEmpty, "\(bundle.warnings)")

        let viaManifest = try OsaurusBundle.load(from: root.appendingPathComponent("osaurus-bundle.json"))
        XCTAssertEqual(viaManifest.agents.count, 2)
    }

    func testRejectsUnknownKeysWithSuggestion() throws {
        try writeFixture()
        try manifest(["agentz": []])
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("unknown key `agentz`") && $0.contains("`agents`") }, "\(found)")
    }

    func testRejectsEnvRefsAndMalformedKeychainRefs() throws {
        try writeFixture()
        try manifest([
            "mcp_servers": [
                ["name": "A", "transport": "http", "url": "https://a.example", "token_ref": "env:A_TOKEN"],
                ["name": "B", "transport": "http", "url": "https://b.example", "token_ref": "keychain:only-service"],
            ],
            "agents": [["path": "agents/writer.json"]],
        ])
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("env: references are not allowed") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("expected keychain:SERVICE/ACCOUNT") }, "\(found)")
    }

    func testRejectsRefsOnTheWrongTransport() throws {
        try writeFixture()
        try manifest([
            "mcp_servers": [
                [
                    "name": "A", "transport": "stdio", "command": "x",
                    "secret_header_refs": ["X-Key": "keychain:s/a"],
                ],
                [
                    "name": "B", "transport": "http", "url": "https://b.example",
                    "secret_env_refs": ["K": "keychain:s/b"],
                ],
            ],
            "agents": [["path": "agents/writer.json"]],
        ])
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("only apply to transport: http") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("only apply to transport: stdio") }, "\(found)")
    }

    func testRejectsPathsOutsideTheBundle() throws {
        try writeFixture()
        try manifest(["agents": [["path": "../outside.json"], ["path": "/etc/hosts"]]])
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("points outside the bundle folder") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("must be a path relative to the bundle folder") }, "\(found)")
    }

    func testRejectsSymlinkInsideSkill() throws {
        try writeFixture()
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("skills/release-notes/link"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("symbolic link") }, "\(found)")
    }

    func testSkillNameMustMatchFrontmatter() throws {
        try writeFixture()
        try write("---\nname: something-else\ndescription: x\n---\n", to: "skills/release-notes/SKILL.md")
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("declares name \"something-else\"") }, "\(found)")
    }

    func testRejectsBadIdentityFields() throws {
        try writeFixture()
        try manifest(["id": "starter", "version": "one", "format_version": 2])
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("reverse-DNS") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("semantic version") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("needs a newer Osaurus") }, "\(found)")
    }

    func testWarnsAboutDependenciesOutsideTheBundle() throws {
        try writeFixture()
        try write(
            #"{"name":"Writer","skills":["not-shipped"],"mcp_servers":{"enabled":["Elsewhere"]}}"#,
            to: "agents/writer.json")
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertTrue(bundle.warnings.contains { $0.contains("\"not-shipped\" is not in this bundle") })
        XCTAssertTrue(bundle.warnings.contains { $0.contains("\"Elsewhere\" is not in this bundle") })
    }

    // MARK: Selection

    func testSelectingAnAgentPullsInItsBundleDependencies() throws {
        try writeFixture()
        let bundle = try OsaurusBundle.load(from: root)
        let items = try bundle.select(kind: nil, names: ["support"])
        XCTAssertEqual(
            items,
            [
                BundleItemRef(kind: .skill, name: "release-notes", explicit: false),
                BundleItemRef(kind: .mcp, name: "Tickets", explicit: false),
                BundleItemRef(kind: .agent, name: "Support", explicit: true),
            ])
    }

    func testExactToolNamesMakeTheirServerADependency() throws {
        try writeFixture()
        try write(
            #"{"name":"Writer","tools":{"mode":"manual","enabled":["files_read_file","get_current_time"]}}"#,
            to: "agents/writer.json")
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertEqual(bundle.agent(named: "Writer")?.mcpServers, ["Files"])
        XCTAssertEqual(
            try bundle.select(kind: .agent, names: ["Writer"]).map(\.name), ["Files", "Writer"])
        XCTAssertEqual(OsaurusBundle.mcpToolPrefix(for: "Acme Tickets"), "acme_tickets")
        XCTAssertEqual(OsaurusBundle.mcpToolPrefix(for: "my-server"), "my_server")
    }

    func testSelectingNothingSelectsEverythingInOrder() throws {
        try writeFixture()
        let bundle = try OsaurusBundle.load(from: root)
        let items = try bundle.select(kind: nil, names: [])
        XCTAssertEqual(items.map(\.kind), [.skill, .mcp, .mcp, .agent, .agent])
        XCTAssertTrue(items.allSatisfy(\.explicit))
        XCTAssertEqual(try bundle.select(kind: .mcp, names: []).map(\.name), ["Tickets", "Files"])
    }

    func testAmbiguousAndUnknownNamesFail() throws {
        try writeFixture()
        try write(
            "---\nname: support\ndescription: x\n---\n", to: "skills/support/SKILL.md")
        try manifest([
            "skills": [
                ["name": "release-notes", "path": "skills/release-notes"],
                ["name": "support", "path": "skills/support"],
            ]
        ])
        let bundle = try OsaurusBundle.load(from: root)
        let found = issues { _ = try bundle.select(kind: nil, names: ["Support", "nope"]) }
        XCTAssertTrue(found.contains { $0.contains("names more than one item") }, "\(found)")
        XCTAssertTrue(
            found.contains { $0.contains("no agent, skill, MCP server, harness runtime or setting named \"nope\"") },
            "\(found)")
        XCTAssertEqual(try bundle.select(kind: .skill, names: ["Support"]).map(\.kind), [.skill])
    }

    func testRisksNameServersAndCapabilities() throws {
        try writeFixture()
        let bundle = try OsaurusBundle.load(from: root)
        let risks = bundle.risks(for: try bundle.select(kind: nil, names: []))
        XCTAssertTrue(risks.contains { $0.contains("\"Tickets\" connects to https://mcp.example.com/mcp") })
        XCTAssertTrue(risks.contains { $0.contains("\"Files\" launches a local process: npx -y @example/files-mcp") })
        XCTAssertTrue(risks.contains { $0.contains("\"Writer\" turns on computer_use_enabled") })
        XCTAssertTrue(bundle.risks(for: [BundleItemRef(kind: .skill, name: "release-notes", explicit: true)]).isEmpty)
    }

    // MARK: Settings

    func testSettingsLoadSelectLastAndHash() throws {
        try writeFixture()
        try manifest([
            "settings": ["require_local_access_key": true, "allowed_origins": ["https://app.example.com"]]
        ])
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertEqual(bundle.settings.map(\.setting.key), ["require_local_access_key", "allowed_origins"])
        XCTAssertEqual(bundle.setting(named: "require_local_access_key")?.value, .bool(true))

        let items = try bundle.select(kind: nil, names: [])
        XCTAssertEqual(items.suffix(2).map(\.kind), [.setting, .setting])
        XCTAssertEqual(try bundle.select(kind: .setting, names: []).map(\.name), bundle.settings.map(\.setting.key))
        XCTAssertEqual(
            try bundle.select(kind: nil, names: ["allowed_origins"]),
            [BundleItemRef(kind: .setting, name: "allowed_origins", explicit: true)])
        XCTAssertEqual(BundleItemKind(argument: "settings"), .setting)

        let hash = try XCTUnwrap(bundle.contentHash(kind: .setting, name: "require_local_access_key"))
        try manifest(["settings": ["require_local_access_key": false]])
        let flipped = try OsaurusBundle.load(from: root)
        XCTAssertNotEqual(flipped.contentHash(kind: .setting, name: "require_local_access_key"), hash)
        XCTAssertNil(flipped.contentHash(kind: .setting, name: "allowed_origins"))
    }

    func testSettingsOnlyBundleIsValid() throws {
        try manifest(["settings": ["require_local_access_key": true]], drop: ["skills", "mcp_servers", "agents"])
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertEqual(try bundle.select(kind: nil, names: []).map(\.kind), [.setting])

        try manifest([:], drop: ["skills", "mcp_servers", "agents"])
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("no agents, skills, MCP servers, harness runtimes or settings") }, "\(found)")
    }

    func testRejectsUnknownSettingsWrongTypesAndBadOrigins() throws {
        try writeFixture()
        try manifest(["settings": ["require_local_acess_key": true, "port": 1337]])
        var found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(
            found.contains { $0.contains("settings: unknown key `require_local_acess_key`") && $0.contains("`require_local_access_key`") },
            "\(found)")

        try manifest(["settings": ["require_local_access_key": ["yes"], "allowed_origins": true]])
        found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("settings.require_local_access_key: must be true or false") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("settings.allowed_origins: must be a list of origins") }, "\(found)")

        try manifest([
            "settings": [
                "allowed_origins": [
                    "*", "https://*.example.com", "https://app.example.com/", "https://app.example.com/path",
                    "ftp://files.example.com", "https://App.Example.com", "app.example.com",
                    "https://app.example.com", "http://localhost:3000",
                ]
            ]
        ])
        found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertEqual(found.count, 7, "\(found)")
        XCTAssertEqual(found.filter { $0.contains("wildcard") }.count, 2, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("\"https://app.example.com/\" has a path") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("\"https://app.example.com/path\" has a path") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("\"ftp://files.example.com\" is not an origin") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("write \"https://App.Example.com\" in lowercase") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("\"app.example.com\" is not an origin") }, "\(found)")

        try manifest(["settings": ["allowed_origins": []]])
        found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("list at least one origin") }, "\(found)")

        try manifest(["settings": ["require_local_access_key"]])
        found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertFalse(found.isEmpty)
    }

    func testOnlySettingsThatLoosenSecurityAreRisks() throws {
        try writeFixture()
        try manifest([
            "settings": ["require_local_access_key": true, "allowed_origins": ["https://app.example.com"]]
        ])
        var bundle = try OsaurusBundle.load(from: root)
        let on = BundleItemRef(kind: .setting, name: "require_local_access_key", explicit: true)
        let origins = BundleItemRef(kind: .setting, name: "allowed_origins", explicit: true)
        XCTAssertTrue(bundle.risks(for: [on]).isEmpty)
        XCTAssertEqual(
            bundle.risks(for: [origins]),
            ["Lets web pages from https://app.example.com call Osaurus on this Mac from a browser"])

        try manifest(["settings": ["require_local_access_key": false]])
        bundle = try OsaurusBundle.load(from: root)
        XCTAssertEqual(bundle.risks(for: [on]).count, 1)
        XCTAssertTrue(bundle.risks(for: [on])[0].contains("Turns off \"Require Access Key for Local Admin Routes\""))
    }

    func testOriginsAreAddedNeverRemoved() {
        let setting = BundleSetting.allowedOrigins
        let wanted = BundleSettingValue.strings(["https://b.example", "https://a.example"])
        let current = BundleSettingValue.strings(["https://a.example", "https://c.example"])
        XCTAssertFalse(setting.isSatisfied(wanted, by: current))
        let stored = setting.applying(wanted, to: current)
        XCTAssertEqual(stored, .strings(["https://a.example", "https://c.example", "https://b.example"]))
        XCTAssertTrue(setting.isSatisfied(wanted, by: stored))

        let toggle = BundleSetting.requireLocalAccessKey
        XCTAssertEqual(toggle.applying(.bool(true), to: .bool(false)), .bool(true))
        XCTAssertFalse(toggle.isSatisfied(.bool(true), by: .bool(false)))
    }

    func testSettingReceiptRoundTripsItsValue() throws {
        ToolsPaths.overrideRoot = root.appendingPathComponent("tools-root", isDirectory: true)
        let receipt = ImportReceipt(
            bundleId: "com.example.starter", bundleName: nil, bundleVersion: "1.0.0", kind: .setting,
            name: "allowed_origins", explicit: true, contentHash: "abc",
            installedAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            settingValue: .strings(["https://app.example.com"]))
        try ImportQueue.saveReceipts([receipt])
        XCTAssertEqual(ImportQueue.loadReceipts(), [receipt])
        let text = try String(contentsOf: ImportQueue.receiptsURL(), encoding: .utf8)
        XCTAssertTrue(text.contains("\"setting_value\""), text)
    }

    func testSkillSlugMatchesAppRules() {
        XCTAssertEqual(OsaurusBundle.skillSlug(for: "Release Notes"), "release-notes")
        XCTAssertEqual(OsaurusBundle.skillSlug(for: "my_skill!"), "my-skill")
        XCTAssertEqual(OsaurusBundle.skillSlug(for: "-Edge-"), "edge")
    }

    // MARK: Queue

    func testEnqueueCopiesOnlyReferencedFilesAndCompletes() throws {
        try writeFixture()
        try write("echo hi", to: "install.sh")
        let bundle = try OsaurusBundle.load(from: root)
        let toolsRoot = root.appendingPathComponent("tools-root", isDirectory: true)
        ToolsPaths.overrideRoot = toolsRoot

        let items = try bundle.select(kind: nil, names: ["Support"])
        let request = ImportRequest(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            bundleId: bundle.id, bundleName: bundle.manifest.name, bundleVersion: bundle.manifest.version,
            operations: items.map { ImportOperation(action: .install, kind: $0.kind, name: $0.name, explicit: $0.explicit) },
            confirmHighRisk: true)
        try ImportQueue.enqueue(request, bundle: bundle)

        let pending = try XCTUnwrap(ImportQueue.pending(id: request.id))
        XCTAssertEqual(pending.request, request)
        let fm = FileManager.default
        let copy = pending.bundleDirectory
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("osaurus-bundle.json").path))
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("skills/release-notes/SKILL.md").path))
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("agents/support.json").path))
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("agents/writer.json").path))
        XCTAssertFalse(fm.fileExists(atPath: copy.appendingPathComponent("install.sh").path))

        let copied = try OsaurusBundle.load(from: copy)
        XCTAssertEqual(
            copied.contentHash(kind: .skill, name: "release-notes"),
            bundle.contentHash(kind: .skill, name: "release-notes"))
        XCTAssertEqual(
            copied.contentHash(kind: .mcp, name: "tickets"), bundle.contentHash(kind: .mcp, name: "Tickets"))

        let result = ImportResult(
            requestId: request.id, bundleId: bundle.id,
            items: [
                ImportItemResult(kind: .agent, name: "Support", action: .install, status: .done),
                ImportItemResult(
                    kind: .mcp, name: "Tickets", action: .install, status: .needsUserAction, message: "token"),
            ], finishedAt: Date(timeIntervalSince1970: 1_800_000_100))
        try ImportQueue.complete(pending, result: result)
        XCTAssertNil(ImportQueue.pending(id: request.id))
        XCTAssertEqual(ImportQueue.result(id: request.id), result)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testContentHashOnlyForItemsInTheBundle() throws {
        try writeFixture()
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertNotNil(bundle.contentHash(kind: .agent, name: "Writer"))
        XCTAssertNil(bundle.contentHash(kind: .agent, name: "Nobody"))
    }

    func testReceiptsRoundTripAndCancelPending() throws {
        try writeFixture()
        let bundle = try OsaurusBundle.load(from: root)
        ToolsPaths.overrideRoot = root.appendingPathComponent("tools-root", isDirectory: true)

        let receipt = ImportReceipt(
            bundleId: bundle.id, bundleName: "Example", bundleVersion: "1.0.0", kind: .skill,
            name: "Release Notes", explicit: true, contentHash: "abc",
            installedAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try ImportQueue.saveReceipts([receipt])
        XCTAssertEqual(ImportQueue.loadReceipts(), [receipt])
        XCTAssertTrue(receipt.matches(kind: .skill, name: "release-notes"))
        XCTAssertFalse(receipt.matches(kind: .agent, name: "Release Notes"))

        let request = ImportRequest(
            bundleId: bundle.id, bundleName: nil, bundleVersion: nil,
            operations: [ImportOperation(action: .remove, kind: .skill, name: "release-notes", explicit: true)],
            confirmHighRisk: false)
        try ImportQueue.enqueue(request, bundle: nil)
        XCTAssertEqual(ImportQueue.cancelPending(bundleId: bundle.id), [request.id])
        XCTAssertTrue(ImportQueue.pending().isEmpty)
    }

    // MARK: Shipped example

    /// docs/examples/osaurus-bundle-example is what the author guide walks
    /// through; it must keep loading.
    func testShippedExampleBundleLoads() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OsaurusRepositoryTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusRepository/
            .deletingLastPathComponent()  // Packages/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("docs/examples/osaurus-bundle-example", isDirectory: true)
        let bundle = try OsaurusBundle.load(from: example)
        XCTAssertEqual(bundle.id, "com.example.acme-support")
        XCTAssertEqual(bundle.warnings, [])
        XCTAssertEqual(bundle.skills.map(\.name), ["triage-ticket"])
        XCTAssertEqual(bundle.mcpServers.map(\.name), ["Acme Tickets", "GitHub"])
        XCTAssertEqual(bundle.agents.map(\.name), ["Support Desk", "Release Checker", "Acme Coder"])
        XCTAssertEqual(bundle.harnessRuntimes.map(\.name), ["Acme Pi"])
        XCTAssertEqual(bundle.agent(named: "Acme Coder")?.harnessRuntime, "Acme Pi")

        let support = try XCTUnwrap(bundle.agent(named: "Support Desk"))
        XCTAssertEqual(support.skills, ["triage-ticket"])
        XCTAssertEqual(support.mcpServers, ["Acme Tickets"])
        let checker = try XCTUnwrap(bundle.agent(named: "Release Checker"))
        XCTAssertEqual(checker.skills, [])
        XCTAssertEqual(checker.mcpServers, ["GitHub"])

        XCTAssertEqual(
            OsaurusBundle.keychainRefs(in: bundle.mcpServers).map(\.ref.display),
            [
                "keychain:com.example.acme-support/tickets-token",
                "keychain:com.example.acme-support/tickets-workspace-key",
                "keychain:com.example.acme-support/github-token",
            ])
        XCTAssertEqual(
            try bundle.select(kind: .agent, names: ["Support Desk"]).map(\.name),
            ["triage-ticket", "Acme Tickets", "Support Desk"])
        XCTAssertEqual(
            try bundle.select(kind: .agent, names: ["Acme Coder"]).map(\.name), ["Acme Pi", "Acme Coder"])
        // Two MCP servers, the runtime, and the agent that runs on it.
        XCTAssertEqual(bundle.risks(for: try bundle.select(kind: nil, names: [])).count, 4)
    }

    // MARK: Harness runtimes

    private func writeRuntimeFixture(_ runtimes: [[String: Any]], agentRuntime: String?) throws {
        try writeFixture()
        try manifest(["harness_runtimes": runtimes])
        var agent: [String: Any] = ["name": "Coder"]
        if let agentRuntime { agent["runtime"] = agentRuntime }
        let data = try JSONSerialization.data(withJSONObject: agent)
        try write(String(decoding: data, as: UTF8.self), to: "agents/writer.json")
    }

    func testRuntimeEntriesAreChecked() throws {
        try writeRuntimeFixture(
            [
                ["name": "builtin", "kind": "pi_rpc"],
                ["name": "Weird", "kind": "acp"],
                ["name": "Blank", "kind": "pi_rpc", "executable": " "],
                ["name": "Typo", "kind": "pi_rpc", "argumnts": []],
                ["name": "Twice", "kind": "pi_rpc"],
                ["name": "twice", "kind": "pi_rpc"],
            ], agentRuntime: nil)
        let found = issues { _ = try OsaurusBundle.load(from: root) }
        XCTAssertTrue(found.contains { $0.contains("harness_runtimes[builtin]") && $0.contains("reserved") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("harness_runtimes[Weird].kind") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("harness_runtimes[Blank].executable") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("unknown key `argumnts`") && $0.contains("arguments") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("harness_runtimes[twice]: listed twice") }, "\(found)")
    }

    func testAgentRuntimeIsADependencyAndARisk() throws {
        try writeRuntimeFixture(
            [["name": "Spotlight", "kind": "pi_rpc", "executable": "~/.local/bin/spotlight",
              "arguments": ["--mode", "rpc"]]],
            agentRuntime: "spotlight")
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertEqual(bundle.warnings, [])
        let refs = try bundle.select(kind: .agent, names: ["Coder"])
        XCTAssertEqual(refs.map(\.kind), [.harnessRuntime, .agent])
        XCTAssertEqual(refs.first?.explicit, false)
        let risks = bundle.risks(for: refs)
        XCTAssertTrue(risks.contains { $0.contains("~/.local/bin/spotlight --mode rpc") }, "\(risks)")
        XCTAssertTrue(risks.contains { $0.contains("Agent \"Coder\" runs on harness runtime") }, "\(risks)")
        XCTAssertEqual(try bundle.select(kind: .harnessRuntime, names: []).map(\.name), ["Spotlight"])
        XCTAssertNotNil(bundle.contentHash(kind: .harnessRuntime, name: "Spotlight"))
        XCTAssertEqual(BundleItemKind(argument: "runtime"), .harnessRuntime)
        XCTAssertEqual(BundleItemKind(argument: "harness_runtimes"), .harnessRuntime)
        XCTAssertTrue(BundleItemKind.harnessRuntime < .agent && BundleItemKind.mcp < .harnessRuntime)
    }

    func testAgentOnARuntimeOutsideTheBundleWarns() throws {
        try writeRuntimeFixture([], agentRuntime: "Claude Code")
        let bundle = try OsaurusBundle.load(from: root)
        XCTAssertTrue(bundle.warnings.contains { $0.contains("agents[Coder].runtime") }, "\(bundle.warnings)")
        XCTAssertEqual(try bundle.select(kind: .agent, names: ["Coder"]).map(\.kind), [.agent])

        try writeRuntimeFixture([], agentRuntime: "builtin")
        XCTAssertFalse(try OsaurusBundle.load(from: root).warnings.contains { $0.contains("runtime") })
    }

    func testResultExitCodes() {
        let done = ImportItemResult(kind: .skill, name: "a", action: .install, status: .done)
        let failed = ImportItemResult(kind: .skill, name: "b", action: .install, status: .failed)
        XCTAssertEqual(ImportResult(requestId: "r", bundleId: "b", items: [done]).exitCode, 0)
        XCTAssertEqual(ImportResult(requestId: "r", bundleId: "b", items: [done]).status, .applied)
        XCTAssertEqual(ImportResult(requestId: "r", bundleId: "b", items: [done, failed]).exitCode, 1)
        XCTAssertEqual(ImportResult(requestId: "r", bundleId: "b", items: [failed]).status, .failed)
    }
}

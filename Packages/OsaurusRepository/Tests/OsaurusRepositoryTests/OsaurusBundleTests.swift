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
        XCTAssertTrue(found.contains { $0.contains("no agent, skill or MCP server named \"nope\"") }, "\(found)")
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
        XCTAssertEqual(bundle.agents.map(\.name), ["Support Desk", "Release Checker"])

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
        XCTAssertEqual(bundle.risks(for: try bundle.select(kind: nil, names: [])).count, 2)
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

//
//  ImportCommandTests.swift
//  osaurus
//
//  `osaurus import`: argument parsing, the root refusal, the checks done
//  before anything is queued, the queued and live-apply paths, and the
//  `--json` shape and exit codes scripts depend on.
//

import Foundation
import OsaurusRepository
import XCTest

@testable import OsaurusCLICore

final class ImportCommandTests: XCTestCase {
    private var root: URL!
    private var bundleURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-import-cli-\(UUID().uuidString)", isDirectory: true)
        bundleURL = root.appendingPathComponent("bundle", isDirectory: true)
        ToolsPaths.overrideRoot = root.appendingPathComponent("osaurus-root", isDirectory: true)
        try writeBundle()
    }

    override func tearDownWithError() throws {
        ToolsPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = bundleURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeBundle(minVersion: String? = nil, stdio: Bool = false) throws {
        var manifest: [String: Any] = [
            "format": "osaurus.bundle", "format_version": 1, "id": "com.example.cli",
            "name": "CLI Test", "version": "1.0.0",
            "skills": [["name": "notes", "path": "skills/notes"]],
            "mcp_servers": [
                [
                    "name": "Tickets", "transport": "http", "url": "https://mcp.example.com/mcp",
                    "auth": "bearer", "token_ref": "keychain:com.example.cli/tickets",
                ]
            ],
            "agents": [["path": "agents/helper.json"], ["path": "agents/plain.json"]],
        ]
        if let minVersion { manifest["min_osaurus_version"] = minVersion }
        if stdio {
            manifest["mcp_servers"] = [
                ["name": "Tickets", "transport": "stdio", "command": "npx", "args": ["tickets-mcp"]]
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try write(String(decoding: data, as: UTF8.self), "osaurus-bundle.json")
        try write("---\nname: notes\ndescription: Take notes.\n---\nBody\n", "skills/notes/SKILL.md")
        try write(
            #"{"name":"Helper","skills":["notes"],"mcp_servers":{"enabled":["Tickets"]}}"#,
            "agents/helper.json")
        try write(#"{"name":"Plain","skills":["notes"]}"#, "agents/plain.json")
    }

    private final class Calls: @unchecked Sendable {
        var posts: [(String, [String: Any])] = []
    }

    private func environment(
        uid: uid_t = 501,
        appVersion: String? = "0.30.0",
        keychain: Bool? = true,
        running: Bool = false,
        calls: Calls = Calls(),
        respond: @escaping @Sendable (String, [String: Any]) -> (Int, Data) = { _, _ in (404, Data()) }
    ) -> ImportEnvironment {
        ImportEnvironment(
            userId: { uid },
            appVersion: { appVersion },
            keychainItemExists: { _ in keychain },
            port: { 1337 },
            isAppRunning: { _ in running },
            post: { _, path, body in
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                calls.posts.append((path, object))
                let (status, data) = respond(path, object)
                return (status, data)
            })
    }

    // MARK: Parsing

    func testParsesInstallWithKindNamesAndFlags() throws {
        let inv = try ImportCommand.parse([
            "install", "--from", "/tmp/b", "agent", "Helper", "Other", "--yes", "--json",
        ])
        XCTAssertEqual(inv.subcommand, .install)
        XCTAssertEqual(inv.from, "/tmp/b")
        XCTAssertEqual(inv.kind, .agent)
        XCTAssertEqual(inv.names, ["Helper", "Other"])
        XCTAssertTrue(inv.yes)
        XCTAssertTrue(inv.json)

        let all = try ImportCommand.parse(["update", "--from=/tmp/b", "skills"])
        XCTAssertEqual(all.kind, .skill)
        XCTAssertEqual(all.names, [])
    }

    func testParseRejectsMissingOrMisplacedOptions() {
        for args in [
            [String](),
            ["install"],
            ["install", "--from"],
            ["remove", "agent", "x"],
            ["remove", "--bundle", "a.b", "--from", "/tmp"],
            ["validate", "--from", "/tmp", "Helper"],
            ["list", "Helper"],
            ["install", "--from", "/tmp", "--frm"],
            ["frobnicate"],
        ] {
            XCTAssertThrowsError(try ImportCommand.parse(args), "\(args)")
        }
        XCTAssertEqual(try ImportCommand.parse(["help"]).subcommand, .help)
    }

    // MARK: Checks

    func testRefusesToRunAsRoot() async throws {
        let inv = try ImportCommand.parse(["install", "--from", bundleURL.path, "--yes"])
        let report = await ImportCommand.run(inv, environment: environment(uid: 0))
        XCTAssertEqual(report.state, "refused")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertTrue(report.issues.first?.contains("launchctl asuser") == true)
        XCTAssertTrue(ImportQueue.pending().isEmpty)
    }

    func testRequiresYesForHighRiskItems() async throws {
        let inv = try ImportCommand.parse(["install", "--from", bundleURL.path])
        let report = await ImportCommand.run(inv, environment: environment())
        XCTAssertEqual(report.state, "refused")
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertTrue(report.risks.contains { $0.contains("connects to https://mcp.example.com/mcp") })
        XCTAssertTrue(ImportQueue.pending().isEmpty)
    }

    func testSkillOnlyInstallNeedsNoConfirmation() async throws {
        let inv = try ImportCommand.parse(["install", "--from", bundleURL.path, "skill", "notes"])
        let report = await ImportCommand.run(inv, environment: environment())
        XCTAssertEqual(report.state, "queued")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.items.map(\.name), ["notes"])
    }

    func testMissingKeychainItemFailsInstallButOnlyWarnsOnValidate() async throws {
        let install = try ImportCommand.parse(["install", "--from", bundleURL.path, "--yes"])
        let failed = await ImportCommand.run(install, environment: environment(keychain: false))
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertTrue(
            failed.issues.contains {
                $0.contains("no Keychain item keychain:com.example.cli/tickets")
                    && $0.contains("-T /Applications/Osaurus.app")
            }, "\(failed.issues)")
        XCTAssertTrue(ImportQueue.pending().isEmpty)

        let validate = try ImportCommand.parse(["validate", "--from", bundleURL.path])
        let report = await ImportCommand.run(validate, environment: environment(keychain: false))
        XCTAssertEqual(report.state, "validated")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertTrue(report.warnings.contains { $0.contains("no Keychain item") })
    }

    func testMinimumOsaurusVersion() async throws {
        try writeBundle(minVersion: "0.31.0")
        let inv = try ImportCommand.parse(["validate", "--from", bundleURL.path])
        let old = await ImportCommand.run(inv, environment: environment(appVersion: "0.30"))
        XCTAssertEqual(old.exitCode, 1)
        XCTAssertTrue(old.issues.contains { $0.contains("needs Osaurus 0.31.0 or newer") })

        let new = await ImportCommand.run(inv, environment: environment(appVersion: "0.31.2"))
        XCTAssertEqual(new.exitCode, 0, "\(new.issues)")

        let unknown = await ImportCommand.run(inv, environment: environment(appVersion: nil))
        XCTAssertEqual(unknown.exitCode, 0)
        XCTAssertTrue(unknown.warnings.contains { $0.contains("min_osaurus_version") })
    }

    // MARK: Queue and apply

    func testQueuesWhenTheAppIsNotRunning() async throws {
        let inv = try ImportCommand.parse(["install", "--from", bundleURL.path, "Helper", "--yes"])
        let calls = Calls()
        let report = await ImportCommand.run(inv, environment: environment(calls: calls))
        XCTAssertEqual(report.state, "queued")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertTrue(calls.posts.isEmpty)
        XCTAssertEqual(
            report.items.map { "\($0.kind.rawValue)/\($0.name)/\($0.status)" },
            ["skill/notes/queued", "mcp/Tickets/queued", "agent/Helper/queued"])

        let pending = try XCTUnwrap(ImportQueue.pending().first)
        XCTAssertEqual(pending.request.id, report.requestId)
        XCTAssertEqual(pending.request.bundleId, "com.example.cli")
        XCTAssertTrue(pending.request.confirmHighRisk)
        XCTAssertEqual(pending.request.operations.map(\.explicit), [false, false, true])
    }

    func testAppliesRightAwayWhenTheAppIsRunning() async throws {
        let inv = try ImportCommand.parse(["install", "--from", bundleURL.path, "--yes", "--json"])
        let calls = Calls()
        let env = environment(running: true, calls: calls) { path, body in
            guard path == "/admin/import/apply", let id = body["id"] as? String else { return (404, Data()) }
            let result = ImportResult(
                requestId: id, bundleId: "com.example.cli",
                items: [
                    ImportItemResult(kind: .skill, name: "notes", action: .install, status: .done),
                    ImportItemResult(
                        kind: .mcp, name: "Tickets", action: .install, status: .needsUserAction,
                        message: "Could not resolve keychain:com.example.cli/tickets",
                        pendingSecrets: ["keychain:com.example.cli/tickets"]),
                ])
            return (200, try! ImportQueue.encoder().encode(result))
        }
        let report = await ImportCommand.run(inv, environment: env)
        XCTAssertEqual(calls.posts.map(\.0), ["/admin/import/apply"])
        XCTAssertEqual(report.state, "partial")
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(report.pendingSecrets, ["keychain:com.example.cli/tickets"])

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(ImportCommand.renderJSON(report).utf8)) as? [String: Any])
        for key in ["command", "state", "exit_code", "bundle_id", "request_id", "items", "pending_secrets", "risks"] {
            XCTAssertNotNil(json[key], "missing \(key)")
        }
        let item = try XCTUnwrap((json["items"] as? [[String: Any]])?.last)
        XCTAssertEqual(item["status"] as? String, "needs_user_action")
        XCTAssertEqual(item["pending_secrets"] as? [String], ["keychain:com.example.cli/tickets"])
    }

    func testOlderRunningAppLeavesTheRequestQueued() async throws {
        let inv = try ImportCommand.parse(["install", "--from", bundleURL.path, "--yes"])
        let report = await ImportCommand.run(inv, environment: environment(running: true))
        XCTAssertEqual(report.state, "queued")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertTrue(report.warnings.contains { $0.contains("too old") })
        XCTAssertEqual(ImportQueue.pending().count, 1)
    }

    func testAppErrorFailsWithItsMessage() async throws {
        let inv = try ImportCommand.parse(["install", "--from", bundleURL.path, "--yes"])
        let env = environment(running: true) { _, _ in
            (500, Data(#"{"error":{"message":"Boom","issues":["agents[Helper]: bad"]}}"#.utf8))
        }
        let report = await ImportCommand.run(inv, environment: env)
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertEqual(report.issues, ["Boom", "agents[Helper]: bad"])
    }

    func testValidateAsksTheRunningAppForTheStrictCheck() async throws {
        let inv = try ImportCommand.parse(["validate", "--from", bundleURL.path])
        let calls = Calls()
        let env = environment(running: true, calls: calls) { _, _ in
            (200, Data(#"{"issues":["agents[Helper]: unknown key `skils`"],"warnings":[]}"#.utf8))
        }
        let report = await ImportCommand.run(inv, environment: env)
        XCTAssertEqual(calls.posts.first?.0, "/admin/import/plan")
        XCTAssertEqual(calls.posts.first?.1["bundle_path"] as? String, bundleURL.standardizedFileURL.path)
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertEqual(report.issues, ["agents[Helper]: unknown key `skils`"])
    }

    // MARK: Remove and list

    func testRemoveUsesReceiptsAndCancelsQueuedRequests() async throws {
        try ImportQueue.saveReceipts([
            ImportReceipt(
                bundleId: "com.example.cli", bundleName: "CLI Test", bundleVersion: "1.0.0", kind: .agent,
                name: "Helper", explicit: true, contentHash: "a"),
            ImportReceipt(
                bundleId: "com.example.cli", bundleName: "CLI Test", bundleVersion: "1.0.0", kind: .skill,
                name: "notes", explicit: false, contentHash: "b"),
            ImportReceipt(
                bundleId: "com.other", bundleName: nil, bundleVersion: "1.0.0", kind: .agent,
                name: "Theirs", explicit: true, contentHash: "c"),
        ])
        let queued = ImportRequest(
            bundleId: "com.example.cli", bundleName: nil, bundleVersion: "1.0.0",
            operations: [ImportOperation(action: .install, kind: .agent, name: "Plain", explicit: true)],
            confirmHighRisk: false)
        try ImportQueue.enqueue(queued, bundle: nil)

        let unknown = try ImportCommand.parse(["remove", "--bundle", "com.example.cli", "Theirs"])
        let refused = await ImportCommand.run(unknown, environment: environment())
        XCTAssertEqual(refused.exitCode, 1)
        XCTAssertTrue(refused.issues.first?.contains("did not install anything named \"Theirs\"") == true)

        let all = try ImportCommand.parse(["remove", "--bundle", "com.example.cli", "--json"])
        let report = await ImportCommand.run(all, environment: environment())
        XCTAssertEqual(report.state, "queued")
        XCTAssertEqual(report.cancelledRequests, [queued.id])
        XCTAssertEqual(report.items.map(\.name), ["Helper", "notes"])
        XCTAssertTrue(report.items.allSatisfy { $0.action == .remove })
        let pending = ImportQueue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.request.operations.map(\.action), [.remove, .remove])
    }

    func testRemoveByNameCanTargetAQueuedInstall() async throws {
        let queued = ImportRequest(
            bundleId: "com.example.cli", bundleName: nil, bundleVersion: "1.0.0",
            operations: [ImportOperation(action: .install, kind: .agent, name: "Plain", explicit: true)],
            confirmHighRisk: false)
        try ImportQueue.enqueue(queued, bundle: nil)
        let inv = try ImportCommand.parse(["remove", "--bundle", "com.example.cli", "agent", "plain"])
        let report = await ImportCommand.run(inv, environment: environment())
        XCTAssertEqual(report.exitCode, 0, "\(report.issues)")
        XCTAssertEqual(report.items.first?.kind, .agent)
    }

    func testListShowsReceiptsQueueAndPendingSecrets() async throws {
        try ImportQueue.saveReceipts([
            ImportReceipt(
                bundleId: "com.example.cli", bundleName: "CLI Test", bundleVersion: "1.0.0", kind: .mcp,
                name: "Tickets", explicit: false, contentHash: "a",
                pendingSecrets: ["keychain:com.example.cli/tickets"])
        ])
        let inv = try ImportCommand.parse(["list", "--json"])
        let report = await ImportCommand.run(inv, environment: environment(uid: 0))
        XCTAssertEqual(report.state, "listed")
        XCTAssertEqual(report.installed?.count, 1)
        XCTAssertEqual(report.pendingSecrets, ["keychain:com.example.cli/tickets"])
        XCTAssertEqual(report.queued, [])
    }

    func testLenientVersionParsing() {
        XCTAssertEqual(ImportCommand.lenientVersion("0.26")?.description, "0.26.0")
        XCTAssertEqual(ImportCommand.lenientVersion("1")?.description, "1.0.0")
        XCTAssertNil(ImportCommand.lenientVersion("abc"))
    }
}

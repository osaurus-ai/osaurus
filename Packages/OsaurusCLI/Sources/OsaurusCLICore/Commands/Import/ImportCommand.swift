//
//  ImportCommand.swift
//  osaurus
//
//  `osaurus import` — install, update and remove the agents, skills, MCP
//  servers and harness runtimes in an Osaurus bundle (a folder with `osaurus-bundle.json`). Built
//  for third-party installer scripts: the command checks the bundle, copies
//  it into `~/.osaurus/import/pending/`, and the app applies it the next
//  time it opens, or right away over loopback when it is already running.
//  The CLI never launches the app. Author guide: docs/OSAURUS_BUNDLES.md.
//

import Foundation
import OsaurusRepository
import Security

// MARK: - Invocation

public struct ImportInvocation: Equatable, Sendable {
    public enum Subcommand: String, Sendable {
        case validate, install, update, remove, list, help
    }

    public var subcommand: Subcommand
    public var from: String?
    public var bundleId: String?
    public var kind: BundleItemKind?
    public var names: [String] = []
    public var yes = false
    public var json = false
}

public struct ImportUsageError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

// MARK: - Report (the `--json` output)

public struct ImportReport: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var kind: BundleItemKind
        public var name: String
        public var action: ImportAction
        /// done, unchanged, needs_user_action, failed, skipped, or queued
        /// when the app has not applied the request yet.
        public var status: String
        public var message: String?
        public var pendingSecrets: [String]?
    }

    public struct Queued: Codable, Equatable, Sendable {
        public var requestId: String
        public var bundleId: String
        public var bundleVersion: String?
        public var createdAt: Date
        public var operations: [ImportOperation]
    }

    public var command: String
    /// validated, applied, partial, queued, failed, refused, listed, nothing_to_do
    public var state: String = "failed"
    public var exitCode: Int32 = 1
    public var bundleId: String?
    public var bundleName: String?
    public var bundleVersion: String?
    public var requestId: String?
    public var items: [Item] = []
    public var risks: [String] = []
    public var warnings: [String] = []
    public var issues: [String] = []
    public var pendingSecrets: [String] = []
    public var cancelledRequests: [String]?
    public var installed: [ImportReceipt]?
    public var queued: [Queued]?

    public init(command: String) { self.command = command }
}

// MARK: - Environment

/// What the command touches outside its own process, so tests can stand
/// in for the user id, the Keychain and the running app.
public struct ImportEnvironment: Sendable {
    public var userId: @Sendable () -> uid_t
    public var appVersion: @Sendable () -> String?
    /// `true` / `false` when the Keychain answered, `nil` when not checked.
    public var keychainItemExists: @Sendable (BundleSecretRef) -> Bool?
    public var port: @Sendable () -> Int
    public var isAppRunning: @Sendable (Int) async -> Bool
    /// POST JSON to the loopback admin API. `nil` on transport errors.
    public var post: @Sendable (Int, String, Data) async -> (status: Int, body: Data)?
    /// Whether a harness runtime's executable resolves on PATH; `nil` when
    /// not checked.
    public var executableOnPath: @Sendable (String) -> Bool?

    public init(
        userId: @escaping @Sendable () -> uid_t,
        appVersion: @escaping @Sendable () -> String?,
        keychainItemExists: @escaping @Sendable (BundleSecretRef) -> Bool?,
        port: @escaping @Sendable () -> Int,
        isAppRunning: @escaping @Sendable (Int) async -> Bool,
        post: @escaping @Sendable (Int, String, Data) async -> (status: Int, body: Data)?,
        executableOnPath: @escaping @Sendable (String) -> Bool? = { _ in nil }
    ) {
        self.userId = userId
        self.appVersion = appVersion
        self.keychainItemExists = keychainItemExists
        self.port = port
        self.isAppRunning = isAppRunning
        self.post = post
        self.executableOnPath = executableOnPath
    }

    public static let live = ImportEnvironment(
        userId: { getuid() },
        appVersion: { CLIVersionResolver.resolve().version },
        keychainItemExists: { ref in
            guard ProcessInfo.processInfo.environment["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS"] != "1" else {
                return nil
            }
            return ImportCommand.keychainItemExists(ref)
        },
        port: { Configuration.resolveConfiguredPort() ?? 1337 },
        isAppRunning: { await ServerControl.checkHealth(port: $0) },
        post: { port, path, body in
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            // Applying waits for new MCP servers to connect.
            request.timeoutInterval = 600
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        },
        executableOnPath: { ImportCommand.executableOnPath($0) }
    )
}

// MARK: - Command

public struct ImportCommand: Command {
    public static let name = "import"

    public static func execute(args: [String]) async {
        let invocation: ImportInvocation
        do {
            invocation = try parse(args)
        } catch {
            fputs("\(error)\n\n", stderr)
            printUsage()
            exit(EXIT_FAILURE)
        }
        if invocation.subcommand == .help {
            printUsage()
            exit(EXIT_SUCCESS)
        }
        let report = await run(invocation, environment: .live)
        if invocation.json {
            print(renderJSON(report))
        } else {
            render(report)
        }
        exit(report.exitCode)
    }

    // MARK: Parsing

    public static func parse(_ args: [String]) throws -> ImportInvocation {
        guard let first = args.first else { throw ImportUsageError(message: "Missing import subcommand.") }
        let subcommand: ImportInvocation.Subcommand
        switch first {
        case "validate": subcommand = .validate
        case "install": subcommand = .install
        case "update": subcommand = .update
        case "remove", "uninstall": subcommand = .remove
        case "list", "ls": subcommand = .list
        case "help", "-h", "--help": return ImportInvocation(subcommand: .help)
        default: throw ImportUsageError(message: "Unknown import subcommand: \(first)")
        }

        var invocation = ImportInvocation(subcommand: subcommand)
        var positionals: [String] = []
        var index = 1
        func value(for flag: String) throws -> String {
            index += 1
            guard index < args.count, !args[index].hasPrefix("-") else {
                throw ImportUsageError(message: "\(flag) needs a value.")
            }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--from": invocation.from = try value(for: arg)
            case "--bundle": invocation.bundleId = try value(for: arg)
            case "--yes", "-y": invocation.yes = true
            case "--json": invocation.json = true
            case "-h", "--help": return ImportInvocation(subcommand: .help)
            default:
                if arg.hasPrefix("--from=") {
                    invocation.from = String(arg.dropFirst("--from=".count))
                } else if arg.hasPrefix("--bundle=") {
                    invocation.bundleId = String(arg.dropFirst("--bundle=".count))
                } else if arg.hasPrefix("-") {
                    throw ImportUsageError(message: "Unknown option: \(arg)")
                } else {
                    positionals.append(arg)
                }
            }
            index += 1
        }

        if let word = positionals.first, let kind = BundleItemKind(argument: word) {
            invocation.kind = kind
            positionals.removeFirst()
        }
        invocation.names = positionals

        switch subcommand {
        case .validate:
            guard invocation.from != nil else {
                throw ImportUsageError(message: "validate needs --from <bundle folder>.")
            }
            guard invocation.bundleId == nil, invocation.kind == nil, invocation.names.isEmpty else {
                throw ImportUsageError(message: "validate takes only --from and --json.")
            }
        case .install, .update:
            guard invocation.from != nil else {
                throw ImportUsageError(message: "\(subcommand.rawValue) needs --from <bundle folder>.")
            }
            guard invocation.bundleId == nil else {
                throw ImportUsageError(
                    message: "\(subcommand.rawValue) reads the bundle id from the manifest; drop --bundle.")
            }
        case .remove:
            guard invocation.bundleId != nil else {
                throw ImportUsageError(message: "remove needs --bundle <bundle id>.")
            }
            guard invocation.from == nil else {
                throw ImportUsageError(message: "remove works from what was installed; drop --from.")
            }
        case .list:
            guard invocation.from == nil, invocation.kind == nil, invocation.names.isEmpty else {
                throw ImportUsageError(message: "list takes only --bundle and --json.")
            }
        case .help:
            break
        }
        return invocation
    }

    // MARK: Running

    public static func run(_ invocation: ImportInvocation, environment: ImportEnvironment) async -> ImportReport {
        var report = ImportReport(command: invocation.subcommand.rawValue)
        if invocation.subcommand != .list && invocation.subcommand != .help,
            let refusal = rootRefusal(uid: environment.userId())
        {
            report.state = "refused"
            report.issues = [refusal]
            report.exitCode = 1
            return report
        }
        switch invocation.subcommand {
        case .validate:
            return await runValidate(invocation, environment: environment, report: report)
        case .install, .update:
            return await runInstallOrUpdate(invocation, environment: environment, report: report)
        case .remove:
            return await runRemove(invocation, environment: environment, report: report)
        case .list:
            return runList(invocation, report: report)
        case .help:
            report.state = "nothing_to_do"
            report.exitCode = 0
            return report
        }
    }

    static func rootRefusal(uid: uid_t) -> String? {
        guard uid == 0 else { return nil }
        return """
            osaurus import must run as the logged-in user, not root. Osaurus keeps its data \
            in the user's home folder and its secrets in the user's login Keychain, so running \
            as root would provision /var/root instead. From a .pkg postinstall or another root \
            context, run it as the console user:
              CONSOLE_USER=$(stat -f %Su /dev/console)
              launchctl asuser "$(id -u "$CONSOLE_USER")" sudo -u "$CONSOLE_USER" \\
                /Applications/Osaurus.app/Contents/Helpers/osaurus import install --from <bundle> --yes
            """
    }

    /// Loads the bundle and runs every check that does not need the app.
    /// Returns nil (with issues in `report`) when the bundle is unusable.
    private static func loadAndCheck(
        _ invocation: ImportInvocation,
        environment: ImportEnvironment,
        report: inout ImportReport,
        secretsAreErrors: Bool
    ) -> (OsaurusBundle, [BundleItemRef])? {
        let path = (invocation.from! as NSString).expandingTildeInPath
        let bundle: OsaurusBundle
        do {
            bundle = try OsaurusBundle.load(from: URL(fileURLWithPath: path))
        } catch let error as OsaurusBundleError {
            report.issues += error.issues
            return nil
        } catch {
            report.issues.append(error.localizedDescription)
            return nil
        }
        report.bundleId = bundle.id
        report.bundleName = bundle.manifest.name
        report.bundleVersion = bundle.manifest.version
        report.warnings += bundle.warnings

        if let required = bundle.manifest.minOsaurusVersion.flatMap(lenientVersion) {
            if let installedText = environment.appVersion(), let installed = lenientVersion(installedText) {
                if installed < required {
                    report.issues.append(
                        "This bundle needs Osaurus \(required) or newer; Osaurus \(installedText) is installed.")
                }
            } else {
                report.warnings.append(
                    "Could not find the installed Osaurus version to check min_osaurus_version "
                        + "(\(required)). Run the osaurus binary inside Osaurus.app/Contents/Helpers/.")
            }
        }

        let items: [BundleItemRef]
        do {
            items = try bundle.select(kind: invocation.kind, names: invocation.names)
        } catch let error as OsaurusBundleError {
            report.issues += error.issues
            return nil
        } catch {
            report.issues.append(error.localizedDescription)
            return nil
        }

        let servers = items.filter { $0.kind == .mcp }.compactMap { bundle.mcpServer(named: $0.name) }
        var skippedKeychain = false
        for (label, ref) in OsaurusBundle.keychainRefs(in: servers) {
            switch environment.keychainItemExists(ref) {
            case .some(true):
                continue
            case .some(false):
                let message =
                    "\(label): no Keychain item \(ref.display). Store it first, as this user: "
                    + "security add-generic-password -U -s '\(ref.service)' -a '\(ref.account)' "
                    + "-w \"$SECRET\" -T /Applications/Osaurus.app"
                if secretsAreErrors { report.issues.append(message) } else { report.warnings.append(message) }
            case .none:
                skippedKeychain = true
            }
        }
        if skippedKeychain {
            report.warnings.append("Keychain checks were skipped (OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1).")
        }

        for item in items where item.kind == .harnessRuntime {
            guard let runtime = bundle.harnessRuntime(named: item.name) else { continue }
            let program =
                runtime.executable?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (runtime.kind == "claude_code" ? "claude" : "pi")
            if environment.executableOnPath(program) == false {
                report.warnings.append(
                    "harness_runtimes[\(runtime.name)].executable: \(program) was not found on PATH. Install it "
                        + "before an agent runs on this runtime; Osaurus looks it up on the login shell's PATH.")
            }
        }

        guard report.issues.isEmpty else { return nil }
        return (bundle, items)
    }

    private static func runValidate(
        _ invocation: ImportInvocation, environment: ImportEnvironment, report: ImportReport
    ) async -> ImportReport {
        var report = report
        guard let (bundle, items) = loadAndCheck(
            invocation, environment: environment, report: &report, secretsAreErrors: false)
        else {
            report.state = "failed"
            report.exitCode = 1
            return report
        }
        report.risks = bundle.risks(for: items)
        report.items = items.map {
            ImportReport.Item(kind: $0.kind, name: $0.name, action: .install, status: "valid", message: nil)
        }

        let port = environment.port()
        if await environment.isAppRunning(port) {
            let body: [String: Any] = [
                "bundle_path": bundle.rootURL.path,
                "operations": items.map { ["action": "install", "kind": $0.kind.rawValue, "name": $0.name] },
            ]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            if let response = await environment.post(port, "/admin/import/plan", data),
                let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            {
                if let error = object["error"] as? [String: Any] {
                    report.issues += (error["issues"] as? [String]) ?? []
                    if let message = error["message"] as? String, (error["issues"] as? [String]) == nil {
                        report.issues.append(message)
                    }
                } else {
                    report.issues += (object["issues"] as? [String]) ?? []
                    report.warnings += (object["warnings"] as? [String]) ?? []
                }
            } else {
                report.warnings.append(
                    "The running Osaurus could not check the agent and server entries; they are checked "
                        + "again when the bundle is applied.")
            }
        } else {
            report.warnings.append(
                "Osaurus is not running, so agent and MCP server entries were only checked for shape. "
                    + "Open Osaurus and re-run validate for the full schema check.")
        }

        report.state = report.issues.isEmpty ? "validated" : "failed"
        report.exitCode = report.issues.isEmpty ? 0 : 1
        return report
    }

    private static func runInstallOrUpdate(
        _ invocation: ImportInvocation, environment: ImportEnvironment, report: ImportReport
    ) async -> ImportReport {
        var report = report
        guard let (bundle, items) = loadAndCheck(
            invocation, environment: environment, report: &report, secretsAreErrors: true)
        else {
            report.state = "failed"
            report.exitCode = 1
            return report
        }
        report.risks = bundle.risks(for: items)
        if !report.risks.isEmpty && !invocation.yes {
            report.state = "refused"
            report.issues.append(
                "This bundle makes high-risk changes (listed under risks). Re-run with --yes to confirm.")
            report.exitCode = 1
            return report
        }

        let action: ImportAction = invocation.subcommand == .update ? .update : .install
        let request = ImportRequest(
            bundleId: bundle.id,
            bundleName: bundle.manifest.name,
            bundleVersion: bundle.manifest.version,
            operations: items.map {
                ImportOperation(action: action, kind: $0.kind, name: $0.name, explicit: $0.explicit)
            },
            confirmHighRisk: invocation.yes)
        do {
            try ImportQueue.enqueue(request, bundle: bundle)
        } catch {
            report.issues.append("Could not queue the import: \(error.localizedDescription)")
            report.exitCode = 1
            return report
        }
        return await applyOrReportQueued(request, environment: environment, report: report)
    }

    private static func runRemove(
        _ invocation: ImportInvocation, environment: ImportEnvironment, report: ImportReport
    ) async -> ImportReport {
        var report = report
        let bundleId = invocation.bundleId!
        report.bundleId = bundleId
        let receipts = ImportQueue.loadReceipts().filter { $0.bundleId == bundleId }
        let pending = ImportQueue.pending().filter { $0.request.bundleId == bundleId }

        var operations: [ImportOperation] = []
        if invocation.names.isEmpty {
            let cancelled = ImportQueue.cancelPending(bundleId: bundleId)
            if !cancelled.isEmpty { report.cancelledRequests = cancelled }
            operations = receipts
                .filter { invocation.kind == nil || $0.kind == invocation.kind }
                .sorted { ($0.kind, $0.name) > ($1.kind, $1.name) }
                .map { ImportOperation(action: .remove, kind: $0.kind, name: $0.name, explicit: true) }
        } else {
            let queuedNames = pending.flatMap(\.request.operations).filter { $0.action != .remove }
            for name in invocation.names {
                var kinds = Set<BundleItemKind>()
                for receipt in receipts where invocation.kind == nil || receipt.kind == invocation.kind {
                    if receipt.matches(kind: receipt.kind, name: name) { kinds.insert(receipt.kind) }
                }
                for op in queuedNames where invocation.kind == nil || op.kind == invocation.kind {
                    let probe = ImportReceipt(
                        bundleId: bundleId, bundleName: nil, bundleVersion: nil, kind: op.kind, name: op.name,
                        explicit: true, contentHash: "")
                    if probe.matches(kind: op.kind, name: name) { kinds.insert(op.kind) }
                }
                switch kinds.count {
                case 0:
                    report.issues.append("\(bundleId) did not install anything named \"\(name)\".")
                case 1:
                    operations.append(
                        ImportOperation(action: .remove, kind: kinds.first!, name: name, explicit: true))
                default:
                    report.issues.append(
                        "\"\(name)\" names more than one installed item. Say which: "
                            + "osaurus import remove --bundle \(bundleId) agent|skill|mcp|runtime \"\(name)\".")
                }
            }
        }
        guard report.issues.isEmpty else {
            report.state = "failed"
            report.exitCode = 1
            return report
        }
        guard !operations.isEmpty else {
            report.state = "nothing_to_do"
            report.exitCode = 0
            if report.cancelledRequests == nil {
                report.warnings.append("Nothing is installed from \(bundleId).")
            }
            return report
        }

        let request = ImportRequest(
            bundleId: bundleId,
            bundleName: receipts.first?.bundleName,
            bundleVersion: receipts.first?.bundleVersion,
            operations: operations,
            confirmHighRisk: false)
        do {
            try ImportQueue.enqueue(request, bundle: nil)
        } catch {
            report.issues.append("Could not queue the removal: \(error.localizedDescription)")
            report.exitCode = 1
            return report
        }
        return await applyOrReportQueued(request, environment: environment, report: report)
    }

    private static func runList(_ invocation: ImportInvocation, report: ImportReport) -> ImportReport {
        var report = report
        report.bundleId = invocation.bundleId
        let matches: (String) -> Bool = { invocation.bundleId == nil || $0 == invocation.bundleId }
        report.installed = ImportQueue.loadReceipts().filter { matches($0.bundleId) }
        report.queued = ImportQueue.pending().filter { matches($0.request.bundleId) }.map {
            ImportReport.Queued(
                requestId: $0.request.id, bundleId: $0.request.bundleId,
                bundleVersion: $0.request.bundleVersion, createdAt: $0.request.createdAt,
                operations: $0.request.operations)
        }
        report.pendingSecrets = Array(Set((report.installed ?? []).flatMap { $0.pendingSecrets ?? [] })).sorted()
        report.state = "listed"
        report.exitCode = 0
        return report
    }

    /// Asks a running app to apply the request now; otherwise reports it
    /// as queued for the next launch.
    private static func applyOrReportQueued(
        _ request: ImportRequest, environment: ImportEnvironment, report: ImportReport
    ) async -> ImportReport {
        var report = report
        report.requestId = request.id
        let queued = request.operations.map {
            ImportReport.Item(kind: $0.kind, name: $0.name, action: $0.action, status: "queued", message: nil)
        }

        let port = environment.port()
        guard await environment.isAppRunning(port) else {
            report.items = queued
            report.state = "queued"
            report.exitCode = 0
            return report
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["id": request.id])) ?? Data()
        guard let response = await environment.post(port, "/admin/import/apply", body) else {
            report.items = queued
            report.state = "queued"
            report.exitCode = 0
            report.warnings.append("Osaurus did not answer; the import applies the next time it opens.")
            return report
        }
        if let result = try? ImportQueue.decoder().decode(ImportResult.self, from: response.body),
            result.requestId == request.id
        {
            report.items = result.items.map {
                ImportReport.Item(
                    kind: $0.kind, name: $0.name, action: $0.action, status: $0.status.rawValue,
                    message: $0.message, pendingSecrets: $0.pendingSecrets)
            }
            report.pendingSecrets = Array(Set(result.items.flatMap { $0.pendingSecrets ?? [] })).sorted()
            report.state = result.status.rawValue
            report.exitCode = result.exitCode
            return report
        }
        if response.status == 404 {
            report.items = queued
            report.state = "queued"
            report.exitCode = 0
            report.warnings.append(
                "The running Osaurus is too old to apply imports live; the import applies after it is "
                    + "updated and reopened.")
            return report
        }
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        report.items = queued
        report.issues.append(error?["message"] as? String ?? "Osaurus could not apply the import (HTTP \(response.status)).")
        report.issues += (error?["issues"] as? [String]) ?? []
        report.state = "failed"
        report.exitCode = 1
        return report
    }

    // MARK: Helpers

    /// Accepts `0.26` and `0.26.0` alike; app versions are not always
    /// three-part.
    static func lenientVersion(_ text: String) -> SemanticVersion? {
        if let version = SemanticVersion.parse(text) { return version }
        let parts = text.split(separator: ".").map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return SemanticVersion.parse((parts + Array(repeating: "0", count: 3 - parts.count)).joined(separator: "."))
    }

    /// Attributes-only lookup: proves the item exists without reading the
    /// secret, and never prompts. It cannot prove Osaurus may read it.
    /// `~` expands; a name without a slash is searched on PATH.
    static func executableOnPath(_ program: String) -> Bool {
        let expanded = (program as NSString).expandingTildeInPath
        let fm = FileManager.default
        if expanded.contains("/") { return fm.isExecutableFile(atPath: expanded) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":").contains { dir in
            fm.isExecutableFile(atPath: (String(dir) as NSString).appendingPathComponent(expanded))
        }
    }

    static func keychainItemExists(_ ref: BundleSecretRef) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ref.service,
            kSecAttrAccount as String: ref.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: Output

    public static func renderJSON(_ report: ImportReport) -> String {
        guard let data = try? ImportQueue.encoder().encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func render(_ report: ImportReport) {
        if let id = report.bundleId {
            var title = report.bundleName.map { "\($0) (\(id))" } ?? id
            if let version = report.bundleVersion { title += " \(version)" }
            print(title)
        }
        for issue in report.issues { fputs("✗ \(issue)\n", stderr) }
        for warning in report.warnings { print("! \(warning)") }
        if !report.risks.isEmpty {
            print("High-risk changes:")
            for risk in report.risks { print("  ! \(risk)") }
        }
        for item in report.items {
            var line = "\(symbol(item.status)) \(item.kind.rawValue)/\(item.name): \(item.status)"
            if let message = item.message { line += " — \(message)" }
            print(line)
        }
        if let installed = report.installed {
            if installed.isEmpty { print("Nothing installed from bundles.") }
            for (bundleId, receipts) in Dictionary(grouping: installed, by: \.bundleId).sorted(by: { $0.key < $1.key }) {
                let version = receipts.first?.bundleVersion.map { " \($0)" } ?? ""
                print("\(bundleId)\(version)")
                for receipt in receipts {
                    var line = "  \(receipt.kind.rawValue)/\(receipt.name)"
                    if !receipt.explicit { line += " (dependency)" }
                    if let secrets = receipt.pendingSecrets, !secrets.isEmpty {
                        line += " — needs secrets: \(secrets.joined(separator: ", "))"
                    }
                    print(line)
                }
            }
        }
        for request in report.queued ?? [] {
            print("queued \(request.requestId) for \(request.bundleId): \(request.operations.count) item(s)")
        }
        if let cancelled = report.cancelledRequests {
            print("Cancelled \(cancelled.count) queued request(s).")
        }
        switch report.state {
        case "queued":
            print("Queued (\(report.requestId ?? "?")); applies the next time Osaurus opens.")
        case "validated":
            print("Bundle is valid.")
        case "partial" where report.exitCode == 3:
            print("Applied. Finish the steps marked … in Osaurus (see docs/OSAURUS_BUNDLES.md).")
        default:
            break
        }
    }

    private static func symbol(_ status: String) -> String {
        switch status {
        case "done", "valid": return "✓"
        case "unchanged": return "="
        case "failed": return "✗"
        case "needs_user_action": return "…"
        case "queued": return "→"
        default: return "•"
        }
    }

    public static func printUsage() {
        print(
            """
            osaurus import - install agents, skills, MCP servers and harness runtimes from an Osaurus bundle

            Usage:
              osaurus import validate --from <bundle> [--json]
                                      Check a bundle without installing anything.
              osaurus import install  --from <bundle> [agent|skill|mcp|runtime] [<name> ...] [--yes] [--json]
                                      Install items (all of them when no names are given).
                                      Installing an agent also installs the skills, MCP
                                      servers and harness runtime it uses from the same bundle.
              osaurus import update   --from <bundle> [agent|skill|mcp|runtime] [<name> ...] [--yes] [--json]
                                      Update items this bundle installed to the bundle's version.
              osaurus import remove   --bundle <id> [agent|skill|mcp|runtime] [<name> ...] [--json]
                                      Remove items this bundle installed (all when no names).
              osaurus import list     [--bundle <id>] [--json]
                                      Show what bundles installed and what is still queued.

            A bundle is a folder with osaurus-bundle.json. Changes are queued in
            ~/.osaurus/import/ and applied the next time Osaurus opens, or right away
            when it is running. MCP servers, harness runtimes and risky agent switches
            need --yes.
            Secrets are keychain:SERVICE/ACCOUNT references to items your installer
            stores with `security add-generic-password ... -T /Applications/Osaurus.app`.
            Run as the logged-in user, never as root.

            Exit codes: 0 = applied or queued; 1 = a check or change failed;
            3 = applied, but a step must be finished in Osaurus (a secret, a sign-in).

            Guide: https://github.com/osaurus-ai/osaurus/blob/main/docs/OSAURUS_BUNDLES.md
            """
        )
    }
}

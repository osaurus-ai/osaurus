//
//  MCPInstall.swift
//  OsaurusCLICore
//
//  `osaurus mcp install | uninstall --client NAME`: registers `osaurus mcp`
//  with an MCP client.
//
//  - Cursor (`~/.cursor/mcp.json`) and Claude Desktop
//    (`~/Library/Application Support/Claude/claude_desktop_config.json`):
//    the `osaurus` entry under `mcpServers` is merged in, every other entry
//    kept, the old file backed up, the new one written atomically.
//  - Codex (`$CODEX_HOME/config.toml`, else `~/.codex/config.toml`): a
//    `[mcp_servers.osaurus]` table between marker comments, replaced in place
//    on later installs, the way Osaurus manages its Codex provider block.
//  - Claude Code: `claude mcp add --scope user`, or the command printed when
//    `claude` is not on PATH.
//
//  The entry runs this CLI by absolute path, because apps opened from the
//  Dock do not get the shell's PATH. It never carries an access key: install
//  asks Osaurus to approve this command-line tool instead, and `osaurus mcp`
//  uses that approval when the client starts it.
//

import Darwin
import Foundation

public enum MCPClientKind: String, CaseIterable, Sendable {
    case cursor
    case claudeCode = "claude-code"
    case claudeDesktop = "claude-desktop"
    case codex

    var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        }
    }

    static func parse(_ raw: String) -> MCPClientKind? {
        switch raw.lowercased() {
        case "cursor": return .cursor
        case "claude-code", "claude_code", "claudecode", "claude": return .claudeCode
        case "claude-desktop", "claude_desktop", "claudedesktop": return .claudeDesktop
        case "codex": return .codex
        default: return nil
        }
    }
}

public enum MCPInstall {
    static let serverName = "osaurus"

    static let usage = """
        Usage:
          osaurus mcp install --client NAME [--tools PATTERNS] [--workflows [PATTERNS]] [--print] [--force]
          osaurus mcp uninstall --client NAME [--print]

        Clients: cursor, claude-code, claude-desktop, codex.

        install adds `osaurus mcp` to the client's MCP config, by absolute path,
        and asks Osaurus to approve this command-line tool so the client can use
        it without an access key. --tools and --workflows are passed through to
        `osaurus mcp` (see `osaurus mcp --help`).

          osaurus mcp install --client cursor --workflows
          osaurus mcp install --client codex --tools "osaurus_*"

        Other servers in the client's config are kept, and the old file is saved
        next to it with an .osaurus-backup suffix. An `osaurus` entry that differs
        from this one is left alone unless you pass --force. --print shows what
        would be written and changes nothing. Restart the client afterwards.
        """

    struct Options: Equatable {
        var client: MCPClientKind
        var uninstall = false
        var tools: String?
        /// `*` for a bare `--workflows`.
        var workflows: String?
        var printOnly = false
        var force = false
    }

    struct UsageError: Error, Equatable {
        let message: String
    }

    // MARK: - Entry

    public static func execute(args: [String], uninstall: Bool) async {
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        let options: Options
        do {
            options = try parse(args, uninstall: uninstall)
        } catch let error as UsageError {
            fputs("osaurus mcp: \(error.message)\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            exit(EXIT_FAILURE)
        }

        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let command = cliPath()
        let serverArgs = serverArguments(options)

        if !options.uninstall, !options.printOnly {
            guard await approve() else { exit(EXIT_FAILURE) }
        }

        do {
            let message: String
            switch options.client {
            case .claudeCode:
                message = try claudeCode(options, command: command, serverArgs: serverArgs, environment: environment)
            case .codex:
                message = try codex(
                    options, command: command, serverArgs: serverArgs,
                    configURL: codexConfigURL(environment: environment, home: home))
            case .cursor, .claudeDesktop:
                message = try jsonClient(
                    options, command: command, serverArgs: serverArgs,
                    configURL: jsonConfigURL(options.client, home: home)!)
            }
            print(message)
            exit(EXIT_SUCCESS)
        } catch let error as UsageError {
            fputs("\(error.message)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func parse(_ args: [String], uninstall: Bool) throws -> Options {
        var client: MCPClientKind?
        var options = Options(client: .cursor, uninstall: uninstall)
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < args.count, !args[index].hasPrefix("--") else {
                throw UsageError(message: "\(flag) needs a value")
            }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--client", "-c":
                let raw = try value(arg)
                guard let kind = MCPClientKind.parse(raw) else {
                    throw UsageError(
                        message: "unknown client `\(raw)`; use "
                            + MCPClientKind.allCases.map(\.rawValue).joined(separator: ", "))
                }
                client = kind
            case "--tools" where !uninstall: options.tools = try value(arg)
            case "--workflows" where !uninstall:
                if index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                    index += 1
                    options.workflows = args[index]
                } else {
                    options.workflows = "*"
                }
            case "--print", "--dry-run": options.printOnly = true
            case "--force" where !uninstall: options.force = true
            default:
                if let kind = MCPClientKind.parse(arg), client == nil {
                    client = kind
                } else {
                    throw UsageError(message: "unexpected `\(arg)`")
                }
            }
            index += 1
        }
        guard let client else { throw UsageError(message: "--client is required") }
        options.client = client
        return options
    }

    static func serverArguments(_ options: Options) -> [String] {
        var args = ["mcp"]
        if let tools = options.tools { args += ["--tools", tools] }
        if let workflows = options.workflows { args += ["--workflows", workflows] }
        return args
    }

    /// Asks Osaurus to approve this CLI so the client's `osaurus mcp` can use
    /// it. Without a terminal there is nobody to ask; the entry is still
    /// written and the client's calls explain what to run.
    @MainActor
    private static func approve() async -> Bool {
        let server = await LocalServerClient.connect(command: "mcp install", args: [], interactive: true)
        if server.hasToken { return true }
        guard isatty(STDERR_FILENO) != 0 else {
            fputs(
                "Not approved yet: run `osaurus mcp install` in Terminal to approve this command-line tool.\n",
                stderr)
            return true
        }
        guard await server.requireToken() else {
            fputs("Nothing was installed.\n", stderr)
            return false
        }
        return true
    }

    // MARK: - Paths

    /// This CLI's absolute path: the PATH entry it was started from (the
    /// stable `/usr/local/bin/osaurus` link), else the running executable.
    static func cliPath(
        argv0: String = CommandLine.arguments.first ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if argv0.contains("/") {
            let absolute = argv0.hasPrefix("/") ? argv0 : currentDirectory + "/" + argv0
            return URL(fileURLWithPath: absolute).standardizedFileURL.path
        }
        if !argv0.isEmpty {
            for directory in (environment["PATH"] ?? "").split(separator: ":") {
                let candidate = String(directory) + "/" + argv0
                if isExecutable(candidate) { return URL(fileURLWithPath: candidate).standardizedFileURL.path }
            }
        }
        return Bundle.main.executablePath ?? argv0
    }

    static func jsonConfigURL(_ client: MCPClientKind, home: URL) -> URL? {
        switch client {
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .claudeCode, .codex:
            return nil
        }
    }

    static func codexConfigURL(environment: [String: String], home: URL) -> URL {
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).appendingPathComponent("config.toml")
        }
        return home.appendingPathComponent(".codex/config.toml")
    }

    static func displayPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.path
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    // MARK: - JSON clients

    enum JSONMerge: Equatable {
        case write(Data)
        case unchanged
        /// An `osaurus` entry exists and differs; --force replaces it.
        case conflict
    }

    static func entry(command: String, serverArgs: [String]) -> [String: Any] {
        ["command": command, "args": serverArgs]
    }

    /// Adds or removes the `osaurus` entry under `mcpServers`, keeping the
    /// rest of the file's keys.
    static func mergeJSON(existing: Data?, entry: [String: Any]?, force: Bool) throws -> JSONMerge {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing, options: [.json5Allowed]),
                let object = parsed as? [String: Any]
            else { throw UsageError(message: "is not a JSON object; fix it or add the entry by hand (--print)") }
            root = object
        }
        var servers: [String: Any] = [:]
        if let raw = root["mcpServers"] {
            guard let object = raw as? [String: Any] else {
                throw UsageError(message: "has an mcpServers value that is not an object")
            }
            servers = object
        }
        let current = servers[serverName] as? [String: Any]
        if let entry {
            if let current {
                if NSDictionary(dictionary: current).isEqual(to: entry) { return .unchanged }
                if !force { return .conflict }
            }
            servers[serverName] = entry
        } else {
            guard servers[serverName] != nil else { return .unchanged }
            servers.removeValue(forKey: serverName)
        }
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return .write(data + Data("\n".utf8))
    }

    static func jsonSnippet(command: String, serverArgs: [String]) -> String {
        let object = ["mcpServers": [serverName: entry(command: command, serverArgs: serverArgs)]]
        let data =
            (try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonClient(
        _ options: Options,
        command: String,
        serverArgs: [String],
        configURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let name = options.client.displayName
        let path = displayPath(configURL)
        if options.printOnly {
            if options.uninstall { return "Would remove `\(serverName)` from mcpServers in \(path)." }
            return "# \(path)\n" + jsonSnippet(command: command, serverArgs: serverArgs)
        }
        let existing = fileManager.contents(atPath: configURL.path)
        let merge: JSONMerge
        do {
            merge = try mergeJSON(
                existing: existing,
                entry: options.uninstall ? nil : entry(command: command, serverArgs: serverArgs),
                force: options.force)
        } catch let error as UsageError {
            throw UsageError(message: "\(path) \(error.message).")
        }
        switch merge {
        case .unchanged:
            return options.uninstall
                ? "\(name) has no `\(serverName)` MCP server; nothing to remove."
                : "\(name) already runs `osaurus mcp` with these options (\(path))."
        case .conflict:
            throw UsageError(
                message: "\(path) already has a different `\(serverName)` MCP server. Pass --force to replace it, "
                    + "or --print to see the new entry.")
        case .write(let data):
            try write(data, to: configURL, backup: existing, fileManager: fileManager)
            return options.uninstall
                ? "Removed Osaurus from \(name) (\(path)). Restart \(name)."
                : "Added Osaurus to \(name) (\(path)). Restart \(name) to load it."
        }
    }

    static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".osaurus-backup")
    }

    private static func write(_ data: Data, to url: URL, backup: Data?, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let backup { try backup.write(to: backupURL(for: url), options: .atomic) }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Codex

    static let codexBlockBegin = "# >>> osaurus mcp (managed by `osaurus mcp install`) >>>"
    static let codexBlockEnd = "# <<< osaurus mcp <<<"

    /// Codex waits 10 s for a server to start and 60 s for a tool by
    /// default. `osaurus mcp` may launch Osaurus first, and a workflow tool
    /// waits up to `MCPCommand.callTimeout` for its run.
    static func codexBlock(command: String, serverArgs: [String]) -> String {
        [
            codexBlockBegin,
            "[mcp_servers.\(serverName)]",
            "command = \(tomlString(command))",
            "args = [" + serverArgs.map(tomlString).joined(separator: ", ") + "]",
            "startup_timeout_sec = 60",
            "tool_timeout_sec = \(Int(MCPCommand.callTimeout(environment: [:])))",
            codexBlockEnd,
        ].joined(separator: "\n") + "\n"
    }

    enum CodexMerge: Equatable {
        case write(String)
        case unchanged
        /// `mcp_servers.osaurus` is defined outside the markers.
        case conflict
    }

    /// Replaces the managed block in place, appends it, or (with nil)
    /// removes it, leaving the rest of the file as it was.
    static func mergeCodex(existing: String, block: String?) -> CodexMerge {
        var lines = existing.components(separatedBy: "\n")
        let begin = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == codexBlockBegin }
        let end = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == codexBlockEnd }
        let managed: Range<Int>? = {
            guard let begin, let end, end >= begin else { return nil }
            return begin..<(end + 1)
        }()
        for (index, line) in lines.enumerated() where !(managed?.contains(index) ?? false) {
            if definesOsaurusServer(line) { return block == nil ? .unchanged : .conflict }
        }
        guard let block else {
            guard var range = managed else { return .unchanged }
            if range.lowerBound > 0, lines[range.lowerBound - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                range = (range.lowerBound - 1)..<range.upperBound
            }
            lines.removeSubrange(range)
            return .write(lines.joined(separator: "\n"))
        }
        let blockLines = String(block.dropLast(block.hasSuffix("\n") ? 1 : 0)).components(separatedBy: "\n")
        if let managed {
            if Array(lines[managed]) == blockLines { return .unchanged }
            lines.replaceSubrange(managed, with: blockLines)
            return .write(lines.joined(separator: "\n"))
        }
        var prefix = existing
        if prefix.isEmpty || prefix.hasSuffix("\n\n") {
        } else if prefix.hasSuffix("\n") {
            prefix += "\n"
        } else {
            prefix += "\n\n"
        }
        return .write(prefix + blockLines.joined(separator: "\n") + "\n")
    }

    static func definesOsaurusServer(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        let patterns = [
            #"^\[\s*mcp_servers\s*\.\s*"?osaurus"?\s*(\]|\.)"#,
            #"^mcp_servers\s*\.\s*"?osaurus"?\s*[.=]"#,
            #"^mcp_servers\s*=.*\bosaurus\b"#,
        ]
        return patterns.contains { trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func codex(
        _ options: Options,
        command: String,
        serverArgs: [String],
        configURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let path = displayPath(configURL)
        let block = codexBlock(command: command, serverArgs: serverArgs)
        if options.printOnly {
            return options.uninstall ? "Would remove the Osaurus MCP block from \(path)." : "# \(path)\n" + block
        }
        let existingData = fileManager.contents(atPath: configURL.path)
        let existing = existingData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        switch mergeCodex(existing: existing, block: options.uninstall ? nil : block) {
        case .unchanged:
            return options.uninstall
                ? "Codex has no Osaurus MCP block in \(path); nothing to remove."
                : "Codex already runs `osaurus mcp` with these options (\(path))."
        case .conflict:
            throw UsageError(
                message: "\(path) already defines mcp_servers.osaurus outside the Osaurus-managed block. Remove "
                    + "it, then run this again, or add the block by hand (--print).")
        case .write(let contents):
            try write(Data(contents.utf8), to: configURL, backup: existingData, fileManager: fileManager)
            return options.uninstall
                ? "Removed Osaurus from Codex (\(path))."
                : "Added Osaurus to Codex (\(path)). New Codex sessions will load it."
        }
    }

    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Claude Code

    static func claudeCodeArguments(_ options: Options, command: String, serverArgs: [String]) -> [String] {
        options.uninstall
            ? ["mcp", "remove", "--scope", "user", serverName]
            : ["mcp", "add", "--scope", "user", serverName, "--", command] + serverArgs
    }

    static func shellQuoted(_ arguments: [String]) -> String {
        arguments.map { arg in
            arg.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@".contains($0) })
                ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        .joined(separator: " ")
    }

    static func findClaude(environment: [String: String], home: URL) -> String? {
        let directories =
            (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appendingPathComponent(".claude/local").path, home.appendingPathComponent(".local/bin").path]
        return directories.map { $0 + "/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func claudeCode(
        _ options: Options,
        command: String,
        serverArgs: [String],
        environment: [String: String]
    ) throws -> String {
        let arguments = claudeCodeArguments(options, command: command, serverArgs: serverArgs)
        let printable = "claude " + shellQuoted(arguments)
        if options.printOnly { return printable }
        guard let claude = findClaude(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
        else {
            return "`claude` is not on your PATH. Run this to \(options.uninstall ? "remove" : "add") Osaurus:\n"
                + printable
        }
        if !options.uninstall, options.force {
            _ = run(claude, ["mcp", "remove", "--scope", "user", serverName])
        }
        let (status, output) = run(claude, arguments)
        guard status == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !options.uninstall, detail.localizedCaseInsensitiveContains("already exists") {
                throw UsageError(
                    message: "Claude Code already has an `\(serverName)` MCP server. Pass --force to replace it.")
            }
            throw UsageError(message: "`\(printable)` failed\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return options.uninstall
            ? "Removed Osaurus from Claude Code."
            : "Added Osaurus to Claude Code (user scope). New Claude Code sessions will load it."
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

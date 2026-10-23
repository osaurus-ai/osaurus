//
//  ClaudeCodeHarnessAdapter.swift
//  osaurus
//
//  Claude Code over `--input-format stream-json`: one process per chat, one
//  `user` line per message, one `result` frame per turn. The conversation
//  lives in Claude Code's own session store, keyed by the Osaurus chat id, so
//  a relaunch resumes it with `--resume`.
//

import Foundation

struct ClaudeCodeHarnessAdapter: HarnessAdapter {
    let runtime: HarnessRuntime

    /// Inherited variables that would change how `claude` authenticates.
    /// `ANTHROPIC_API_KEY` silently moves the run off the user's Claude
    /// subscription onto API billing.
    static let removedEnvironment: Set<String> = ["ANTHROPIC_API_KEY"]

    func tokenToolScope(context: HarnessLaunchContext) -> Set<String>? {
        let config = context.claudeCode
        guard config.mode == .agent, config.allowOsaurusTools else { return [] }
        return Set(ClaudeCodeConfiguration.osaurusToolPatterns(allowConfigWrites: Self.allowsConfigWrites(context)))
    }

    func tokenAllowsConfigWrites(context: HarnessLaunchContext) -> Bool {
        let config = context.claudeCode
        return config.mode == .agent && config.allowOsaurusTools && Self.allowsConfigWrites(context)
    }

    /// `osaurus_config` only ever runs for the Default agent, so a custom
    /// agent's opt-in is ignored rather than handed a tool that always refuses.
    static func allowsConfigWrites(_ context: HarnessLaunchContext) -> Bool {
        context.claudeCode.allowOsaurusConfigWrites && context.agentId == Agent.defaultId
    }

    func launchPlan(context: HarnessLaunchContext, token: String?) throws -> HarnessLaunchPlan {
        let config = context.claudeCode
        var temporaryFiles: [URL] = []
        let privateDirectory = HarnessScratch.privateDirectory(chatId: context.chatId)

        var arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            // Only MCP servers Osaurus passes may load, never the user's
            // terminal configuration.
            "--strict-mcp-config",
            "--model", config.resolvedModel,
        ]

        let sessionId = context.chatId.uuidString.lowercased()
        let environmentForLookup = runtime.environment
        let resume: Bool
        switch context.sessionMode {
        case .forceResume: resume = true
        case .forceNew: resume = false
        case .automatic:
            resume = ClaudeCodeSessionLocator.sessionExists(id: sessionId, environment: environmentForLookup)
        }
        arguments += resume ? ["--resume", sessionId] : ["--session-id", sessionId]

        var bridgeAttached = false
        switch config.mode {
        case .textOnly:
            arguments += ["--tools", ""]
        case .agent:
            // Fail-closed: anything not allow-listed is denied, not prompted.
            arguments += ["--permission-mode", "dontAsk"]
            var allowed = ClaudeCodeConfiguration.defaultAllowedTools
            if config.allowWrites {
                allowed.append(ClaudeCodeConfiguration.scopedWriteRule(root: context.workingDirectory))
            }
            if config.allowShell { allowed += ClaudeCodeConfiguration.shellTools }
            if config.allowOsaurusTools, context.serverReachable, let cliPath = context.osaurusCLIPath,
                let json = ClaudeCodeConfiguration.mcpConfigJSON(
                    cliPath: cliPath,
                    allowConfigWrites: Self.allowsConfigWrites(context),
                    bridgeGrant: token
                )
            {
                let url = try HarnessScratch.writePrivateFile(
                    named: "mcp-config-\(UUID().uuidString).json",
                    contents: json,
                    in: privateDirectory
                )
                temporaryFiles.append(url)
                arguments += ["--mcp-config", url.path]
                allowed += ClaudeCodeConfiguration.osaurusAllowedToolNames(
                    allowConfigWrites: Self.allowsConfigWrites(context)
                )
                bridgeAttached = true
            }
            arguments += ["--allowedTools", allowed.joined(separator: ",")]
        }

        var promptParts: [String] = []
        if let systemPrompt = context.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !systemPrompt.isEmpty
        {
            promptParts.append(systemPrompt)
        }
        if config.mode == .agent, config.allowOsaurusTools {
            promptParts.append(
                ClaudeCodeConfiguration.osaurusToolsSystemNote(
                    available: bridgeAttached,
                    allowConfigWrites: Self.allowsConfigWrites(context),
                    reason: bridgeAttached ? nil : (context.osaurusCLIPath == nil ? .notEnabled : .serverNotRunning)
                )
            )
        }
        if !promptParts.isEmpty {
            // A file, not `--append-system-prompt`: argv is visible to every
            // process the user runs.
            let url = try HarnessScratch.writePrivateFile(
                named: "system-prompt-\(UUID().uuidString).md",
                contents: promptParts.joined(separator: "\n\n"),
                in: privateDirectory
            )
            temporaryFiles.append(url)
            arguments += ["--append-system-prompt-file", url.path]
        }

        arguments += runtime.resolvedArguments(
            chatId: context.chatId,
            agentId: context.agentId,
            workingDirectory: context.workingDirectory
        )

        var environment = runtime.environment
        for (key, value) in HarnessEnvironment.contract(context: context, token: token) {
            environment[key] = value
        }

        return HarnessLaunchPlan(
            spec: HarnessProcess.LaunchSpec(
                executable: runtime.executable,
                arguments: arguments,
                environment: environment,
                removingEnvironment: HarnessEnvironment.alwaysRemoved.union(Self.removedEnvironment),
                workingDirectory: context.workingDirectory,
                runtimeName: runtime.displayName
            ),
            temporaryFiles: temporaryFiles
        )
    }

    func makeCodec() -> HarnessCodec {
        ClaudeCodeHarnessCodec(runtimeName: runtime.displayName)
    }

    /// The session file lookup can miss (a `CLAUDE_CONFIG_DIR` the app can't
    /// see, a session pruned by Claude). Both mistakes fail fast with a
    /// recognizable message, so flip the mode once.
    func retryMode(after error: HarnessError, context: HarnessLaunchContext) -> HarnessLaunchContext.SessionMode? {
        let text = (error.errorDescription ?? "").lowercased()
        if text.contains("already in use") { return .forceResume }
        if text.contains("no conversation found") { return .forceNew }
        return nil
    }
}

final class ClaudeCodeHarnessCodec: HarnessCodec {
    private let runtimeName: String
    private var decoder = ClaudeCodeStreamDecoder()

    init(runtimeName: String) {
        self.runtimeName = runtimeName
    }

    var pendingDialogIds: [String] { [] }

    func beginTurn(_ message: HarnessUserMessage) throws -> [Data] {
        var content: [[String: Any]] = []
        for image in message.images {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.data.base64EncodedString(),
                ],
            ])
        }
        content.append(["type": "text", "text": message.text])
        return [
            try HarnessJSON.encode([
                "type": "user",
                "message": ["role": "user", "content": content],
            ])
        ]
    }

    func decode(line: Data) -> (events: [HarnessEvent], replies: [Data]) {
        let decoded = decoder.decode(line: line)
        var events: [HarnessEvent] = []
        var turnEnded = false
        var failure: String?
        for event in decoded {
            switch event {
            case .text(let text):
                events.append(.text(text))
            case .reasoning(let text):
                events.append(.reasoning(text))
            case .toolTrace(let trace):
                // The `result` frame's synthetic "close everything" trace is
                // replaced by the turn-end event.
                guard !trace.endRun else { continue }
                if trace.phase == "started" {
                    events.append(.toolStarted(callId: trace.callId, name: trace.name))
                } else {
                    events.append(.toolFinished(callId: trace.callId, name: trace.name, isError: trace.isError))
                }
            case .stats(let outputTokens, let tokensPerSecond, let stopReason):
                events.append(.stats(outputTokens: outputTokens, tokensPerSecond: tokensPerSecond, stopReason: stopReason))
                turnEnded = true
            case .rateLimit(let status, let utilization, _):
                guard status != "allowed" else { continue }
                let percent = Int((utilization * 100).rounded())
                events.append(
                    .notice(
                        String(format: L("Claude subscription usage at %d%%"), percent),
                        isError: status != "allowed_warning"
                    )
                )
            case .failure(let detail):
                failure = detail
            }
        }
        if let failure {
            events.append(.turnFailed(HarnessError.classify(runtime: runtimeName, detail: failure)))
        } else if turnEnded {
            events.append(.turnCompleted)
        }
        return (events, [])
    }

    func interruptRecords() -> [Data] {
        let record = try? HarnessJSON.encode([
            "type": "control_request",
            "request_id": "osaurus-interrupt-\(UUID().uuidString)",
            "request": ["subtype": "interrupt"],
        ])
        return record.map { [$0] } ?? []
    }

    func dialogResponse(id: String, response: HarnessDialogResponse) -> Data? { nil }
}

/// Finds Claude Code's on-disk session for an id, to choose between
/// `--session-id` (new) and `--resume` (existing). Sessions live at
/// `<config dir>/projects/<project>/<id>.jsonl`, under whichever project
/// directory the session started in.
enum ClaudeCodeSessionLocator {
    static func configDirectory(environment: [String: String]) -> URL {
        let override =
            environment["CLAUDE_CONFIG_DIR"]
            ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: ExecutableLocator.expandUserPath(override), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static func sessionExists(id: String, environment: [String: String]) -> Bool {
        let projects = configDirectory(environment: environment).appendingPathComponent("projects", isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: projects,
                includingPropertiesForKeys: nil
            )
        else { return false }
        return entries.contains { project in
            FileManager.default.fileExists(atPath: project.appendingPathComponent("\(id).jsonl").path)
        }
    }
}

/// Per-chat scratch area: the working directory for chats without a folder,
/// and where per-process private files (system prompt, MCP config) live.
enum HarnessScratch {
    static func root() -> URL {
        OsaurusPaths.root().appendingPathComponent("harness", isDirectory: true)
    }

    static func directory(chatId: UUID) -> URL {
        let dir = root().appendingPathComponent(chatId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Private per-process files sit beside, not inside, the scratch working
    /// directory so a harness listing its cwd never sees its own token.
    static func privateDirectory(chatId: UUID) -> URL {
        let dir = root().appendingPathComponent(".private", isDirectory: true)
            .appendingPathComponent(chatId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// Write a file only the current user can read.
    static func writePrivateFile(named name: String, contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw HarnessError.launchFailed(runtime: name, detail: L("Couldn't write a temporary file."))
        }
        return url
    }
}

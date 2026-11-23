//
//  ClaudeCodeConfiguration.swift
//  osaurus
//
//  Static configuration for the Claude Code harness: locating the user's
//  `claude` binary, the model aliases, tool rules, and sign-in.
//
//  Osaurus drives the user's own locally-authenticated Claude Code install as
//  a subprocess. There are no credentials here by design — the user runs
//  `claude login` once in their terminal and the CLI owns that session. This
//  is the sanctioned way to reach a Claude Pro/Max subscription
//  programmatically; Osaurus never mints or stores an Anthropic token.
//

import Foundation
import SwiftUI

/// How much of Claude Code's own agent loop the caller wants.
public enum ClaudeCodeMode: String, Codable, Sendable, CaseIterable {
    /// Claude Code runs its own tools and multi-turn loop; Osaurus renders the
    /// text plus a sanitized read-only tool trace.
    case agent
    /// All built-in tools disabled — the CLI is a plain text generator and
    /// Osaurus's own agent loop runs on top.
    ///
    /// Note that Osaurus's tools are *not* forwarded to the CLI in this mode:
    /// `claude -p` accepts tool definitions only over MCP, never as
    /// OpenAI-style schemas. Text-only genuinely means "no tools at all".
    case textOnly
}

/// Model aliases Osaurus exposes for the CLI. These are Claude Code's own
/// `--model` aliases rather than pinned model ids, so the CLI keeps resolving
/// them to whatever the current generation is without an Osaurus release.
public enum ClaudeCodeModel: String, CaseIterable, Sendable {
    case sonnet
    case opus
    case fable
    case haiku

    public var displayName: String {
        switch self {
        case .sonnet: return "Claude Code (Sonnet)"
        case .opus: return "Claude Code (Opus)"
        case .fable: return "Claude Code (Fable)"
        case .haiku: return "Claude Code (Haiku)"
        }
    }

    /// Parse a legacy `claude-code/sonnet` model id back into an alias.
    public static func fromPickerId(_ id: String) -> ClaudeCodeModel? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(ClaudeCodeConfiguration.modelPrefix) else { return nil }
        let alias = String(trimmed.dropFirst(ClaudeCodeConfiguration.modelPrefix.count))
        return ClaudeCodeModel(rawValue: alias.lowercased())
    }
}

/// `--effort` levels. Unset leaves the CLI on its own per-model default; a
/// level the selected model doesn't support is the CLI's call to downgrade.
public enum ClaudeCodeEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    public var displayName: String {
        switch self {
        case .low: return L("Low")
        case .medium: return L("Medium")
        case .high: return L("High")
        case .xhigh: return L("Extra High")
        case .max: return L("Max")
        }
    }
}

extension ClaudeCodeEffort {
    /// The chat picker's Reasoning Effort row for a Claude Code agent: a
    /// Default segment (no `--effort`, the CLI's per-model default) plus every
    /// level. Reads and writes the agent's `ClaudeCodeAgentConfig.effort`.
    static let pickerOptionID = "reasoningEffort"

    static var pickerOption: ModelOptionDefinition {
        ModelOptionDefinition(
            id: pickerOptionID,
            label: L("Reasoning Effort"),
            kind: .segmented(
                [ModelOptionSegment(id: ModelOptionSegment.defaultID, label: L("Default"))]
                    + allCases.map { ModelOptionSegment(id: $0.rawValue, label: $0.displayName) }
            ),
            help: L("Default leaves Claude Code on its own per-model default. Applies from the next message.")
        )
    }

    /// The stored `effort` for a picker segment; nil for Default.
    static func storedValue(forSegment id: String?) -> String? {
        guard let id, let effort = ClaudeCodeEffort(rawValue: id) else { return nil }
        return effort.rawValue
    }
}

/// Decoded `claude auth status --json`.
///
/// Only the fields Osaurus actually shows are modeled; the CLI adds keys over
/// time and unknown ones are ignored by the synthesized decoder. Everything
/// except `loggedIn` is optional because an enterprise/gateway login reports a
/// different subset than a personal claude.ai one.
public struct ClaudeCodeAuthStatus: Codable, Sendable, Equatable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let subscriptionType: String?
    public let email: String?
    public let orgName: String?

    public init(
        loggedIn: Bool,
        authMethod: String? = nil,
        subscriptionType: String? = nil,
        email: String? = nil,
        orgName: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.subscriptionType = subscriptionType
        self.email = email
        self.orgName = orgName
    }

    /// Human-facing plan name — `"pro"` → `"Pro"`. Nil when the CLI didn't
    /// report one (an API-key or gateway login has no subscription tier).
    public var displayPlan: String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// True when this login actually draws on a Claude subscription, rather
    /// than billing an API key through the CLI. Drives whether we tell the user
    /// they're set up for subscription use.
    public var usesSubscription: Bool {
        loggedIn && displayPlan != nil
    }
}

/// The three states the setup UI renders.
public enum ClaudeCodeSetupState: Sendable, Equatable {
    case notInstalled(searchedPath: String)
    /// The installed CLI predates machine-readable authentication commands.
    /// It may already be signed in, but Osaurus cannot prove that without
    /// spending a generation, so the UI offers a manual terminal check.
    case statusUnavailable(cliVersion: String?)
    case signedOut
    case signedIn(ClaudeCodeAuthStatus)
}

public enum ClaudeCodeConfiguration {
    /// Prefix of the model ids Claude Code used before it became a harness
    /// runtime. Only read to migrate agents and to refuse those ids.
    public static let modelPrefix = "claude-code/"

    /// Claude's brand gradient (`BrandPalette.claudeCode`).
    public static var brandGradient: [Color] { BrandPalette.claudeCode }

    /// The command we look for on PATH.
    public static let executableName = "claude"

    /// Read-only built-ins allowed by default. Anything outside this list is
    /// refused by `--permission-mode dontAsk`, which is what makes the default
    /// fail-closed: a non-interactive run can't prompt, so an un-allowlisted
    /// tool is denied rather than silently approved.
    public static let defaultAllowedTools = ["Read", "Grep", "Glob"]

    /// The only way writes are granted. Claude Code's `Edit(...)` rules govern
    /// every built-in that edits files (Edit, Write, NotebookEdit). `//` anchors
    /// the gitignore-style pattern
    /// at the filesystem root; the path goes through `realpath` because Claude
    /// matches against real paths (`/tmp` is `/private/tmp`), and Foundation's
    /// `resolvingSymlinksInPath` strips `/private` instead of adding it.
    public static func scopedWriteRule(root: URL) -> String {
        let standardized = root.standardizedFileURL.path
        let resolved =
            standardized.withCString { pointer -> String? in
                guard let real = realpath(pointer, nil) else { return nil }
                defer { free(real) }
                return String(cString: real)
            } ?? standardized
        let trimmed = resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
        return "Edit(/\(trimmed)/**)"
    }

    /// Tools added when the agent opts into shell access. `Monitor` runs a
    /// shell command in the background under the same rules as Bash.
    public static let shellTools = ["Bash", "Monitor"]

    /// The other built-ins that run commands or code — what the CLI's own
    /// `--restricted` mode strips, besides the shell tools and WebFetch.
    /// Hidden without shell access; never auto-approved.
    public static let codeRunningTools = ["CronCreate", "LSP", "RemoteTrigger", "Workflow"]

    /// Built-ins whose writes `Edit(...)` rules govern.
    public static let writeTools = ["Edit", "Write", "NotebookEdit"]

    /// Built-ins no toggle grants.
    public static let neverAllowedTools = ["WebFetch", "WebSearch"]

    /// Permission-free built-ins kept on every agent run. Names a CLI no
    /// longer has are ignored by `--tools`.
    public static let permissionFreeTools = ["TodoWrite"]

    /// The `--tools` value: the only built-ins the model sees. An allow list,
    /// because new CLI releases add built-ins (agent teams, scheduling,
    /// worktrees, `ToolSearch`) that a deny list never names.
    public static func availableBuiltinTools(allowWrites: Bool, allowShell: Bool) -> [String] {
        var tools = defaultAllowedTools + permissionFreeTools
        if allowWrites { tools += writeTools }
        if allowShell { tools += shellTools }
        return tools
    }

    /// Built-ins to remove from the model's tool list for this run.
    ///
    /// `dontAsk` refuses an un-allowlisted tool only after the model calls it,
    /// so a visible-but-refused tool shows up as a failed call the model keeps
    /// retrying. Claude Code also auto-approves read-only shell commands, so a
    /// visible Bash or Monitor would run `ls` with shell access off. A bare
    /// name in `--disallowedTools` drops the tool from the list entirely, and
    /// a deny beats an allow, so a granted tool must never appear here.
    public static func hiddenBuiltinTools(allowWrites: Bool, allowShell: Bool) -> [String] {
        var hidden: [String] = []
        if !allowShell { hidden += shellTools + codeRunningTools }
        if !allowWrites { hidden += writeTools }
        return hidden + neverAllowedTools
    }

    /// What the chat shows for a tool call Claude Code's permission rules
    /// refused, naming the toggle that grants it.
    public static func permissionDeniedMessage(tool: String) -> String {
        if shellTools.contains(tool) {
            return L(
                "Claude Code isn't allowed to run shell commands for this agent. Turn on Allow shell commands in the agent's Claude Code Options."
            )
        }
        if writeTools.contains(tool) {
            return L(
                "Claude Code isn't allowed to change this file. File changes need Allow file changes in the agent's Claude Code Options and stay limited to the chat folder."
            )
        }
        return L("Claude Code isn't allowed to use this tool for this agent.")
    }

    /// What the chat shows when the model called a tool this run doesn't have.
    public static func unavailableToolMessage(tool: String) -> String {
        L("Claude Code doesn't have this tool on this run, so the call didn't happen.")
    }

    /// The name a tool card shows: Osaurus's own tools without the MCP
    /// namespace Claude Code puts on them.
    public static func displayToolName(_ name: String) -> String {
        let prefix = "mcp__\(mcpServerName)__"
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    // MARK: - Osaurus tools over MCP

    /// The MCP server name Osaurus registers itself under. Claude Code exposes
    /// MCP tools as `mcp__<server>__<tool>`, so this also fixes the allow-list
    /// spelling.
    public static let mcpServerName = "osaurus"

    /// Osaurus config tools that only read, added to every agent's harness
    /// surface whatever its own tool list says.
    public static let osaurusReadOnlyTools = ["osaurus_inspect", "osaurus_help"]

    /// The Architect's Osaurus tools, sorted so the argv is stable.
    static var architectToolPatterns: [String] { HarnessGrantStore.architectToolNames.sorted() }

    static func namespaced(_ tools: [String]) -> [String] {
        tools.map { "mcp__\(mcpServerName)__\($0)" }
    }

    /// Claude Code's own MCP tool timeout (milliseconds). `workflow_test`
    /// runs a whole workflow, far past the CLI's default.
    static let mcpToolTimeoutMilliseconds = 15 * 60 * 1000

    /// Why Osaurus's own tools aren't reachable on this run.
    public enum OsaurusToolsUnavailableReason: Sendable, Equatable {
        /// Use Osaurus Tools is off for this agent.
        case notEnabled
        /// The agent's own tools are off, so there is nothing to attach.
        case agentToolsOff
        /// This copy of Osaurus has no embedded `osaurus` CLI to proxy through.
        case bridgeMissing
        /// The local HTTP server the bridge proxies to is down.
        case serverNotRunning
        /// Text-only mode disables every tool.
        case textOnlyMode
    }

    /// A note appended to the system prompt describing which Osaurus tools this
    /// run actually has.
    ///
    /// An agent's own instructions may name Osaurus tools. They only arrive
    /// when the MCP bridge is attached, so without this note the model is told
    /// to use tools it cannot see and spends the turn guessing at permission
    /// errors instead of answering.
    /// - Parameter tools: The attached tools; empty when the bridge isn't.
    public static func osaurusToolsSystemNote(
        tools: Set<String>,
        reason: OsaurusToolsUnavailableReason? = nil
    ) -> String {
        guard !tools.isEmpty else {
            let cause: String
            switch reason {
            case .serverNotRunning:
                cause = L(
                    "the Osaurus server is not running — tell the user to start it from the Osaurus app"
                )
            case .textOnlyMode:
                cause = L("this agent runs Claude Code in text-only mode, which disables all tools")
            case .agentToolsOff:
                cause = L("this agent's tools are turned off in its settings")
            case .bridgeMissing:
                cause = L("this copy of Osaurus is missing the bundled part that connects them")
            case .notEnabled, nil:
                cause = L(
                    "they are switched off for this agent — tell the user to turn on \"Use Osaurus Tools\" in this agent's Claude Code Options"
                )
            }
            return String(
                format: L(
                    "You do NOT have any Osaurus tools (`mcp__osaurus__*`) on this run, because %@. Do not try to call them and do not speculate about permission errors. If the user asks for something only Osaurus can do, say plainly that you can't right now, explain why, and offer what they can do themselves."
                ),
                cause
            )
        }

        var note = L(
            "The `mcp__osaurus__*` tools are this agent's Osaurus tools: its plugins, apps, and settings, run by Osaurus with its permission checks. Use them for anything they cover instead of working around them. Tools named in your instructions that aren't among them are not present on this run."
        )
        if !tools.contains(HarnessGrantStore.configWriteToolName) {
            note += " "
            note += L(
                "You cannot change Osaurus's configuration; describe the change the user should make instead."
            )
        }
        return note
    }

    /// The Default agent's delegation note: who `run_workflow` can hand a
    /// request to. Nil without `run_workflow` or anyone to run.
    @MainActor
    static func teammateRoutingNote(tools: Set<String>) -> String? {
        guard tools.contains(RunWorkflowTool.toolName),
            let team = SystemPromptTemplates.orchestratorTeam(
                RoutableWorkflowCatalog.team(), canHandOffToConfigurator: false)
        else { return nil }
        let rules = L(
            "When a request needs something a teammate below covers (their calendar, reminders, mail, notes, or a workflow's job), call `mcp__osaurus__run_workflow` with `workflow` set to its name and `input` set to `{\"task\": <the user's request>}` for an agent, then answer from its result. Osaurus shows the run in the chat and asks the user for any approval it needs, so don't ask first. Do the work yourself when your own tools cover it."
        )
        return team + "\n\n" + rules
    }

    /// The Architect's note when its drafting tools can't attach, so it says
    /// why instead of improvising with tools it doesn't have.
    public static func architectToolsUnavailableNote(reason: OsaurusToolsUnavailableReason) -> String {
        let cause =
            reason == .serverNotRunning
            ? L("the Osaurus server is not running — tell the person to start it from the Osaurus app")
            : L("this copy of Osaurus is missing the bundled part that connects them")
        return String(
            format: L(
                "Your workflow tools are NOT connected on this run, because %@. You cannot read or change the draft. Do not call any tool; say plainly that you can't build the workflow until this is fixed, then send a new message."
            ),
            cause
        )
    }

    /// Absolute path to the `osaurus` CLI shipped inside this app bundle.
    ///
    /// Mirrors `ConfigurationView.resolveCLIExecutableURL`'s order: the
    /// `Helpers` copy embedded by `make app` first, then the `MacOS` fallback.
    /// Returns nil in a bare source build with no embedded CLI, which callers
    /// treat as "no MCP bridge" rather than falling back to a PATH lookup — a
    /// stray `osaurus` on PATH could belong to a different install talking to a
    /// different data root.
    public static func embeddedCLIPath(bundle: Bundle = .main) -> String? {
        let fm = FileManager.default
        for relative in ["Contents/Helpers/osaurus", "Contents/MacOS/osaurus"] {
            let candidate = bundle.bundleURL.appendingPathComponent(relative, isDirectory: false)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    /// The `--mcp-config` payload pointing Claude Code back at this Osaurus.
    ///
    /// `osaurus mcp` proxies to `127.0.0.1:<port>` and relies on loopback trust
    /// when network exposure is off, so no credential is embedded here.
    /// - Parameter bridgeGrant: The process's agent token, proving which
    ///   agent's chat this subprocess serves. Delivered through the server block's `env` rather
    ///   than `args`, so it never appears in `ps` output for other processes on
    ///   the machine. Nil omits it, which leaves the child unattributed — fine
    ///   for a custom agent, but the Default agent's tools will refuse.
    /// - Parameter patterns: The `--tools` value handed to `osaurus mcp`, so
    ///   the proxy hides everything else at the source. Empty returns nil.
    /// The `osaurus` CLI's server-port override.
    static let osaurusCLIPortKey = "OSU_PORT"

    /// `port` is the server the launch resolved; `osaurus mcp` otherwise
    /// reads the saved server port, which a server on another port (the
    /// eval lane's) doesn't match.
    static func mcpConfigJSON(cliPath: String, patterns: [String], bridgeGrant: String?, port: Int? = nil) -> String? {
        guard !patterns.isEmpty else { return nil }
        var server: [String: Any] = [
            "command": cliPath,
            "args": ["mcp", "--tools", patterns.joined(separator: ",")],
        ]
        var env: [String: String] = [:]
        if let bridgeGrant, !bridgeGrant.isEmpty { env[HarnessGrantStore.environmentKey] = bridgeGrant }
        if let port { env[osaurusCLIPortKey] = String(port) }
        if !env.isEmpty { server["env"] = env }
        let payload: [String: Any] = ["mcpServers": [mcpServerName: server]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Binary resolution

    /// Absolute path to the user's `claude`, or nil when it isn't installed
    /// / isn't visible on this app's PATH.
    public static func resolveExecutable(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        ExecutableLocator.resolve(command: executableName, env: env)
    }

    public static func searchedPath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        ExecutableLocator.searchPath(env: env)
    }

    /// Cheap availability probe: does the binary exist and is it executable?
    ///
    /// Deliberately does *not* spawn `claude --version` — this is called during
    /// layout, and paying a process spawn there would stall the UI.
    public static func isAvailable(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolveExecutable(env: env) != nil
    }

    // MARK: - Authentication

    /// Decode a `claude auth status --json` payload.
    ///
    /// Split out from `authStatus()` so the parsing is testable without a
    /// subprocess. The CLI prints JSON on stdout for both signed-in and
    /// signed-out states, so a decode failure means something else went wrong
    /// (old CLI without `auth status`, a crash) and is reported as signed-out
    /// rather than guessed at.
    public static func decodeAuthStatus(_ data: Data) -> ClaudeCodeAuthStatus? {
        try? JSONDecoder().decode(ClaudeCodeAuthStatus.self, from: data)
    }

    /// Parse the first non-empty line of `claude --version`.
    public static func decodeVersion(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    /// Control commands run with the environment a chat process gets (login
    /// shell PATH, the interpreter beside an npm `claude`, `ANTHROPIC_API_KEY`
    /// removed), so the status shown is the status a chat will see.
    static func controlCommand(
        _ command: String,
        overlay: [String: String]
    ) async -> HarnessControlCommand.Resolved? {
        await HarnessControlCommand.resolve(
            command,
            overlay: overlay,
            removing: HarnessEnvironment.alwaysRemoved.union(ClaudeCodeHarnessAdapter.removedEnvironment)
        )
    }

    public static func cliVersion(
        command: String = executableName,
        overlay: [String: String] = [:],
        timeout: TimeInterval = 5
    ) async -> String? {
        guard let resolved = await controlCommand(command, overlay: overlay),
            let result = await ClaudeCodeProcessRunner.capture(
                executable: resolved.executable,
                arguments: ["--version"],
                environment: resolved.environment,
                timeout: timeout
            ),
            result.exitCode == 0,
            !result.timedOut
        else { return nil }
        return decodeVersion(result.stdout)
    }

    /// Ask the CLI who is signed in. Spawns a process, so it is only called
    /// from settings and onboarding, never from layout.
    public static func authStatus(
        command: String = executableName,
        overlay: [String: String] = [:],
        timeout: TimeInterval = 10
    ) async -> ClaudeCodeAuthStatus? {
        guard let resolved = await controlCommand(command, overlay: overlay),
            let result = await ClaudeCodeProcessRunner.capture(
                executable: resolved.executable,
                arguments: ["auth", "status", "--json"],
                environment: resolved.environment,
                timeout: timeout
            ),
            !result.timedOut
        else { return nil }
        // Some versions use a non-zero exit for the signed-out JSON state.
        // Decode the payload before considering the status code.
        return decodeAuthStatus(result.stdout)
    }

    /// Resolve what the setup UI should show.
    public static func setupState(
        command: String = executableName,
        overlay: [String: String] = [:]
    ) async -> ClaudeCodeSetupState {
        guard await controlCommand(command, overlay: overlay) != nil else {
            return .notInstalled(searchedPath: await HarnessControlCommand.searchedPath())
        }
        let version = await cliVersion(command: command, overlay: overlay)
        guard let status = await authStatus(command: command, overlay: overlay) else {
            // Older CLIs accept unknown subcommands by printing general help
            // with exit code zero. A missing JSON payload, not the exit code,
            // is therefore the reliable capability signal.
            return .statusUnavailable(cliVersion: version)
        }
        guard status.loggedIn else {
            return .signedOut
        }
        return .signedIn(status)
    }

    /// Start the CLI's own browser sign-in.
    ///
    /// `claude auth login` opens the system browser and blocks until the round
    /// trip finishes, so this returns only once the user has completed (or
    /// abandoned) the flow, or the calling task is cancelled. Osaurus never
    /// sees the credential — the CLI writes it to its own store, exactly as it
    /// would from a terminal.
    ///
    /// Returns the post-login status so the caller can update in place.
    public static func login(
        command: String = executableName,
        overlay: [String: String] = [:],
        timeout: TimeInterval = 300
    ) async -> ClaudeCodeAuthStatus? {
        guard let resolved = await controlCommand(command, overlay: overlay) else { return nil }
        _ = await ClaudeCodeProcessRunner.capture(
            executable: resolved.executable,
            arguments: ["auth", "login"],
            environment: resolved.environment,
            timeout: timeout
        )
        guard !Task.isCancelled else { return nil }
        return await authStatus(command: command, overlay: overlay)
    }

    /// Sign in from Terminal instead, for logins the headless flow can't
    /// finish (a CLI that asks a question, SSO that needs a TTY). Writes a
    /// one-line `.command` script and opens it, which needs no Automation
    /// permission.
    @MainActor
    public static func openTerminalLogin(command: String = executableName, overlay: [String: String] = [:]) async {
        let resolved = await controlCommand(command, overlay: overlay)
        let executable = resolved?.executable ?? command
        let path = resolved?.environment["PATH"]
        var script = "#!/bin/zsh -l\n"
        if let path { script += "export PATH=\(shellQuoted(path))\n" }
        script += "\(shellQuoted(executable)) auth login\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-claude-login-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

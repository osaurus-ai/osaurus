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

    /// Claude's brand gradient, from Anthropic's published accent orange
    /// (#D97757) to a darker shade of the same hue.
    ///
    /// Deliberately not the accent color: the picker's generic `.symbol` rows
    /// all hover to the accent, so an accent-tinted Claude Code row was
    /// indistinguishable from "Use an API key". Measured against every existing
    /// row gradient, the nearest in the same list is OpenRouter at ΔE 22.7
    /// (CIELAB) — comfortably distinguishable.
    public static let brandGradient: [Color] = [
        Color(red: 0.851, green: 0.467, blue: 0.341),
        Color(red: 0.749, green: 0.373, blue: 0.259),
    ]

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

    /// Tools added when the agent opts into shell access.
    public static let shellTools = ["Bash"]

    // MARK: - Osaurus tools over MCP

    /// The MCP server name Osaurus registers itself under. Claude Code exposes
    /// MCP tools as `mcp__<server>__<tool>`, so this also fixes the allow-list
    /// spelling.
    public static let mcpServerName = "osaurus"

    /// Osaurus config tools that only read. Safe to grant whenever the user
    /// turns Osaurus tools on.
    public static let osaurusReadOnlyTools = ["osaurus_inspect", "osaurus_help"]

    /// The Osaurus tool that mutates app state — agents, providers, models,
    /// plugins, and schedules. Behind its own opt-in.
    public static let osaurusConfigWriteTools = [HarnessGrantStore.configWriteToolName]

    /// The `--tools` value handed to `osaurus mcp`, so the proxy hides
    /// everything else at the source rather than trusting the client to skip it.
    public static func osaurusToolPatterns(allowConfigWrites: Bool) -> [String] {
        allowConfigWrites ? osaurusReadOnlyTools + osaurusConfigWriteTools : osaurusReadOnlyTools
    }

    /// Claude Code's namespaced spelling of the same set, for `--allowedTools`.
    public static func osaurusAllowedToolNames(allowConfigWrites: Bool) -> [String] {
        osaurusToolPatterns(allowConfigWrites: allowConfigWrites)
            .map { "mcp__\(mcpServerName)__\($0)" }
    }

    /// Why Osaurus's own tools aren't reachable on this run.
    public enum OsaurusToolsUnavailableReason: Sendable, Equatable {
        /// The agent hasn't opted in.
        case notEnabled
        /// Opted in, but the local HTTP server the bridge proxies to is down.
        case serverNotRunning
        /// Text-only mode disables every tool.
        case textOnlyMode
    }

    /// A note appended to the system prompt describing which Osaurus tools this
    /// run actually has.
    ///
    /// An agent's own instructions may tell it to "check `osaurus_inspect`".
    /// The tools only arrive when the MCP bridge is attached, so without this
    /// note the model is told to use tools it cannot see and spends the turn
    /// guessing at permission errors instead of answering.
    public static func osaurusToolsSystemNote(
        available: Bool,
        allowConfigWrites: Bool = false,
        reason: OsaurusToolsUnavailableReason? = nil
    ) -> String {
        guard available else {
            let cause: String
            switch reason {
            case .serverNotRunning:
                cause = L(
                    "the Osaurus server is not running — tell the user to start it from the Osaurus app"
                )
            case .textOnlyMode:
                cause = L("this agent runs Claude Code in text-only mode, which disables all tools")
            case .notEnabled, nil:
                cause = L(
                    "they are switched off for this agent — tell the user to turn on \"Allow Osaurus read tools\" in this agent's Claude Code Options"
                )
            }
            return String(
                format: L(
                    "You do NOT have Osaurus's configuration tools (osaurus_inspect, osaurus_help, osaurus_config) on this run, because %@. Do not try to call them and do not speculate about permission errors. If the user asks about Osaurus's configuration, say plainly that you can't read it right now, explain why, and offer what they can check themselves."
                ),
                cause
            )
        }

        let names = osaurusToolPatterns(allowConfigWrites: allowConfigWrites)
            .map { "`\($0)`" }
            .joined(separator: ", ")
        var note = String(
            format: L(
                "You can inspect this Osaurus install through these tools: %@. They are the only Osaurus tools available — others named in your instructions are not present on this run."
            ),
            names
        )
        if !allowConfigWrites {
            note += " "
            note += L(
                "They are read-only. You cannot change Osaurus's configuration; describe the change the user should make instead."
            )
        }
        return note
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
    public static func mcpConfigJSON(
        cliPath: String,
        allowConfigWrites: Bool,
        bridgeGrant: String? = nil
    ) -> String? {
        let patterns = osaurusToolPatterns(allowConfigWrites: allowConfigWrites)
        guard !patterns.isEmpty else { return nil }
        var server: [String: Any] = [
            "command": cliPath,
            "args": ["mcp", "--tools", patterns.joined(separator: ",")],
        ]
        if let bridgeGrant, !bridgeGrant.isEmpty {
            server["env"] = [HarnessGrantStore.environmentKey: bridgeGrant]
        }
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

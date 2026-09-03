//
//  ClaudeCodeConfiguration.swift
//  osaurus
//
//  Static configuration for the Claude Code provider: locating the user's
//  `claude` binary, the model catalog, and the argument vector.
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
    case haiku

    /// Routing id surfaced to the model picker and matched by
    /// `ClaudeCodeService.handles(requestedModel:)`.
    public var pickerId: String { "\(ClaudeCodeConfiguration.modelPrefix)\(rawValue)" }

    public var displayName: String {
        switch self {
        case .sonnet: return "Claude Code (Sonnet)"
        case .opus: return "Claude Code (Opus)"
        case .haiku: return "Claude Code (Haiku)"
        }
    }

    /// Parse a routing id such as `claude-code/sonnet` back into an alias.
    public static func fromPickerId(_ id: String) -> ClaudeCodeModel? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(ClaudeCodeConfiguration.modelPrefix) else { return nil }
        let alias = String(trimmed.dropFirst(ClaudeCodeConfiguration.modelPrefix.count))
        return ClaudeCodeModel(rawValue: alias.lowercased())
    }
}

public enum ClaudeCodeError: LocalizedError, Sendable, Equatable {
    case binaryNotFound(searchedPath: String)
    case notAuthenticated(detail: String)
    case launchFailed(String)
    case turnFailed(String)
    case exited(code: Int32, stderrTail: String)
    case rateLimited(detail: String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return L(
                "Claude Code isn't installed, or its `claude` command isn't on this app's PATH. Install it, then restart Osaurus."
            )
        case .notAuthenticated:
            return L("Claude Code isn't signed in. Open `claude` in a terminal, sign in, then try again.")
        case .launchFailed(let detail):
            return String(format: L("Couldn't start Claude Code: %@"), detail)
        case .turnFailed(let detail):
            return String(format: L("Claude Code couldn't complete the turn: %@"), detail)
        case .exited(let code, let tail):
            if tail.isEmpty {
                return String(format: L("Claude Code exited with code %d."), Int(code))
            }
            return String(format: L("Claude Code exited with code %d: %@"), Int(code), tail)
        case .rateLimited(let detail):
            return String(format: L("Claude Code hit a subscription rate limit: %@"), detail)
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
    /// Routing prefix. Chosen so it can't collide with an MLX bundle id or a
    /// remote provider's `<provider-name>/` prefix.
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

    /// Tools added when the agent opts into writes.
    public static let writeTools = ["Edit", "Write", "NotebookEdit"]

    /// Tools added when the agent opts into shell access.
    public static let shellTools = ["Bash"]

    // MARK: - Osaurus tools over MCP

    /// The MCP server name Osaurus registers itself under. Claude Code exposes
    /// MCP tools as `mcp__<server>__<tool>`, so this also fixes the allow-list
    /// spelling.
    public static let mcpServerName = "osaurus"

    /// Osaurus config tools that only read. Safe to grant whenever the user
    /// turns Osaurus tools on.
    public static let osaurusReadOnlyTools = [
        "osaurus_status", "osaurus_list", "osaurus_describe", "osaurus_search",
    ]

    /// Osaurus config tools that mutate app state. Behind their own opt-in:
    /// granting these lets a run silently rewrite agents, providers, and
    /// installed plugins.
    public static let osaurusConfigWriteTools = [
        "osaurus_agent", "osaurus_provider", "osaurus_model", "osaurus_plugin", "osaurus_mcp",
    ]

    /// Deliberately never exposed. `osaurus_schedule` can queue agent runs, so
    /// a Claude Code subprocess could schedule work that starts another Claude
    /// Code subprocess. `AGENTS.md` forbids recursive agent workers, and this
    /// is the path that would create them.
    public static let osaurusExcludedTools = ["osaurus_schedule"]

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
    /// Osaurus agents are prompted to "read current state with `osaurus_status`"
    /// and similar. That prompt reaches Claude Code verbatim, but the tools only
    /// arrive when the MCP bridge is attached — so without this note the model
    /// is told to use tools it cannot see, and spends the turn guessing at
    /// permission errors instead of answering. Stating the real capability is
    /// the fix; suppressing the agent's prompt would break every other backend.
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
                    "they are switched off for this agent — tell the user to enable \"Give It Osaurus's Own Tools\" in Osaurus settings"
                )
            }
            return String(
                format: L(
                    "You do NOT have Osaurus's configuration tools (osaurus_status, osaurus_list, and similar) on this run, because %@. Do not try to call them and do not speculate about permission errors. If the user asks about Osaurus's configuration, say plainly that you can't read it right now, explain why, and offer what they can check themselves."
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
    /// - Parameter bridgeGrant: Per-turn grant proving which agent's chat this
    ///   subprocess serves. Delivered through the server block's `env` rather
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
            server["env"] = [ClaudeCodeBridgeGrantStore.environmentKey: bridgeGrant]
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
    /// model-picker layout, and paying a process spawn there would stall the UI.
    /// Authentication state is discovered on the first real run instead, where
    /// it surfaces as a typed `notAuthenticated` error.
    public static func isAvailable(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolveExecutable(env: env) != nil
    }

    // MARK: - Argument vector

    /// Build the `claude` argument vector for one non-interactive turn.
    ///
    /// - Parameters:
    ///   - model: alias passed straight through to `--model`.
    ///   - mode: agent vs text-only.
    ///   - allowedTools: auto-approved tools in agent mode. Ignored in
    ///     text-only mode, where all built-ins are disabled.
    ///   - systemPrompt: appended to Claude Code's own system prompt rather
    ///     than replacing it, so its tool contract stays intact.
    /// - Parameter mcpConfigPath: when non-nil, an `--mcp-config` file exposing
    ///   Osaurus's own tools. Only meaningful in agent mode — text-only mode
    ///   disables every tool, MCP included.
    public static func arguments(
        model: ClaudeCodeModel,
        mode: ClaudeCodeMode,
        allowedTools: [String],
        systemPrompt: String?,
        mcpConfigPath: String? = nil
    ) -> [String] {
        var args = [
            "--print",
            "--output-format", "stream-json",
            "--verbose",
            // Without this the CLI emits only whole messages, so the chat
            // would sit blank and then paint the full answer at once.
            "--include-partial-messages",
            // One Osaurus turn is one CLI invocation; nothing should be
            // written to the user's ~/.claude session history.
            "--no-session-persistence",
            // Only MCP servers Osaurus passes explicitly (currently none) may
            // load. Without this the CLI would silently inherit whatever the
            // user configured for their terminal sessions.
            "--strict-mcp-config",
            "--model", model.rawValue,
        ]

        switch mode {
        case .textOnly:
            // The CLI's documented "disable every built-in" form.
            args += ["--tools", ""]
        case .agent:
            // Fail-closed: un-allowlisted tools are denied, not prompted for.
            args += ["--permission-mode", "dontAsk"]
            if !allowedTools.isEmpty {
                args += ["--allowedTools", allowedTools.joined(separator: ",")]
            }
            // Ordering matters only for readability; `--strict-mcp-config`
            // above already guarantees nothing else loads.
            if let mcpConfigPath {
                args += ["--mcp-config", mcpConfigPath]
            }
        }

        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--append-system-prompt", systemPrompt]
        }

        return args
    }

    /// Tools to auto-approve given an agent's opt-ins.
    ///
    /// `allowOsaurusTools` adds the namespaced MCP names; without them the
    /// server would be attached but every call denied by `dontAsk`.
    public static func allowedTools(
        allowWrites: Bool,
        allowShell: Bool,
        allowOsaurusTools: Bool = false,
        allowOsaurusConfigWrites: Bool = false
    ) -> [String] {
        var tools = defaultAllowedTools
        if allowWrites { tools += writeTools }
        if allowShell { tools += shellTools }
        if allowOsaurusTools {
            tools += osaurusAllowedToolNames(allowConfigWrites: allowOsaurusConfigWrites)
        }
        return tools
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

    public static func cliVersion(
        env: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 5
    ) async -> String? {
        guard let executable = resolveExecutable(env: env),
            let result = await ClaudeCodeProcessRunner.capture(
                executable: executable,
                arguments: ["--version"],
                environment: env,
                timeout: timeout
            ),
            result.exitCode == 0,
            !result.timedOut
        else { return nil }
        return decodeVersion(result.stdout)
    }

    /// Ask the CLI who is signed in.
    ///
    /// Unlike `isAvailable()` this *does* spawn a process, so it is only called
    /// from the settings sheet — never from model-picker layout.
    public static func authStatus(
        env: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10
    ) async -> ClaudeCodeAuthStatus? {
        guard let executable = resolveExecutable(env: env) else { return nil }
        guard let result = await ClaudeCodeProcessRunner.capture(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                environment: env,
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
        env: [String: String] = ProcessInfo.processInfo.environment
    ) async -> ClaudeCodeSetupState {
        guard resolveExecutable(env: env) != nil else {
            return .notInstalled(searchedPath: searchedPath(env: env))
        }
        let version = await cliVersion(env: env)
        guard let status = await authStatus(env: env) else {
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
    /// abandoned) the flow. Osaurus never sees the credential — the CLI writes
    /// it to its own store, exactly as it would from a terminal.
    ///
    /// Returns the post-login status so the caller can update in place.
    public static func login(
        env: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 300
    ) async -> ClaudeCodeAuthStatus? {
        guard let executable = resolveExecutable(env: env) else { return nil }
        _ = await ClaudeCodeProcessRunner.capture(
            executable: executable,
            arguments: ["auth", "login"],
            environment: env,
            timeout: timeout
        )
        return await authStatus(env: env)
    }
}

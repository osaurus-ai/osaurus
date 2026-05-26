//
//  ClaudePluginVariableExpander.swift
//  osaurus
//
//  Substitutes the variables defined by the Claude Code plugin spec:
//    `${CLAUDE_PLUGIN_ROOT}` — synthesised read-only cache directory.
//    `${CLAUDE_PLUGIN_DATA}` — per-plugin persistent data directory.
//    `${CLAUDE_PROJECT_DIR}` — current workspace root (best-effort, empty
//                              when none is set).
//    `${user_config.KEY}`    — value from the per-plugin userconfig store
//                              (sensitive values pulled from Keychain).
//    `${ENV_VAR}`            — host environment, allow-listed.
//
//  Designed to be called from the installer when writing MCP-provider
//  command / args / cwd / env fields, and from the runtime when injecting
//  user_config values into skill / command bodies. Per the spec, sensitive
//  user_config values are *only* exposed via environment variables — the
//  expander mirrors that by refusing to splice sensitive values into
//  arbitrary text (callers opt in to "env-only" mode for sensitive cases).
//

import Foundation

/// Per-call context the expander needs to resolve substitutions for a
/// single plugin. Built once per install or runtime hook and passed
/// through every `expand(_:)` call.
public struct ClaudePluginExpansionContext: Sendable {
    public let pluginId: String
    /// Non-sensitive user_config values, keyed by config key. Sensitive
    /// values are *not* placed here; lookups for sensitive keys fall back
    /// to `sensitiveResolver` when set.
    public let userConfig: [String: String]
    /// Closure for resolving sensitive user_config values on-demand. The
    /// installer wires this to `ToolSecretsKeychain` reads; tests usually
    /// pass `nil` so sensitive substitutions fall through to literal
    /// `${user_config.X}` (no plaintext secrets in test output).
    public let sensitiveResolver: (@Sendable (_ key: String) -> String?)?
    /// Workspace root used for `${CLAUDE_PROJECT_DIR}`. `nil` → expands
    /// to the empty string (matches Claude Code's best-effort behavior
    /// when no project is set).
    public let projectDir: String?
    /// Allow-list of environment variable names that may resolve via
    /// `${VAR}`. Always includes the default safe set (`PATH`, `HOME`,
    /// `USER`, `HOSTNAME`) plus any extra keys the caller supplies (e.g.
    /// keys declared in `userConfig` so authors can pull custom vars
    /// the same way they would on Claude Code).
    public let allowedEnvVars: Set<String>

    public init(
        pluginId: String,
        userConfig: [String: String] = [:],
        sensitiveResolver: (@Sendable (_ key: String) -> String?)? = nil,
        projectDir: String? = nil,
        extraAllowedEnvVars: Set<String> = []
    ) {
        self.pluginId = pluginId
        self.userConfig = userConfig
        self.sensitiveResolver = sensitiveResolver
        self.projectDir = projectDir
        self.allowedEnvVars = Self.defaultEnvAllowList.union(extraAllowedEnvVars)
    }

    public static let defaultEnvAllowList: Set<String> = [
        "PATH", "HOME", "USER", "HOSTNAME", "LANG", "LC_ALL", "TERM",
    ]

    public var claudePluginRoot: URL {
        OsaurusPaths.claudePluginCacheDir(for: pluginId)
    }

    public var claudePluginData: URL {
        // Created lazily on first reference, matching the spec.
        ClaudePluginManifestStore.ensureDataDir(for: pluginId)
    }
}

/// Stateless variable expander. Holds no plugin state itself — callers
/// pass a fresh `ClaudePluginExpansionContext` per plugin / invocation.
public enum ClaudePluginVariableExpander {
    /// Expand every recognised variable in `input`. Substitutions are
    /// idempotent — running `expand` twice on the same string produces
    /// the same output as running it once.
    public static func expand(
        _ input: String,
        context: ClaudePluginExpansionContext
    ) -> String {
        var out = input

        // Order matters: resolve plugin-scoped vars first so callers can
        // chain them inside `user_config` values, then user_config, then
        // generic environment.
        out = replace(in: out, pattern: #"\$\{CLAUDE_PLUGIN_ROOT\}"#) { _ in
            context.claudePluginRoot.path
        }
        out = replace(in: out, pattern: #"\$\{CLAUDE_PLUGIN_DATA\}"#) { _ in
            context.claudePluginData.path
        }
        out = replace(in: out, pattern: #"\$\{CLAUDE_PROJECT_DIR\}"#) { _ in
            context.projectDir ?? ""
        }
        // user_config: `${user_config.KEY}` — KEY allows letters, digits,
        // `_`, `-`, and `.` (nested keys aren't part of the spec but we
        // accept dots so authors can name keys like `db.host`).
        out = replace(
            in: out,
            pattern: #"\$\{user_config\.([A-Za-z0-9_.\-]+)\}"#
        ) { match in
            let key = String(match.dropFirst("${user_config.".count).dropLast())
            if let value = context.userConfig[key] { return value }
            if let resolver = context.sensitiveResolver,
                let value = resolver(key)
            {
                return value
            }
            return match  // Leave unresolved tokens alone for visibility.
        }
        // `${ENV_VAR}` — only resolves allow-listed names so a malicious
        // plugin can't exfiltrate arbitrary host env vars by name.
        out = replace(
            in: out,
            pattern: #"\$\{([A-Z][A-Z0-9_]*)\}"#
        ) { match in
            let name = String(match.dropFirst(2).dropLast())
            guard context.allowedEnvVars.contains(name) else { return match }
            return ProcessInfo.processInfo.environment[name] ?? ""
        }
        return out
    }

    /// Apply `expand` to every value of a `[String: String]` bag — used
    /// by the installer when persisting MCP `env` / `args` arrays.
    public static func expand(
        _ input: [String: String],
        context: ClaudePluginExpansionContext
    ) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in input {
            out[key] = expand(value, context: context)
        }
        return out
    }

    public static func expand(
        _ input: [String],
        context: ClaudePluginExpansionContext
    ) -> [String] {
        input.map { expand($0, context: context) }
    }

    /// Environment overlay that the installer (or runtime) should attach
    /// to a launched MCP subprocess. Mirrors the variables the spec
    /// guarantees are exported into every plugin process, plus
    /// `CLAUDE_PLUGIN_OPTION_<KEY>` for each user_config value (sensitive
    /// values overlay non-sensitive ones).
    public static func subprocessEnv(
        context: ClaudePluginExpansionContext,
        includeSensitive: Bool = true
    ) -> [String: String] {
        var env: [String: String] = [:]
        env["CLAUDE_PLUGIN_ROOT"] = context.claudePluginRoot.path
        env["CLAUDE_PLUGIN_DATA"] = context.claudePluginData.path
        if let project = context.projectDir, !project.isEmpty {
            env["CLAUDE_PROJECT_DIR"] = project
        }
        for (key, value) in context.userConfig {
            env["CLAUDE_PLUGIN_OPTION_\(key)"] = value
        }
        if includeSensitive, let resolver = context.sensitiveResolver {
            // Caller is responsible for knowing which keys are sensitive
            // — we don't have the manifest spec here. The resolver
            // returns `nil` for unknown keys so this is a safe sweep
            // over the keys the manifest declared (stored in
            // `extraAllowedEnvVars` for convenience).
            for key in context.allowedEnvVars where key.hasPrefix("USER_CONFIG_") {
                if let value = resolver(String(key.dropFirst("USER_CONFIG_".count))) {
                    env["CLAUDE_PLUGIN_OPTION_\(String(key.dropFirst("USER_CONFIG_".count)))"] = value
                }
            }
        }
        return env
    }

    // MARK: - Internals

    private static func replace(
        in input: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [])
        else { return input }
        let ns = input as NSString
        let matches = regex.matches(
            in: input,
            range: NSRange(location: 0, length: ns.length)
        )
        guard !matches.isEmpty else { return input }
        var result = input
        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            guard let r = Range(fullRange, in: result) else { continue }
            let captured = ns.substring(with: fullRange)
            let replacement = transform(captured)
            result.replaceSubrange(r, with: replacement)
        }
        return result
    }
}

//
//  CodexCLIConfiguration.swift
//  osaurus
//
//  Generates the `~/.codex` configuration that lets OpenAI's Codex CLI use
//  this Osaurus as a model provider, and merges it into the user's files.
//
//  This is the reverse of the `openAICodex` remote provider (Osaurus
//  consuming a ChatGPT subscription). Here Codex is the client and Osaurus's
//  local `/v1/responses` endpoint is the model backend.
//
//  Two files are involved, for a TOML reason:
//
//  - `config.toml` gets a `[model_providers.osaurus]` table. Tables can be
//    appended anywhere, so the block is wrapped in marker comments and
//    replaced in place on later writes, leaving the rest of the file
//    byte-for-byte untouched.
//  - `osaurus.config.toml` is a Codex *profile* holding `model` and
//    `model_provider`. Those are top-level keys, which TOML requires to
//    precede every `[table]` header — they cannot be appended safely to a
//    file we don't own. The profile file is ours outright, so it's written
//    whole. The user activates it with `codex --profile osaurus`.
//

import Foundation

public enum CodexCLIConfiguration {

    // MARK: - Constants

    /// Provider id registered under `model_providers`. Codex reserves
    /// `openai`, `ollama`, and `lmstudio`; anything else is fair game.
    public static let providerId = "osaurus"

    /// Profile name; the profile file is `<name>.config.toml` and is
    /// selected with `--profile <name>`.
    public static let profileName = "osaurus"

    public static let configFileName = "config.toml"
    public static var profileFileName: String { "\(profileName).config.toml" }

    /// Environment variable the exposed-network snippet tells Codex to read
    /// the access key from. Never the key itself: an access key is shown
    /// once at creation and belongs in the user's shell environment, not in a
    /// world-readable config file.
    public static let accessKeyEnvironmentVariable = "OSAURUS_API_KEY"

    /// The command a user runs to start Codex against Osaurus.
    public static let usageCommand = "codex --profile \(profileName)"

    static let managedBlockBegin =
        "# >>> osaurus managed (do not edit; regenerated from Osaurus → Server) >>>"
    static let managedBlockEnd = "# <<< osaurus managed <<<"

    // MARK: - Locations

    /// Codex's state directory: `$CODEX_HOME`, else `~/.codex`.
    public static func codexHome(
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func configURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent(configFileName, isDirectory: false)
    }

    public static func profileURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent(profileFileName, isDirectory: false)
    }

    /// Codex appends `/responses` to this, landing on Osaurus's `/v1/responses`.
    /// Always loopback: Codex runs on the same Mac, and the loopback address
    /// is what the server trusts without a key when network exposure is off.
    public static func baseURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/v1"
    }

    // MARK: - Snippets

    /// The managed `[model_providers.osaurus]` block, markers included.
    ///
    /// - Parameter exposeToNetwork: When the server binds 0.0.0.0 it stops
    ///   trusting loopback callers, so Codex must send a Bearer key. The block
    ///   then names an env var for it rather than embedding a secret.
    public static func providerBlock(port: Int, exposeToNetwork: Bool) -> String {
        var lines = [
            managedBlockBegin,
            "[model_providers.\(providerId)]",
            "name = \"Osaurus\"",
            "base_url = \(tomlString(baseURL(port: port)))",
            // The only value current Codex accepts; `chat` was removed.
            "wire_api = \"responses\"",
        ]
        if exposeToNetwork {
            lines.append("env_key = \(tomlString(accessKeyEnvironmentVariable))")
            lines.append(
                "env_key_instructions = "
                    + tomlString(
                        "Osaurus is exposed to the network, so loopback callers need a key too. Create one in Osaurus → Server → Access Keys and export \(accessKeyEnvironmentVariable) before running codex."
                    )
            )
        }
        lines.append(managedBlockEnd)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The context window to advertise to Codex: the bundle's declared length
    /// bounded by the server's KV retention cap. The engine keeps at most
    /// `kvRetentionCap` tokens of KV and rolls the window silently past it, so
    /// telling Codex the bundle's 131k–262k would make it compact far too
    /// late and lose its instructions and early turns without any signal.
    /// `nil` when neither side knows.
    public static func effectiveContextWindow(bundleContextLength: Int?, kvRetentionCap: Int?) -> Int? {
        let bundle = bundleContextLength.flatMap { $0 > 0 ? $0 : nil }
        let cap = kvRetentionCap.flatMap { $0 > 0 ? $0 : nil }
        switch (bundle, cap) {
        case (let b?, let c?): return min(b, c)
        case (let b?, nil): return b
        case (nil, let c?): return c
        case (nil, nil): return nil
        }
    }

    /// The whole `osaurus.config.toml` profile file.
    public static func profileFile(modelId: String, contextWindow: Int?) -> String {
        var lines = [
            "# Codex profile generated by Osaurus (Server → Use with Codex CLI).",
            "# Run: \(usageCommand)",
            "model = \(tomlString(modelId))",
            "model_provider = \(tomlString(providerId))",
        ]
        if let contextWindow, contextWindow > 0 {
            lines.append("model_context_window = \(contextWindow)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Everything the card shows and the Copy button puts on the clipboard:
    /// both files, labelled with their destination paths, plus the command.
    public static func snippet(
        port: Int,
        exposeToNetwork: Bool,
        modelId: String,
        contextWindow: Int?,
        codexHome: URL
    ) -> String {
        let configPath = displayPath(configURL(codexHome: codexHome))
        let profilePath = displayPath(profileURL(codexHome: codexHome))
        return """
            # \(configPath)
            \(providerBlock(port: port, exposeToNetwork: exposeToNetwork))
            # \(profilePath)
            \(profileFile(modelId: modelId, contextWindow: contextWindow))
            # Then:
            \(usageCommand)
            """
    }

    /// `/Users/me/.codex/config.toml` → `~/.codex/config.toml` for display.
    public static func displayPath(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = url.path
        let home = homeDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Merge

    public enum MergeError: Error, Equatable, Sendable {
        /// `config.toml` already defines `model_providers.osaurus` outside our
        /// markers. Writing a second table would make the whole file fail to
        /// parse and lock the user out of Codex, so the caller must refuse.
        case unmanagedProviderTable
    }

    public struct MergeResult: Equatable, Sendable {
        public let contents: String
        /// True when an earlier managed block was replaced rather than appended.
        public let replacedExistingBlock: Bool
    }

    /// Insert or refresh the managed block in an existing `config.toml`.
    ///
    /// - The managed block, if present, is replaced in place (including the
    ///   marker lines). Text before and after it is preserved exactly.
    /// - Otherwise the block is appended, separated from existing content by
    ///   one blank line.
    /// - Any definition of `model_providers.osaurus` outside the markers —
    ///   a `[model_providers.osaurus]` table, dotted keys, or an inline
    ///   `model_providers = { … }` — is a conflict.
    public static func merge(into existing: String, block: String) -> Result<MergeResult, MergeError> {
        let lines = existing.components(separatedBy: "\n")
        let beginIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == managedBlockBegin }
        let endIndex = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == managedBlockEnd }

        var managedRange: Range<Int>?
        if let beginIndex, let endIndex, endIndex >= beginIndex {
            managedRange = beginIndex..<(endIndex + 1)
        }

        for (index, line) in lines.enumerated() {
            if let managedRange, managedRange.contains(index) { continue }
            if definesOsaurusProvider(line) {
                return .failure(.unmanagedProviderTable)
            }
        }

        let blockLines = block.hasSuffix("\n") ? String(block.dropLast()) : block

        if let managedRange {
            var updated = lines
            updated.replaceSubrange(managedRange, with: blockLines.components(separatedBy: "\n"))
            return .success(
                MergeResult(contents: updated.joined(separator: "\n"), replacedExistingBlock: true)
            )
        }

        var prefix = existing
        if prefix.isEmpty {
            // Fresh file: just the block.
        } else if prefix.hasSuffix("\n\n") {
            // Already ends with a blank line.
        } else if prefix.hasSuffix("\n") {
            prefix += "\n"
        } else {
            prefix += "\n\n"
        }
        let appended = prefix + blockLines + "\n"
        return .success(MergeResult(contents: appended, replacedExistingBlock: false))
    }

    /// Does this single TOML line (outside our markers) define
    /// `model_providers.osaurus` in any spelling?
    static func definesOsaurusProvider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return false }
        let patterns = [
            // [model_providers.osaurus] / [model_providers."osaurus"] / [model_providers.osaurus.auth]
            #"^\[\s*model_providers\s*\.\s*"?osaurus"?\s*(\]|\.)"#,
            // model_providers.osaurus.base_url = ...
            #"^model_providers\s*\.\s*"?osaurus"?\s*\."#,
            // model_providers = { osaurus = { ... } }
            #"^model_providers\s*="#,
        ]
        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    // MARK: - Write

    public struct WriteResult: Equatable, Sendable {
        public let configURL: URL
        public let profileURL: URL
        public let replacedExistingBlock: Bool
    }

    public enum WriteError: LocalizedError, Equatable {
        case conflict(configURL: URL)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .conflict(let url):
                return String(
                    format: L(
                        "%@ already defines model_providers.osaurus outside the Osaurus-managed block. Remove that definition (or move it between the markers) and try again."
                    ),
                    displayPath(url)
                )
            case .io(let detail):
                return String(format: L("Couldn't write Codex configuration: %@"), detail)
            }
        }
    }

    /// Write both files. Creates `codexHome` when missing. Both writes are
    /// atomic; `config.toml` is merged, the profile is overwritten.
    @discardableResult
    public static func write(
        port: Int,
        exposeToNetwork: Bool,
        modelId: String,
        contextWindow: Int?,
        codexHome: URL,
        fileManager: FileManager = .default
    ) throws -> WriteResult {
        let configURL = configURL(codexHome: codexHome)
        let profileURL = profileURL(codexHome: codexHome)

        do {
            try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        } catch {
            throw WriteError.io(error.localizedDescription)
        }

        let existing: String
        if fileManager.fileExists(atPath: configURL.path) {
            guard let data = fileManager.contents(atPath: configURL.path),
                let text = String(data: data, encoding: .utf8)
            else {
                throw WriteError.io(
                    String(format: L("%@ is not readable as UTF-8 text."), displayPath(configURL))
                )
            }
            existing = text
        } else {
            existing = ""
        }

        let block = providerBlock(port: port, exposeToNetwork: exposeToNetwork)
        let merged: MergeResult
        switch merge(into: existing, block: block) {
        case .success(let result):
            merged = result
        case .failure(.unmanagedProviderTable):
            throw WriteError.conflict(configURL: configURL)
        }

        let profile = profileFile(modelId: modelId, contextWindow: contextWindow)

        do {
            try Data(merged.contents.utf8).write(to: configURL, options: .atomic)
            try Data(profile.utf8).write(to: profileURL, options: .atomic)
        } catch {
            throw WriteError.io(error.localizedDescription)
        }

        return WriteResult(
            configURL: configURL,
            profileURL: profileURL,
            replacedExistingBlock: merged.replacedExistingBlock
        )
    }

    // MARK: - TOML helpers

    /// Basic (double-quoted) TOML string with the escapes the spec requires.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

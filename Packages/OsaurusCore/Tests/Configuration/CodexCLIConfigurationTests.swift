import Foundation
import Testing

@testable import OsaurusCore

/// `CodexCLIConfiguration` writes into a file Osaurus does not own
/// (`~/.codex/config.toml`). A mistake there breaks Codex startup for the
/// user, not just the Osaurus profile, so the merge contract is pinned
/// tightly: unrelated bytes are preserved, our block is replaced in place,
/// and a hand-written `model_providers.osaurus` is a refusal rather than a
/// duplicate table.
@Suite("Codex CLI configuration")
struct CodexCLIConfigurationTests {

    // MARK: - Provider block

    @Test("loopback block names the port, speaks responses, and carries no key")
    func loopbackProviderBlock() {
        let block = CodexCLIConfiguration.providerBlock(port: 4242, exposeToNetwork: false)
        #expect(block.contains("[model_providers.osaurus]"))
        #expect(block.contains("base_url = \"http://127.0.0.1:4242/v1\""))
        #expect(block.contains("wire_api = \"responses\""))
        #expect(!block.contains("env_key"))
        #expect(block.hasPrefix(CodexCLIConfiguration.managedBlockBegin + "\n"))
        #expect(block.hasSuffix(CodexCLIConfiguration.managedBlockEnd + "\n"))
    }

    @Test("exposed block adds an env-var key reference, never a literal key")
    func exposedProviderBlock() {
        let block = CodexCLIConfiguration.providerBlock(port: 1337, exposeToNetwork: true)
        #expect(block.contains("env_key = \"OSAURUS_API_KEY\""))
        #expect(block.contains("env_key_instructions = \""))
        #expect(block.contains("wire_api = \"responses\""))
        // Nothing resembling a bearer token may be baked in.
        #expect(!block.contains("experimental_bearer_token"))
        #expect(!block.contains("http_headers"))
    }

    @Test("wire_api is always responses; Codex removed chat")
    func wireApiIsResponsesRegardlessOfExposure() {
        for exposed in [false, true] {
            let block = CodexCLIConfiguration.providerBlock(port: 1337, exposeToNetwork: exposed)
            #expect(block.contains("wire_api = \"responses\""))
            #expect(!block.contains("wire_api = \"chat\""))
        }
    }

    // MARK: - Profile file

    @Test("profile pins model and provider, adds the window only when known")
    func profileFile() {
        let withWindow = CodexCLIConfiguration.profileFile(modelId: "qwen3-8b-4bit", contextWindow: 40960)
        #expect(withWindow.contains("model = \"qwen3-8b-4bit\""))
        #expect(withWindow.contains("model_provider = \"osaurus\""))
        #expect(withWindow.contains("model_context_window = 40960"))
        #expect(withWindow.contains(CodexCLIConfiguration.usageCommand))

        let withoutWindow = CodexCLIConfiguration.profileFile(modelId: "qwen3-8b-4bit", contextWindow: nil)
        #expect(!withoutWindow.contains("model_context_window"))

        let zeroWindow = CodexCLIConfiguration.profileFile(modelId: "x", contextWindow: 0)
        #expect(!zeroWindow.contains("model_context_window"))
    }

    @Test("profile keys stay top-level: no table header precedes them")
    func profileHasNoTableHeaders() {
        let profile = CodexCLIConfiguration.profileFile(modelId: "m", contextWindow: 8192)
        let firstKeyLine = profile.components(separatedBy: "\n").first { !$0.hasPrefix("#") && !$0.isEmpty }
        #expect(firstKeyLine?.hasPrefix("model = ") == true)
        #expect(!profile.contains("["))
    }

    @Test("TOML strings escape quotes and backslashes")
    func tomlEscaping() {
        #expect(CodexCLIConfiguration.tomlString(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(CodexCLIConfiguration.tomlString("tab\there") == #""tab\there""#)
        #expect(CodexCLIConfiguration.tomlString("plain-slug") == "\"plain-slug\"")
    }

    // MARK: - Merge

    private var block: String { CodexCLIConfiguration.providerBlock(port: 1337, exposeToNetwork: false) }

    @Test("empty file becomes exactly the block")
    func mergeIntoEmpty() throws {
        let result = try CodexCLIConfiguration.merge(into: "", block: block).get()
        #expect(result.contents == block)
        #expect(!result.replacedExistingBlock)
    }

    @Test("append preserves existing content byte-for-byte with one blank line")
    func mergeAppends() throws {
        let existing = """
            model = "gpt-5.6-terra"
            approval_policy = "on-request"

            [mcp_servers.context7]
            command = "npx"
            args = ["-y", "@upstash/context7-mcp"]
            """
        let result = try CodexCLIConfiguration.merge(into: existing, block: block).get()
        #expect(result.contents.hasPrefix(existing))
        #expect(result.contents == existing + "\n\n" + block)
        #expect(!result.replacedExistingBlock)
    }

    @Test("append after a trailing newline adds exactly one blank line")
    func mergeAppendsAfterTrailingNewline() throws {
        let existing = "model = \"x\"\n"
        let result = try CodexCLIConfiguration.merge(into: existing, block: block).get()
        #expect(result.contents == existing + "\n" + block)
    }

    @Test("append after an existing blank line does not add another")
    func mergeAppendsAfterBlankLine() throws {
        let existing = "model = \"x\"\n\n"
        let result = try CodexCLIConfiguration.merge(into: existing, block: block).get()
        #expect(result.contents == existing + block)
    }

    @Test("an existing managed block is replaced in place, leaving neighbours intact")
    func mergeReplacesManagedBlock() throws {
        let stale = CodexCLIConfiguration.providerBlock(port: 9999, exposeToNetwork: true)
        let existing = "model = \"x\"\n\n" + stale + "\n[tui]\nanimations = false\n"
        let result = try CodexCLIConfiguration.merge(into: existing, block: block).get()
        #expect(result.replacedExistingBlock)
        #expect(result.contents == "model = \"x\"\n\n" + block + "\n[tui]\nanimations = false\n")
        #expect(!result.contents.contains("9999"))
        #expect(!result.contents.contains("env_key"))
    }

    @Test("merging twice is idempotent")
    func mergeIsIdempotent() throws {
        let once = try CodexCLIConfiguration.merge(into: "[tui]\nanimations = false\n", block: block).get()
        let twice = try CodexCLIConfiguration.merge(into: once.contents, block: block).get()
        #expect(twice.contents == once.contents)
        #expect(twice.replacedExistingBlock)
    }

    @Test("a hand-written provider table outside the markers is a conflict")
    func mergeRefusesUnmanagedTable() {
        let variants = [
            "[model_providers.osaurus]\nbase_url = \"http://localhost:1337/v1\"\n",
            "  [ model_providers.osaurus ]\n",
            "[model_providers.\"osaurus\"]\n",
            "[model_providers.osaurus.auth]\ncommand = \"x\"\n",
            "model_providers.osaurus.base_url = \"http://localhost:1337/v1\"\n",
            "model_providers = { osaurus = { base_url = \"x\" } }\n",
            "[MODEL_PROVIDERS.OSAURUS]\n",
        ]
        for existing in variants {
            let result = CodexCLIConfiguration.merge(into: existing, block: block)
            #expect(result == .failure(.unmanagedProviderTable), "should conflict: \(existing)")
        }
    }

    @Test("other providers and commented-out tables are not conflicts")
    func mergeIgnoresUnrelatedProviders() throws {
        let existing = """
            # [model_providers.osaurus]  ← commented out, not live
            [model_providers.osaurus_old]
            base_url = "http://localhost:1/v1"

            [model_providers.mistral]
            name = "Mistral"
            """
        let result = try CodexCLIConfiguration.merge(into: existing, block: block).get()
        #expect(result.contents.hasPrefix(existing))
    }

    // MARK: - Locations

    @Test("CODEX_HOME overrides ~/.codex and expands a tilde")
    func codexHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let defaultHome = CodexCLIConfiguration.codexHome(env: [:], homeDirectory: home)
        #expect(defaultHome.path == "/Users/example/.codex")

        let overridden = CodexCLIConfiguration.codexHome(env: ["CODEX_HOME": "/opt/codex"], homeDirectory: home)
        #expect(overridden.path == "/opt/codex")

        let blank = CodexCLIConfiguration.codexHome(env: ["CODEX_HOME": "   "], homeDirectory: home)
        #expect(blank.path == "/Users/example/.codex")

        let tilde = CodexCLIConfiguration.codexHome(env: ["CODEX_HOME": "~/.codex-alt"], homeDirectory: home)
        #expect(tilde.path.hasSuffix("/.codex-alt"))
        #expect(!tilde.path.contains("~"))
    }

    @Test("display path collapses the home directory to ~")
    func displayPath() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let inside = URL(fileURLWithPath: "/Users/example/.codex/config.toml")
        #expect(CodexCLIConfiguration.displayPath(inside, homeDirectory: home) == "~/.codex/config.toml")
        let outside = URL(fileURLWithPath: "/opt/codex/config.toml")
        #expect(CodexCLIConfiguration.displayPath(outside, homeDirectory: home) == "/opt/codex/config.toml")
        // `/Users/example-other` must not be treated as inside `/Users/example`.
        let sibling = URL(fileURLWithPath: "/Users/example-other/x")
        #expect(CodexCLIConfiguration.displayPath(sibling, homeDirectory: home) == "/Users/example-other/x")
    }

    @Test("snippet names both destination files and the command")
    func snippetContents() {
        let home = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)
        let snippet = CodexCLIConfiguration.snippet(
            port: 1337, exposeToNetwork: false, modelId: "m", contextWindow: nil, codexHome: home
        )
        #expect(snippet.contains("# /tmp/codex-home/config.toml"))
        #expect(snippet.contains("# /tmp/codex-home/osaurus.config.toml"))
        #expect(snippet.contains("[model_providers.osaurus]"))
        #expect(snippet.contains("model = \"m\""))
        #expect(snippet.contains("codex --profile osaurus"))
    }

    // MARK: - Write

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-codex-tests-\(UUID().uuidString)", isDirectory: true)
        // Not created: `write` must create it.
        return url
    }

    @Test("write creates the directory, merges config.toml, and writes the profile")
    func writeCreatesBothFiles() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let result = try CodexCLIConfiguration.write(
            port: 1337, exposeToNetwork: false, modelId: "qwen3-8b-4bit", contextWindow: 32768, codexHome: home
        )
        #expect(!result.replacedExistingBlock)
        let config = try String(contentsOf: result.configURL, encoding: .utf8)
        let profile = try String(contentsOf: result.profileURL, encoding: .utf8)
        #expect(config == CodexCLIConfiguration.providerBlock(port: 1337, exposeToNetwork: false))
        #expect(profile == CodexCLIConfiguration.profileFile(modelId: "qwen3-8b-4bit", contextWindow: 32768))
        #expect(result.profileURL.lastPathComponent == "osaurus.config.toml")
    }

    @Test("a second write refreshes the block and rewrites the profile")
    func writeIsRepeatable() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let userConfig = "model = \"gpt-5.6-terra\"\n\n[tui]\nanimations = false\n"
        try Data(userConfig.utf8).write(to: CodexCLIConfiguration.configURL(codexHome: home))

        _ = try CodexCLIConfiguration.write(
            port: 1337, exposeToNetwork: false, modelId: "a", contextWindow: nil, codexHome: home
        )
        let second = try CodexCLIConfiguration.write(
            port: 2000, exposeToNetwork: true, modelId: "b", contextWindow: 4096, codexHome: home
        )
        #expect(second.replacedExistingBlock)

        let config = try String(contentsOf: second.configURL, encoding: .utf8)
        #expect(config.hasPrefix(userConfig))
        #expect(config.contains("http://127.0.0.1:2000/v1"))
        #expect(!config.contains("http://127.0.0.1:1337/v1"))
        #expect(config.contains("env_key = \"OSAURUS_API_KEY\""))
        #expect(config.components(separatedBy: "[model_providers.osaurus]").count == 2)

        let profile = try String(contentsOf: second.profileURL, encoding: .utf8)
        #expect(profile.contains("model = \"b\""))
        #expect(profile.contains("model_context_window = 4096"))
        #expect(!profile.contains("model = \"a\""))
    }

    @Test("write refuses when the user already defines the provider by hand")
    func writeRefusesConflict() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configURL = CodexCLIConfiguration.configURL(codexHome: home)
        let manual = "[model_providers.osaurus]\nbase_url = \"http://localhost:1337/v1\"\n"
        try Data(manual.utf8).write(to: configURL)

        #expect(throws: CodexCLIConfiguration.WriteError.conflict(configURL: configURL)) {
            try CodexCLIConfiguration.write(
                port: 1337, exposeToNetwork: false, modelId: "m", contextWindow: nil, codexHome: home
            )
        }
        // Neither file may have been touched.
        #expect(try String(contentsOf: configURL, encoding: .utf8) == manual)
        #expect(!FileManager.default.fileExists(atPath: CodexCLIConfiguration.profileURL(codexHome: home).path))
    }
}

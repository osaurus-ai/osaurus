//
//  ClaudePluginInstallerTests.swift
//  osaurus
//
//  Tests for the Claude plugin importer's pure pieces:
//  - Marketplace JSON decoding for both schemas (legacy `skills: [String]`
//    and the new directory-discovery layout used by claude-for-legal).
//  - YAML frontmatter extraction used to read scheduled-agent metadata.
//  - `.mcp.json` parser that classifies HTTP/SSE vs stdio servers.
//  - Stable plugin id derivation used for grouping/uninstall.
//
//  Tests that would require network access or singleton disk writes
//  (`SkillManager.shared`, `ScheduleStore`, `MCPProviderManager.shared`,
//  `SlashCommandStore`) are intentionally omitted here — those are
//  validated end-to-end through the importer UI.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ClaudePluginInstallerTests {

    // MARK: - Marketplace schema decoding

    /// Legacy `marketplace.json` declares plugins as
    /// `{ "name": "...", "skills": ["./skills/foo"] }`. These must still
    /// decode unchanged after we made `skills` optional.
    @Test func decodesLegacyMarketplaceWithFlatSkillsArray() throws {
        let json = #"""
            {
                "name": "legacy-pack",
                "plugins": [
                    {
                        "name": "writing-pack",
                        "description": "Writing skills",
                        "skills": ["./skills/copywriting", "./skills/editing"]
                    }
                ]
            }
            """#

        let decoded = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(json.utf8)
        )

        #expect(decoded.name == "legacy-pack")
        #expect(decoded.plugins.count == 1)
        let plugin = decoded.plugins[0]
        #expect(plugin.name == "writing-pack")
        #expect(plugin.skills == ["./skills/copywriting", "./skills/editing"])
    }

    /// `anthropics/claude-for-legal`-style marketplace.json: each plugin only
    /// declares `source` and `author`, and skills live under
    /// `<source>/skills/*`. Previously this failed to decode because `skills`
    /// was required.
    @Test func decodesNewStyleMarketplaceWithoutSkillsArray() throws {
        let json = #"""
            {
                "name": "claude-for-legal",
                "owner": { "name": "Anthropic" },
                "plugins": [
                    {
                        "name": "commercial-legal",
                        "source": "./commercial-legal",
                        "description": "Reviews vendor agreements",
                        "author": { "name": "Anthropic" }
                    },
                    {
                        "name": "privacy-legal",
                        "source": "./privacy-legal",
                        "description": "Privacy workflows"
                    }
                ]
            }
            """#

        let decoded = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(json.utf8)
        )

        #expect(decoded.plugins.count == 2)
        let commercial = decoded.plugins[0]
        #expect(commercial.skills == nil)
        #expect(commercial.source == "./commercial-legal")
        #expect(commercial.author?.name == "Anthropic")
        let privacy = decoded.plugins[1]
        #expect(privacy.skills == nil)
        #expect(privacy.author == nil)
    }

    /// A mixed marketplace (legacy + new-style entries side by side) should
    /// decode cleanly without losing information from either schema.
    @Test func decodesMixedSchemaMarketplace() throws {
        let json = #"""
            {
                "name": "mixed-pack",
                "plugins": [
                    {
                        "name": "legacy",
                        "skills": ["./skills/one"]
                    },
                    {
                        "name": "modern",
                        "source": "./modern"
                    }
                ]
            }
            """#

        let decoded = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(json.utf8)
        )

        #expect(decoded.plugins.count == 2)
        #expect(decoded.plugins[0].skills == ["./skills/one"])
        #expect(decoded.plugins[1].skills == nil)
        #expect(decoded.plugins[1].source == "./modern")
    }

    // MARK: - YAML frontmatter

    @Test func extractsFlatScalarFrontmatter() {
        let markdown = """
            ---
            name: renewal-watcher
            description: A short description.
            ---

            # Body
            Hello.
            """

        let (frontmatter, body) = ClaudeMarkdownParser.extract(markdown)

        #expect(frontmatter["name"] == "renewal-watcher")
        #expect(frontmatter["description"] == "A short description.")
        #expect(body.contains("# Body"))
        #expect(body.contains("Hello."))
    }

    /// claude-for-legal uses YAML folded scalars (`>`) for long descriptions.
    /// We need to fold them down to a single string so the description still
    /// makes it through.
    @Test func extractsFoldedScalarFrontmatter() {
        let markdown = """
            ---
            name: review
            description: >
              Review a vendor agreement, NDA, or SaaS subscription against your playbook.
              Identifies the agreement structure from titles, routes to the right review.
            ---

            # Body
            """

        let (frontmatter, _) = ClaudeMarkdownParser.extract(markdown)

        #expect(frontmatter["name"] == "review")
        let description = frontmatter["description"] ?? ""
        #expect(description.contains("Review a vendor agreement"))
        #expect(description.contains("Identifies the agreement structure"))
        // Folded scalar must be a single line (no embedded newlines).
        #expect(!description.contains("\n"))
    }

    /// SKILL.md files in `claude-for-legal` use folded scalars (`>`) for the
    /// description. Before the fix, `Skill.parseAnyFormat` returned the
    /// literal `">"` because its YAML parser didn't recognize the block
    /// scalar introducer. This test pins that the description survives.
    @Test func parsesFoldedDescriptionInSkillMarkdown() throws {
        let markdown = """
            ---
            name: review
            description: >
              Review a vendor agreement, NDA, or SaaS subscription against
              your playbook. Identifies the agreement structure and routes
              to the right review steps.
            version: 1.0.0
            ---

            # Review Skill

            Body content.
            """

        let skill = try Skill.parseAnyFormat(from: markdown)

        #expect(skill.description.contains("Review a vendor agreement"))
        #expect(skill.description.contains("routes to the right review"))
        // No leftover marker, no embedded newlines.
        #expect(skill.description != ">")
        #expect(!skill.description.contains("\n"))
    }

    /// `description: |` (literal block scalar) should preserve newlines
    /// between collected lines so multi-paragraph instructions read the way
    /// the author wrote them.
    @Test func parsesLiteralDescriptionInSkillMarkdown() throws {
        let markdown = """
            ---
            name: review
            description: |
              line one
              line two
            version: 1.0.0
            ---

            # Body
            """

        let skill = try Skill.parseAnyFormat(from: markdown)

        #expect(skill.description == "line one\nline two")
    }

    @Test func returnsBodyWhenNoFrontmatter() {
        let markdown = "# Just a body, no frontmatter\nHello."
        let (frontmatter, body) = ClaudeMarkdownParser.extract(markdown)
        #expect(frontmatter.isEmpty)
        #expect(body == markdown)
    }

    // MARK: - MCP JSON parser

    /// `.mcp.json` with an HTTP/SSE entry (`url:` + bearer token in env) is the
    /// happy path — the installer should be able to register it as a remote
    /// MCP provider.
    @Test func parsesHTTPMCPServer() {
        let json = #"""
            {
                "mcpServers": {
                    "ironclad": {
                        "url": "https://example.com/mcp",
                        "env": { "API_KEY": "abc123" }
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers.count == 1)
        let server = parsed.servers[0]
        #expect(server.name == "ironclad")
        #expect(server.url == "https://example.com/mcp")
        #expect(server.token == "abc123")
    }

    /// `.mcp.json` with a stdio entry (`command:` + `args:`) must produce a
    /// `url == nil` server so the installer can list it under "needs manual
    /// setup".
    @Test func parsesStdioMCPServerAsSkippable() {
        let json = #"""
            {
                "mcpServers": {
                    "local-fs": {
                        "command": "/usr/local/bin/mcp-fs",
                        "args": ["--root", "/tmp"]
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers.count == 1)
        let server = parsed.servers[0]
        #expect(server.name == "local-fs")
        #expect(server.url == nil)
    }

    /// Some forks of the spec use `servers: {}` instead of `mcpServers: {}`.
    /// Both should work.
    @Test func parsesServersKeyVariant() {
        let json = #"""
            {
                "servers": {
                    "alpha": { "url": "https://a.example.com/mcp" },
                    "beta":  { "command": "stdio-bin" }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        let names = parsed.servers.map(\.name).sorted()
        #expect(names == ["alpha", "beta"])
    }

    @Test func parsesEmptyMCPJSONGracefully() {
        #expect(MCPJSONParser.parse("").servers.isEmpty)
        #expect(MCPJSONParser.parse("not json").servers.isEmpty)
        #expect(MCPJSONParser.parse("{}").servers.isEmpty)
    }

    /// `.mcp.json` files in public plugins usually contain placeholder
    /// secrets (`${VAR}` or `<your token>`). Storing those as literal
    /// bearer tokens breaks auth silently — the parser must surface them
    /// as a "placeholder" flag and drop the value.
    @Test func skipsBraceStyleEnvPlaceholderToken() {
        let json = #"""
            {
                "mcpServers": {
                    "ironclad": {
                        "url": "https://example.com/mcp",
                        "env": { "API_KEY": "${VAULT_TOKEN}" }
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers.count == 1)
        let server = parsed.servers[0]
        #expect(server.token == nil)
        #expect(server.tokenIsPlaceholder == true)
    }

    @Test func skipsDollarStyleEnvPlaceholderToken() {
        let json = #"""
            {
                "mcpServers": {
                    "ironclad": {
                        "url": "https://example.com/mcp",
                        "env": { "API_KEY": "$ANTHROPIC_API_KEY" }
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers[0].token == nil)
        #expect(parsed.servers[0].tokenIsPlaceholder == true)
    }

    @Test func skipsAngleBracketPlaceholderToken() {
        let json = #"""
            {
                "mcpServers": {
                    "ironclad": {
                        "url": "https://example.com/mcp",
                        "env": { "API_KEY": "<your token here>" }
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers[0].token == nil)
        #expect(parsed.servers[0].tokenIsPlaceholder == true)
    }

    @Test func preservesRealEnvToken() {
        let json = #"""
            {
                "mcpServers": {
                    "ironclad": {
                        "url": "https://example.com/mcp",
                        "env": { "API_KEY": "sk-real-token-123" }
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers[0].token == "sk-real-token-123")
        #expect(parsed.servers[0].tokenIsPlaceholder == false)
    }

    /// Spot-check the underlying placeholder predicate so future maintainers
    /// can extend it without re-running the JSON harness.
    @Test func isPlaceholderRecognisesCommonForms() {
        #expect(MCPJSONParser.isPlaceholder("${VAULT_TOKEN}") == true)
        #expect(MCPJSONParser.isPlaceholder("${VAULT_TOKEN:-default}") == true)
        #expect(MCPJSONParser.isPlaceholder("$ANTHROPIC_API_KEY") == true)
        #expect(MCPJSONParser.isPlaceholder("<paste here>") == true)
        #expect(MCPJSONParser.isPlaceholder("") == true)
        #expect(MCPJSONParser.isPlaceholder("   ") == true)
        // Real-looking secrets pass through.
        #expect(MCPJSONParser.isPlaceholder("sk-1234567890abcdef") == false)
        #expect(MCPJSONParser.isPlaceholder("Bearer abc.def") == false)
        // `$1` is too short / not a valid env var; treat as a real token.
        #expect(MCPJSONParser.isPlaceholder("$") == false)
    }

    // MARK: - Plugin id derivation

    /// The plugin id is what ties skills, schedules, slash commands, and MCP
    /// providers back to a single bundle. It must be stable and unique per
    /// `owner/repo/plugin`.
    @Test func derivesStablePluginIdFromRepoAndName() {
        let repo = GitHubRepo(owner: "anthropics", name: "claude-for-legal", branch: "main")
        let id = ClaudePluginInstaller.pluginId(repo: repo, pluginName: "commercial-legal")
        #expect(id == "github:anthropics/claude-for-legal/commercial-legal")

        // Different plugin in the same repo → different id.
        let other = ClaudePluginInstaller.pluginId(repo: repo, pluginName: "privacy-legal")
        #expect(other != id)

        // Different owner → different id even with the same plugin name.
        let otherRepo = GitHubRepo(owner: "someone-else", name: "claude-for-legal", branch: "main")
        let conflict = ClaudePluginInstaller.pluginId(repo: otherRepo, pluginName: "commercial-legal")
        #expect(conflict != id)
    }

    // MARK: - GitHubPluginsResult convenience

    /// `isLegacyOnly` decides whether the import sheet falls back to the
    /// existing flat skill picker or shows the new per-plugin tree.
    @Test func isLegacyOnlyTreatsNewStyleAsNonLegacy() {
        let legacyManifest = ClaudePluginManifest(
            name: "old",
            description: nil,
            source: "./old",
            skills: [ClaudeSkillEntry(path: "./old/foo")],
            isLegacy: true
        )
        let newStyleManifest = ClaudePluginManifest(
            name: "new",
            description: nil,
            source: "new",
            skills: [ClaudeSkillEntry(path: "new/skills/bar")],
            agents: [ClaudeAgentEntry(path: "new/agents/baz.md")],
            isLegacy: false
        )

        let repo = GitHubRepo(owner: "x", name: "y")
        let marketplace = GitHubMarketplace(
            name: "y",
            owner: nil,
            metadata: nil,
            plugins: []
        )

        let legacyOnly = GitHubPluginsResult(
            repo: repo,
            marketplace: marketplace,
            plugins: [legacyManifest]
        )
        #expect(legacyOnly.isLegacyOnly == true)

        let mixed = GitHubPluginsResult(
            repo: repo,
            marketplace: marketplace,
            plugins: [legacyManifest, newStyleManifest]
        )
        #expect(mixed.isLegacyOnly == false)
    }
}

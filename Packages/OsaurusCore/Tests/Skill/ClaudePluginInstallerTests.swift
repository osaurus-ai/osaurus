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
        if case .localDirectory(let dir) = commercial.source {
            #expect(dir == "./commercial-legal")
        } else {
            Issue.record("commercial.source should decode as .localDirectory")
        }
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
        if case .localDirectory(let dir) = decoded.plugins[1].source {
            #expect(dir == "./modern")
        } else {
            Issue.record("modern plugin source should decode as .localDirectory")
        }
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
    /// `url == nil` server and now preserve `command`, `args`, `env`, `cwd`
    /// so the installer can persist them on the resulting `MCPProvider`.
    @Test func parsesStdioMCPServerWithCommandAndArgs() {
        let json = #"""
            {
                "mcpServers": {
                    "local-fs": {
                        "command": "/usr/local/bin/mcp-fs",
                        "args": ["--root", "/tmp"],
                        "env": { "LOG_LEVEL": "debug", "API_KEY": "${SECRET}" },
                        "cwd": "/tmp"
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers.count == 1)
        let server = parsed.servers[0]
        #expect(server.name == "local-fs")
        #expect(server.url == nil)
        #expect(server.command == "/usr/local/bin/mcp-fs")
        #expect(server.args == ["--root", "/tmp"])
        #expect(server.cwd == "/tmp")
        #expect(server.env["LOG_LEVEL"] == "debug")
        #expect(server.env["API_KEY"] == "${SECRET}")
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
        let repo = GitHubRepo(owner: "x", name: "y")
        let legacyManifest = ClaudePluginManifest(
            name: "old",
            description: nil,
            source: "./old",
            sourceRepo: repo,
            skills: [ClaudeSkillEntry(path: "./old/foo")],
            isLegacy: true
        )
        let newStyleManifest = ClaudePluginManifest(
            name: "new",
            description: nil,
            source: "new",
            sourceRepo: repo,
            skills: [ClaudeSkillEntry(path: "new/skills/bar")],
            agents: [ClaudeAgentEntry(path: "new/agents/baz.md")],
            isLegacy: false
        )

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

    // MARK: - MarketplaceSource (anthropics/claude-plugins-community shape)

    /// `claude-plugins-community` ships object-shaped sources like
    /// `{ "source": "url", "url": "https://github.com/.../foo.git", "sha": "..." }`.
    /// Decoding must extract the external repo + pinned sha so subsequent
    /// fetches hit that repo at that commit.
    @Test func decodesExternalRepoSourceAsObject() throws {
        let json = #"""
            {
                "name": "claude-community",
                "plugins": [
                    {
                        "name": "0x",
                        "source": {
                            "source": "url",
                            "url": "https://github.com/0xProject/0x-ai.git",
                            "sha": "fdb8a21d6e3a1d933c1043e21874e432790682dc"
                        }
                    }
                ]
            }
            """#

        let decoded = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(json.utf8)
        )
        #expect(decoded.plugins.count == 1)
        switch decoded.plugins[0].source {
        case .externalRepo(let repo, let ref):
            #expect(repo.owner == "0xProject")
            #expect(repo.name == "0x-ai")
            // The pinned sha must take precedence over `main` so raw URL
            // fetches resolve at the documented commit.
            #expect(repo.branch == "fdb8a21d6e3a1d933c1043e21874e432790682dc")
            #expect(ref == "fdb8a21d6e3a1d933c1043e21874e432790682dc")
        default:
            Issue.record("expected .externalRepo")
        }
    }

    /// `git-subdir` variant — same repo, but only a subpath of it hosts
    /// the plugin. Used by `barnburner121/claude-plugin-marketplace`-style
    /// entries.
    @Test func decodesExternalSubdirSourceAsObject() throws {
        let json = #"""
            {
                "name": "claude-community",
                "plugins": [
                    {
                        "name": "a11y-fixer",
                        "source": {
                            "source": "git-subdir",
                            "url": "barnburner121/claude-plugin-marketplace",
                            "path": "generated-plugins/a11y-fixer",
                            "ref": "main",
                            "sha": "5f6b5d32d9f457dc9c2c7c0fb1d67dffc9140f33"
                        }
                    }
                ]
            }
            """#

        let decoded = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(json.utf8)
        )
        switch decoded.plugins[0].source {
        case .externalSubdir(let repo, let path, let ref):
            #expect(repo.owner == "barnburner121")
            #expect(repo.name == "claude-plugin-marketplace")
            #expect(path == "generated-plugins/a11y-fixer")
            // sha takes precedence over ref
            #expect(repo.branch == "5f6b5d32d9f457dc9c2c7c0fb1d67dffc9140f33")
            #expect(ref == "5f6b5d32d9f457dc9c2c7c0fb1d67dffc9140f33")
        default:
            Issue.record("expected .externalSubdir")
        }
    }

    /// When neither `sha` nor `ref` is given, the parsed repo defaults to
    /// `main`. `pinnedExternalRepo` (private) will then go look up the
    /// actual default branch via the GitHub API at fetch time — this test
    /// only validates the decoder result.
    @Test func decodesExternalRepoSourceWithoutSha() throws {
        let json = #"""
            {
                "name": "claude-community",
                "plugins": [
                    {
                        "name": "no-sha",
                        "source": { "source": "url", "url": "https://github.com/owner/repo.git" }
                    }
                ]
            }
            """#

        let decoded = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(json.utf8)
        )
        switch decoded.plugins[0].source {
        case .externalRepo(let repo, let ref):
            #expect(repo.owner == "owner")
            #expect(repo.name == "repo")
            #expect(repo.branch == "main")
            #expect(ref == nil)
        default:
            Issue.record("expected .externalRepo")
        }
    }

    /// Unknown `source` discriminator should not blow up the whole
    /// marketplace; we fall through to "external repo" as a best-effort.
    @Test func decodesUnknownSourceKindAsExternal() throws {
        let json = #"""
            {
                "name": "weird",
                "plugins": [
                    {
                        "name": "future",
                        "source": { "source": "ipfs", "url": "https://github.com/foo/bar.git" }
                    }
                ]
            }
            """#

        let decoded = try JSONDecoder().decode(
            GitHubMarketplace.self,
            from: Data(json.utf8)
        )
        #expect(decoded.plugins.count == 1)
        if case .externalRepo = decoded.plugins[0].source {
            // OK
        } else {
            Issue.record("unknown discriminator should degrade to .externalRepo")
        }
    }

    // MARK: - MCP OAuth (anthropics/knowledge-work-plugins shape)

    /// Anthropic's `knowledge-work-plugins/productivity/.mcp.json` lists
    /// Slack as `{type: "http", url, oauth: { clientId, callbackPort }}`. The
    /// parser must classify those as `.oauth` so the installer creates
    /// providers with `authType: .oauth` and stashes the metadata.
    @Test func parsesOAuthMCPServer() {
        let json = #"""
            {
                "mcpServers": {
                    "slack": {
                        "type": "http",
                        "url": "https://mcp.slack.com/mcp",
                        "oauth": {
                            "clientId": "1601185624273.8899143856786",
                            "callbackPort": 3118
                        }
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers.count == 1)
        let server = parsed.servers[0]
        #expect(server.name == "slack")
        #expect(server.url == "https://mcp.slack.com/mcp")
        #expect(server.kind == .oauth)
        #expect(server.oauth?.clientId == "1601185624273.8899143856786")
        #expect(server.oauth?.callbackPort == 3118)
        // No bearer token — OAuth servers don't ship literal tokens in .mcp.json.
        #expect(server.token == nil)
    }

    /// A server with `type: "http"` + non-empty `url` but no `oauth` block
    /// is still a plain bearer/no-auth provider.
    @Test func httpServerWithoutOAuthClassifiesAsBearer() {
        let json = #"""
            {
                "mcpServers": {
                    "plain": {
                        "type": "http",
                        "url": "https://example.com/mcp"
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers[0].kind == .bearer)
        #expect(parsed.servers[0].oauth == nil)
    }

    /// A server with an empty url string lands in `.empty` so the
    /// installer can list it as "needs configuration" rather than silently
    /// creating a broken provider.
    @Test func httpServerWithEmptyURLClassifiesAsEmpty() {
        let json = #"""
            {
                "mcpServers": {
                    "needs-config": {
                        "type": "http",
                        "url": ""
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers[0].kind == .empty)
    }

    /// Stdio entries (command-based) keep their existing classification so
    /// the older summary line ("stdio servers — manual setup") still works.
    @Test func stdioServerClassifiesAsStdio() {
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
        #expect(parsed.servers[0].kind == .stdio)
        #expect(parsed.servers[0].url == nil)
    }

    /// Accept snake_case spellings (`client_id`, `callback_port`) too —
    /// the spec hasn't settled, and a couple of community plugins use the
    /// Python-style naming.
    @Test func parsesOAuthSnakeCaseSpellings() {
        let json = #"""
            {
                "mcpServers": {
                    "snake": {
                        "type": "http",
                        "url": "https://example.com/mcp",
                        "oauth": {
                            "client_id": "snake-client",
                            "callback_port": 9999
                        }
                    }
                }
            }
            """#

        let parsed = MCPJSONParser.parse(json)
        #expect(parsed.servers[0].oauth?.clientId == "snake-client")
        #expect(parsed.servers[0].oauth?.callbackPort == 9999)
    }

    // MARK: - Sibling skill name extraction

    /// Real prose from `financial-services/plugins/agent-plugins/pitch-agent/agents/pitch-agent.md`.
    @Test func extractsSiblingSkillNamesFromPitchAgentBody() {
        let body = """
            Workflow:
            1. Scope the ask.
            2. **Write the situation overview.** Invoke the `sector-overview` skill to draft …
            4. **Spread the peer set.** Invoke the `comps-analysis` skill to lay out trading comps …
            5. **Stand up the sponsor case.** Invoke the `lbo-model` skill for an illustrative LBO …
            6. **Build the rest of the model.** Invoke `dcf-model` and `3-statement-model`; follow `audit-xls` conventions …

            ## Skills this agent uses

            `sector-overview` · `comps-analysis` · `lbo-model` · `dcf-model` · `3-statement-model` · `audit-xls` · `pitch-deck` · `ib-check-deck` · `deck-refresh`
            """

        let names = ClaudePluginInstaller.extractSiblingSkillNames(from: body)
        // We don't pin the exact set because the prose mentions some skills
        // without "skill" suffix — but every named sibling must be found via
        // either path.
        #expect(names.contains("sector-overview"))
        #expect(names.contains("comps-analysis"))
        #expect(names.contains("lbo-model"))
        #expect(names.contains("dcf-model"))
        #expect(names.contains("3-statement-model"))
        #expect(names.contains("audit-xls"))
        #expect(names.contains("pitch-deck"))
        #expect(names.contains("ib-check-deck"))
        #expect(names.contains("deck-refresh"))
    }

    /// Plain prose with no skill backticks should yield an empty set.
    @Test func extractsNoNamesFromGenericPlaintext() {
        let body = "Just a description of what this skill does. No skill references here."
        #expect(ClaudePluginInstaller.extractSiblingSkillNames(from: body).isEmpty)
    }

    /// File paths and shell snippets must not be misread as skill names.
    @Test func extractsRejectsPathsAndShellTokens() {
        let body = """
            ## Skills this agent uses

            `python recalc.py` · `scripts/validate.py` · `dcf-model`
            """
        let names = ClaudePluginInstaller.extractSiblingSkillNames(from: body)
        #expect(names.contains("dcf-model"))
        #expect(!names.contains("python recalc.py"))
        #expect(!names.contains("scripts/validate.py"))
    }

    // MARK: - PluginDependencyGraph

    /// Selecting `pitch-agent` should auto-pull in `financial-analysis`
    /// (which owns the referenced sibling skills) via the transitive graph.
    @Test func transitiveDependenciesReturnsAllOwners() {
        let graph = PluginDependencyGraph(
            dependencies: [
                "pitch-agent": ["financial-analysis"],
                "financial-analysis": [],
            ]
        )
        let resolved = graph.transitiveDependencies(of: "pitch-agent")
        #expect(resolved == ["financial-analysis"])
    }

    @Test func transitiveDependenciesHandlesChain() {
        let graph = PluginDependencyGraph(
            dependencies: [
                "a": ["b"],
                "b": ["c"],
                "c": [],
            ]
        )
        #expect(graph.transitiveDependencies(of: "a") == ["b", "c"])
    }

    /// Cycle handling — the resolver should not spin forever. We
    /// deliberately build a cycle here.
    @Test func transitiveDependenciesHandlesCycle() {
        let graph = PluginDependencyGraph(
            dependencies: [
                "a": ["b"],
                "b": ["a"],
            ]
        )
        let resolved = graph.transitiveDependencies(of: "a")
        // `a` is excluded from its own dep set by definition.
        #expect(resolved == ["b"])
    }

    // MARK: - rewriteSkillBody

    /// `${CLAUDE_PLUGIN_ROOT}/skills/dashboard.html` references in the
    /// `productivity/start` SKILL.md must be rewritten to a local path
    /// (`references/dashboard.html` because HTML is in the text-extension
    /// set — readable docs go to references so the model can see them).
    @Test func rewritesPluginRootReferenceToBundledAsset() {
        let asset = ClaudePluginInstaller.FetchedSkillAsset(
            relativePath: "dashboard.html",
            data: Data("<html></html>".utf8)
        )
        let body = """
            ## Setup

            Copy it from `${CLAUDE_PLUGIN_ROOT}/skills/dashboard.html` to the working directory.
            """
        let out = ClaudePluginInstaller.rewriteSkillBody(
            body,
            skillDir: "productivity/skills/start",
            sourceDir: "productivity",
            fetchedAssets: [asset],
            fetchedRootDocs: ClaudePluginInstaller.FetchedRootDocs(files: [:])
        )
        #expect(out.rewritten.contains("references/dashboard.html"))
        #expect(!out.rewritten.contains("${CLAUDE_PLUGIN_ROOT}"))
        #expect(out.rewritten.contains("**Imported assets:**"))
    }

    /// Binary-y assets (PowerPoint templates, PDF templates) must land
    /// under `assets/`, not `references/` — `loadReferenceContents` skips
    /// non-text by extension, so leaving them in `references/` would waste
    /// context allocation.
    @Test func binaryAssetsLandUnderAssets() {
        let asset = ClaudePluginInstaller.FetchedSkillAsset(
            relativePath: "templates/cover.pptx",
            data: Data([0x50, 0x4B])
        )
        let body = "Use `${CLAUDE_PLUGIN_ROOT}/templates/cover.pptx` as the title slide."
        let out = ClaudePluginInstaller.rewriteSkillBody(
            body,
            skillDir: "fin/skills/pitch-deck",
            sourceDir: "fin",
            fetchedAssets: [asset],
            fetchedRootDocs: ClaudePluginInstaller.FetchedRootDocs(files: [:])
        )
        #expect(out.rewritten.contains("assets/cover.pptx"))
    }

    /// `../../CONNECTORS.md` (relative markdown link from
    /// `productivity/skills/start/SKILL.md`) must resolve to a local
    /// `references/CONNECTORS.md` once the rewriter has the file content.
    @Test func rewritesRelativeMarkdownLinkToAttachedRootDoc() {
        let root = ClaudePluginInstaller.FetchedRootDocs(
            files: ["CONNECTORS.md": "## Connectors\nIntegrations."]
        )
        let body = """
            > If you see unfamiliar placeholders, see [CONNECTORS.md](../../CONNECTORS.md).
            """
        let out = ClaudePluginInstaller.rewriteSkillBody(
            body,
            skillDir: "productivity/skills/start",
            sourceDir: "productivity",
            fetchedAssets: [],
            fetchedRootDocs: root
        )
        #expect(out.rewritten.contains("[CONNECTORS.md](references/CONNECTORS.md)"))
        #expect(out.additionalReferences.contains { $0.name == "CONNECTORS.md" })
    }

    /// A `${CLAUDE_PLUGIN_ROOT}/<rel>` reference that didn't match any
    /// fetched asset or root doc lands in the "unbundled" footer so the
    /// user knows the runtime resource is missing.
    @Test func unresolvedPluginRootReferenceIsFlaggedInFooter() {
        let body = "Run `${CLAUDE_PLUGIN_ROOT}/bin/missing-tool` before delivery."
        let out = ClaudePluginInstaller.rewriteSkillBody(
            body,
            skillDir: "some-plugin/skills/foo",
            sourceDir: "some-plugin",
            fetchedAssets: [],
            fetchedRootDocs: ClaudePluginInstaller.FetchedRootDocs(files: [:])
        )
        #expect(out.rewritten.contains("not bundled"))
        #expect(out.rewritten.contains("bin/missing-tool"))
    }

    /// Text-y assets (Python helpers, requirements.txt, markdown) should
    /// rewrite under `references/` so they get loaded into context.
    @Test func textAssetsLandUnderReferences() {
        let recalc = ClaudePluginInstaller.FetchedSkillAsset(
            relativePath: "scripts/recalc.py",
            data: Data("print('hi')".utf8)
        )
        let body = "Run `${CLAUDE_PLUGIN_ROOT}/scripts/recalc.py` to recompute."
        let out = ClaudePluginInstaller.rewriteSkillBody(
            body,
            skillDir: "fin/skills/dcf-model",
            sourceDir: "fin",
            fetchedAssets: [recalc],
            fetchedRootDocs: ClaudePluginInstaller.FetchedRootDocs(files: [:])
        )
        #expect(out.rewritten.contains("references/recalc.py"))
    }

    // MARK: - Free-form SKILL.md (no YAML frontmatter)

    /// `anthropics/financial-services/plugins/vertical-plugins/investment-banking/skills/buyer-list/SKILL.md`
    /// ships *no* YAML frontmatter — it opens with `# Buyer List` and an
    /// unwrapped `description:` line. Before the fallback parser these all
    /// failed with "Missing required field: name". This test pins the
    /// recovery: name comes from the H1, description from the plain text
    /// line, instructions retain the full body.
    @Test func parsesFreeformSkillWithH1AndUnwrappedDescription() throws {
        let body = """
            # Buyer List

            description: Build and organize a universe of potential acquirers for sell-side M&A processes.

            ## Workflow

            ### Step 1: Understand the Target
            """

        let skill = try ClaudePluginInstaller.parseSkillWithFallback(
            body,
            skillPath: "plugins/vertical-plugins/investment-banking/skills/buyer-list"
        )
        #expect(skill.name == "Buyer List")
        #expect(skill.description.contains("Build and organize a universe of potential acquirers"))
        #expect(skill.directoryName == "buyer-list")
        #expect(skill.instructions.contains("## Workflow"))
    }

    /// When the file has no H1 either, fall back to a human-readable form
    /// of the directory name (`cim-builder` → "Cim Builder"). Better than
    /// "Missing required field: name" — gives the user something they can
    /// rename later.
    @Test func parsesFreeformSkillWithNoHeaderUsesDirectoryName() throws {
        let body = "Just some body with no title and no description.\n\n## Steps\n1. Do thing."

        let skill = try ClaudePluginInstaller.parseSkillWithFallback(
            body,
            skillPath: "plugins/foo/skills/cim-builder"
        )
        #expect(skill.name == "Cim Builder")
        #expect(skill.directoryName == "cim-builder")
    }

    /// Strict YAML frontmatter wins — the fallback is a fallback, not a
    /// rewrite. Authors who already wrote a proper `---\nname:\n---` block
    /// must not see their metadata clobbered by H1 inference.
    @Test func preservesYamlFrontmatterWhenPresent() throws {
        let body = """
            ---
            name: comps-analysis
            description: |
              Build comparable company analyses.
            ---

            # Comps Analysis

            ## Workflow
            """

        let skill = try ClaudePluginInstaller.parseSkillWithFallback(
            body,
            skillPath: "skills/comps-analysis"
        )
        // `parseAgentSkillsFormat` title-cases the YAML `name` for display
        // (`comps-analysis` → "Comps Analysis"); the fallback parser must
        // not run at all so the description and metadata come from the
        // YAML block, not from the H1 / first paragraph.
        #expect(skill.name == "Comps Analysis")
        #expect(skill.description.contains("Build comparable company analyses"))
    }

    /// Malformed frontmatter (opening `---` but no closing) is a real
    /// authoring bug and should NOT silently fall through to the
    /// free-form parser — surface it so the operator knows the file is
    /// broken.
    @Test func malformedFrontmatterStillThrows() {
        let body = """
            ---
            name: oops
            description: missing the closing fence
            """

        do {
            _ = try ClaudePluginInstaller.parseSkillWithFallback(
                body,
                skillPath: "skills/oops"
            )
            Issue.record("Expected malformedFrontmatter to escape the fallback")
        } catch let error as SkillParseError {
            switch error {
            case .malformedFrontmatter:
                // Expected.
                break
            default:
                Issue.record("Expected .malformedFrontmatter, got \(error)")
            }
        } catch {
            Issue.record("Expected SkillParseError, got \(error)")
        }
    }

    // MARK: - GitHubFetchLimiter

    /// Concurrency cap holds — the limiter must never let more than
    /// `maxConcurrent` tasks run at once. We probe by counting peak
    /// in-flight work across 20 concurrent calls.
    @Test func fetchLimiterEnforcesMaxConcurrent() async {
        let limiter = GitHubFetchLimiter(maxConcurrent: 3)
        actor Counter {
            var current = 0
            var peak = 0
            func enter() {
                current += 1
                peak = max(peak, current)
            }
            func exit() { current -= 1 }
            func snapshot() -> (current: Int, peak: Int) { (current, peak) }
        }
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    _ = try? await limiter.run {
                        await counter.enter()
                        // Sleep so multiple tasks overlap and the peak
                        // counter has a chance to climb if the limiter
                        // misbehaves.
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await counter.exit()
                        return 0
                    }
                }
            }
        }
        let snap = await counter.snapshot()
        #expect(snap.peak <= 3)
        #expect(snap.current == 0)
    }
}

//
//  ClaudePluginSpecTests.swift
//  osaurus
//
//  Pure-logic tests for the Claude-plugin spec coverage added when we
//  unified Claude plugins into the Plugins tab:
//   * `ClaudePluginJSON.parse` — tolerant `plugin.json` decoding.
//   * `ClaudePluginVersionResolver.{resolve,hasUpdate}` — precedence and
//     diffing per the Claude Code spec.
//   * `ClaudePluginVariableExpander.expand` — `${CLAUDE_PLUGIN_*}` /
//     `${user_config.*}` / `${ENV}` substitution rules including the
//     sensitive-value carve-out.
//   * `ClaudePluginManifestStore` round-trip + delete using
//     `OSAURUS_TEST_ROOT` so writes never touch `~/.osaurus`.
//
//  All tests are source-only / disk-only — no network, no Keychain, no
//  background services. Honours the AGENTS.md keychain-free gate.
//

import Foundation
import Testing

@testable import OsaurusCore

/// Serialized because the manifest-store + expander tests in this suite
/// mutate the process-wide `OSAURUS_TEST_ROOT` env var via `setenv`
/// (see `isolatedRoot(label:)`). Swift Testing runs `@Test` cases in
/// parallel by default, which lets concurrent tests trample each
/// other's value. Tests that also mutate `OsaurusPaths.overrideRoot`
/// must additionally run through `StoragePathsTestLock` so they cannot
/// race other serialized suites that share the same process-global path
/// override.
@Suite(.serialized)
struct ClaudePluginSpecTests {

    // MARK: - Test root isolation

    /// Returns a fresh isolated root directory + a teardown closure the
    /// caller is expected to invoke after each test. Keeps disk writes
    /// inside `/tmp/osaurus-claude-plugin-tests/*` so the suite never
    /// mutates `~/.osaurus`.
    ///
    /// Drives isolation through `OsaurusPaths.overrideRoot` (the typed
    /// test hook) rather than `setenv("OSAURUS_TEST_ROOT", …)`. Under
    /// xctest on macOS 26 / Apple-Virtual-Machine arm64e (what CI
    /// runs), `ProcessInfo.processInfo.environment` was caching the
    /// first observed value, so a later test's `setenv` was invisible
    /// to `OsaurusPaths.root()` and two serialized tests wound up
    /// resolving to the same physical directory — the previous test's
    /// snapshot leaked into the next test's `all()` listing. The env
    /// var still has to be set for the few tests that exercise the
    /// subprocess-shape path (`subprocessEnv` / variable expander),
    /// because that codepath legitimately reads the env var; but the
    /// override is the source of truth for in-process resolution and
    /// `@Suite(.serialized)` keeps the override mutation safe.
    private static func isolatedRoot(label: String) -> (URL, () -> Void) {
        let unique = "\(label)-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: "/tmp/osaurus-claude-plugin-tests")
            .appendingPathComponent(unique, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let previousOverride = OsaurusPaths.overrideRoot
        let previousEnv = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]
        OsaurusPaths.overrideRoot = root
        setenv("OSAURUS_TEST_ROOT", root.path, 1)
        let teardown = {
            try? FileManager.default.removeItem(at: root)
            OsaurusPaths.overrideRoot = previousOverride
            if let previousEnv {
                setenv("OSAURUS_TEST_ROOT", previousEnv, 1)
            } else {
                unsetenv("OSAURUS_TEST_ROOT")
            }
        }
        return (root, teardown)
    }

    private static func withIsolatedRoot<T: Sendable>(
        label: String,
        _ body: @Sendable (_ root: URL) async throws -> T
    ) async rethrows -> T {
        try await StoragePathsTestLock.shared.run {
            let (root, teardown) = Self.isolatedRoot(label: label)
            defer { teardown() }
            return try await body(root)
        }
    }

    // MARK: - plugin.json decoding

    /// A canonical-ish `plugin.json` with all fields present should land
    /// every value on the resulting struct. The spec is intentionally
    /// flexible — `author` may be an object or a string — but the
    /// happy-path object form is what plugin authors copy from the docs.
    @Test func parsesCanonicalPluginJSON() {
        let json = #"""
            {
                "name": "renewal-watcher",
                "displayName": "Renewal Watcher",
                "version": "1.2.3",
                "description": "Watches contract renewals.",
                "author": {
                    "name": "Ada Lovelace",
                    "email": "ada@example.com",
                    "url": "https://ada.example.com"
                },
                "homepage": "https://example.com/renewal",
                "repository": "https://github.com/example/renewal",
                "license": "MIT",
                "keywords": ["contracts", "renewals"],
                "userConfig": {
                    "API_KEY": {
                        "type": "string",
                        "title": "API Key",
                        "description": "Vendor API key.",
                        "sensitive": true,
                        "required": true
                    },
                    "DEBUG": {
                        "type": "boolean",
                        "title": "Debug logs",
                        "description": "Verbose logging.",
                        "default": "false"
                    }
                }
            }
            """#

        let parsed = ClaudePluginJSON.parse(json)
        #expect(parsed != nil)
        guard let parsed else { return }
        #expect(parsed.name == "renewal-watcher")
        #expect(parsed.displayName == "Renewal Watcher")
        #expect(parsed.version == "1.2.3")
        #expect(parsed.description?.contains("Watches contract") == true)
        #expect(parsed.authorName == "Ada Lovelace")
        #expect(parsed.authorEmail == "ada@example.com")
        #expect(parsed.authorURL == "https://ada.example.com")
        #expect(parsed.homepage == "https://example.com/renewal")
        #expect(parsed.repository == "https://github.com/example/renewal")
        #expect(parsed.license == "MIT")
        #expect(parsed.keywords == ["contracts", "renewals"])
        #expect(parsed.userConfig.count == 2)
        #expect(parsed.userConfig.contains { $0.key == "API_KEY" && $0.sensitive })
        #expect(parsed.userConfig.contains { $0.key == "DEBUG" && $0.type == .boolean })
        #expect(parsed.hasHooks == false)
        #expect(parsed.unsupportedComponents.isEmpty)
    }

    /// A plain-string `author` (still legal per the spec, used by a couple
    /// of community plugins) should populate `authorName` only, leaving
    /// email/url nil rather than failing decode.
    @Test func parsesStringAuthorForm() {
        let json = #"""
            {
                "name": "tiny",
                "author": "Solo Maker"
            }
            """#
        let parsed = ClaudePluginJSON.parse(json)
        #expect(parsed?.authorName == "Solo Maker")
        #expect(parsed?.authorEmail == nil)
        #expect(parsed?.authorURL == nil)
    }

    /// Unknown top-level fields are required by spec to be silently
    /// ignored — authors will add new fields before our decoder catches up.
    @Test func parsePluginJSONIgnoresUnknownFields() {
        let json = #"""
            {
                "name": "future",
                "monitors": [{ "name": "uptime" }],
                "channels": ["alerts"],
                "experimental": { "themes": ["dark"], "monitors": ["cpu"] }
            }
            """#
        let parsed = ClaudePluginJSON.parse(json)
        #expect(parsed != nil)
        // Each unsupported component is recorded so the detail view can
        // show a "not yet honored" notice — without failing decode.
        let unsupported = parsed?.unsupportedComponents ?? []
        #expect(unsupported.contains("channels"))
        #expect(unsupported.contains("themes"))
        #expect(unsupported.contains("monitors"))
    }

    /// A `hooks` key in any shape (object, array, string) flips
    /// `hasHooks` true so the UI can warn that hook execution is
    /// deferred.
    @Test func parsePluginJSONDetectsHooksDeclaration() {
        let cases: [String] = [
            #"{ "name": "a", "hooks": { "preCompact": "./hooks.json" } }"#,
            #"{ "name": "a", "hooks": ["./hooks.json"] }"#,
            #"{ "name": "a", "hooks": "./hooks.json" }"#,
        ]
        for json in cases {
            let parsed = ClaudePluginJSON.parse(json)
            #expect(parsed?.hasHooks == true)
        }
    }

    /// Malformed JSON should be rejected with `nil`, not an empty struct
    /// — the caller treats `nil` as "fall back to marketplace metadata".
    @Test func parsePluginJSONReturnsNilOnMalformed() {
        #expect(ClaudePluginJSON.parse("") == nil)
        #expect(ClaudePluginJSON.parse("not json") == nil)
        #expect(ClaudePluginJSON.parse(#"{ "name":  }"#) == nil)
    }

    // MARK: - Version resolution + diffing

    /// `plugin.json.version` wins over marketplace and SHA. This is the
    /// spec-defined precedence so plugin authors get a single source of
    /// truth when they bump the manifest.
    @Test func versionResolutionPrefersPluginJSON() {
        let v = GitHubSkillService.ClaudePluginVersionResolver.resolve(
            pluginJSONVersion: "2.0.0",
            marketplaceVersion: "1.5.0",
            sha: "deadbeefdeadbeefdeadbeef"
        )
        #expect(v == "2.0.0")
    }

    /// Marketplace version takes over when `plugin.json` lacks `version`.
    @Test func versionResolutionFallsBackToMarketplace() {
        let v = GitHubSkillService.ClaudePluginVersionResolver.resolve(
            pluginJSONVersion: nil,
            marketplaceVersion: "1.5.0",
            sha: "deadbeefdeadbeefdeadbeef"
        )
        #expect(v == "1.5.0")
    }

    /// SHA fallback truncates to the conventional 7-char short SHA so
    /// the UI pill stays compact.
    @Test func versionResolutionTruncatesShaToShort() {
        let v = GitHubSkillService.ClaudePluginVersionResolver.resolve(
            pluginJSONVersion: nil,
            marketplaceVersion: nil,
            sha: "deadbeefdeadbeefdeadbeef"
        )
        #expect(v == "deadbee")
    }

    @Test func versionResolutionReturnsNilWhenAllAbsent() {
        let v = GitHubSkillService.ClaudePluginVersionResolver.resolve(
            pluginJSONVersion: "  ",
            marketplaceVersion: "",
            sha: nil
        )
        #expect(v == nil)
    }

    /// Semver compare: 1.2.3 → 1.2.4 is an update; 1.2.4 → 1.2.3 is not;
    /// equal is not.
    @Test func hasUpdateSemverComparison() {
        let r = GitHubSkillService.ClaudePluginVersionResolver.self
        #expect(r.hasUpdate(installed: "1.2.3", available: "1.2.4") == true)
        #expect(r.hasUpdate(installed: "1.2.4", available: "1.2.3") == false)
        #expect(r.hasUpdate(installed: "1.2.3", available: "1.2.3") == false)
    }

    /// SHA-vs-SHA falls back to string inequality per spec — any
    /// difference counts as an update.
    @Test func hasUpdateShaFallback() {
        let r = GitHubSkillService.ClaudePluginVersionResolver.self
        #expect(r.hasUpdate(installed: "abc1234", available: "def5678") == true)
        #expect(r.hasUpdate(installed: "abc1234", available: "abc1234") == false)
    }

    /// First install (installed = nil) should always surface an update
    /// when an available version exists.
    @Test func hasUpdateMissingInstalledCountsAsUpdate() {
        let r = GitHubSkillService.ClaudePluginVersionResolver.self
        #expect(r.hasUpdate(installed: nil, available: "1.0.0") == true)
        #expect(r.hasUpdate(installed: "", available: "1.0.0") == true)
    }

    /// No available version → no update (so the badge stays clean when
    /// the update probe hasn't run yet).
    @Test func hasUpdateMissingAvailableMeansNoUpdate() {
        let r = GitHubSkillService.ClaudePluginVersionResolver.self
        #expect(r.hasUpdate(installed: "1.0.0", available: nil) == false)
        #expect(r.hasUpdate(installed: "1.0.0", available: "") == false)
    }

    // MARK: - Variable expander

    /// `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_DATA}` must resolve
    /// to the per-plugin paths owned by `OsaurusPaths` so MCP servers can
    /// read from / write to a stable location.
    @Test func expandsPluginRootAndDataPaths() async {
        await Self.withIsolatedRoot(label: "expander-paths") { _ in
            let pluginId = "github:owner/repo/example"
            let ctx = ClaudePluginExpansionContext(pluginId: pluginId)
            let input = "root=${CLAUDE_PLUGIN_ROOT} data=${CLAUDE_PLUGIN_DATA}"
            let expanded = ClaudePluginVariableExpander.expand(input, context: ctx)

            #expect(expanded.contains(OsaurusPaths.claudePluginCacheDir(for: pluginId).path))
            #expect(expanded.contains(OsaurusPaths.claudePluginDataDir(for: pluginId).path))
            #expect(!expanded.contains("${CLAUDE_PLUGIN_ROOT}"))
            #expect(!expanded.contains("${CLAUDE_PLUGIN_DATA}"))
        }
    }

    /// `${user_config.KEY}` substitutes from the non-sensitive bag.
    /// Unknown keys fall through to the literal token so authors notice
    /// when a value isn't wired up.
    @Test func expandsUserConfigValuesAndPreservesUnknown() {
        let ctx = ClaudePluginExpansionContext(
            pluginId: "github:o/r/p",
            userConfig: ["REGION": "us-west-2"]
        )
        let input = "--region ${user_config.REGION} --secret ${user_config.MISSING}"
        let out = ClaudePluginVariableExpander.expand(input, context: ctx)
        #expect(out.contains("--region us-west-2"))
        // Unresolved key remains as a literal — never coerced to an empty
        // string, which would silently break MCP command lines.
        #expect(out.contains("${user_config.MISSING}"))
    }

    /// Sensitive values are routed through the optional resolver. This
    /// preserves the spec rule that plaintext sensitive values are never
    /// in the non-sensitive bag.
    @Test func expandsSensitiveUserConfigViaResolver() {
        let resolver: @Sendable (String) -> String? = { key in
            key == "API_KEY" ? "sk-secret" : nil
        }
        let ctx = ClaudePluginExpansionContext(
            pluginId: "github:o/r/p",
            userConfig: [:],
            sensitiveResolver: resolver
        )
        let out = ClaudePluginVariableExpander.expand(
            "auth=${user_config.API_KEY}",
            context: ctx
        )
        #expect(out == "auth=sk-secret")
    }

    /// Generic `${VAR}` resolves only for allow-listed names. Anything
    /// else stays literal so a hostile plugin can't pull a random env var
    /// by guessing its name.
    @Test func expandsAllowListedEnvVarsOnly() {
        setenv("CLAUDE_PLUGIN_TEST_ALLOWED", "yes", 1)
        setenv("CLAUDE_PLUGIN_TEST_FORBIDDEN", "no", 1)
        defer {
            unsetenv("CLAUDE_PLUGIN_TEST_ALLOWED")
            unsetenv("CLAUDE_PLUGIN_TEST_FORBIDDEN")
        }
        let ctx = ClaudePluginExpansionContext(
            pluginId: "github:o/r/p",
            extraAllowedEnvVars: ["CLAUDE_PLUGIN_TEST_ALLOWED"]
        )
        let out = ClaudePluginVariableExpander.expand(
            "a=${CLAUDE_PLUGIN_TEST_ALLOWED} b=${CLAUDE_PLUGIN_TEST_FORBIDDEN}",
            context: ctx
        )
        #expect(out.contains("a=yes"))
        // Forbidden var is kept as the literal token, not the host value.
        #expect(out.contains("b=${CLAUDE_PLUGIN_TEST_FORBIDDEN}"))
        #expect(!out.contains("b=no"))
    }

    /// Expansion must be idempotent — running it twice on the same
    /// string mustn't keep substituting fresh values. This pins the
    /// caller-friendly contract that `expand(expand(x)) == expand(x)`.
    @Test func expandIsIdempotent() async {
        await Self.withIsolatedRoot(label: "expander-idempotent") { _ in
            let ctx = ClaudePluginExpansionContext(
                pluginId: "github:o/r/p",
                userConfig: ["FOO": "bar"]
            )
            let input = "${CLAUDE_PLUGIN_DATA}/work-${user_config.FOO}"
            let once = ClaudePluginVariableExpander.expand(input, context: ctx)
            let twice = ClaudePluginVariableExpander.expand(once, context: ctx)
            #expect(once == twice)
        }
    }

    /// Subprocess env overlay exports the two filesystem paths plus a
    /// `CLAUDE_PLUGIN_OPTION_<KEY>` for each user_config value. This is
    /// the shape Claude Code injects into MCP processes.
    @Test func subprocessEnvIncludesPluginOptions() async {
        await Self.withIsolatedRoot(label: "expander-subprocess") { _ in
            let ctx = ClaudePluginExpansionContext(
                pluginId: "github:o/r/p",
                userConfig: ["REGION": "us-west-2", "DEBUG": "1"]
            )
            let env = ClaudePluginVariableExpander.subprocessEnv(context: ctx)
            #expect(env["CLAUDE_PLUGIN_ROOT"]?.isEmpty == false)
            #expect(env["CLAUDE_PLUGIN_DATA"]?.isEmpty == false)
            #expect(env["CLAUDE_PLUGIN_OPTION_REGION"] == "us-west-2")
            #expect(env["CLAUDE_PLUGIN_OPTION_DEBUG"] == "1")
        }
    }

    // MARK: - Manifest store

    /// Round-trip: save a snapshot, load by id, and confirm every
    /// persisted field survives. Uses an isolated test root so the
    /// per-test JSON lives under `/tmp/...`.
    @Test func manifestStoreRoundTripsSnapshot() async {
        await Self.withIsolatedRoot(label: "manifest-store-rt") { _ in
            let snap = ClaudePluginManifestSnapshot(
                pluginId: "github:acme/widgets/renewals",
                name: "renewals",
                displayName: "Renewals",
                description: "Tracks contract renewals.",
                version: "1.0.0",
                sourceOwner: "acme",
                sourceRepo: "widgets",
                sourceBranch: "main",
                sourcePath: "renewals",
                authorName: "Ada",
                authorEmail: "ada@example.com",
                authorURL: nil,
                homepage: "https://example.com",
                repository: "https://github.com/acme/widgets",
                license: "MIT",
                keywords: ["contracts", "renewals"],
                installedAt: Date(timeIntervalSince1970: 1_700_000_000),
                userConfigSpec: [
                    ClaudePluginUserConfigField(
                        key: "API_KEY",
                        type: .string,
                        title: "API Key",
                        description: "Vendor key",
                        sensitive: true,
                        required: true
                    )
                ],
                declaresHooks: true,
                declaresUnsupportedComponents: ["channels"],
                declaredCounts: .init(skills: 2, agents: 1, commands: 0, mcp: 1)
            )

            #expect(ClaudePluginManifestStore.save(snap) == true)
            let loaded = ClaudePluginManifestStore.load(pluginId: snap.pluginId)
            #expect(loaded != nil)
            #expect(loaded == snap)
        }
    }

    /// `all()` should sort by displayName and tolerate corrupt files —
    /// one bad JSON shouldn't blank the grid for every other plugin.
    @Test func manifestStoreAllSkipsCorruptFiles() async {
        await Self.withIsolatedRoot(label: "manifest-store-all") { _ in
            let good = ClaudePluginManifestSnapshot(
                pluginId: "github:o/r/good",
                name: "good",
                displayName: "Good Plugin",
                description: nil,
                version: nil,
                sourceOwner: "o",
                sourceRepo: "r",
                installedAt: Date(),
                declaredCounts: .init(skills: 0, agents: 0, commands: 0, mcp: 0)
            )
            let other = ClaudePluginManifestSnapshot(
                pluginId: "github:o/r/another",
                name: "another",
                displayName: "Another Plugin",
                description: nil,
                version: nil,
                sourceOwner: "o",
                sourceRepo: "r",
                installedAt: Date(),
                declaredCounts: .init(skills: 0, agents: 0, commands: 0, mcp: 0)
            )
            ClaudePluginManifestStore.save(good)
            ClaudePluginManifestStore.save(other)

            // Drop a non-JSON file alongside the snapshots to simulate
            // corruption. `all()` must skip it without throwing.
            let dir = OsaurusPaths.claudePluginsManifestsDir()
            let garbage = dir.appendingPathComponent("garbage.json")
            try? Data("not json".utf8).write(to: garbage)

            let all = ClaudePluginManifestStore.all()
            let names = all.map(\.displayName)
            #expect(names == ["Another Plugin", "Good Plugin"])
        }
    }

    /// `delete(pluginId:)` removes the manifest, user-config, and data
    /// directories so an uninstall leaves no residue.
    @Test func manifestStoreDeleteRemovesAllSidecars() async {
        await Self.withIsolatedRoot(label: "manifest-store-del") { _ in
            let pluginId = "github:o/r/del"
            let snap = ClaudePluginManifestSnapshot(
                pluginId: pluginId,
                name: "del",
                displayName: "Delete Me",
                description: nil,
                version: nil,
                sourceOwner: "o",
                sourceRepo: "r",
                installedAt: Date(),
                declaredCounts: .init(skills: 0, agents: 0, commands: 0, mcp: 0)
            )
            ClaudePluginManifestStore.save(snap)
            ClaudePluginManifestStore.saveUserConfig(
                pluginId: pluginId,
                values: ["DEBUG": "1"]
            )
            _ = ClaudePluginManifestStore.ensureDataDir(for: pluginId)

            #expect(
                FileManager.default.fileExists(
                    atPath: OsaurusPaths.claudePluginManifestFile(for: pluginId).path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: OsaurusPaths.claudePluginUserConfigFile(for: pluginId).path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: OsaurusPaths.claudePluginDataDir(for: pluginId).path
                )
            )

            ClaudePluginManifestStore.delete(pluginId: pluginId)

            #expect(
                !FileManager.default.fileExists(
                    atPath: OsaurusPaths.claudePluginManifestFile(for: pluginId).path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: OsaurusPaths.claudePluginUserConfigFile(for: pluginId).path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: OsaurusPaths.claudePluginDataDir(for: pluginId).path
                )
            )
            #expect(ClaudePluginManifestStore.load(pluginId: pluginId) == nil)
            #expect(ClaudePluginManifestStore.loadUserConfig(pluginId: pluginId).isEmpty)
        }
    }

    /// User-config snapshot round-trips its keyed values verbatim. This
    /// is the non-sensitive store; sensitive keys go through Keychain.
    @Test func manifestStoreUserConfigRoundTrip() async {
        await Self.withIsolatedRoot(label: "manifest-store-uc") { _ in
            let pluginId = "github:o/r/uc"
            ClaudePluginManifestStore.saveUserConfig(
                pluginId: pluginId,
                values: ["REGION": "us-west-2", "DEBUG": "true"]
            )
            let loaded = ClaudePluginManifestStore.loadUserConfig(pluginId: pluginId)
            #expect(loaded["REGION"] == "us-west-2")
            #expect(loaded["DEBUG"] == "true")
        }
    }

    /// `claudePluginSafeId` must collapse path separators / colons so
    /// `github:owner/repo/plugin` becomes a single-segment filename. The
    /// store relies on this to flatten ids into one directory.
    @Test func safePluginIdReplacesUnsafeCharacters() {
        let id = OsaurusPaths.claudePluginSafeId("github:owner/repo/plugin-name")
        // Allowed chars: A-Za-z0-9_- — colons and slashes get replaced.
        #expect(!id.contains(":"))
        #expect(!id.contains("/"))
        #expect(id.contains("plugin-name"))
    }

    // MARK: - Aggregator projections

    /// `InstalledClaudePluginsAggregator.buildPlugins` should fan each
    /// manager record into the per-item arrays keyed by `pluginId`,
    /// keep them sorted by display name, and ignore non-Claude records
    /// (skills/schedules/commands/MCPs whose `pluginId` is nil or not a
    /// `github:` id). This is the new per-item detail story driving the
    /// Components section.
    @Test func aggregatorProjectsPerItemRecordsByPluginId() {
        let pluginA = "github:owner/repo/alpha"
        let pluginB = "github:owner/repo/beta"

        let snapshots = [
            Self.makeSnapshot(pluginId: pluginA, displayName: "Alpha"),
            Self.makeSnapshot(pluginId: pluginB, displayName: "Beta"),
        ]
        let skills: [Skill] = [
            Skill(
                name: "Zeta",
                description: "z desc",
                version: "2.0.0",
                author: "Ada",
                category: "Finance",
                keywords: ["alpha", "beta"],
                instructions: "Read carefully and respond.",
                references: [SkillFile(name: "ref1.md", relativePath: "references/ref1.md", size: 10)],
                assets: [
                    SkillFile(name: "logo.png", relativePath: "assets/logo.png", size: 5),
                    SkillFile(name: "doc.pdf", relativePath: "assets/doc.pdf", size: 5),
                ],
                pluginId: pluginA
            ),
            Skill(name: "Aether", description: "a desc", enabled: false, pluginId: pluginA),
            // User-authored skill — should not project onto any plugin.
            Skill(name: "User Skill", description: "x"),
            // Foreign plugin id — also ignored.
            Skill(name: "Sandbox", pluginId: "sandbox-plugin:unrelated"),
        ]
        let schedules: [Schedule] = [
            Schedule(
                name: "Daily summary",
                instructions: "Summarize the day's contracts.",
                parameters: [ScheduleManager.pluginIdParameterKey: pluginA],
                folderPath: "/tmp/work",
                frequency: .daily(hour: 9, minute: 0)
            ),
            Schedule(
                name: "Hourly check",
                instructions: "check",
                parameters: [ScheduleManager.pluginIdParameterKey: pluginB],
                frequency: .hourly(minute: 0),
                isEnabled: false
            ),
        ]
        let commands: [SlashCommand] = [
            SlashCommand(
                name: "lookup",
                description: "Find a contract",
                template: "Look up the contract called {{name}}.",
                pluginId: pluginA
            ),
            SlashCommand(
                name: "alpha-cmd",
                description: "",
                template: nil,
                pluginId: pluginA
            ),
        ]
        let providers: [MCPProvider] = [
            MCPProvider(
                name: "remote-mcp",
                url: "https://example.com/mcp",
                pluginId: pluginA
            ),
            MCPProvider(
                name: "local-mcp",
                url: "",
                pluginId: pluginB,
                transport: .stdio,
                executionHost: .sandbox,
                command: "npx",
                args: ["-y", "@scope/local-mcp"],
                env: ["REGION": "us-west-2", "API_KEY": "should-not-leak"],
                secretEnvKeys: ["API_KEY"],
                workingDirectory: "/tmp/mcp"
            ),
        ]

        let result = InstalledClaudePluginsAggregator.buildPlugins(
            snapshots: snapshots,
            skills: skills,
            schedules: schedules,
            commands: commands,
            providers: providers
        )

        // Sorted by displayName: Alpha then Beta.
        #expect(result.map(\.pluginId) == [pluginA, pluginB])

        let alpha = result[0]
        // Skills sorted by name (case-insensitive): Aether, Zeta.
        #expect(alpha.skills.map(\.name) == ["Aether", "Zeta"])
        #expect(alpha.skills.first { $0.name == "Aether" }?.enabled == false)
        #expect(alpha.skills.first { $0.name == "Zeta" }?.enabled == true)
        // Preview-driving skill fields.
        let zeta = alpha.skills.first { $0.name == "Zeta" }
        #expect(zeta?.instructions == "Read carefully and respond.")
        #expect(zeta?.keywords == ["alpha", "beta"])
        #expect(zeta?.version == "2.0.0")
        #expect(zeta?.author == "Ada")
        #expect(zeta?.category == "Finance")
        #expect(zeta?.referenceCount == 1)
        #expect(zeta?.assetCount == 2)
        // Schedules.
        #expect(alpha.schedules.map(\.name) == ["Daily summary"])
        #expect(alpha.schedules.first?.frequencyText.contains("Daily") == true)
        #expect(alpha.schedules.first?.instructions == "Summarize the day's contracts.")
        #expect(alpha.schedules.first?.folderPath == "/tmp/work")
        // Commands sorted by name: alpha-cmd, lookup.
        #expect(alpha.commands.map(\.name) == ["alpha-cmd", "lookup"])
        // Template preview present for command with a template.
        let lookup = alpha.commands.first { $0.name == "lookup" }
        #expect(lookup?.templatePreview == "Look up the contract called {{name}}.")
        // Full template preserved for the preview popover.
        #expect(lookup?.template == "Look up the contract called {{name}}.")
        // Empty-template command yields nil preview.
        let alphaCmd = alpha.commands.first { $0.name == "alpha-cmd" }
        #expect(alphaCmd?.templatePreview == nil)
        #expect(alphaCmd?.template == nil)
        // Counts derived from same arrays.
        #expect(alpha.counts.skill == 2)
        #expect(alpha.counts.schedule == 1)
        #expect(alpha.counts.command == 2)
        #expect(alpha.counts.mcp == 1)
        // MCP subtitle for HTTP provider is the URL.
        #expect(alpha.mcps.first?.subtitle == "https://example.com/mcp")
        #expect(alpha.mcps.first?.transport == .http)
        #expect(alpha.mcps.first?.isStdio == false)
        #expect(alpha.mcps.first?.url == "https://example.com/mcp")
        #expect(alpha.mcps.first?.command.isEmpty == true)
        #expect(alpha.mcps.first?.envEntries.isEmpty == true)

        let beta = result[1]
        // Stdio provider subtitle is `command args...`.
        #expect(beta.mcps.first?.subtitle == "npx -y @scope/local-mcp")
        #expect(beta.mcps.first?.transport == .stdio)
        #expect(beta.mcps.first?.isStdio == true)
        #expect(beta.mcps.first?.executionHost == .sandbox)
        #expect(beta.mcps.first?.command == "npx")
        #expect(beta.mcps.first?.args == ["-y", "@scope/local-mcp"])
        #expect(beta.mcps.first?.workingDirectory == "/tmp/mcp")
        // Sensitive env value must be scrubbed; non-secret value pass-through.
        let env = beta.mcps.first?.envEntries ?? []
        let apiKey = env.first { $0.key == "API_KEY" }
        let region = env.first { $0.key == "REGION" }
        #expect(apiKey?.value == nil)
        #expect(apiKey?.isSensitive == true)
        #expect(region?.value == "us-west-2")
        #expect(region?.isSensitive == false)
        #expect(beta.schedules.first?.isEnabled == false)
        // Beta has zero skills/commands; arrays must be empty (not nil).
        #expect(beta.skills.isEmpty)
        #expect(beta.commands.isEmpty)
    }

    /// A plugin with a manifest snapshot but no live artifacts must
    /// still render — with all four projection arrays as empty arrays
    /// (never nil). The detail view relies on this so it can show "0
    /// imported" placeholders for each kind instead of hiding them.
    @Test func aggregatorTreatsCountZeroAsEmptyArray() {
        let pluginId = "github:owner/repo/silent"
        let snapshots = [Self.makeSnapshot(pluginId: pluginId, displayName: "Silent")]

        let result = InstalledClaudePluginsAggregator.buildPlugins(
            snapshots: snapshots,
            skills: [],
            schedules: [],
            commands: [],
            providers: []
        )

        #expect(result.count == 1)
        let p = result[0]
        #expect(p.pluginId == pluginId)
        #expect(p.skills == [])
        #expect(p.schedules == [])
        #expect(p.commands == [])
        #expect(p.mcps == [])
        #expect(p.counts.total == 0)
    }

    // MARK: - Helpers

    private static func makeSnapshot(
        pluginId: String,
        displayName: String
    ) -> ClaudePluginManifestSnapshot {
        ClaudePluginManifestSnapshot(
            pluginId: pluginId,
            name: displayName.lowercased(),
            displayName: displayName,
            description: nil,
            version: nil,
            sourceOwner: "owner",
            sourceRepo: "repo",
            installedAt: Date(),
            declaredCounts: .init(skills: 0, agents: 0, commands: 0, mcp: 0)
        )
    }
}

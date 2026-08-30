//
//  ConfigSecretRefTests.swift
//  OsaurusCoreTests
//
//  Phase 4 — secrets by reference. Pins the `*_ref` grammar, the planner
//  validation (format, env presence, placement rules, mutual exclusion),
//  the plan wording (ref display names only — never values), and the
//  channel apply path end-to-end via the in-memory test Keychain. The
//  MCP/provider Keychains have no in-memory store: under
//  OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS their apply paths are pinned to the
//  documented needs-user-action / failure shapes; with a live Keychain
//  (CI's xcodebuild lane) the store succeeds and the row completes.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Grammar

struct ConfigSecretRefGrammarTests {

    @Test
    func parsesEnvAndKeychainForms() {
        guard case .success(let env) = ConfigSecretRef.parse("env:MY_API_KEY") else {
            Issue.record("env ref failed to parse")
            return
        }
        #expect(env.source == .env("MY_API_KEY"))
        #expect(env.display == "env:MY_API_KEY")

        guard case .success(let kc) = ConfigSecretRef.parse("keychain:my-service/my-account")
        else {
            Issue.record("keychain ref failed to parse")
            return
        }
        #expect(kc.source == .keychain(service: "my-service", account: "my-account"))
        #expect(kc.display == "keychain:my-service/my-account")
    }

    @Test
    func rejectsMalformedRefs() {
        for raw in [
            "sk-live-actual-secret",  // a raw secret is never a ref
            "env:",
            "env:9BAD",
            "env:HAS SPACE",
            "keychain:no-slash",
            "keychain:/account",
            "keychain:service/",
        ] {
            if case .success = ConfigSecretRef.parse(raw) {
                Issue.record("`\(raw)` should not parse as a secret ref")
            }
        }
    }

    @Test
    func envResolutionUsesOverrideAndTrims() {
        let environment = ["SET_KEY": "  value-123  ", "EMPTY_KEY": "   "]

        guard case .success(let set) = ConfigSecretRef.parse("env:SET_KEY"),
            case .success(let empty) = ConfigSecretRef.parse("env:EMPTY_KEY"),
            case .success(let missing) = ConfigSecretRef.parse("env:MISSING_KEY")
        else {
            Issue.record("refs failed to parse")
            return
        }
        #expect(set.resolve(environment: environment) == "value-123")
        #expect(empty.resolve(environment: environment) == nil)
        #expect(missing.resolve(environment: environment) == nil)
        #expect(set.planTimeIssue(label: "x", environment: environment) == nil)
        #expect(empty.planTimeIssue(label: "x", environment: environment) != nil)
        #expect(missing.planTimeIssue(label: "x", environment: environment) != nil)
    }
}

// MARK: - Planner validation and wording

/// Merge (never clear) the shared env override: suites run in parallel, so
/// clearing it from one test would yank keys out from under another. Key
/// names are unique per test; leftovers are harmless in the test process.
@MainActor
private func mergeSecretRefTestEnv(_ pairs: [String: String]) {
    var environment = ConfigSecretRef.environmentOverrideForTests ?? [:]
    environment.merge(pairs) { _, new in new }
    ConfigSecretRef.environmentOverrideForTests = environment
}

@Suite(.serialized)
@MainActor
struct ConfigSecretRefPlannerTests {

    private func planIssues(_ mutate: (inout OsaurusConfigDocument) -> Void) -> [String] {
        var document = OsaurusConfigDocument()
        mutate(&document)
        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            return []
        } catch let error as ConfigPlanIssues {
            return error.issues
        } catch {
            return ["unexpected error: \(error)"]
        }
    }

    @Test
    func providerRefRules_areValidated() {
        mergeSecretRefTestEnv(["GOOD_KEY": "k"])

        let issues = planIssues { document in
            var raw = ProviderEntry(name: "Raw Secret Probe \(UUID().uuidString.prefix(6))")
            raw.provider = "openai"
            raw.apiKeyRef = "sk-live-oops"
            var both = ProviderEntry(name: "Both Probe \(UUID().uuidString.prefix(6))")
            both.provider = "openai"
            both.apiKeyRef = "env:GOOD_KEY"
            both.setApiKey = true
            var oauth = ProviderEntry(name: "OAuth Probe \(UUID().uuidString.prefix(6))")
            oauth.provider = "codex_oauth"
            oauth.apiKeyRef = "env:GOOD_KEY"
            var missing = ProviderEntry(name: "Missing Env Probe \(UUID().uuidString.prefix(6))")
            missing.provider = "openai"
            missing.apiKeyRef = "env:NOT_SET_ANYWHERE"
            document.providers = [raw, both, oauth, missing]
        }
        #expect(issues.contains { $0.contains("not a secret reference") })
        #expect(issues.contains { $0.contains("not both") })
        #expect(issues.contains { $0.contains("OAuth/pairing") })
        #expect(issues.contains { $0.contains("`NOT_SET_ANYWHERE` is not set") })
    }

    @Test
    func mcpRefPlacement_isValidatedByTransport() {
        mergeSecretRefTestEnv(["GOOD_KEY": "k"])

        let issues = planIssues { document in
            var stdio = MCPServerEntry(name: "Stdio Ref Probe")
            stdio.transport = "stdio"
            stdio.command = "/usr/bin/true"
            stdio.tokenRef = "env:GOOD_KEY"
            var http = MCPServerEntry(name: "HTTP Ref Probe")
            http.url = "https://mcp.example.test"
            http.secretEnvRefs = ["API_TOKEN": "env:GOOD_KEY"]
            var oauth = MCPServerEntry(name: "OAuth Ref Probe")
            oauth.url = "https://mcp.example.test/oauth"
            oauth.auth = "oauth"
            oauth.tokenRef = "env:GOOD_KEY"
            document.mcpServers = [stdio, http, oauth]
        }
        #expect(issues.contains { $0.contains("url/auth/token_ref only apply") })
        #expect(issues.contains { $0.contains("secret_env_refs only apply to transport: stdio") })
        #expect(issues.contains { $0.contains("token_ref only fits bearer auth") })
    }

    @Test
    func channelRefPlacement_isValidatedByPlatform() {
        mergeSecretRefTestEnv(["GOOD_KEY": "k"])

        let issues = planIssues { document in
            var channels = ChannelsSection()
            var imessage = ChannelPlatformSection()
            imessage.botTokenRef = "env:GOOD_KEY"
            channels.imessage = imessage
            var discord = ChannelPlatformSection()
            discord.appTokenRef = "env:GOOD_KEY"
            channels.discord = discord
            document.channels = channels
        }
        #expect(issues.contains { $0.contains("imessage") && $0.contains("no bot token") })
        #expect(issues.contains { $0.contains("only Slack uses an app-level token") })
    }

    @Test
    func planShowsRefDisplayNames_andNeverSecretValues() throws {
        mergeSecretRefTestEnv(["PROBE_KEY": "super-secret-value-987"])

        var document = OsaurusConfigDocument()
        var provider = ProviderEntry(name: "Ref Provider Probe \(UUID().uuidString.prefix(6))")
        provider.provider = "openai"
        provider.apiKeyRef = "env:PROBE_KEY"
        document.providers = [provider]
        var channels = ChannelsSection()
        var telegram = ChannelPlatformSection()
        telegram.botTokenRef = "env:PROBE_KEY"
        channels.telegram = telegram
        document.channels = channels

        let plan = try ConfigPlanner.plan(document: document, prune: false)
        let text = plan.summaryText()
        #expect(text.contains("env:PROBE_KEY"))
        #expect(!text.contains("super-secret-value-987"))

        // A ref creates a provider WITHOUT the interactive credential sheet.
        let providerAction = plan.actions.first { $0.section == "providers" }
        #expect(providerAction?.kind == .create)
        #expect(plan.actions.contains { $0.section == "channels" && $0.target == "telegram" })
    }
}

// MARK: - Apply

@Suite(.serialized)
@MainActor
struct ConfigSecretRefApplyTests {

    private static func apply(
        prune: Bool = false, _ mutate: (inout OsaurusConfigDocument) -> Void
    ) async -> [ConfigApplyResult] {
        var document = OsaurusConfigDocument()
        mutate(&document)
        return await ConfigApplier.apply(document: document, prune: prune)
    }

    @Test
    func channelBotTokenRef_storesTheTokenFromEnv() async throws {
        // Channel config stores are shared with the channel connection
        // suites, which serialize through this lock.
        try await AgentChannelConfigurationTestLock.shared.run {
            try await Self.runChannelBotTokenRefStore()
        }
    }

    @MainActor
    private static func runChannelBotTokenRefStore() async throws {
        let secret = "tg-token-\(UUID().uuidString.prefix(8))"
        mergeSecretRefTestEnv(["TG_PROBE_TOKEN": secret])
        defer { TelegramCredentialStore.deleteBotToken() }

        var channels = ChannelsSection()
        var telegram = ChannelPlatformSection()
        telegram.botTokenRef = "env:TG_PROBE_TOKEN"
        channels.telegram = telegram
        let results = await apply { $0.channels = channels }

        let result = results.first { $0.section == "channels" && $0.target == "telegram" }
        #expect(result?.status == .done, "\(results)")
        #expect(result?.message?.contains("env:TG_PROBE_TOKEN") == true)
        #expect(result?.message?.contains(secret) != true)
        #expect(TelegramCredentialStore.botToken() == secret)

        // The stored token never surfaces in an export, and re-planning the
        // fresh export stays a no-op (refs are write-only). Scoped to the
        // channels section so concurrent suites mutating other live state
        // cannot poison the check.
        let yaml = try ConfigYAML.encode(ConfigExporter.export())
        #expect(!yaml.contains(secret))
        #expect(!yaml.contains("token_ref"))
        let scoped = ConfigExporter.export().filtered(to: [.channels])
        let plan = try ConfigPlanner.plan(document: scoped, prune: false)
        #expect(plan.isEmpty, "expected no-op plan, got:\n\(plan.summaryText())")
    }

    @Test
    func unresolvableChannelRef_failsWithoutPartialWrites() async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            try await Self.runUnresolvableChannelRef()
        }
    }

    @MainActor
    private static func runUnresolvableChannelRef() async throws {
        mergeSecretRefTestEnv([:])

        let before = ConfigExporter.export().channels?.telegram

        var channels = ChannelsSection()
        var telegram = ChannelPlatformSection()
        telegram.botTokenRef = "env:NOT_SET"
        telegram.defaultReadLimit = (before?.defaultReadLimit == 33) ? 44 : 33
        channels.telegram = telegram
        let results = await apply { $0.channels = channels }

        let result = results.first { $0.section == "channels" && $0.target == "telegram" }
        #expect(result?.status == .failed)
        // The read-limit change was withheld — no partial write.
        let after = ConfigExporter.export().channels?.telegram
        #expect(after?.defaultReadLimit == before?.defaultReadLimit)
    }

    @Test
    func mcpSecretEnvRef_reportsKeychainUnavailabilityHonestly() async throws {
        // MCPProviderKeychain goes to the real Keychain (no in-memory test
        // store), so the expected apply status depends on the launch mode:
        // under OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS the documented contract
        // is server registered + needs-user-action (never a silent fake
        // success); with a live Keychain (CI's xcodebuild lane) the secret
        // stores and the row completes. Both modes must keep the secret
        // value out of every message and export.
        let secret = "mcp-secret-\(UUID().uuidString.prefix(8))"
        mergeSecretRefTestEnv(["MCP_PROBE_TOKEN": secret])

        let name = "Stdio Secret Probe \(UUID().uuidString.prefix(6))"
        var entry = MCPServerEntry(name: name)
        entry.transport = "stdio"
        entry.command = "/usr/bin/true"
        entry.enabled = false
        entry.secretEnvRefs = ["API_TOKEN": "env:MCP_PROBE_TOKEN"]
        let results = await Self.apply { $0.mcpServers = [entry] }

        let result = results.first { $0.section == "mcp_servers" && $0.target == name }
        if KeychainQueryHelpers.disablesKeychainForProcess {
            #expect(result?.status == .needsUserAction, "\(results)")
            #expect(result?.message?.contains("API_TOKEN") == true)
        } else {
            #expect(result?.status == .done, "\(results)")
        }
        #expect(result?.message?.contains(secret) != true)

        // The secret env key left the plain env and never exports a value.
        let exported = (ConfigExporter.export().mcpServers ?? []).first { $0.name == name }
        #expect(exported != nil)
        #expect(exported?.env?["API_TOKEN"] == nil)
        let yaml = try ConfigYAML.encode(ConfigExporter.export())
        #expect(!yaml.contains(secret))

        // Cleanup: prune the probe server away.
        let others = (ConfigExporter.export().mcpServers ?? []).filter { $0.name != name }
        _ = await Self.apply(prune: true) { $0.mcpServers = others }
    }

    @Test
    func unresolvableMCPTokenRef_doesNotCreateTheServer() async throws {
        mergeSecretRefTestEnv([:])

        let name = "HTTP Ref Probe \(UUID().uuidString.prefix(6))"
        var entry = MCPServerEntry(name: name)
        entry.url = "https://mcp.example.test"
        entry.tokenRef = "env:NOT_SET"
        let results = await Self.apply { $0.mcpServers = [entry] }

        let result = results.first { $0.section == "mcp_servers" && $0.target == name }
        #expect(result?.status == .failed)
        let exported = (ConfigExporter.export().mcpServers ?? []).first { $0.name == name }
        #expect(exported == nil, "server must not be registered on an unresolvable ref")
    }
}

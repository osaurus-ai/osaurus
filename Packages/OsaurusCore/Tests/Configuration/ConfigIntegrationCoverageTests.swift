//
//  ConfigIntegrationCoverageTests.swift
//  OsaurusCoreTests
//
//  Wave 3c — integrations coverage. Pins the new sections (commands,
//  knowledge_collections, channels), the mcp_servers stdio extension, and
//  the provider endpoint contract (export + create-only) through the
//  planner (validation, risk flags) plus apply -> export round trips
//  against the real stores (under OSAURUS_TEST_ROOT). The theme/voice keys
//  this file once covered were removed in the scope reduction.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Planner validation

@Suite(.serialized)
@MainActor
struct ConfigIntegrationPlannerTests {

    private func plan(_ mutate: (inout OsaurusConfigDocument) -> Void) throws -> ConfigPlan {
        var document = OsaurusConfigDocument()
        mutate(&document)
        return try ConfigPlanner.plan(document: document, prune: false)
    }

    private func planIssues(_ mutate: (inout OsaurusConfigDocument) -> Void) -> [String] {
        do {
            _ = try plan(mutate)
            return []
        } catch let error as ConfigPlanIssues {
            return error.issues
        } catch {
            return ["unexpected error: \(error)"]
        }
    }

    @Test
    func commands_rejectBuiltinsBadNamesAndMissingTemplate() {
        let issues = planIssues { document in
            var reserved = CommandEntry(name: "clear")
            reserved.template = "t"
            var spaced = CommandEntry(name: "two words")
            spaced.template = "t"
            let missingTemplate = CommandEntry(name: "no-template")
            document.commands = [reserved, spaced, missingTemplate]
        }
        #expect(issues.contains { $0.contains("built-in command") })
        #expect(issues.contains { $0.contains("no spaces") })
        #expect(issues.contains { $0.contains("`template` is required") })
    }

    @Test
    func knowledgeCollections_requireExistingFolderToCreate() {
        let issues = planIssues { document in
            var entry = KnowledgeCollectionEntry(name: "Probe Collection")
            entry.folderPath = "/nonexistent/osaurus-probe-\(UUID().uuidString.prefix(6))"
            document.knowledgeCollections = [entry]
        }
        #expect(issues.contains { $0.contains("not an existing directory") })

        let missing = planIssues { document in
            document.knowledgeCollections = [KnowledgeCollectionEntry(name: "Probe Collection")]
        }
        #expect(missing.contains { $0.contains("`folder_path` is required") })
    }

    @Test
    func channels_validateReadLimitAndInboundAgent() {
        let issues = planIssues { document in
            var channels = ChannelsSection()
            var discord = ChannelPlatformSection()
            discord.defaultReadLimit = 500
            discord.inboundAgent = .value("default")
            channels.discord = discord
            var slack = ChannelPlatformSection()
            slack.inboundAgent = .value("No Such Agent \(UUID().uuidString.prefix(6))")
            channels.slack = slack
            document.channels = channels
        }
        #expect(issues.contains { $0.contains("channels.discord.default_read_limit") })
        #expect(issues.contains { $0.contains("never the Default agent") })
        #expect(issues.contains { $0.contains("no custom agent named") })
    }

    @Test
    func mcpStdio_requiresCommandAndValidHostAndSplitsFieldsByTransport() {
        let issues = planIssues { document in
            var noCommand = MCPServerEntry(name: "Stdio Probe A")
            noCommand.transport = "stdio"
            var badHost = MCPServerEntry(name: "Stdio Probe B")
            badHost.transport = "stdio"
            badHost.command = "/usr/bin/true"
            badHost.executionHost = "cloud"
            var mixed = MCPServerEntry(name: "HTTP Probe")
            mixed.url = "https://mcp.example.test"
            mixed.command = "/usr/bin/true"
            document.mcpServers = [noCommand, badHost, mixed]
        }
        #expect(issues.contains { $0.contains("`command` is required") })
        #expect(issues.contains { $0.contains("sandbox or host") })
        #expect(issues.contains { $0.contains("only apply to transport: stdio") })
    }

    @Test
    func newStdioServer_isFlaggedHighRisk() throws {
        let plan = try plan { document in
            var entry = MCPServerEntry(name: "Stdio Risk Probe")
            entry.transport = "stdio"
            entry.command = "/usr/local/bin/mcp-server"
            entry.args = ["--serve"]
            entry.executionHost = "host"
            document.mcpServers = [entry]
        }
        #expect(plan.hasHighRiskChanges)
        #expect(
            plan.risks.contains(
                ConfigRisk.stdioCommand("Stdio Risk Probe", "/usr/local/bin/mcp-server --serve")))
        #expect(plan.risks.contains(ConfigRisk.stdioOnHost("Stdio Risk Probe")))
    }

    @Test
    func channelWriteEnables_areFlaggedHighRisk() throws {
        let current = ConfigExporter.export().channels
        let plan = try plan { document in
            var channels = ChannelsSection()
            channels.writeEnabled = true
            var discord = ChannelPlatformSection()
            discord.writeEnabled = true
            discord.autoReplyEnabled = true
            channels.discord = discord
            document.channels = channels
        }
        if current?.writeEnabled != true {
            #expect(plan.risks.contains(ConfigRisk.channelWritesGlobal))
        }
        if current?.discord?.writeEnabled != true {
            #expect(plan.risks.contains(ConfigRisk.channelWrites("discord")))
        }
        if current?.discord?.autoReplyEnabled != true {
            #expect(plan.risks.contains(ConfigRisk.channelAutoReply("discord")))
        }
    }

    @Test
    func providerEndpointChanges_onExistingProviderAreRefused() async throws {
        // Serialize with suites that install/remove live remote providers,
        // so the provider read here cannot vanish mid-test.
        try await RemoteProviderTestLock.shared.run {
            // An edited endpoint on any existing provider is refused; the
            // unchanged-export no-op contract lives in the apply suite.
            guard var entry = ConfigExporter.export().providers?.first else { return }
            entry.host = "attacker.example.test"
            let issues = self.planIssues { $0.providers = [entry] }
            #expect(issues.contains { $0.contains("cannot be changed") })
        }
    }

    @Test
    func providerEndpointRanges_areValidated() {
        let issues = planIssues { document in
            var entry = ProviderEntry(name: "Endpoint Probe \(UUID().uuidString.prefix(6))")
            entry.provider = "custom"
            entry.providerProtocol = "gopher"
            entry.port = .value(70000)
            entry.timeoutSeconds = 0
            document.providers = [entry]
        }
        #expect(issues.contains { $0.contains("protocol: must be http or https") })
        #expect(issues.contains { $0.contains("port: must be in 1...65535") })
        #expect(issues.contains { $0.contains("timeout_seconds: must be in 1...600") })
    }
}

// MARK: - Apply -> export round trips

@Suite(.serialized)
@MainActor
struct ConfigIntegrationApplyTests {

    private static func apply(
        prune: Bool = false, _ mutate: (inout OsaurusConfigDocument) -> Void
    ) async -> [ConfigApplyResult] {
        var document = OsaurusConfigDocument()
        mutate(&document)
        return await ConfigApplier.apply(document: document, prune: prune)
    }

    private static func expectNoFailures(_ results: [ConfigApplyResult]) {
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
    }

    /// Section-scoped so concurrent suites mutating unrelated live state
    /// (providers, agents, server, ...) cannot poison the no-op check.
    private static func expectIdempotentExport(sections: Set<ConfigSectionID>) throws {
        let scoped = ConfigExporter.export().filtered(to: sections)
        let plan = try ConfigPlanner.plan(document: scoped, prune: false)
        #expect(plan.isEmpty, "expected no-op plan, got:\n\(plan.summaryText())")
    }

    @Test
    func ephemeralProviders_areInvisibleToExportAndSurvivePrune() async throws {
        // Serialize with suites that install/remove live remote providers.
        try await RemoteProviderTestLock.shared.run {
            try await Self.runEphemeralProviderScope()
        }
    }

    @MainActor
    private static func runEphemeralProviderScope() async throws {
        // Ephemeral providers (Bonjour peers, the eval harness's in-memory
        // run/judge providers) are runtime state, not configuration: they
        // must never export, and a prune apply must never remove them.
        let name = "Ephemeral Probe \(UUID().uuidString.prefix(6))"
        let provider = RemoteProvider(
            id: UUID(),
            name: name,
            host: "ephemeral.probe.invalid",
            providerProtocol: .https,
            port: nil,
            basePath: "/v1",
            customHeaders: [:],
            authType: .none,
            providerType: .openaiLegacy,
            enabled: false,
            autoConnect: false,
            timeout: 30
        )
        RemoteProviderManager.shared.addProvider(provider, apiKey: nil, isEphemeral: true)
        defer { RemoteProviderManager.shared.removeProvider(id: provider.id) }

        let exported = ConfigExporter.export().providers ?? []
        #expect(!exported.contains { $0.name == name })

        // A prune apply of exactly the manageable slice is a no-op for the
        // manageable providers AND leaves the ephemeral one alive. Before
        // the manageable-scope fix this delete evicted it.
        expectNoFailures(await apply(prune: true) { $0.providers = exported })
        let stillThere = RemoteProviderManager.shared.configuration.providers
            .contains { $0.id == provider.id }
        #expect(stillThere, "prune apply must not remove an ephemeral provider")
    }

    @Test
    func commands_createUpdatePruneRoundTrip() async throws {
        // Storage-paths lock: the slash command store lives under
        // `OsaurusPaths`, which other suites redirect via `overrideRoot`.
        try await StoragePathsTestLock.shared.run {
            try await Self.runCommandsRoundTrip()
        }
    }

    @MainActor
    private static func runCommandsRoundTrip() async throws {
        let name = "probe-\(UUID().uuidString.prefix(6).lowercased())"

        var entry = CommandEntry(name: name)
        entry.description = "Probe command"
        entry.template = "Do the probe thing."
        expectNoFailures(await apply { $0.commands = [entry] })

        var exported = ConfigExporter.export().commands ?? []
        var found = exported.first { $0.name == name }
        #expect(found?.template == "Do the probe thing.")
        try expectIdempotentExport(sections: [.commands])

        entry.template = "Do the probe thing, but better."
        entry.icon = "sparkles"
        expectNoFailures(await apply { $0.commands = [entry] })
        exported = ConfigExporter.export().commands ?? []
        found = exported.first { $0.name == name }
        #expect(found?.template == "Do the probe thing, but better.")
        #expect(found?.icon == "sparkles")

        // Prune with the command absent deletes it (and only it).
        let others = exported.filter { $0.name != name }
        expectNoFailures(await apply(prune: true) { $0.commands = others })
        let after = ConfigExporter.export().commands ?? []
        #expect(!after.contains { $0.name == name })
    }

    @Test
    func knowledgeCollections_createUpdatePruneRoundTrip() async throws {
        // Storage-paths lock: the knowledge collection store lives under
        // `OsaurusPaths`, which other suites redirect via `overrideRoot`.
        try await StoragePathsTestLock.shared.run {
            try await Self.runKnowledgeCollectionsRoundTrip()
        }
    }

    @MainActor
    private static func runKnowledgeCollectionsRoundTrip() async throws {
        let name = "Probe Collection \(UUID().uuidString.prefix(6))"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-kc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var entry = KnowledgeCollectionEntry(name: name)
        entry.folderPath = folder.path
        entry.summary = "Probe docs"
        entry.includeGlobs = ["**/*.md"]
        expectNoFailures(await apply { $0.knowledgeCollections = [entry] })

        var exported = ConfigExporter.export().knowledgeCollections ?? []
        var found = exported.first { $0.name == name }
        #expect(found?.summary == "Probe docs")
        #expect(found?.includeGlobs == ["**/*.md"])
        #expect(found?.enabled == true)
        try expectIdempotentExport(sections: [.knowledgeCollections])

        entry.enabled = false
        entry.excludeGlobs = ["**/secrets/**"]
        expectNoFailures(await apply { $0.knowledgeCollections = [entry] })
        exported = ConfigExporter.export().knowledgeCollections ?? []
        found = exported.first { $0.name == name }
        #expect(found?.enabled == false)
        #expect(found?.excludeGlobs == ["**/secrets/**"])

        let others = exported.filter { $0.name != name }
        expectNoFailures(await apply(prune: true) { $0.knowledgeCollections = others })
        let after = ConfigExporter.export().knowledgeCollections ?? []
        #expect(!after.contains { $0.name == name })
    }

    @Test
    func channels_applyThenExportRoundTrip() async throws {
        // Channel config stores are shared with the channel connection
        // suites, which serialize through this lock.
        try await AgentChannelConfigurationTestLock.shared.run {
            try await Self.runChannelsRoundTrip()
        }
    }

    @MainActor
    private static func runChannelsRoundTrip() async throws {
        let before = ConfigExporter.export().channels

        var channels = ChannelsSection()
        var telegram = ChannelPlatformSection()
        telegram.defaultReadLimit = before?.telegram?.defaultReadLimit == 25 ? 40 : 25
        telegram.senderAllowlist = ["1001", "1002"]
        telegram.requireMention = !(before?.telegram?.requireMention ?? true)
        channels.telegram = telegram
        expectNoFailures(await apply { $0.channels = channels })

        let after = ConfigExporter.export().channels
        #expect(after?.telegram?.defaultReadLimit == telegram.defaultReadLimit)
        #expect(after?.telegram?.senderAllowlist == ["1001", "1002"])
        #expect(after?.telegram?.requireMention == telegram.requireMention)
        try expectIdempotentExport(sections: [.channels])

        var restore = ChannelsSection()
        var restoreTelegram = ChannelPlatformSection()
        restoreTelegram.defaultReadLimit = before?.telegram?.defaultReadLimit
        restoreTelegram.senderAllowlist = before?.telegram?.senderAllowlist ?? []
        restoreTelegram.requireMention = before?.telegram?.requireMention
        restore.telegram = restoreTelegram
        _ = await apply { $0.channels = restore }
    }

    @Test
    func channelKillSwitch_applyThenExportRoundTrip() async throws {
        try await AgentChannelConfigurationTestLock.shared.run {
            try await Self.runChannelKillSwitchRoundTrip()
        }
    }

    @MainActor
    private static func runChannelKillSwitchRoundTrip() async throws {
        let before = ConfigExporter.export().channels?.writeEnabled ?? true

        var channels = ChannelsSection()
        channels.writeEnabled = !before
        expectNoFailures(await apply { $0.channels = channels })
        #expect(ConfigExporter.export().channels?.writeEnabled == !before)
        try expectIdempotentExport(sections: [.channels])

        var restore = ChannelsSection()
        restore.writeEnabled = before
        _ = await apply { $0.channels = restore }
    }

    @Test
    func mcpStdio_createUpdatePruneRoundTrip() async throws {
        let name = "Stdio Probe \(UUID().uuidString.prefix(6))"

        var entry = MCPServerEntry(name: name)
        entry.transport = "stdio"
        entry.command = "/usr/bin/true"
        entry.args = ["--flag"]
        entry.env = ["PROBE_MODE": "on"]
        // Disabled: apply must register it without launching the process.
        entry.enabled = false
        Self.expectNoFailures(await Self.apply { $0.mcpServers = [entry] })

        var exported = ConfigExporter.export().mcpServers ?? []
        var found = exported.first { $0.name == name }
        #expect(found?.transport == "stdio")
        #expect(found?.command == "/usr/bin/true")
        #expect(found?.args == ["--flag"])
        #expect(found?.env?["PROBE_MODE"] == "on")
        #expect(found?.executionHost == "sandbox")
        #expect(found?.url == nil)
        try Self.expectIdempotentExport(sections: [.mcpServers])

        entry.args = ["--flag", "--verbose"]
        entry.env = ["PROBE_MODE": "off"]
        Self.expectNoFailures(await Self.apply { $0.mcpServers = [entry] })
        exported = ConfigExporter.export().mcpServers ?? []
        found = exported.first { $0.name == name }
        #expect(found?.args == ["--flag", "--verbose"])
        #expect(found?.env?["PROBE_MODE"] == "off")

        let others = exported.filter { $0.name != name }
        Self.expectNoFailures(await Self.apply(prune: true) { $0.mcpServers = others })
        let after = ConfigExporter.export().mcpServers ?? []
        #expect(!after.contains { $0.name == name })
    }

    @Test
    func exportedDocument_stillContainsNoSecretShapedKeys() throws {
        let yaml = try ConfigYAML.encode(ConfigExporter.export())
        let lowered = yaml.lowercased()
        for forbidden in ["api_key", "apikey", "access_token", "bearer_token", "password"] {
            #expect(!lowered.contains(forbidden), "exported YAML contains `\(forbidden)`")
        }
    }
}

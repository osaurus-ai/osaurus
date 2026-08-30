//
//  DeclarativeConfigTests.swift
//  OsaurusCoreTests
//
//  The declarative configuration engine behind `osaurus_config`:
//   * `ConfigYAML` — strict two-phase decode (unknown keys are actionable
//     errors, not silent no-ops), null-vs-absent semantics, round-trip.
//   * `ConfigTemplateStore` — the ONLY file surface of the tool. Names are
//     sanitised and path-confined to `~/.osaurus/templates/`; traversal
//     and absolute-path escapes must be impossible.
//   * `ConfigPlanner` — merge-by-default diffing, all-or-nothing
//     validation, prune-only deletions, and high-risk flagging (the exact
//     strings the apply approval gate lists).
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - ConfigYAML

struct ConfigYAMLStrictDecodeTests {

    @Test
    func unknownKey_failsWithDidYouMean() {
        let yaml = """
            default_agent:
              temprature: 0.7
            """
        do {
            _ = try ConfigYAML.decode(yaml)
            Issue.record("expected ConfigYAMLError for the typo'd key")
        } catch let error as ConfigYAMLError {
            let joined = error.messages.joined(separator: "\n")
            #expect(joined.contains("temprature"))
            #expect(joined.contains("temperature"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func unknownTopLevelSection_isRejected() {
        do {
            _ = try ConfigYAML.decode("agentz:\n  - name: Probe\n")
            Issue.record("expected rejection of unknown section")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("agentz"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func removedSections_teachTheSettingsUIRedirect() {
        // Scope reduction 2: `server`, `chat`, `app` are Settings-UI-only.
        // A document naming them must get the honest redirect, not a
        // did-you-mean loop.
        for removed in ["server", "chat", "app"] {
            do {
                _ = try ConfigYAML.decode("\(removed):\n  anything: true\n")
                Issue.record("expected rejection of removed section `\(removed)`")
            } catch let error as ConfigYAMLError {
                let joined = error.messages.joined(separator: "\n")
                #expect(joined.contains("Settings UI"), "no redirect for `\(removed)`: \(joined)")
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }

    @Test
    func topLevelSectionAliases_teachTheRealSection() {
        // `mcp:` for `mcp_servers:` is the dominant local-model miss; the
        // edit distance (8) is beyond the did-you-mean budget, so the alias
        // table must bridge it.
        let cases: [(yaml: String, wrong: String, right: String)] = [
            ("mcp:\n  - name: Acme\n", "mcp", "mcp_servers"),
            ("knowledge:\n  - name: Docs\n", "knowledge", "knowledge_collections"),
        ]
        for testCase in cases {
            do {
                _ = try ConfigYAML.decode(testCase.yaml)
                Issue.record("expected rejection of `\(testCase.wrong)`")
            } catch let error as ConfigYAMLError {
                let joined = error.messages.joined(separator: "\n")
                #expect(joined.contains(testCase.wrong))
                #expect(joined.contains(testCase.right))
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }

    @Test
    func emptyDocument_isRejectedWithClearMessage() {
        do {
            _ = try ConfigYAML.decode("   \n")
            Issue.record("expected rejection of empty document")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().lowercased().contains("empty"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func nonMappingRoot_isRejected() {
        do {
            _ = try ConfigYAML.decode("- just\n- a\n- list\n")
            Issue.record("expected rejection of list root")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("mapping"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func entityListItems_requireTheirNameKey() {
        let yaml = """
            agents:
              - system_prompt: no name here
            """
        do {
            _ = try ConfigYAML.decode(yaml)
            Issue.record("expected missing-name rejection")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("name"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func unknownKeyErrors_teachTheDocumentKey() {
        // Models copy field names from osaurus_inspect payloads (`id`,
        // `default_model`, `provider_type`) into YAML; the validator must
        // name the real key in one step instead of listing all valid keys.
        let yaml = """
            agents:
              - id: 2BFA42F0-D9F3-4061-BDB1-3B68E97724F1
                default_model: claude-fable-5
            """
        do {
            _ = try ConfigYAML.decode(yaml)
            Issue.record("expected rejection of inspect-payload keys")
        } catch let error as ConfigYAMLError {
            let joined = error.messages.joined(separator: "\n")
            #expect(joined.contains("match by `name`"))
            #expect(joined.contains("Use `model`"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        do {
            _ = try ConfigYAML.decode("providers:\n  - name: xAI\n    provider_type: xai\n")
            Issue.record("expected rejection of provider_type")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("Use `provider`"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func unknownScheduleKeys_teachTheFlatFrequencyShape() {
        // Prose vocabulary ("run on a daily cadence at 08:00", "a cron
        // schedule") leads models to invent `cadence:`/`cron:`/`time:` keys —
        // observed live on Ornith-9B, which then gave up instead of retrying.
        // The teach must name the real keys in one step.
        do {
            _ = try ConfigYAML.decode(
                "schedules:\n  - name: Brief\n    agent: A\n    cadence: daily\n")
            Issue.record("expected rejection of cadence")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("Use `frequency`"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        do {
            _ = try ConfigYAML.decode(
                "schedules:\n  - name: Brief\n    agent: A\n    cron: \"0 8 * * *\"\n")
            Issue.record("expected rejection of cron")
        } catch let error as ConfigYAMLError {
            let joined = error.messages.joined()
            #expect(joined.contains("frequency: cron"))
            #expect(joined.contains("frequency_value"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        do {
            _ = try ConfigYAML.decode(
                "schedules:\n  - name: Brief\n    agent: A\n    time: \"08:00\"\n")
            Issue.record("expected rejection of time")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("Use `frequency_time_of_day`"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func providerSetApiKey_decodesAsRequestFlag() throws {
        // `set_api_key: true` is the document's way to ask apply to open the
        // credential sheet on an EXISTING provider (set or rotate the key,
        // even when OAuth already works). It must decode, and it must never
        // round-trip out of an export (it's a request, not state).
        let yaml = """
            providers:
              - name: xAI
                set_api_key: true
            """
        let document = try ConfigYAML.decode(yaml)
        let entry = try #require(document.providers?.first)
        #expect(entry.setApiKey == true)

        var exported = OsaurusConfigDocument()
        exported.providers = [ProviderEntry(name: "xAI")]
        let encoded = try ConfigYAML.encode(exported)
        #expect(!encoded.contains("set_api_key"))
    }

    @Test
    func nullVsAbsent_surviveDecoding() throws {
        // `temperature: null` must decode as an explicit clear, while an
        // absent `model` stays untouched — the merge semantics the whole
        // document contract rests on.
        let yaml = """
            default_agent:
              temperature: null
              max_tokens: 2048
            """
        let document = try ConfigYAML.decode(yaml)
        let defaultAgent = try #require(document.defaultAgent)
        #expect(defaultAgent.temperature == .null)
        #expect(defaultAgent.model == .absent)
        #expect(defaultAgent.maxTokens == .value(2048))
    }

    @Test
    func roundTrip_preservesTheDocument() throws {
        var document = OsaurusConfigDocument()
        var defaultAgent = DefaultAgentSection()
        defaultAgent.maxTokens = .value(2048)
        defaultAgent.temperature = .value(0.6)
        document.defaultAgent = defaultAgent
        var agent = AgentEntry(name: "Researcher")
        agent.systemPrompt = "Research things.\nBe concise."
        document.agents = [agent]
        document.models = ["mlx-community/Some-Model-4bit"]

        let yaml = try ConfigYAML.encode(document)
        let decoded = try ConfigYAML.decode(yaml)
        #expect(decoded.defaultAgent?.maxTokens == .value(2048))
        #expect(decoded.defaultAgent?.temperature == .value(0.6))
        #expect(decoded.agents?.first?.name == "Researcher")
        #expect(decoded.agents?.first?.systemPrompt?.contains("Be concise") == true)
        #expect(decoded.models == ["mlx-community/Some-Model-4bit"])
    }

    @Test
    func agentCapabilitiesDocument_decodesWithoutTrapping() throws {
        // Regression: the validation walk used to pass `&issues` to
        // `checkList` while the per-item closure CAPTURED the same variable —
        // a Swift exclusivity violation that crashed the app for any document
        // with `agents[].capabilities` (the schema's own example shape).
        let yaml = """
            agents:
              - name: Research Agent
                capabilities:
                  tools_enabled: true
                  web_search_enabled: true
            """
        let document = try ConfigYAML.decode(yaml)
        #expect(document.agents?.first?.capabilities?.toolsEnabled == true)
        #expect(document.agents?.first?.capabilities?.webSearchEnabled == true)
    }

    @Test
    func unknownKeyInsideAgentCapabilities_stillReportsDidYouMean() {
        // The same closure path must keep REPORTING issues after the
        // exclusivity fix (it now writes through an inout parameter).
        let yaml = """
            agents:
              - name: Research Agent
                capabilities:
                  web_serach_enabled: true
            """
        do {
            _ = try ConfigYAML.decode(yaml)
            Issue.record("expected rejection of the typo'd capability key")
        } catch let error as ConfigYAMLError {
            let joined = error.messages.joined(separator: "\n")
            #expect(joined.contains("web_serach_enabled"))
            #expect(joined.contains("web_search_enabled"))
            #expect(joined.contains("agents[0].capabilities"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func unsupportedVersion_isRejected() {
        do {
            _ = try ConfigYAML.decode("version: 2\nmemory:\n  enabled: true\n")
            Issue.record("expected version rejection")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("version"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func invalidToolPolicyValue_isRejected() {
        let yaml = """
            tools:
              policies:
                web_search: always
            """
        do {
            _ = try ConfigYAML.decode(yaml)
            Issue.record("expected policy-value rejection")
        } catch let error as ConfigYAMLError {
            #expect(error.messages.joined().contains("auto, ask, deny"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

// MARK: - Template store confinement

struct ConfigTemplateStoreSecurityTests {

    @Test
    func traversalAndSeparatorNames_areRejected() {
        for hostile in [
            "../outside", "..", "a/b", "a\\b", "/etc/passwd",
            "~/.ssh/id_rsa", ".hidden", "name\0null", "a:b",
        ] {
            if case .success(let fileName) = ConfigTemplateStore.sanitizedFileName(hostile) {
                Issue.record("hostile name `\(hostile)` sanitised to `\(fileName)`")
            }
        }
    }

    @Test
    func reasonableNames_areAccepted() {
        for good in ["research-setup", "My_Template.v2", "daily.brief", "a"] {
            guard case .success(let fileName) = ConfigTemplateStore.sanitizedFileName(good) else {
                Issue.record("good name `\(good)` was rejected")
                continue
            }
            #expect(fileName.hasSuffix(".yaml"))
            #expect(!fileName.contains("/"))
        }
    }

    @Test
    func yamlExtensionIsStrippedBeforeSanitising() {
        guard case .success(let fileName) = ConfigTemplateStore.sanitizedFileName("setup.yaml")
        else {
            Issue.record("`setup.yaml` was rejected")
            return
        }
        #expect(fileName == "setup.yaml")
    }

    @Test
    func overlongNames_areRejected() {
        let overlong = String(repeating: "a", count: 101)
        if case .success = ConfigTemplateStore.sanitizedFileName(overlong) {
            Issue.record("101-char name was accepted")
        }
    }

    @Test
    func saveLoadList_roundTripInsideTemplatesDir() throws {
        let name = "decl-config-test-\(UUID().uuidString.prefix(8))"
        let yaml = "memory:\n  enabled: true\n"
        guard case .success(let url) = ConfigTemplateStore.save(yaml: yaml, name: name) else {
            Issue.record("save failed")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        // Confined: the saved file must live inside the templates dir.
        // (Both sides symlink-resolved: under OSAURUS_TEST_ROOT=/tmp the
        // store's confinement resolves /tmp -> /private/tmp.)
        let resolvedDir = OsaurusPaths.configTemplates()
            .resolvingSymlinksInPath().standardizedFileURL.path
        #expect(url.path.hasPrefix(resolvedDir))
        guard case .success(let loaded) = ConfigTemplateStore.load(name: name) else {
            Issue.record("load failed")
            return
        }
        #expect(loaded == yaml)
        #expect(ConfigTemplateStore.list().contains(String(name)))
    }

    @Test
    func loadMissingTemplate_failsWithHint() {
        guard
            case .failure(let message) = ConfigTemplateStore.load(
                name: "definitely-missing-\(UUID().uuidString.prefix(8))")
        else {
            Issue.record("expected missing-template failure")
            return
        }
        #expect(message.contains("No template named"))
    }

    @Test
    func symlinkInsideTemplatesDir_cannotReadOutsideFiles() throws {
        // A symlink named like a template must not let `load` read files
        // outside the directory — confinement resolves symlinks first.
        let fm = FileManager.default
        let outside = fm.temporaryDirectory
            .appendingPathComponent("decl-config-secret-\(UUID().uuidString.prefix(8)).txt")
        try Data("outside-secret".utf8).write(to: outside)
        defer { try? fm.removeItem(at: outside) }

        try OsaurusPaths.ensureExists(OsaurusPaths.configTemplates())
        let linkName = "sneaky-link-\(UUID().uuidString.prefix(8))"
        let link = OsaurusPaths.configTemplates().appendingPathComponent(linkName + ".yaml")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? fm.removeItem(at: link) }

        switch ConfigTemplateStore.load(name: linkName) {
        case .success(let contents):
            #expect(
                contents != "outside-secret",
                "symlink escape: template load read a file outside the templates dir")
        case .failure:
            // Rejected — the confinement held.
            break
        }
    }
}

// MARK: - Planner

@Suite(.serialized)
@MainActor
struct ConfigPlannerTests {

    @Test
    func documentMatchingCurrentState_plansNoChanges() throws {
        // Exporting the live state and planning it back must be a no-op —
        // the idempotence contract behind "apply is safe to re-run".
        let current = ConfigExporter.export()
        let plan = try ConfigPlanner.plan(document: current, prune: false)
        #expect(plan.isEmpty, "expected no-op plan, got:\n\(plan.summaryText())")
    }

    @Test
    func memoryBudgetChange_plansAnUpdateWithoutRisk() throws {
        var document = OsaurusConfigDocument()
        var memory = MemorySection()
        // Any budget different from the current one.
        let currentBudget = ConfigExporter.export().memory?.budgetTokens ?? 0
        memory.budgetTokens = currentBudget == 1200 ? 1600 : 1200
        document.memory = memory

        let plan = try ConfigPlanner.plan(document: document, prune: false)
        #expect(plan.actions.count == 1)
        #expect(plan.actions.first?.section == "memory")
        #expect(plan.actions.first?.kind == .update)
        #expect(!plan.hasHighRiskChanges)
    }

    @Test
    func autoToolPolicy_isFlaggedHighRisk() throws {
        // The high-risk gate fixture: `tools.policies: auto` survives scope
        // reduction 2 (server-owned gates left with the `server` section).
        var document = OsaurusConfigDocument()
        var tools = ToolsSection()
        tools.policies = ["web_search": "auto"]
        document.tools = tools

        let plan = try ConfigPlanner.plan(document: document, prune: false)
        // Either the current state already has it on auto (no change) or the
        // plan must carry the exact risk string the apply gate lists.
        if !plan.isEmpty {
            #expect(plan.risks.contains(ConfigRisk.autoPolicy("web_search")))
            #expect(plan.hasHighRiskChanges)
        }
    }

    @Test
    func newMCPServer_isFlaggedHighRiskAndNeverCarriesSecrets() throws {
        var document = OsaurusConfigDocument()
        var entry = MCPServerEntry(name: "Planner Probe MCP")
        entry.url = "https://mcp.example.test/sse"
        document.mcpServers = [entry]

        let plan = try ConfigPlanner.plan(document: document, prune: false)
        #expect(plan.actions.contains { $0.section == "mcp_servers" && $0.kind == .create })
        #expect(
            plan.risks.contains(
                ConfigRisk.mcpEndpoint("Planner Probe MCP", "https://mcp.example.test/sse")))
    }

    @Test
    func newAgentWithComputerUse_isFlaggedHighRisk() throws {
        var document = OsaurusConfigDocument()
        var agent = AgentEntry(name: "Planner Probe Agent \(UUID().uuidString.prefix(6))")
        var caps = AgentCapabilitiesEntry()
        caps.computerUseEnabled = true
        agent.capabilities = caps
        document.agents = [agent]

        let plan = try ConfigPlanner.plan(document: document, prune: false)
        #expect(plan.hasHighRiskChanges)
        #expect(plan.risks.contains { $0.contains("screen control") })
    }

    @Test
    func pruneWithoutFlag_neverPlansDeletes() throws {
        // A merge (non-prune) plan for an empty agents list must not delete
        // anything, no matter what exists.
        var document = OsaurusConfigDocument()
        document.agents = []
        let plan = try ConfigPlanner.plan(document: document, prune: false)
        #expect(!plan.actions.contains { $0.kind == .delete })
    }

    @Test
    func scheduleReferencingUnknownAgent_failsValidationAtomically() {
        var document = OsaurusConfigDocument()
        var schedule = ScheduleEntry(name: "Planner Probe Schedule")
        schedule.agent = "no-such-agent-\(UUID().uuidString.prefix(6))"
        schedule.instructions = "do things"
        schedule.frequency = "daily"
        schedule.frequencyTimeOfDay = "08:00"
        document.schedules = [schedule]

        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            Issue.record("expected ConfigPlanIssues for the unknown agent reference")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("no-such-agent") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func invalidScheduleFrequency_failsWithActionableMessage() {
        var document = OsaurusConfigDocument()
        var schedule = ScheduleEntry(name: "Planner Probe Schedule")
        schedule.agent = "default"
        schedule.instructions = "do things"
        schedule.frequency = "fortnightly"
        document.schedules = [schedule]

        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            Issue.record("expected frequency validation failure")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("frequency") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func setApiKey_plansCredentialPromptEvenWhenCredentialsExist() throws {
        // Regression for the live "set up xAI with an API key" transcript: the
        // provider existed with working (OAuth) credentials, so a plain entry
        // diffed to an empty plan, apply returned no_changes, and the sheet
        // never opened. `set_api_key: true` must plan the prompt regardless.
        let name = "Planner Probe Provider \(UUID().uuidString.prefix(6))"
        let provider = RemoteProvider(
            id: UUID(), name: name, host: "api.example.test",
            enabled: true, autoConnect: false
        )
        RemoteProviderManager.shared.addProvider(provider, apiKey: nil, isEphemeral: false)
        defer { RemoteProviderManager.shared.removeProvider(id: provider.id) }

        // Without the flag: nothing to change → empty plan (authType .none
        // counts as credentials-present).
        var document = OsaurusConfigDocument()
        var entry = ProviderEntry(name: name)
        entry.enabled = true
        document.providers = [entry]
        let noFlagPlan = try ConfigPlanner.plan(document: document, prune: false)
        #expect(noFlagPlan.isEmpty, "expected empty plan, got:\n\(noFlagPlan.summaryText())")

        // With the flag: the plan must announce the credential sheet.
        entry.setApiKey = true
        document.providers = [entry]
        let plan = try ConfigPlanner.plan(document: document, prune: false)
        let action = try #require(
            plan.actions.first { $0.section == "providers" && $0.target == name })
        #expect(action.kind == .needsUserInput)
        #expect(action.changes.joined().contains("credential sheet"))
    }

    @Test
    func unknownProviderId_failsValidationWithCanonicalList() {
        var document = OsaurusConfigDocument()
        var provider = ProviderEntry(name: "Mystery")
        provider.provider = "acme_llm"
        document.providers = [provider]

        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            Issue.record("expected provider-id validation failure")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("anthropic") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

// MARK: - Prune cross-reference integrity

@Suite(.serialized)
@MainActor
struct ConfigPlannerPruneIntegrityTests {

    /// Seed a custom agent, run `body`, and delete it afterwards.
    private func withSeededAgent(
        _ body: (Agent) async throws -> Void
    ) async throws {
        let agent = AgentManager.shared.create(
            name: "Prune Probe Agent \(UUID().uuidString.prefix(6))",
            description: "", systemPrompt: "")
        do {
            try await body(agent)
        } catch {
            _ = await AgentManager.shared.delete(id: agent.id)
            throw error
        }
        _ = await AgentManager.shared.delete(id: agent.id)
    }

    @Test
    func pruneRefusesToDeleteAgentASurvivingScheduleStillRunsOn() async throws {
        try await withSeededAgent { agent in
            let schedule = ScheduleManager.shared.create(
                name: "Prune Probe Schedule \(UUID().uuidString.prefix(6))",
                instructions: "do things",
                agentId: agent.id,
                frequency: .daily(hour: 8, minute: 0),
                isEnabled: false
            )
            defer { ScheduleManager.shared.delete(id: schedule.id) }

            // `agents: []` + prune deletes the agent; the schedules section
            // is ABSENT so the schedule survives — must refuse.
            var document = OsaurusConfigDocument()
            document.agents = []
            do {
                _ = try ConfigPlanner.plan(document: document, prune: true)
                Issue.record("expected prune refusal for the dangling schedule")
            } catch let issues as ConfigPlanIssues {
                #expect(issues.issues.contains { $0.contains(schedule.name) })
                #expect(issues.issues.contains { $0.contains(agent.name) })
            }
        }
    }

    @Test
    func pruneRefusesToDeleteAgentASurvivingWatcherStillRunsOn() async throws {
        try await withSeededAgent { agent in
            let watcher = WatcherManager.shared.create(
                name: "Prune Probe Watcher \(UUID().uuidString.prefix(6))",
                instructions: "organize",
                agentId: agent.id,
                isEnabled: false
            )
            defer { WatcherManager.shared.delete(id: watcher.id) }

            var document = OsaurusConfigDocument()
            document.agents = []
            do {
                _ = try ConfigPlanner.plan(document: document, prune: true)
                Issue.record("expected prune refusal for the dangling watcher")
            } catch let issues as ConfigPlanIssues {
                #expect(issues.issues.contains { $0.contains(watcher.name) })
            }
        }
    }

    @Test
    func pruningTheScheduleAlongsideItsAgent_isAllowed() async throws {
        try await withSeededAgent { agent in
            let schedule = ScheduleManager.shared.create(
                name: "Prune Probe Schedule \(UUID().uuidString.prefix(6))",
                instructions: "do things",
                agentId: agent.id,
                frequency: .daily(hour: 8, minute: 0),
                isEnabled: false
            )
            defer { ScheduleManager.shared.delete(id: schedule.id) }

            // Declaring `schedules: []` prunes the schedule together with
            // the agent — nothing dangles, so the plan must succeed.
            var document = OsaurusConfigDocument()
            document.agents = []
            document.schedules = []
            let plan = try ConfigPlanner.plan(document: document, prune: true)
            #expect(plan.actions.contains { $0.section == "agents" && $0.kind == .delete })
            #expect(plan.actions.contains { $0.section == "schedules" && $0.kind == .delete })
        }
    }

    @Test
    func scheduleReassignedToAPrunedAgent_failsValidation() async throws {
        try await withSeededAgent { agent in
            // The document keeps NO agents but tries to point a schedule at
            // the pruned one — the post-apply agent set must exclude it.
            var schedule = ScheduleEntry(name: "Prune Probe Reassign")
            schedule.agent = agent.name
            schedule.instructions = "do things"
            schedule.frequency = "daily"
            schedule.frequencyTimeOfDay = "08:00"

            var document = OsaurusConfigDocument()
            document.agents = []
            document.schedules = [schedule]
            do {
                _ = try ConfigPlanner.plan(document: document, prune: true)
                Issue.record("expected validation failure for reassignment to a pruned agent")
            } catch let issues as ConfigPlanIssues {
                #expect(issues.issues.contains { $0.contains(agent.name) })
            }
        }
    }

    @Test
    func schedulePruneDeletes_carryARiskString() async throws {
        try await withSeededAgent { agent in
            let schedule = ScheduleManager.shared.create(
                name: "Prune Probe Schedule \(UUID().uuidString.prefix(6))",
                instructions: "do things",
                agentId: agent.id,
                frequency: .daily(hour: 8, minute: 0),
                isEnabled: false
            )
            defer { ScheduleManager.shared.delete(id: schedule.id) }

            // Prune ONLY the schedules section (agents stay): the delete
            // must be flagged high-risk so the apply gate prompts.
            var document = OsaurusConfigDocument()
            document.schedules = []
            let plan = try ConfigPlanner.plan(document: document, prune: true)
            #expect(plan.hasHighRiskChanges)
            #expect(plan.risks.contains(ConfigRisk.deleteSchedule(schedule.name)))
        }
    }

    @Test
    func watcherPruneDeletes_carryARiskString() async throws {
        try await withSeededAgent { agent in
            let watcher = WatcherManager.shared.create(
                name: "Prune Probe Watcher \(UUID().uuidString.prefix(6))",
                instructions: "organize",
                agentId: agent.id,
                isEnabled: false
            )
            defer { WatcherManager.shared.delete(id: watcher.id) }

            var document = OsaurusConfigDocument()
            document.watchers = []
            let plan = try ConfigPlanner.plan(document: document, prune: true)
            #expect(plan.hasHighRiskChanges)
            #expect(plan.risks.contains(ConfigRisk.deleteWatcher(watcher.name)))
        }
    }
}

// MARK: - Plan fidelity (false-positive diffs, duplicate ids)

@Suite(.serialized)
@MainActor
struct ConfigPlanFidelityTests {

    @Test
    func equivalentFrequencySpellings_doNotPlanAnUpdate() async throws {
        let agent = AgentManager.shared.create(
            name: "Fidelity Probe Agent \(UUID().uuidString.prefix(6))",
            description: "", systemPrompt: "")
        let schedule = ScheduleManager.shared.create(
            name: "Fidelity Probe Schedule \(UUID().uuidString.prefix(6))",
            instructions: "do things",
            agentId: agent.id,
            frequency: .weekly(dayOfWeek: 2, hour: 8, minute: 0),
            isEnabled: false
        )

        // Stored: weekly MON 08:00. Document: lenient spellings the parser
        // accepts — must NOT show as a change.
        var entry = ScheduleEntry(name: schedule.name)
        entry.frequency = "Weekly"
        entry.frequencyValue = "Monday"
        entry.frequencyTimeOfDay = "08:00"

        var document = OsaurusConfigDocument()
        document.schedules = [entry]
        let plan = try? ConfigPlanner.plan(document: document, prune: false)

        ScheduleManager.shared.delete(id: schedule.id)
        _ = await AgentManager.shared.delete(id: agent.id)

        guard let plan else {
            Issue.record("plan unexpectedly failed validation")
            return
        }
        #expect(
            !plan.actions.contains { $0.section == "schedules" && $0.kind == .update },
            "equivalent frequency spellings planned an update:\n\(plan.summaryText())")
    }

    @Test
    func floatStoredTemperature_doesNotDiffAgainstYAMLDouble() async throws {
        // Live agent temperatures are Float; 0.7 as YAML Double differs in
        // the last bits. The planner must treat them as equal.
        var agent = AgentManager.shared.create(
            name: "Fidelity Probe Agent \(UUID().uuidString.prefix(6))",
            description: "", systemPrompt: "")
        agent.temperature = Float(0.7)
        AgentManager.shared.update(agent)

        var entry = AgentEntry(name: agent.name)
        entry.temperature = .value(0.7)

        var document = OsaurusConfigDocument()
        document.agents = [entry]
        let plan = try? ConfigPlanner.plan(document: document, prune: false)

        _ = await AgentManager.shared.delete(id: agent.id)

        guard let plan else {
            Issue.record("plan unexpectedly failed validation")
            return
        }
        #expect(
            !plan.actions.contains {
                $0.section == "agents" && $0.changes.contains { $0.hasPrefix("temperature:") }
            },
            "Float/Double temperature false positive:\n\(plan.summaryText())")
    }

    @Test
    func duplicateModelAndPluginIds_failValidation() {
        var document = OsaurusConfigDocument()
        document.models = ["mlx-community/Some-Model-4bit", "MLX-Community/Some-Model-4bit"]
        document.plugins = ["osaurus.weather", "osaurus.weather"]
        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            Issue.record("expected duplicate-id validation failure")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("models: duplicate") })
            #expect(issues.issues.contains { $0.contains("plugins: duplicate") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

// MARK: - Schema reference parity

struct ConfigSchemaParityTests {

    @Test
    func everyEnforcedKeyIsDocumentedInTheSchemaReference() {
        // `ConfigYAML.knownKeys` is the enforced schema; the reference text
        // is its documentation. A key added to the document model must show
        // up in both or the model gets a schema it cannot legally write.
        let text = ConfigSchemaReference.text
        for (path, keys) in ConfigYAML.knownKeys {
            for key in keys {
                let location = path.isEmpty ? "top level" : path
                #expect(
                    text.contains("\(key):"),
                    "`\(key)` (at `\(location)`) is enforced by ConfigYAML.knownKeys but missing from ConfigSchemaReference.text"
                )
            }
        }
    }
}

// MARK: - Export redaction

@Suite(.serialized)
@MainActor
struct ConfigExportRedactionTests {

    @Test
    func exportedYAML_neverContainsSecretShapedKeys() throws {
        // The schema has no secret-bearing fields BY CONSTRUCTION; this pin
        // exists so a future section addition that sneaks one in fails a
        // test instead of shipping key material through chat transcripts.
        let yaml = try ConfigYAML.encode(ConfigExporter.export())
        let lowered = yaml.lowercased()
        for forbidden in ["api_key", "apikey", "access_token", "refresh_token", "password"] {
            #expect(!lowered.contains(forbidden), "exported YAML contains `\(forbidden)`")
        }
    }
}

// MARK: - Apply security gates

/// The high-risk approval gate inside `osaurus_config` apply. Headless
/// surfaces must DENY (never mount an approval panel nobody can click),
/// and nothing may be applied on denial.
@Suite(.serialized)
struct OsaurusConfigToolHighRiskGateTests {

    // A surviving high-risk gate (scope reduction 2 removed the server-owned
    // ones): setting a tool policy to `auto` runs it without asking.
    private static let highRiskYAML = """
        tools:
          policies:
            web_search: auto
        """

    private static func applyArgs() -> String {
        let args: [String: Any] = ["action": "apply", "yaml": highRiskYAML]
        let data = try! JSONSerialization.data(withJSONObject: args)
        return String(decoding: data, as: UTF8.self)
    }

    @Test
    func headlessDenyContext_refusesHighRiskApply() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                try await OsaurusConfigTool().execute(argumentsJSON: Self.applyArgs())
            }
        }
        #expect(result.contains("user_denied") || result.contains("declined"))
        #expect(!result.contains("\"status\":\"applied\""))
        // And the tool policy must be unchanged afterwards.
        let policy = await MainActor.run {
            ConfigExporter.export().tools?.policies?["web_search"]
        }
        #expect(policy != "auto", "high-risk apply leaked through the deny gate")
    }

    @Test
    func schemaAction_honorsSectionsFilter_inArrayAndStringForm() async throws {
        // Models send `sections` both as `["models"]` and as the bare string
        // `"models"`; both must return only the asked section.
        for sectionsValue: Any in [["models"], "models"] {
            let args: [String: Any] = ["action": "schema", "sections": sectionsValue]
            let data = try JSONSerialization.data(withJSONObject: args)
            let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
                try await OsaurusConfigTool()
                    .execute(argumentsJSON: String(decoding: data, as: UTF8.self))
            }
            #expect(result.contains("models:"))
            #expect(!result.contains("mcp_servers:"), "filter ignored for \(sectionsValue)")
        }
    }

    @Test
    func schemaAction_unknownSection_suggestsTheRealOne() async throws {
        let args: [String: Any] = ["action": "schema", "sections": "mcp"]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool()
                .execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("mcp_servers"))
        #expect(result.contains("Did you mean"))
    }

    @Test
    func planResult_isMarkedAsDryRun_neverAsAnOutcome() async throws {
        // Small models read the plan summary as "done" and narrate success
        // without calling apply; the envelope must scream dry-run in both
        // the human summary and a typed status field.
        let yaml = """
            providers:
              - name: zz-dry-run-probe-\(UUID().uuidString.prefix(8))
                provider: openrouter
            """
        let args: [String: Any] = ["action": "plan", "yaml": yaml]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool()
                .execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("DRY RUN — nothing changed yet"), "missing dry-run marker: \(result)")
        #expect(result.contains("dry_run_not_applied"), "missing typed dry-run status: \(result)")
        #expect(!result.contains("\"status\":\"applied\""))
    }

    @Test
    func scopedExport_carriesTheFullKeyRosterAsYamlShape() async throws {
        // Exported YAML omits empty maps (e.g. `tools.policies` with no
        // entries) and models read the omission as "that key doesn't
        // exist"; the scoped export must ship the schema shape alongside.
        let args: [String: Any] = ["action": "export", "sections": "tools"]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusConfigTool()
                .execute(argumentsJSON: String(decoding: data, as: UTF8.self))
        }
        #expect(result.contains("yaml_shape"), "scoped export lost its yaml_shape: \(result)")
        #expect(result.contains("policies"), "tools shape must surface the `policies` key")
    }

    @Test
    func pruneApplyThatDeletesNothing_saysSoInTheNotes() async throws {
        // Observed fabrication: asked to remove a nonexistent entry, the
        // model applies an imagined keep-list with prune, which deletes
        // nothing (and may CREATE the imagined entries) — then narrates a
        // successful removal. The apply notes must state what happened.
        // Commands are a pure store write (no connect/credential side
        // effects), so the apply completes headlessly.
        let before = await MainActor.run { ConfigExporter.export() }
        let keepList = (before.commands ?? []).map { "  - name: \($0.name)" }
        let probe = "zz-prune-probe-\(UUID().uuidString.prefix(8))"
        let yaml =
            "commands:\n" + (keepList + ["  - name: \(probe)\n    template: \"probe\""])
            .joined(separator: "\n")
        let args: [String: Any] = ["action": "apply", "yaml": yaml, "prune": true]
        let data = try JSONSerialization.data(withJSONObject: args)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                try await OsaurusConfigTool()
                    .execute(argumentsJSON: String(decoding: data, as: UTF8.self))
            }
        }
        #expect(result.contains("prune: true deleted NOTHING"), "missing prune-honesty note: \(result)")
        #expect(result.contains("This apply CREATED"), "missing phantom-create note: \(result)")
        // Cleanup: restore the original commands list (prunes the probe).
        let cleanupYAML =
            keepList.isEmpty ? "commands: []" : "commands:\n" + keepList.joined(separator: "\n")
        let cleanup: [String: Any] = ["action": "apply", "yaml": cleanupYAML, "prune": true]
        let cleanupData = try JSONSerialization.data(withJSONObject: cleanup)
        _ = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                try await OsaurusConfigTool()
                    .execute(argumentsJSON: String(decoding: cleanupData, as: UTF8.self))
            }
        }
    }

    @Test
    func externalSurface_refusesHighRiskApply() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await ChatExecutionContext.$isExternalSurface.withValue(true) {
                try await OsaurusConfigTool().execute(argumentsJSON: Self.applyArgs())
            }
        }
        #expect(result.contains("user_denied") || result.contains("declined"))
        let policy = await MainActor.run {
            ConfigExporter.export().tools?.policies?["web_search"]
        }
        #expect(policy != "auto", "high-risk apply leaked through the external-surface gate")
    }
}

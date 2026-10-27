//
//  ConfigHarnessRuntimeTests.swift
//  OsaurusCoreTests
//
//  `harness_runtimes` and the `runtime` / `claude_code` agent keys: plan
//  validation and risks, apply into the runtime store and agent records,
//  and export → re-plan as a no-op.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Config harness runtimes", .serialized)
struct ConfigHarnessRuntimeTests {

    /// Runs `body` against an empty Osaurus root and runtime store.
    private func isolated(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = try HarnessFixtures.temporaryDirectory("config-harness")
            let previousStoreDir = await MainActor.run { HarnessRuntimeStore.overrideDirectory }
            await MainActor.run {
                OsaurusPaths.overrideRoot = root
                OsaurusPaths.ensureExistsSilent(OsaurusPaths.config())
                DefaultAgentConfigurationStore.resetCacheForTests()
                HarnessRuntimeStore.overrideDirectory = root
                HarnessRuntimeStore.shared.resetForTests()
                AgentManager.shared.refresh()
            }
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try await body()
            } catch {
                Issue.record("\(error)")
            }
            await MainActor.run {
                OsaurusPaths.overrideRoot = nil
                DefaultAgentConfigurationStore.resetCacheForTests()
                HarnessRuntimeStore.overrideDirectory = previousStoreDir
                HarnessRuntimeStore.shared.resetForTests()
                AgentManager.shared.refresh()
            }
        }
    }

    @MainActor
    private func issues(_ document: OsaurusConfigDocument, prune: Bool = false) -> [String] {
        do {
            _ = try ConfigPlanner.plan(document: document, prune: prune)
            return []
        } catch let error as ConfigPlanIssues {
            return error.issues
        } catch {
            return ["unexpected error: \(error)"]
        }
    }

    private static func spotlight() -> HarnessRuntimeEntry {
        var entry = HarnessRuntimeEntry(name: "Spotlight")
        entry.kind = "pi_rpc"
        entry.executable = "~/.local/bin/spotlight"
        entry.arguments = ["--mode", "rpc", "--session-id", "{chat_id}"]
        entry.environment = ["PI_LOG_LEVEL": "info"]
        return entry
    }

    @Test func invalidRuntimeEntriesAreTypedIssues() async throws {
        try await isolated {
            var reserved = HarnessRuntimeEntry(name: "builtin")
            reserved.kind = "pi_rpc"
            var badKind = HarnessRuntimeEntry(name: "Weird")
            badKind.kind = "acp"
            let noKind = HarnessRuntimeEntry(name: "Kindless")
            var emptyExecutable = HarnessRuntimeEntry(name: "Blank")
            emptyExecutable.kind = "pi_rpc"
            emptyExecutable.executable = "  "
            var document = OsaurusConfigDocument()
            document.harnessRuntimes = [reserved, badKind, noKind, emptyExecutable, Self.spotlight(), Self.spotlight()]

            let found = issues(document)
            #expect(found.contains { $0.contains("harness_runtimes[builtin]") && $0.contains("reserved") })
            #expect(found.contains { $0.contains("harness_runtimes[Weird].kind") })
            #expect(found.contains { $0.contains("harness_runtimes[Kindless]") && $0.contains("required") })
            #expect(found.contains { $0.contains("harness_runtimes[Blank].executable") })
            #expect(found.contains { $0.contains("harness_runtimes[Spotlight]") && $0.contains("duplicate") })
        }
    }

    @Test func unknownRuntimeNameIsAnIssueNeverAFallback() async throws {
        try await isolated {
            var agent = AgentEntry(name: "Researcher")
            agent.runtime = "Nowhere"
            var section = DefaultAgentSection()
            section.runtime = "Also Nowhere"
            var document = OsaurusConfigDocument()
            document.agents = [agent]
            document.defaultAgent = section

            let found = issues(document)
            #expect(found.contains { $0.contains("agents[Researcher].runtime") && $0.contains("Nowhere") })
            #expect(found.contains { $0.contains("default_agent.runtime") })

            // A runtime added by the same document resolves.
            document.harnessRuntimes = [Self.spotlight()]
            agent.runtime = "spotlight"
            document.agents = [agent]
            document.defaultAgent = nil
            #expect(issues(document).isEmpty)
        }
    }

    @Test func configWritesAreDefaultAgentOnly() async throws {
        try await isolated {
            var claudeCode = AgentClaudeCodeEntry()
            claudeCode.allowOsaurusConfigWrites = true
            var agent = AgentEntry(name: "Coder")
            agent.claudeCode = claudeCode
            var document = OsaurusConfigDocument()
            document.agents = [agent]
            #expect(issues(document).contains { $0.contains("agents[Coder].claude_code.allow_osaurus_config_writes") })

            var badMode = AgentClaudeCodeEntry()
            badMode.mode = "chatty"
            var section = DefaultAgentSection()
            section.claudeCode = badMode
            document = OsaurusConfigDocument()
            document.defaultAgent = section
            #expect(issues(document).contains { $0.contains("default_agent.claude_code.mode") })

            var badEffort = AgentClaudeCodeEntry()
            badEffort.effort = "turbo"
            section.claudeCode = badEffort
            document.defaultAgent = section
            #expect(issues(document).contains { $0.contains("default_agent.claude_code.effort") })
        }
    }

    @Test func effortPatchesClearsAndPlans() {
        var config = ClaudeCodeAgentConfig.default
        var entry = AgentClaudeCodeEntry()
        entry.effort = "XHigh"
        #expect(ConfigHarness.changes(entry, current: config, prefix: "claude_code") == ["claude_code.effort: default -> xhigh"])
        ConfigHarness.patch(&config, from: entry)
        #expect(config.resolvedEffort == .xhigh)
        #expect(ConfigHarness.export(config, includeConfigWrites: false).effort == "xhigh")

        entry.effort = "default"
        ConfigHarness.patch(&config, from: entry)
        #expect(config.effort == nil)
        #expect(ConfigHarness.export(config, includeConfigWrites: false).effort == "default")

        entry.effort = "turbo"
        ConfigHarness.patch(&config, from: entry)
        #expect(config.effort == nil, "an unknown value never reaches the agent")
    }

    @Test func planFlagsLaunchCommandsAndHarnessMoves() async throws {
        try await isolated {
            var agent = AgentEntry(name: "Researcher")
            agent.runtime = "Spotlight"
            var claudeCode = AgentClaudeCodeEntry()
            claudeCode.allowShell = true
            claudeCode.allowOsaurusConfigWrites = true
            var section = DefaultAgentSection()
            section.claudeCode = claudeCode
            var document = OsaurusConfigDocument()
            document.harnessRuntimes = [Self.spotlight()]
            document.agents = [agent]
            document.defaultAgent = section

            let plan = try ConfigPlanner.plan(document: document, prune: false)
            let create = plan.actions.first { $0.section == "harness_runtimes" }
            #expect(create?.kind == .create)
            #expect(create?.risks.contains { $0.contains("~/.local/bin/spotlight --mode rpc") } == true)
            let agentAction = plan.actions.first { $0.section == "agents" }
            #expect(agentAction?.risks.contains(ConfigRisk.agentOnHarness("Researcher", "Spotlight")) == true)
            let defaultAction = plan.actions.first { $0.section == "default_agent" }
            #expect(defaultAction?.risks.contains(ConfigRisk.claudeCodeShell("default")) == true)
            #expect(defaultAction?.risks.contains(ConfigRisk.claudeCodeConfigWrites("default")) == true)
        }
    }

    @Test func applyThenExportRoundTripsAndReplansClean() async throws {
        try await isolated {
            var claudeCode = AgentClaudeCodeEntry()
            claudeCode.model = "opus"
            claudeCode.effort = "max"
            claudeCode.allowWrites = true
            var section = DefaultAgentSection()
            section.runtime = "Spotlight"
            section.claudeCode = claudeCode
            var document = OsaurusConfigDocument()
            document.harnessRuntimes = [Self.spotlight()]
            document.defaultAgent = section
            #expect(issues(document).isEmpty)

            let results = await ConfigApplier.apply(document: document, prune: false)
            #expect(results.allSatisfy { $0.status == .done }, "\(results)")

            let runtime = try #require(ConfigHarness.runtime(named: "spotlight"))
            #expect(runtime.kind == .piRPC)
            #expect(runtime.executable == "~/.local/bin/spotlight")
            #expect(runtime.arguments == ["--mode", "rpc", "--session-id", "{chat_id}"])
            #expect(runtime.environment == ["PI_LOG_LEVEL": "info"])
            let stored = DefaultAgentConfigurationStore.load()
            #expect(stored.runtime == .harness(runtime.id))
            #expect(stored.claudeCode?.model == "opus")
            #expect(stored.claudeCode?.allowWrites == true)
            #expect(stored.claudeCode?.resolvedEffort == .max)

            let exported = ConfigExporter.export(sections: [.harnessRuntimes, .defaultAgent])
            #expect(exported.defaultAgent?.runtime == "Spotlight")
            #expect(exported.defaultAgent?.claudeCode?.model == "opus")
            #expect(exported.defaultAgent?.claudeCode?.effort == "max")
            #expect(exported.harnessRuntimes?.first { $0.name == "Spotlight" }?.kind == "pi_rpc")
            let replan = try ConfigPlanner.plan(document: exported, prune: false)
            #expect(replan.actions.isEmpty, "\(replan.actions)")

            // Environment merges; the kind is fixed after create.
            var update = HarnessRuntimeEntry(name: "Spotlight")
            update.environment = ["EXTRA": "1"]
            document = OsaurusConfigDocument()
            document.harnessRuntimes = [update]
            _ = await ConfigApplier.apply(document: document, prune: false)
            #expect(ConfigHarness.runtime(named: "Spotlight")?.environment == ["PI_LOG_LEVEL": "info", "EXTRA": "1"])
            update.kind = "claude_code"
            document.harnessRuntimes = [update]
            #expect(issues(document).contains { $0.contains("immutable") })

            // Back to the built-in loop.
            section = DefaultAgentSection()
            section.runtime = "builtin"
            document = OsaurusConfigDocument()
            document.defaultAgent = section
            _ = await ConfigApplier.apply(document: document, prune: false)
            #expect(DefaultAgentConfigurationStore.load().runtime == nil)
        }
    }

    @Test func createdHarnessAgentIsNotAdvertisedAsSpawnable() async throws {
        try await isolated {
            var agent = AgentEntry(name: "Researcher")
            agent.runtime = "Spotlight"
            var document = OsaurusConfigDocument()
            document.harnessRuntimes = [Self.spotlight()]
            document.agents = [agent]

            let results = await ConfigApplier.apply(document: document, prune: false)
            let created = try #require(results.first { $0.section == "agents" })
            #expect(created.status == .done)
            #expect(created.message?.contains("harness runtime `Spotlight`") == true, "\(created)")
            #expect(created.message?.contains("call `spawn_agent`") == false)
        }
    }

    @Test func pruneRemovesUnlistedRuntimes() async throws {
        try await isolated {
            HarnessRuntimeStore.shared.upsert(HarnessRuntime(name: "Old", kind: .piRPC))
            var document = OsaurusConfigDocument()
            document.harnessRuntimes = [Self.spotlight()]
            let plan = try ConfigPlanner.plan(document: document, prune: true)
            let delete = plan.actions.first { $0.kind == .delete && $0.target == "Old" }
            #expect(delete?.risks == [ConfigRisk.deleteHarnessRuntime("Old")])

            _ = await ConfigApplier.apply(document: document, prune: true)
            #expect(HarnessRuntimeStore.shared.all().map(\.displayName) == ["Spotlight"])

            // An agent in a pruning document can't keep naming a pruned runtime.
            var agent = AgentEntry(name: "Researcher")
            agent.runtime = "Old"
            document.agents = [agent]
            #expect(issues(document, prune: true).contains { $0.contains("agents[Researcher].runtime") })
        }
    }

    @Test func templateDraftNotesAnUnknownRuntime() async throws {
        try await isolated {
            var entry = AgentEntry(name: "Imported")
            entry.runtime = "Spotlight"
            let (agent, outcome) = ConfigApplier.draftAgent(from: entry)
            #expect(agent.runtime == nil)
            #expect(outcome.notes.contains { $0.contains("`Spotlight` is not registered") })

            HarnessRuntimeStore.shared.upsert(HarnessRuntime(name: "Spotlight", kind: .piRPC))
            let (resolved, _) = ConfigApplier.draftAgent(from: entry)
            #expect(resolved.runtime == ConfigHarness.resolve("Spotlight"))
        }
    }
}

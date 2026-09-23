//
//  AppleAppsDeclarativeConfigTests.swift
//  OsaurusCoreTests — AppleApps
//
//  The Orchestrator's control surface for Apple apps is
//  `agents[].capabilities.apple_apps` through `osaurus_config`. Pins:
//  manifest advertises the key, YAML decodes it, unknown names fail
//  validation with the allowed list, the plan renders enable/disable rows,
//  apply writes `enabledAppleApps` on an existing agent and on a freshly
//  provisioned one, `[]` disables all, export round-trips, and
//  `osaurus_inspect`'s agent payload reports the field.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct AppleAppsDeclarativeConfigTests {

    /// Seed a custom agent under the canonical locks (`AgentManager.shared`
    /// reads `OsaurusPaths.overrideRoot`; `create` auto-adds to the Default
    /// spawn pool), run `body`, and delete it afterwards.
    private func withSeededAgent(_ body: @MainActor @Sendable (Agent) async throws -> Void) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let agent = AgentManager.shared.create(
                name: "Apple Config Probe \(UUID().uuidString.prefix(6))",
                description: "", systemPrompt: "")
            do {
                try await body(agent)
            } catch {
                _ = await AgentManager.shared.delete(id: agent.id)
                throw error
            }
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    private func current(_ id: UUID) -> Agent? {
        AgentManager.shared.agents.first { $0.id == id }
    }

    @Test("the manifest advertises capabilities.apple_apps and the schema reference names it")
    func manifestAdvertisesKey() {
        #expect(ConfigManifest.knownKeys["agents[].capabilities"]?.contains("apple_apps") == true)
        let rendered = ConfigManifest.renderedSchemaSections(only: [.agents])
        #expect(rendered.contains("apple_apps"))
        #expect(rendered.contains("calendar"))
        #expect(rendered.contains("shortcuts"))
    }

    @Test("YAML decodes apple_apps into AgentCapabilitiesEntry")
    func yamlDecodes() throws {
        let document = try ConfigYAML.decode(
            """
            agents:
              - name: Planner
                capabilities:
                  apple_apps: [calendar, reminders]
            """)
        #expect(document.agents?.first?.capabilities?.appleApps == ["calendar", "reminders"])
    }

    @Test("unknown app names fail validation and list the allowed names")
    func invalidNameRejected() async throws {
        try await withSeededAgent { agent in
            var entry = AgentEntry(name: agent.name)
            var caps = AgentCapabilitiesEntry()
            caps.appleApps = ["calendar", "safari"]
            entry.capabilities = caps
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            do {
                _ = try ConfigPlanner.plan(document: document, prune: false)
                Issue.record("expected validation failure for `safari`")
            } catch let issues as ConfigPlanIssues {
                let joined = issues.issues.joined(separator: "\n")
                #expect(joined.contains("safari"))
                #expect(joined.contains("apple_apps"))
                for app in AppleApp.allCases { #expect(joined.contains(app.rawValue), "allowed list should mention \(app.rawValue)") }
            }
        }
    }

    @Test("enabling Mail / Messages / Shortcuts carries a ConfigRisk; organiser apps do not")
    func appleAppRisks() async throws {
        try await withSeededAgent { agent in
            @MainActor func plan(_ apps: [String]) throws -> ConfigPlanAction? {
                var entry = AgentEntry(name: agent.name)
                var caps = AgentCapabilitiesEntry()
                caps.appleApps = apps
                entry.capabilities = caps
                var document = OsaurusConfigDocument()
                document.agents = [entry]
                return try ConfigPlanner.plan(document: document, prune: false).actions
                    .first { $0.section == "agents" && $0.target == agent.name }
            }
            let risky = try #require(try plan(["mail", "messages", "shortcuts", "calendar"]))
            #expect(risky.risks.count == 3, "\(risky.risks)")
            #expect(risky.risks.contains { $0.contains("Mail") && $0.contains("send") })
            #expect(risky.risks.contains { $0.contains("Messages") })
            #expect(risky.risks.contains { $0.contains("Shortcuts") })
            #expect(!risky.risks.contains { $0.contains("Calendar") })

            let safe = try #require(try plan(["calendar", "reminders", "contacts"]))
            #expect(safe.risks.isEmpty, "\(safe.risks)")

            // Already-enabled risky apps are not re-flagged.
            var updated = try #require(current(agent.id))
            updated.settings.enabledAppleApps = [.mail]
            AgentManager.shared.update(updated)
            let unchanged = try #require(try plan(["mail", "notes"]))
            #expect(unchanged.risks.isEmpty, "\(unchanged.risks)")

            // Creating an agent with a risky app flags it too.
            var created = AgentEntry(name: "Risk Probe \(UUID().uuidString.prefix(6))")
            var caps = AgentCapabilitiesEntry()
            caps.appleApps = ["messages"]
            created.capabilities = caps
            var document = OsaurusConfigDocument()
            document.agents = [created]
            let createPlan = try ConfigPlanner.plan(document: document, prune: false)
            let createAction = createPlan.actions.first { $0.section == "agents" && $0.target == created.name }
            #expect(createAction?.kind == .create)
            #expect(createAction?.risks.contains { $0.contains("Messages") } == true)
        }
    }

    @Test("plan renders enable/disable rows; identical sets plan no change")
    func planDiff() async throws {
        try await withSeededAgent { agent in
            @MainActor func plan(_ apps: [String]) throws -> ConfigPlan {
                var entry = AgentEntry(name: agent.name)
                var caps = AgentCapabilitiesEntry()
                caps.appleApps = apps
                entry.capabilities = caps
                var document = OsaurusConfigDocument()
                document.agents = [entry]
                return try ConfigPlanner.plan(document: document, prune: false)
            }
            // add
            let add = try plan(["calendar", "mail"])
            let addAction = add.actions.first { $0.section == "agents" && $0.target == agent.name }
            #expect(addAction?.kind == .update)
            #expect(addAction?.changes.contains { $0.contains("apple_apps") && $0.contains("enable") && $0.contains("Calendar") && $0.contains("Mail") } == true, "\(String(describing: addAction?.changes))")

            // Apply so the next plans diff against a non-empty set.
            var updated = try #require(current(agent.id))
            updated.settings.enabledAppleApps = [.calendar, .mail]
            AgentManager.shared.update(updated)

            // same set → no agents action
            let same = try plan(["mail", "calendar"])
            #expect(!same.actions.contains { $0.section == "agents" && $0.target == agent.name }, "\(same.actions)")

            // replace (remove mail, add notes)
            let replace = try plan(["calendar", "notes"])
            let replaceAction = replace.actions.first { $0.section == "agents" && $0.target == agent.name }
            #expect(replaceAction?.changes.contains { $0.contains("enable") && $0.contains("Notes") } == true)
            #expect(replaceAction?.changes.contains { $0.contains("disable") && $0.contains("Mail") } == true)

            // [] disables all
            let clear = try plan([])
            let clearAction = clear.actions.first { $0.section == "agents" && $0.target == agent.name }
            #expect(clearAction?.changes.contains { $0.contains("disable") && $0.contains("Calendar") && $0.contains("Mail") } == true)

            // absent key → untouched
            var entry = AgentEntry(name: agent.name)
            entry.capabilities = AgentCapabilitiesEntry()
            var document = OsaurusConfigDocument()
            document.agents = [entry]
            let absent = try ConfigPlanner.plan(document: document, prune: false)
            #expect(!absent.actions.contains { $0.section == "agents" && $0.target == agent.name && $0.changes.contains { $0.contains("apple_apps") } })
        }
    }

    @Test("apply writes enabledAppleApps on an existing agent; [] clears; absent leaves it alone")
    func applyToExistingAgent() async throws {
        try await withSeededAgent { agent in
            func apply(_ apps: [String]?) async {
                var entry = AgentEntry(name: agent.name)
                var caps = AgentCapabilitiesEntry()
                caps.appleApps = apps
                entry.capabilities = caps
                var document = OsaurusConfigDocument()
                document.agents = [entry]
                let results = await ConfigApplier.apply(document: document, prune: false)
                #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
            }
            await apply(["reminders", "Contacts"])
            #expect(current(agent.id)?.settings.enabledAppleApps == [.reminders, .contacts])
            await apply(nil)
            #expect(current(agent.id)?.settings.enabledAppleApps == [.reminders, .contacts], "absent key must not clear")
            await apply([])
            #expect(current(agent.id)?.settings.enabledAppleApps == [])
        }
    }

    @Test("a new agent can be provisioned with apple_apps in one call")
    func createWithAppleApps() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            try await createWithAppleAppsBody()
        }
    }

    private func createWithAppleAppsBody() async throws {
        let name = "Apple Create Probe \(UUID().uuidString.prefix(6))"
        var entry = AgentEntry(name: name)
        var caps = AgentCapabilitiesEntry()
        caps.appleApps = ["mail", "calendar"]
        entry.capabilities = caps
        var document = OsaurusConfigDocument()
        document.agents = [entry]

        let plan = try ConfigPlanner.plan(document: document, prune: false)
        let create = plan.actions.first { $0.section == "agents" && $0.target == name }
        #expect(create?.kind == .create)
        #expect(create?.changes.contains { $0.contains("apple_apps") && $0.contains("Calendar") } == true)

        let results = await ConfigApplier.apply(document: document, prune: false)
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
        guard let created = AgentManager.shared.agents.first(where: { $0.name == name }) else {
            Issue.record("agent `\(name)` was not created")
            return
        }
        #expect(created.settings.enabledAppleApps == [.mail, .calendar])
        #expect(AgentManager.shared.effectiveCapabilities(for: created.id).enabledAppleApps == [.mail, .calendar])
        _ = await AgentManager.shared.delete(id: created.id)
    }

    @Test("export round-trips the set in allCases order and the inspect payload reports it")
    func exportAndInspect() async throws {
        try await withSeededAgent { agent in
            var updated = try #require(current(agent.id))
            updated.settings.enabledAppleApps = [.shortcuts, .calendar, .music]
            AgentManager.shared.update(updated)

            let exported = ConfigExporter.export(sections: [.agents])
            let entry = exported.agents?.first { $0.name == agent.name }
            #expect(entry?.capabilities?.appleApps == ["calendar", "music", "shortcuts"])

            // Re-planning the export must be a no-op for this agent.
            let plan = try ConfigPlanner.plan(document: exported, prune: false)
            #expect(!plan.actions.contains { $0.section == "agents" && $0.target == agent.name }, "\(plan.actions)")

            let payload = AgentCapabilitiesPayload.payload(for: try #require(current(agent.id)))
            #expect(payload["apple_apps"] as? [String] == ["calendar", "music", "shortcuts"])
        }
    }

    @Test("the Default agent entry never exports or accepts apple_apps")
    func defaultAgentHasNoAppleApps() async {
        await SandboxTestLock.runWithStoragePaths {
            let exported = ConfigExporter.export(sections: [.defaultAgent, .agents])
            // The Default agent is not in `agents[]`; its own section has no capabilities.apple_apps key.
            #expect(ConfigManifest.knownKeys["default_agent"]?.contains("apple_apps") != true)
            #expect(exported.agents?.contains { $0.name == "Default" && $0.capabilities?.appleApps?.isEmpty == false } != true)
        }
    }
}

@Suite("AgentSettings.enabledAppleApps codable")
struct AppleAppsSettingsCodableTests {

    @Test("round-trips, encodes in stable order, and defaults to empty when absent")
    func roundTrip() throws {
        var settings = AgentSettings.defaultDisabled
        settings.enabledAppleApps = [.music, .calendar]
        let data = try JSONEncoder().encode(settings)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["enabledAppleApps"] as? [String] == ["calendar", "music"])
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(decoded.enabledAppleApps == [.music, .calendar])

        // Legacy payload without the key.
        var legacy = json
        legacy.removeValue(forKey: "enabledAppleApps")
        let old = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.enabledAppleApps.isEmpty)

        // Unknown future names are dropped rather than failing the decode.
        var future = json
        future["enabledAppleApps"] = ["calendar", "vision_pro"]
        let tolerant = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: future))
        #expect(tolerant.enabledAppleApps == [.calendar])

        // The removed Weather app: agents persisted before its removal still load.
        var removed = json
        removed["enabledAppleApps"] = ["calendar", "weather"]
        let afterRemoval = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: removed))
        #expect(afterRemoval.enabledAppleApps == [.calendar])
        #expect(AppleApp(rawValue: "weather") == nil)
        #expect(AppleApp.allCases.count == 9)
    }

    @Test("an Agent with enabled apps survives a full encode/decode")
    func agentRoundTrip() throws {
        var agent = Agent(name: "Codable Probe", agentAddress: "codable-probe")
        agent.settings.enabledAppleApps = [.messages]
        let decoded = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        #expect(decoded.settings.enabledAppleApps == [.messages])
    }
}

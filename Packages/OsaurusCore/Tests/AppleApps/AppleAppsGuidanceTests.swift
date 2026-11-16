//
//  AppleAppsGuidanceTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Guidance / UX contracts around the Apple app tools: the prompt block
//  names every tool prefix (including `location_*`), sends are per-call
//  approvals, spawned children inherit the app families, the Tools catalog
//  groups per app, and settings-search landings resolve to a custom agent.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Apple tools: guidance and UX contracts")
struct AppleAppsGuidanceTests {

    @Test("guidance prefixes come from the tool names so Maps renders location_* and maps_*")
    func guidancePrefixes() {
        let prefixes = SystemPromptTemplates.appleToolPrefixes(for: [.maps])
        #expect(prefixes.contains("location"))
        #expect(prefixes.contains("maps"))
        let text = SystemPromptTemplates.appleAppsGuidance(apps: [.maps, .calendar])
        #expect(text.contains("`location_*`"))
        #expect(text.contains("`maps_*`"))
        #expect(text.contains("`calendar_*`"))
        // No stale promise that every send merely "pauses".
        #expect(!text.contains("sending or deleting always does"))
        #expect(text.contains("cannot be pre-approved"))
    }

    @Test("messages_send is per-call; mail_compose / mail_reply are per-call only when send is true")
    @MainActor
    func sendToolsArePerCall() {
        let tools = AppleAppToolCatalog.makeTools()
        let send = tools.first { $0.name == "messages_send" }
        #expect((send as? PerCallApprovalTool)?.requiresApprovalEveryCall == true)

        let compose = tools.first { $0.name == "mail_compose" } as? ArgumentAwarePerCallApprovalTool
        let reply = tools.first { $0.name == "mail_reply" } as? ArgumentAwarePerCallApprovalTool
        #expect(compose != nil)
        #expect(reply != nil)
        #expect(compose?.requiresApprovalEveryCall(argumentsJSON: #"{"to":["a@b.c"],"subject":"s","body":"b","send":true}"#) == true)
        #expect(compose?.requiresApprovalEveryCall(argumentsJSON: #"{"to":["a@b.c"],"subject":"s","body":"b"}"#) == false)
        #expect(compose?.requiresApprovalEveryCall(argumentsJSON: #"{"send":false}"#) == false)
        #expect(compose?.requiresApprovalEveryCall(argumentsJSON: "not json") == false)
        #expect(reply?.requiresApprovalEveryCall(argumentsJSON: #"{"id":"1","body":"x","send":"true"}"#) == true)
        #expect(reply?.requiresApprovalEveryCall(argumentsJSON: #"{"id":"1","body":"x"}"#) == false)

        // Reads never ask per call.
        #expect(!(tools.first { $0.name == "mail_list" } is PerCallApprovalTool))
        #expect(!(tools.first { $0.name == "mail_list" } is ArgumentAwarePerCallApprovalTool))
    }

    @Test("spawned children inherit the enabled Apple app families; AppleToolBase is spawn-exposable and grouped per app")
    @MainActor
    func spawnParityAndGrouping() {
        var caps = AgentCapabilities(
            toolsEnabled: true, memoryEnabled: false, dbEnabled: false, renderChartEnabled: false,
            speakEnabled: false, searchMemoryEnabled: false, webSearchEnabled: false,
            selfSchedulingEnabled: false, knowledgeEnabled: false, knowledgeCuratorEnabled: false
        )
        #expect(!TextSubagentKind.autoChildToolNames(capabilities: caps).contains("mail_list"))
        caps.enabledAppleApps = [.mail, .maps]
        let names = Set(TextSubagentKind.autoChildToolNames(capabilities: caps))
        #expect(names.isSuperset(of: AppleApp.mail.toolNames))
        #expect(names.isSuperset(of: AppleApp.maps.toolNames))
        #expect(!names.contains("calendar_events"))

        for tool in AppleAppToolCatalog.makeTools() {
            #expect(tool.canExposeToSpawnedOperation)
            let grouped = tool as? any CapabilityToolGroupDeclaring
            let app = AppleApp.app(forTool: tool.name)
            #expect(grouped?.capabilityGroupId == "apple:\(app?.rawValue ?? "?")", "\(tool.name)")
        }
    }

    @Test("settings-search landing picks the open custom agent, else the first custom agent, never the Default agent")
    @MainActor
    func landingAgent() {
        let custom1 = Agent(name: "A", agentAddress: "a")
        let custom2 = Agent(name: "B", agentAddress: "b")
        let builtIn = Agent(id: Agent.defaultId, name: "Default", isBuiltIn: true, agentAddress: "default")
        #expect(builtIn.isBuiltIn)
        let all = [builtIn, custom1, custom2]
        #expect(AgentsView.appleAppsLandingAgent(open: nil, all: all)?.id == custom1.id)
        #expect(AgentsView.appleAppsLandingAgent(open: custom2, all: all)?.id == custom2.id)
        #expect(AgentsView.appleAppsLandingAgent(open: builtIn, all: all)?.id == custom1.id)
        #expect(AgentsView.appleAppsLandingAgent(open: nil, all: [builtIn]) == nil)
        #expect(AgentDetailTabRoute.resolve(AgentsView.appleAppsLandingTabRaw) != nil)
        for entry in SettingsSearchIndex.appleAppEntries {
            #expect(entry.subTab == AgentsView.appleAppsLandingTabRaw)
        }
    }

    @Test("the badge tap opens Full Disk Access first, then the first still-missing grant")
    @MainActor
    func badgeSettingsTarget() {
        #expect(AgentCapabilityManagerView.settingsTarget(forStillMissing: [.automationMessages, .disk]) == .disk)
        #expect(AgentCapabilityManagerView.settingsTarget(forStillMissing: [.automationMail]) == .automationMail)
        #expect(AgentCapabilityManagerView.settingsTarget(forStillMissing: []) == nil)
    }
}

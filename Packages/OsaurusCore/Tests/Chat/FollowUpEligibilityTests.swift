import Foundation
import Testing

@testable import OsaurusCore

@Suite("follow-up suggestion eligibility")
struct FollowUpEligibilityTests {
    private func eligible(
        settingEnabled: Bool = true,
        agentEnabled: Bool = true,
        isChatSource: Bool = true,
        runCompletedCleanly: Bool = true,
        waitingOnUser: Bool = false,
        isAgentDraft: Bool = false
    ) -> Bool {
        ChatSession.followUpsEligible(
            settingEnabled: settingEnabled,
            agentEnabled: agentEnabled,
            isChatSource: isChatSource,
            runCompletedCleanly: runCompletedCleanly,
            waitingOnUser: waitingOnUser,
            isAgentDraft: isAgentDraft
        )
    }

    @Test("a clean chat turn with every switch on offers follow-ups")
    func cleanTurnIsEligible() {
        #expect(eligible())
    }

    @Test("each blocking condition alone suppresses follow-ups")
    func eachConditionBlocks() {
        #expect(!eligible(settingEnabled: false))
        #expect(!eligible(agentEnabled: false))
        #expect(!eligible(isChatSource: false))
        #expect(!eligible(runCompletedCleanly: false))
        #expect(!eligible(waitingOnUser: true))
        #expect(!eligible(isAgentDraft: true))
    }

    @Test("the Architect never offers follow-ups; the Orchestrator follows the global switch")
    func builtInDefaults() {
        #expect(Agent.architect.settings.followUp.enabled == false)
        #expect(Agent.default.settings.followUp.enabled == true)
        #expect(AgentSettings.defaultDisabled.followUp.enabled == true)
    }

    @Test("agents saved before the switch keep follow-ups on; explicit Off round-trips")
    func agentSettingBackCompatAndRoundTrip() throws {
        let legacySettings = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(legacySettings.followUp.enabled)
        let legacyConfig = try JSONDecoder().decode(
            AgentFollowUpConfig.self, from: Data(#"{"model":"small-model"}"#.utf8))
        #expect(legacyConfig.enabled)
        #expect(legacyConfig.model == "small-model")

        var settings = AgentSettings.defaultDisabled
        settings.followUp = AgentFollowUpConfig(enabled: false, model: "small-model")
        let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.followUp == AgentFollowUpConfig(enabled: false, model: "small-model"))
    }

    @Test("follow_up_suggestions survives the strict schema, JSON round-trip and template overrides")
    func declarativeKeyRoundTrips() throws {
        let doc = try ConfigYAML.decode("agents:\n  - name: Quiet\n    follow_up_suggestions: false\n")
        let entry = try #require(doc.agents?.first)
        #expect(entry.followUpSuggestions == false)
        let restored = try ConfigYAML.decode(ConfigJSON.encode(doc))
        #expect(restored.agents?.first?.followUpSuggestions == false)

        let template = AgentTemplate(name: "Quiet", agent: entry)
        #expect(template.document(overrides: AgentEntry(name: "Quiet")).agents?.first?.followUpSuggestions == false)
        var on = AgentEntry(name: "Quiet")
        on.followUpSuggestions = true
        #expect(template.document(overrides: on).agents?.first?.followUpSuggestions == true)
    }
}

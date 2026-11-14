import Testing

@testable import OsaurusCore

struct AgentAdvancedSettingsLandingTests {
    @Test func advancedSettingsOpenTheAgentEditor() {
        for anchor in ["agents.showResponseMetrics", "agents.generation.temperature", "agents.generation.templateKwargs"] {
            #expect(AgentAdvancedSettingsLanding.matches(anchor))
        }
        for anchor: String? in [nil, "", "agents.configure", "agents.templates", "settings.chat.topP", "agents.appleApps"] {
            #expect(!AgentAdvancedSettingsLanding.matches(anchor))
        }
    }
}

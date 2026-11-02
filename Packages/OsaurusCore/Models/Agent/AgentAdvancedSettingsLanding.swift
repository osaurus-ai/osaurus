/// Shared by the Agents grid router and the editor disclosure.
/// A new Advanced setting must reach the editor before its anchor can scroll/glow.
enum AgentAdvancedSettingsLanding {
    static func matches(_ anchor: String?) -> Bool {
        guard let anchor else { return false }
        return anchor.hasPrefix("agents.generation.") || anchor == "agents.showResponseMetrics"
    }
}

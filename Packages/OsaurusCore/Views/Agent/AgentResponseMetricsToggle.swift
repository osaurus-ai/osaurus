import SwiftUI

/// Per-custom-agent display preference. It never changes generation.
/// A row of the Advanced Settings group; the group draws the surface.
struct AgentResponseMetricsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        SettingsToggle(
            title: "Show Response Metrics",
            description: "Show token count, tokens per second and timing under each response. Inspect response always has them.",
            anchorId: "agents.showResponseMetrics",
            isOn: $isOn
        )
        .accessibilityIdentifier("agent.showResponseMetrics")
    }
}

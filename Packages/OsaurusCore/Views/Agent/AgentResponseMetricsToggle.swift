import SwiftUI

/// Per-custom-agent display preference. It never changes generation.
struct AgentResponseMetricsToggle: View {
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsToggle(
            title: "Show Response Metrics",
            description:
                "Show measured token count, tokens per second and timings below responses. Metrics remain available in Inspect response.",
            anchorId: "agents.showResponseMetrics",
            isOn: $isOn
        )
        .accessibilityIdentifier("agent.showResponseMetrics")
        .padding(.horizontal, theme.space.s12)
        .settingsChrome(.surface)
    }
}

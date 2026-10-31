import SwiftUI

/// Presentation preference; never changes generation or recorded usage.
struct AgentResponseMetricsToggle: View {
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L("Show Response Metrics"), isOn: $isOn)
                .toggleStyle(.switch)
                .accessibilityIdentifier("agent.showResponseMetrics")
                .settingsLandingAnchor("agents.showResponseMetrics")
            Text(L("Show measured token count, tokens per second and timings below responses. Metrics remain available in Inspect response."))
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}

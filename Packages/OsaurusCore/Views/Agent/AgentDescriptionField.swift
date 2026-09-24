import SwiftUI

/// Shared creation/repair editor. Never truncates or invents routing metadata.
struct AgentDescriptionField: View {
    @Binding var text: String

    private var violation: AgentDescriptionPolicy.Violation? {
        AgentDescriptionPolicy.violation(in: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent description (required)", bundle: .module)
                .font(.caption.weight(.semibold))
            StyledTextField(
                placeholder: L("What does this agent do, and when should it be used?"),
                text: $text,
                icon: "text.alignleft"
            )
            .accessibilityLabel(Text("Agent description (required)", bundle: .module))
            .accessibilityIdentifier("agent.description")
            Text("\(AgentDescriptionPolicy.normalized(text).count)/160 characters · up to 1,024 UTF-8 bytes", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let violation {
                Text(LocalizedStringKey(violation.message), bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .settingsLandingAnchor("agents.description")
    }
}

/// Persistent, nonmodal upgrade notice. Observes saved records so repairing
/// one agent immediately updates every open chat without losing chat state.
struct AgentDescriptionRepairNotice: View {
    @ObservedObject private var manager = AgentManager.shared

    var body: some View {
        let incomplete = manager.agents.filter { !$0.isBuiltIn && $0.requiresDescriptionRepair }
        if !incomplete.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                Text("Agent descriptions required", bundle: .module)
                    .font(.caption)
                Spacer(minLength: 8)
                Menu {
                    ForEach(incomplete) { agent in
                        Button(agent.name) {
                            AppDelegate.shared?.showAgentDetail(agentId: agent.id, tab: "configure")
                        }
                    }
                } label: {
                    Text("Add descriptions (\(incomplete.count))", bundle: .module)
                }
                .accessibilityIdentifier("agent.descriptionRepair")
            }
            .padding(10)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .help(L("These agents keep their chats and settings, but cannot receive delegated tasks until you add descriptions."))
        }
    }
}

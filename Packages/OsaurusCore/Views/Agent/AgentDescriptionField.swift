import SwiftUI

/// Shared creation/repair editor. Suggestions require explicit review before applying.
struct AgentDescriptionField: View {
    @Binding var text: String
    var systemPrompt: String = ""
    var generatesOnCreate: Bool = false

    @State private var suggestion: String?
    @State private var suggestionError: String?
    @State private var suggestionTask: Task<Void, Never>?
    @State private var requestID: UUID?

    private func cancelSuggestion() {
        requestID = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestion = nil
    }

    private func suggest() {
        cancelSuggestion()
        suggestionError = nil
        let prompt = systemPrompt
        let original = text
        let id = UUID()
        requestID = id
        suggestionTask = Task { @MainActor in
            do {
                let result = try await AgentDescriptionGenerator.resolve(
                    description: "", systemPrompt: prompt)
                try Task.checkCancellation()
                guard requestID == id, systemPrompt == prompt, text == original else { return }
                suggestion = try AgentDescriptionPolicy.validated(result)
            } catch is CancellationError {
                // Cancellation leaves the user's draft untouched.
            } catch {
                guard requestID == id else { return }
                if let violation = error as? AgentDescriptionPolicy.Violation {
                    suggestionError = violation.message
                } else {
                    suggestionError = L("Could not suggest a description. Try again or enter one manually.")
                }
            }
            if requestID == id {
                requestID = nil
                suggestionTask = nil
            }
        }
    }

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
            if !AgentDescriptionPolicy.normalized(systemPrompt).isEmpty,
                AgentDescriptionPolicy.normalized(text).isEmpty
            {
                if suggestionTask != nil {
                    Button(action: { cancelSuggestion() }) { Text("Cancel suggestion", bundle: .module) }
                } else {
                    Button(action: { suggest() }) { Text("Suggest from system prompt", bundle: .module) }
                        .accessibilityIdentifier("agent.descriptionSuggest")
                }
            }
            if let suggestion {
                Text(suggestion).font(.caption)
                Button(action: {
                    text = suggestion
                    cancelSuggestion()
                }) { Text("Use suggested description", bundle: .module) }
                .accessibilityIdentifier("agent.descriptionUseSuggestion")
            }
            if let suggestionError {
                Text(suggestionError).font(.caption).foregroundStyle(.red)
            }
            if generatesOnCreate, violation == .required,
                !AgentDescriptionPolicy.normalized(systemPrompt).isEmpty
            {
                Text("Leave blank to generate a description from the system prompt when creating this agent.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let violation {
                Text(LocalizedStringKey(violation.message), bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: systemPrompt) {
            cancelSuggestion()
            suggestionError = nil
        }
        .onChange(of: text) {
            cancelSuggestion()
            suggestionError = nil
        }
        .onDisappear { cancelSuggestion() }
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

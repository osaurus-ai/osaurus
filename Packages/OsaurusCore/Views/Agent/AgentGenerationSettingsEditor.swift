import SwiftUI

/// Custom-agent settings only. Editing never writes the shared per-model option store.
struct AgentGenerationSettingsEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.settingsLandingPending) private var pendingLanding
    let modelID: String?
    let modelIsLocal: Bool
    let catalogCapabilities: ModelReasoningCapabilities?
    let savedTemperature: Float?
    let savedMaxTokens: Int?
    let savedSettings: AgentGenerationSettings?
    let onSave: (AgentGenerationDraft.Values) -> Void
    var showsSaveButton = true
    var onDraftChange: ((AgentGenerationDraft) -> Void)? = nil
    var onReasoningChoicesChange: ((AgentGenerationReasoningChoices?) -> Void)? = nil
    var initialDraft: AgentGenerationDraft? = nil

    @State private var draft = AgentGenerationDraft()
    @State private var choices: AgentGenerationReasoningChoices?
    @State private var error: String?
    @State private var capabilityRevision = 0
    @State private var showMoreSampling = false
    @State private var showTemplateParameters = false

    private struct CapabilityKey: Hashable {
        let modelID: String?
        let isLocal: Bool
        let catalog: ModelReasoningCapabilities?
        let revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inherit keeps the existing model and server defaults. Custom values are saved only for this agent.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                parameter("Temperature", value: $draft.temperature, anchor: "agents.generation.temperature")
                parameter("Max Tokens", value: $draft.maxTokens, anchor: "agents.generation.maxTokens")
                parameter("Top P", value: $draft.topP, anchor: "agents.generation.topP")
                parameter("Top K", value: $draft.topK, anchor: "agents.generation.topK")
            }

            reasoningControls

            DisclosureGroup(L("More sampling parameters"), isExpanded: $showMoreSampling) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    parameter("Min P", value: $draft.minP, anchor: "agents.generation.minP")
                    parameter("Repetition penalty", value: $draft.repetitionPenalty, anchor: "agents.generation.repetitionPenalty")
                    parameter("Frequency penalty", value: $draft.frequencyPenalty, anchor: "agents.generation.frequencyPenalty")
                    parameter("Presence penalty", value: $draft.presencePenalty, anchor: "agents.generation.presencePenalty")
                    parameter("Seed", value: $draft.seed, anchor: "agents.generation.seed")
                }
                .padding(.top, 10)
                parameter("Stop sequences (JSON array)", value: $draft.stop, anchor: "agents.generation.stop",
                    multiline: true, inheritedJSON: "[]")
                    .padding(.top, 10)
                Text("An array of additional stop strings, for example [\"END\"]. Inherit adds none ([]); the model's end-of-turn tokens still apply.", bundle: .module)
                    .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }

            DisclosureGroup(L("Template parameters (JSON)"), isExpanded: $showTemplateParameters) {
                parameter("Template parameters (JSON)", value: $draft.templateKwargs,
                    anchor: "agents.generation.templateKwargs", multiline: true, inheritedJSON: "{}")
                    .padding(.top, 10)
                Text("A JSON object of additional parameters, not the chat template itself. Inherit adds none ({}); the model's template defaults still apply. Conversation, tools and special-token variables cannot be replaced.", bundle: .module)
                    .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Reset to inherited")) {
                    draft = AgentGenerationDraft()
                    save()
                }
                .buttonStyle(.borderless)
                if showsSaveButton {
                    Spacer()
                    Button(L("Save generation defaults"), action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled((choices == nil || choices?.modelID != modelID)
                            && (draft.reasoningEffort != "" || draft.thinking != "inherit"))
                }
            }
        }
        .onAppear { restore(); expandForLanding(pendingLanding) }
        .onChange(of: pendingLanding) { _, value in expandForLanding(value) }
        .onChange(of: draft) { _, value in
            onDraftChange?(value)
            if !showsSaveButton {
                do { _ = try value.validated(); error = nil }
                catch { self.error = error.localizedDescription }
            }
        }
        .onChange(of: choices) { _, value in onReasoningChoicesChange?(value) }
        .task(id: CapabilityKey(modelID: modelID, isLocal: modelIsLocal, catalog: catalogCapabilities, revision: capabilityRevision)) {
            choices = nil
            guard let modelID else { return }
            var resolved = await AgentGenerationReasoningChoices.resolve(modelID: modelID, isLocal: modelIsLocal)
            guard !Task.isCancelled else { return }
            if let catalogCapabilities { resolved.efforts = catalogCapabilities }
            choices = resolved
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            capabilityRevision += 1
        }
    }

    @ViewBuilder
    private var reasoningControls: some View {
        if modelID == nil {
            Text("Choose a model to detect its reasoning controls.", bundle: .module)
                .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
        } else if let choices, choices.modelID == modelID {
            if let capabilities = choices.efforts, !capabilities.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reasoning effort", bundle: .module)
                        .font(.system(size: 11, weight: .medium)).foregroundColor(theme.secondaryText)
                    Picker(L("Reasoning effort"), selection: $draft.reasoningEffort) {
                        Text(localized: "Inherit").tag("")
                        ForEach(capabilities.levels) { level in
                            Text(ModelReasoningCapabilities.displayLabel(forEffort: level.id)).tag(level.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsLandingAnchor("agents.generation.reasoningEffort")
                    if !draft.reasoningEffort.isEmpty,
                        !capabilities.levels.contains(where: { $0.id == draft.reasoningEffort })
                    {
                        unsupportedReasoning
                    }
                }
            } else if !draft.reasoningEffort.isEmpty {
                unsupportedReasoning
            }
            if choices.showsThinkingControl {
                Picker(L("Thinking"), selection: $draft.thinking) {
                    Text(localized: "Inherit").tag("inherit")
                    Text(localized: "On").tag("on")
                    Text(localized: "Off").tag("off")
                }
                .settingsLandingAnchor("agents.generation.thinking")
            } else if draft.thinking != "inherit" {
                if choices.supportsThinking {
                    HStack {
                        Text(localized: "Thinking")
                        Text(draft.thinking == "on" ? L("On") : L("Off"))
                        Spacer()
                        Button(L("Use Inherit")) { draft.thinking = "inherit" }.buttonStyle(.borderless)
                    }
                } else { unsupportedReasoning }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Detecting model reasoning controls…", bundle: .module)
                    .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }
        }
    }

    private var unsupportedReasoning: some View {
        HStack {
            Text("Saved reasoning choices are not supported by the selected model.", bundle: .module)
                .font(.system(size: 11)).foregroundColor(.orange)
            Button(L("Use Inherit")) {
                draft.reasoningEffort = ""
                draft.thinking = "inherit"
            }.buttonStyle(.borderless)
        }
    }

    private func parameter(_ title: String, value: Binding<AgentGenerationFieldDraft>, anchor: String,
        multiline: Bool = false, inheritedJSON: String? = nil) -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(theme.secondaryText)
                Spacer(minLength: 4)
                Toggle(L("Custom"), isOn: Binding(
                    get: { value.wrappedValue.isCustom },
                    set: { value.wrappedValue.setCustom($0, inheritedText: inheritedJSON) }
                )).toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            if value.wrappedValue.isCustom {
                StyledTextField(placeholder: multiline ? "JSON" : L("Value"), text: value.text,
                    axis: multiline ? .vertical : .horizontal, lineLimit: multiline ? 6 : nil,
                    monospaced: multiline)
            } else {
                Text(localized: "Inherit").font(.system(size: 12)).foregroundColor(theme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
        }
        .settingsLandingAnchor(anchor)
    }

    private func restore() {
        draft = initialDraft ?? AgentGenerationDraft(
            temperature: savedTemperature, maxTokens: savedMaxTokens, settings: savedSettings)
        error = nil
    }

    private func expandForLanding(_ id: String?) {
        guard let id else { return }
        if id == "agents.generation.templateKwargs" { showTemplateParameters = true }
        if ["minP", "repetitionPenalty", "frequencyPenalty", "presencePenalty", "seed", "stop"]
            .contains(where: { id == "agents.generation.\($0)" })
        {
            showMoreSampling = true
        }
    }

    private func save() {
        do {
            let values = try draft.validated()
            if let settings = values.settings {
                if settings.reasoningEffort != nil || settings.enableThinking != nil {
                    guard let choices, choices.modelID == modelID else {
                        throw ChatTurnOverrides.ValidationError.invalid("Choose a model and wait for its reasoning controls to be detected.")
                    }
                    try choices.validate(settings: settings)
                }
            }
            onSave(values)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

import SwiftUI
@preconcurrency import MLXLMCommon

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
    @State private var editorWidth: CGFloat = 0
    @State private var showTemplateParameters = false
    @State private var modelDefaults = LocalGenerationDefaults.Defaults.empty
    @State private var runtimeDefaults = VMLXServerGenerationDefaults()
    @State private var defaultsModelID: String?
    @State private var appTopP: Float?
    @State private var modelOptions: [String: ModelOptionValue] = [:]

    private var inherited: AgentGenerationInheritedValues {
        .resolve(
            modelID: defaultsModelID == modelID ? modelID : nil,
            isLocal: modelIsLocal,
            modelDefaults: modelDefaults,
            runtime: runtimeDefaults,
            appTopP: appTopP,
            modelOptions: modelOptions,
            draft: draft
        )
    }

    private struct CapabilityKey: Hashable {
        let modelID: String?
        let isLocal: Bool
        let catalog: ModelReasoningCapabilities?
        let revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.cardBorder)
            VStack(alignment: .leading, spacing: 24) {
                group("Sampling", subtitle: "How tokens are chosen") {
                    parameter(
                        "Temperature",
                        description: "Randomness of token choice. Lower is more focused, higher is more varied.",
                        field: .temperature
                    )
                    parameter(
                        "Top P",
                        description: "Sample only from tokens within this cumulative probability (0–1).",
                        field: .topP
                    )
                    parameter("Top K", description: "Sample only from the K most likely tokens.", field: .topK)
                    parameter(
                        "Min P",
                        description: "Drop tokens below this fraction of the most likely token's probability.",
                        field: .minP
                    )
                }
                group("Length & reasoning", subtitle: "How much and when to stop") {
                    parameter(
                        "Max Tokens",
                        description: "Upper limit on tokens generated in one response, including reasoning.",
                        field: .maxTokens
                    )
                    reasoningControls
                    speculationControls
                    stopSequences
                }
                group("Repetition", subtitle: "Discourage repeated text") {
                    parameter(
                        "Repetition penalty",
                        description: "Multiplicative penalty on tokens already used. 1.0 means off.",
                        field: .repetitionPenalty
                    )
                    parameter(
                        "Frequency penalty",
                        description: "Penalizes tokens in proportion to how often they've appeared.",
                        field: .frequencyPenalty
                    )
                    parameter(
                        "Presence penalty",
                        description: "Penalizes tokens that have appeared at least once.",
                        field: .presencePenalty
                    )
                }
                group("Reproducibility", subtitle: "") {
                    parameter(
                        "Seed",
                        description: "A fixed seed requests repeatable sampling; results also depend on the backend.",
                        field: .seed
                    )
                }
                templateParameters

                if let error,
                    !AgentGenerationField.allCases.contains(where: { draft.validationMessage(for: $0) == error })
                {
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
                            .disabled(
                                (choices == nil || choices?.modelID != modelID)
                                    && (draft.reasoningEffort != "" || draft.thinking != "inherit" || draft.speculation != "inherit")
                            )
                    }
                }
            }
            .padding(16)
        }
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            editorWidth = $0
        }
        .onAppear {
            restore(); expandForLanding(pendingLanding)
        }
        .onChange(of: pendingLanding) { _, value in expandForLanding(value) }
        .onChange(of: draft) { _, value in
            onDraftChange?(value)
            if !showsSaveButton {
                do { _ = try value.validated(); error = nil } catch { self.error = error.localizedDescription }
            }
        }
        .onChange(of: choices) { _, value in onReasoningChoicesChange?(value) }
        .task(
            id: CapabilityKey(
                modelID: modelID,
                isLocal: modelIsLocal,
                catalog: catalogCapabilities,
                revision: capabilityRevision
            )
        ) {
            choices = nil
            defaultsModelID = nil
            appTopP = ChatConfigurationStore.load().topPOverride
            modelOptions = modelID.flatMap { ModelOptionsStore.shared.loadOptions(for: $0) } ?? [:]
            let id = modelID
            let local = modelIsLocal
            let snapshot = await Task.detached(priority: .utility) {
                let runtime = await RuntimeConfig.snapshot()
                let bundle = id.flatMap { local ? LocalGenerationDefaults.defaults(forModelId: $0) : nil } ?? .empty
                return (runtime.generation, bundle)
            }.value
            guard !Task.isCancelled else { return }
            runtimeDefaults = snapshot.0
            modelDefaults = snapshot.1
            defaultsModelID = modelID
            guard let modelID else { return }
            var resolved = await AgentGenerationReasoningChoices.resolve(
                modelID: modelID, isLocal: modelIsLocal, includeSpeculation: true)
            guard !Task.isCancelled else { return }
            if let catalogCapabilities { resolved.efforts = catalogCapabilities }
            choices = resolved
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerRuntimeSettingsStore.didSaveNotification)) { _ in
            capabilityRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            capabilityRevision += 1
        }
    }

    @ViewBuilder
    private var speculationControls: some View {
        if let choices, choices.modelID == modelID {
            if let status = choices.speculation, status.speculationAvailable {
                rowLabel("Speculative Decoding", "Off uses ordinary decoding. On requests adaptive drafting without changing sampling.")
                Picker(L("Speculative Decoding"), selection: $draft.speculation) {
                    Text(localized: "Inherit").tag("inherit")
                    Text(localized: "Off (AR)").tag("off")
                    if !status.speculationBlocked {
                        Text(localized: "On (Adaptive)").tag("on")
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .settingsLandingAnchor("agents.generation.speculativeDecoding")
                Text(status.speculationCapabilityDescription)
                    .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft.speculation != "inherit",
                choices.speculation?.speculationAvailable != true
                    || (draft.speculation == "on" && choices.speculation?.speculationBlocked == true)
            {
                HStack {
                    Text("Saved speculation override is unavailable for this model.", bundle: .module)
                        .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                    Button(L("Use Inherit")) { draft.speculation = "inherit" }.buttonStyle(.borderless)
                }
            }
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
                    .pickerStyle(.segmented).labelsHidden()
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
                rowLabel("Thinking", "Let the model reason before answering, on models that support it.")
                Picker(L("Thinking"), selection: $draft.thinking) {
                    Text(localized: "Inherit").tag("inherit")
                    Text(localized: "On").tag("on")
                    Text(localized: "Off").tag("off")
                }
                .pickerStyle(.segmented).labelsHidden()
                .settingsLandingAnchor("agents.generation.thinking")
            } else if draft.thinking != "inherit" {
                if choices.supportsThinking {
                    HStack {
                        Text(localized: "Thinking")
                        Text(draft.thinking == "on" ? L("On") : L("Off"))
                        Spacer()
                        Button(L("Use Inherit")) { draft.thinking = "inherit" }.buttonStyle(.borderless)
                    }
                } else {
                    unsupportedReasoning
                }
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .medium)).foregroundColor(theme.accentColor)
                .padding(10).background(theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text("Generation Overrides", bundle: .module)
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(theme.primaryText)
                Text(
                    "Every setting inherits the model and server defaults. Switch a setting to Custom to override it for this agent only.",
                    bundle: .module
                )
                .font(.system(size: 12)).foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("Overrides: \(draft.overrideCount)", bundle: .module)
                .font(.system(size: 11, weight: .medium)).foregroundColor(theme.accentColor)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(theme.accentColor.opacity(0.10), in: Capsule())
                .fixedSize()
        }.padding(16)
    }

    private func group<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(LocalizedStringKey(title), bundle: .module).textCase(.uppercase)
                    .font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundColor(theme.accentColor)
                Spacer()
                if !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle), bundle: .module)
                        .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                }
            }
            Divider().overlay(theme.cardBorder)
            content()
        }
    }

    private func rowLabel(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(theme.primaryText)
            if !description.isEmpty {
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modePicker(_ title: String, field: AgentGenerationField) -> some View {
        Picker(
            LocalizedStringKey(title),
            selection: Binding(
                get: { draft[keyPath: field.path].isCustom },
                set: { draft[keyPath: field.path].setCustom($0, inheritedText: inherited[field].customText) }
            )
        ) {
            Text(localized: "Inherit").tag(false)
            Text(localized: "Custom").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 148)
            .accessibilityLabel(Text("\(title) mode"))
    }

    private func inheritedValue(_ field: AgentGenerationField) -> some View {
        let value = inherited[field]
        return HStack(spacing: 6) {
            Text(value.text).font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !value.source.isEmpty {
                Text(value.source.uppercased())
                    .font(.system(size: 9, weight: .semibold))
            }
        }.foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(
                    theme.inputBorder,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
    }

    private func parameter(_ title: String, description: String, field: AgentGenerationField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Use the card width for every row. Ideal text widths made ViewThatFits
            // mix horizontal and stacked rows on the same editing screen.
            if editorWidth >= 600 {
                HStack(alignment: .top, spacing: 14) {
                    rowLabel(title, description).frame(minWidth: 190)
                    modePicker(title, field: field)
                    parameterValue(title, field: field).frame(width: 160)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    rowLabel(title, description)
                    HStack(alignment: .top, spacing: 12) {
                        modePicker(title, field: field)
                        parameterValue(title, field: field)
                    }
                }
            }
            if let message = draft.validationMessage(for: field) { validation(message) }
        }.settingsLandingAnchor("agents.generation.\(field.rawValue)")
    }

    @ViewBuilder
    private func parameterValue(_ title: String, field: AgentGenerationField) -> some View {
        if draft[keyPath: field.path].isCustom {
            StyledTextField(
                placeholder: L("Value"),
                text: Binding(get: { draft[keyPath: field.path].text }, set: { draft[keyPath: field.path].text = $0 })
            )
            .accessibilityLabel(Text(title))
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(
                    draft.validationMessage(for: field) == nil ? Color.clear : .red,
                    lineWidth: 1
                )
            )
        } else {
            inheritedValue(field)
        }
    }

    private func validation(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundColor(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stopSequences: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                rowLabel(
                    "Stop sequences",
                    "Generation ends when any additional stop string is produced. Model end-of-turn tokens still apply."
                )
                modePicker("Stop sequences", field: .stop)
            }
            if draft.stop.isCustom {
                VStack(alignment: .leading, spacing: 8) {
                    let values = (try? JSONDecoder().decode([String].self, from: Data(draft.stop.text.utf8))) ?? []
                    // Adaptive columns keep long exact strings reachable at narrow creation widths.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            HStack(spacing: 8) {
                                Text(String(reflecting: value)).font(.system(size: 11, design: .monospaced))
                                    .lineLimit(2).help(value)
                                Spacer(minLength: 0)
                                Button {
                                    var edited = values
                                    edited.remove(at: index)
                                    do { try draft.setStopSequences(edited) } catch {
                                        self.error = error.localizedDescription
                                    }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 10))
                                }
                                .buttonStyle(.plain).accessibilityLabel(
                                    Text("Remove stop sequence \(index + 1)", bundle: .module)
                                )
                            }.padding(8)
                                .background(theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
                        }
                    }
                    HStack {
                        StyledTextField(
                            placeholder: L("Type a sequence, press Enter"),
                            text: $draft.pendingStopSequence,
                            monospaced: true
                        )
                        .accessibilityLabel(Text("New stop sequence", bundle: .module))
                        .onSubmit(commitStopSequence)
                        Button(L("Add"), action: commitStopSequence).disabled(draft.pendingStopSequence.isEmpty)
                    }
                    Text("Text is kept exactly as entered. Saving also adds a pending sequence.", bundle: .module)
                        .font(.system(size: 10)).foregroundColor(theme.tertiaryText)
                }
            } else {
                inheritedValue(.stop)
            }
            if let message = draft.validationMessage(for: .stop) { validation(message) }
        }.settingsLandingAnchor("agents.generation.stop")
    }

    private func commitStopSequence() {
        do { try draft.commitStopSequence() } catch { self.error = error.localizedDescription }
    }

    private var templateParameters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showTemplateParameters.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Advanced: chat template parameters", bundle: .module)
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(theme.primaryText)
                        Text(draft.templateKwargs.isCustom ? L("Custom parameters") : L("Inherited from the model"))
                            .font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    Text(showTemplateParameters ? L("Hide") : L("Show")).foregroundColor(theme.accentColor)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showTemplateParameters {
                HStack {
                    Text("Template parameters (JSON)", bundle: .module).font(.system(size: 12, weight: .medium))
                    Spacer()
                    modePicker("Template parameters", field: .templateKwargs)
                }
                if draft.templateKwargs.isCustom {
                    StyledTextField(
                        placeholder: "{}",
                        text: $draft.templateKwargs.text,
                        axis: .vertical,
                        lineLimit: 8,
                        monospaced: true
                    )
                    .accessibilityLabel(Text("Template parameters JSON", bundle: .module))
                } else {
                    Text("{} · No additional parameters", bundle: .module)
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(theme.tertiaryText)
                }
                Text(
                    "Additional variables for the model's template, not the template itself. Conversation, tools and special-token variables cannot be replaced.",
                    bundle: .module
                )
                .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            }
            if let message = draft.validationMessage(for: .templateKwargs) { validation(message) }
        }.padding(14)
            .background(theme.inputBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.cardBorder, lineWidth: 1))
            .settingsLandingAnchor("agents.generation.templateKwargs")
    }

    private func restore() {
        draft =
            initialDraft
            ?? AgentGenerationDraft(
                temperature: savedTemperature,
                maxTokens: savedMaxTokens,
                settings: savedSettings
            )
        error = nil
    }

    private func expandForLanding(_ id: String?) {
        guard let id else { return }
        if id == "agents.generation.templateKwargs" { showTemplateParameters = true }

    }

    private func save() {
        do {
            try draft.commitStopSequence()
            let values = try draft.validated()
            if let settings = values.settings {
                if settings.reasoningEffort != nil || settings.enableThinking != nil || settings.speculativeDecoding != nil {
                    guard let choices, choices.modelID == modelID else {
                        throw ChatTurnOverrides.ValidationError.invalid(
                            "Choose a model and wait for its reasoning controls to be detected."
                        )
                    }
                    try choices.validate(settings: settings)
                }
            }
            onSave(values)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

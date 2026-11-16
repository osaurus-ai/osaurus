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
    @State private var applicability = AgentGenerationApplicability.unrestricted
    @State private var appTopP: Float?
    @State private var modelOptions: [String: ModelOptionValue] = [:]

    private var savedDraft: AgentGenerationDraft {
        .init(temperature: savedTemperature, maxTokens: savedMaxTokens, settings: savedSettings)
    }

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

    private var currentApplicability: AgentGenerationApplicability {
        defaultsModelID == modelID ? applicability : .unrestricted
    }

    private struct CapabilityKey: Hashable {
        let modelID: String?
        let isLocal: Bool
        let catalog: ModelReasoningCapabilities?
        let revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s24) {
            header
            if currentApplicability == .nativeBlockDiffusion {
                Text(
                    "This model uses its native denoising schedule. Temperature, probability filters and repetition penalties are not used. Saved overrides are kept for models that use them.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
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
                validation(error)
            }
            HStack {
                SettingsButton(.tertiary, "Reset to inherited", size: .compact) {
                    draft = AgentGenerationDraft()
                    save()
                }
                if showsSaveButton {
                    Spacer()
                    SettingsButton(.primary, "Save generation defaults", size: .compact, action: save)
                        .disabled(
                            (choices == nil || choices?.modelID != modelID)
                                && (draft.reasoningEffort != "" || draft.thinking != "inherit" || draft.speculation != "inherit")
                        )
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            editorWidth = $0
        }
        .onAppear {
            restore(); expandForLanding(pendingLanding)
        }
        .onChange(of: pendingLanding) { _, value in expandForLanding(value) }
        .onChange(of: savedDraft) { previous, latest in
            draft.mergeSavedChanges(from: previous, to: latest)
        }
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
                let applicability = AgentGenerationApplicability.resolve(modelID: id, isLocal: local)
                return (runtime.generation, bundle, applicability)
            }.value
            guard !Task.isCancelled else { return }
            runtimeDefaults = snapshot.0
            modelDefaults = snapshot.1
            applicability = snapshot.2
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
                AssignedBaseSegmentedPicker(
                    selection: $draft.speculation,
                    options: [.init("inherit", "Inherit"), .init("off", "Off (AR)")]
                        + (status.speculationBlocked ? [] : [.init("on", "On (Adaptive)")])
                )
                .fixedSize()
                .accessibilityLabel(Text("Speculative Decoding", bundle: .module))
                .settingsLandingAnchor("agents.generation.speculativeDecoding")
                Text(status.speculationCapabilityDescription)
                    .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft.speculation != "inherit",
                choices.speculation?.speculationAvailable != true
                    || (draft.speculation == "on" && choices.speculation?.speculationBlocked == true)
            {
                HStack {
                    Text("Saved speculation override is unavailable for this model.", bundle: .module)
                        .font(SettingsFont.rowDescription).foregroundColor(theme.status.warning.foreground)
                    SettingsButton(.tertiary, "Use Inherit", size: .compact) { draft.speculation = "inherit" }
                }
            }
        }
    }

    @ViewBuilder
    private var reasoningControls: some View {
        if modelID == nil {
            Text("Choose a model to detect its reasoning controls.", bundle: .module)
                .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
        } else if let choices, choices.modelID == modelID {
            if let capabilities = choices.efforts, !capabilities.isEmpty {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    Text("Reasoning effort", bundle: .module)
                        .font(SettingsFont.rowTitle).foregroundColor(theme.text.primary)
                    AssignedBaseSegmentedPicker(
                        selection: $draft.reasoningEffort,
                        options: [.init("", "Inherit")]
                            + capabilities.levels.map {
                                .init($0.id, ModelReasoningCapabilities.displayLabel(forEffort: $0.id), verbatim: true)
                            }
                    )
                    .fixedSize()
                    .accessibilityLabel(Text("Reasoning effort", bundle: .module))
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
                rowLabel("thinking.mode.label", "Let the model reason before answering, on models that support it.")
                AssignedBaseSegmentedPicker(
                    selection: $draft.thinking,
                    options: [.init("inherit", "Inherit"), .init("on", "On"), .init("off", "Off")]
                )
                .fixedSize()
                .accessibilityLabel(Text(verbatim: L("thinking.mode.label")))
                .settingsLandingAnchor("agents.generation.thinking")
            } else if draft.thinking != "inherit" {
                if choices.supportsThinking {
                    HStack {
                        Text(localized: "thinking.mode.label")
                        Text(draft.thinking == "on" ? L("On") : L("Off"))
                        Spacer()
                        SettingsButton(.tertiary, "Use Inherit", size: .compact) { draft.thinking = "inherit" }
                    }
                } else {
                    unsupportedReasoning
                }
            }
        } else {
            HStack(spacing: theme.space.s8) {
                SettingsSpinner()
                Text("Detecting model reasoning controls…", bundle: .module)
                    .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
            }
        }
    }

    private var unsupportedReasoning: some View {
        HStack {
            Text("Saved reasoning choices are not supported by the selected model.", bundle: .module)
                .font(SettingsFont.rowDescription).foregroundColor(theme.status.warning.foreground)
            SettingsButton(.tertiary, "Use Inherit", size: .compact) {
                draft.reasoningEffort = ""
                draft.thinking = "inherit"
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            Text(
                "Available settings inherit the model and server defaults. Switch a setting to Custom to override it for this agent only.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: theme.space.s4) {
                Text("Overrides: \(draft.overrideCount)", bundle: .module)
                    .font(SettingsFont.chip).foregroundColor(theme.action.primary.default.background)
                    .padding(.horizontal, theme.space.s8).padding(.vertical, theme.space.s4)
                    .background(theme.selection.background, in: Capsule())
                    .fixedSize()
                let inactive = currentApplicability.inactiveOverrideCount(in: draft)
                if inactive > 0 {
                    Text("\(inactive) not used by this model", bundle: .module)
                        .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func group<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(SettingsFont.sectionTitle).foregroundColor(theme.text.primary)
                Spacer()
                if !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle), bundle: .module)
                        .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                }
            }
            Divider().overlay(theme.border.subtle)
            content()
        }
    }

    private func rowLabel(_ title: String, _ description: String) -> some View {
        SettingsRowText(title, description: description)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modePicker(_ title: String, field: AgentGenerationField) -> some View {
        AssignedBaseSegmentedPicker(
            selection: Binding(
                get: { draft[keyPath: field.path].isCustom },
                set: { draft[keyPath: field.path].setCustom($0, inheritedText: inherited[field].customText) }
            ),
            options: [.init(false, "Inherit"), .init(true, "Custom")]
        )
        .fixedSize()
        .accessibilityLabel(Text("\(title) mode"))
        .disabled(!currentApplicability.isApplicable(field))
    }

    private func inheritedValue(_ field: AgentGenerationField) -> some View {
        let value = inherited[field]
        return HStack(spacing: theme.space.s6) {
            Text(value.text).font(SettingsFont.mono)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !value.source.isEmpty {
                Text(value.source)
                    .font(SettingsFont.chip)
            }
        }.foregroundColor(theme.text.tertiary)
            .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium).stroke(
                    theme.border.default,
                    style: StrokeStyle(lineWidth: theme.stroke.default, dash: [4, 3])
                )
            )
    }

    private func parameter(_ title: String, description: String, field: AgentGenerationField) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            // Use the editor width for every row. Ideal text widths made ViewThatFits
            // mix horizontal and stacked rows on the same editing screen.
            if editorWidth >= 600 {
                HStack(alignment: .top, spacing: theme.space.s14) {
                    rowLabel(title, description).frame(minWidth: 190)
                    modePicker(title, field: field)
                    parameterValue(title, field: field).frame(maxWidth: 160)
                }
            } else {
                VStack(alignment: .leading, spacing: theme.space.s10) {
                    rowLabel(title, description)
                    HStack(alignment: .top, spacing: theme.space.s12) {
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
        if !currentApplicability.isApplicable(field) {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                if draft[keyPath: field.path].isCustom {
                    Text(draft[keyPath: field.path].text).font(SettingsFont.mono)
                    Text("Saved; not used by this model", bundle: .module)
                        .font(SettingsFont.rowDescription)
                } else {
                    Text("Not used by this model", bundle: .module)
                        .font(SettingsFont.rowDescription)
                }
            }
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(
                draft[keyPath: field.path].isCustom
                    ? Text("\(draft[keyPath: field.path].text). Saved; not used by this model", bundle: .module)
                    : Text("Not used by this model", bundle: .module)
            )
        } else if draft[keyPath: field.path].isCustom {
            SettingsTextField(
                placeholder: L("Value"),
                text: Binding(get: { draft[keyPath: field.path].text }, set: { draft[keyPath: field.path].text = $0 }),
                isInvalid: draft.validationMessage(for: field) != nil
            )
            .accessibilityLabel(Text(title))
        } else {
            inheritedValue(field)
        }
    }

    private func validation(_ message: String) -> some View {
        Text(message).font(SettingsFont.rowDescription).foregroundColor(theme.status.error.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stopSequences: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(alignment: .top, spacing: theme.space.s12) {
                rowLabel(
                    "Stop sequences",
                    "Generation ends when any additional stop string is produced. Model end-of-turn tokens still apply."
                )
                modePicker("Stop sequences", field: .stop)
            }
            if draft.stop.isCustom {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    let values = (try? JSONDecoder().decode([String].self, from: Data(draft.stop.text.utf8))) ?? []
                    // Adaptive columns keep long exact strings reachable at narrow creation widths.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                        alignment: .leading,
                        spacing: theme.space.s6
                    ) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            HStack(spacing: theme.space.s8) {
                                Text(String(reflecting: value)).font(SettingsFont.monoSmall)
                                    .foregroundColor(theme.text.primary)
                                    .lineLimit(2).help(value)
                                Spacer(minLength: 0)
                                Button {
                                    var edited = values
                                    edited.remove(at: index)
                                    do { try draft.setStopSequences(edited) } catch {
                                        self.error = error.localizedDescription
                                    }
                                } label: {
                                    Image(systemName: "xmark").font(SettingsFont.glyphSmall)
                                        .foregroundColor(theme.text.secondary)
                                }
                                .buttonStyle(.plain).accessibilityLabel(
                                    Text("Remove stop sequence \(index + 1)", bundle: .module)
                                )
                            }.padding(theme.space.s8)
                                .background(theme.surface.subtle, in: RoundedRectangle(cornerRadius: theme.radius.medium))
                                .overlay(
                                    RoundedRectangle(cornerRadius: theme.radius.medium)
                                        .stroke(theme.border.subtle, lineWidth: theme.stroke.default))
                        }
                    }
                    HStack {
                        SettingsTextField(
                            placeholder: L("Type a sequence, press Enter"),
                            text: $draft.pendingStopSequence,
                            monospaced: true,
                            onSubmit: commitStopSequence
                        )
                        .accessibilityLabel(Text("New stop sequence", bundle: .module))
                        SettingsButton(.secondary, "Add", size: .compact, action: commitStopSequence)
                            .disabled(draft.pendingStopSequence.isEmpty)
                    }
                    Text("Text is kept exactly as entered. Saving also adds a pending sequence.", bundle: .module)
                        .font(SettingsFont.footnote).foregroundColor(theme.text.tertiary)
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
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Button {
                withAnimation(theme.motion.quick) { showTemplateParameters.toggle() }
            } label: {
                HStack {
                    SettingsRowText {
                        Text("Advanced: chat template parameters", bundle: .module)
                    } description: {
                        Text(draft.templateKwargs.isCustom ? L("Custom parameters") : L("Inherited from the model"))
                    }
                    Spacer()
                    Text(showTemplateParameters ? L("Hide") : L("Show"))
                        .font(SettingsFont.smallLabel).foregroundColor(theme.action.primary.default.background)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showTemplateParameters {
                HStack {
                    Text("Template parameters (JSON)", bundle: .module)
                        .font(SettingsFont.rowTitle).foregroundColor(theme.text.primary)
                    Spacer()
                    modePicker("Template parameters", field: .templateKwargs)
                }
                if draft.templateKwargs.isCustom {
                    SettingsTextField(
                        placeholder: "{}",
                        text: $draft.templateKwargs.text,
                        axis: .vertical,
                        lineLimit: 8,
                        monospaced: true
                    )
                    .accessibilityLabel(Text("Template parameters JSON", bundle: .module))
                } else {
                    Text("{} · No additional parameters", bundle: .module)
                        .font(SettingsFont.mono).foregroundColor(theme.text.tertiary)
                }
                Text(
                    "Additional variables for the model's template, not the template itself. Conversation, tools and special-token variables cannot be replaced.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
            }
            if let message = draft.validationMessage(for: .templateKwargs) { validation(message) }
        }.padding(theme.space.s12)
            .background(theme.surface.subtle, in: RoundedRectangle(cornerRadius: theme.radius.large))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.large).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
            .settingsLandingAnchor("agents.generation.templateKwargs")
    }

    private func restore() {
        draft = initialDraft ?? savedDraft
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

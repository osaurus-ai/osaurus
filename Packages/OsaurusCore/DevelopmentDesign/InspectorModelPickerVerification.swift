#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Matches production call-site configurations. Selections stay local to this preview.
struct InspectorModelPickerVerification: View {
    var catalogPreview = false
    @ObservedObject private var cache = ModelPickerItemCache.shared
    @ObservedObject private var runtimes = HarnessRuntimeStore.shared
    @ObservedObject private var favorites = FavoriteModelsStore.shared
    @State private var variant = "Chat composer · Multiple option sections"
    @State private var selected: String?
    @State private var selectedHarness: String?
    @State private var optionValues: [String: ModelOptionValue] = [:]
    @State private var size = CGSize(width: 700, height: 480)
    private let variants = [
        "Chat composer · Multiple option sections", "Chat composer", "Chat · Context compaction",
        "Settings · Model Defaults", "Agent settings · Default model", "Agent settings · Follow-up model",
        "Agent creation", "Agent setup"
    ]
    private var providers: [ChatModelPickerProvider] {
        ChatModelPickerProvider.groups(from: cache.items,
            cloudModelIDs: Set(cache.items.filter { favorites.isFavorite($0.favoriteKey) || $0.id == selected }.map(\.id)),
            harnesses: ChatModelPickerProvider.harnessProviders(runtimes: runtimes.all()))
    }
    private var modelOptions: ModelPickerOptionsControl? {
        guard let model = selected else { return nil }
        let definitions = ModelProfileRegistry.options(for: model)
        let thinkingID = ModelProfileRegistry.profile(for: model)?.thinkingOption?.id
        let options = definitions.filter { $0.id != thinkingID }
        let capabilities = cache.items.first { $0.id == model }?.reasoningCapabilities
            ?? ModelProfileRegistry.reasoningCapabilities(for: model)
        let explicitThinking = ModelProfileRegistry.thinkingEnabled(for: model, values: optionValues)
        let thinking: ModelPickerThinkingControl? = thinkingID.flatMap { id in
            guard definitions.contains(where: { $0.id == id }) else { return nil }
            return ModelPickerThinkingControl(
                isEnabled: AgentReasoningPolicy.effectiveEnableThinkingForPresentation(
                    isAgentOrToolRequest: true, modelOptions: optionValues,
                    capability: LocalReasoningCapability.capability(forModelId: model)),
                isExplicit: explicitThinking != nil,
                onSetEnabled: { enabled in
                    if let enabled, let stored = ModelProfileRegistry.thinkingStoredOption(for: model, enabled: enabled) {
                        optionValues[stored.id] = stored.value
                    } else { optionValues.removeValue(forKey: id) }
                },
                supportsUnspecifiedDefault: LocalReasoningCapability.capability(forModelId: model).preservesOmittedThinking)
        }
        guard !options.isEmpty || thinking != nil else { return nil }
        var defaults = ModelProfileRegistry.defaults(for: model)
        if let capabilities { defaults = capabilities.defaultLevelId.map { ["reasoningEffort": .string($0)] } ?? [:] }
        return ModelPickerOptionsControl(capabilities: capabilities, thinking: thinking,
            options: options, values: ModelProfileRegistry.normalizedOptions(for: model, persisted: optionValues),
            defaults: defaults, onChange: { key, value in
                if key == "reasoningEffort" { optionValues.removeValue(forKey: "disableThinking") }
                optionValues[key] = value
            })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Preview", selection: $variant) {
                ForEach(variants, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            if variant == "Chat composer · Multiple option sections" {
                CatalogModelOptionSectionsExample()
            } else if variant == "Chat composer" {
                // Options come from the same model profile/capability registry as the composer.
                // Changes are preview-local and never save runtime preferences.
                ChatModelPickerCard(providers: providers, selectedModel: $selected,
                    optionsControl: modelOptions, selectedHarnessID: selectedHarness,
                    onSelectHarness: { selectedHarness = $0?.id },
                    onExploreLocal: {}, onExploreCloud: {}, onSizeChange: { size = $0 })
                    .frame(width: min(size.width, 900), height: size.height)
            } else if variant == "Chat · Context compaction" {
                ModelPickerView(options: cache.items, selectedModel: $selected, agentId: nil,
                    onDismiss: {}, onAddModel: {})
            } else {
                ModelSearchablePicker(
                    items: cache.items, selection: $selected,
                    noneTitle: settingsDefaultTitle,
                    style: variant == "Settings · Model Defaults" ? .compact : .field,
                    actions: settingsActions
                )
            }
        }
        .onReceive(cache.$items) { items in
            guard selected == nil else { return }
            selected = items.first { !ModelProfileRegistry.options(for: $0.id).isEmpty }?.id ?? items.first?.id
        }
        .onChange(of: selected) { _, _ in optionValues = [:] }
    }

    private var settingsDefaultTitle: String {
        switch variant {
        case "Settings · Model Defaults": L("Use chat model (default)")
        case "Agent settings · Follow-up model": L("Default (shared core model)")
        default: L("Default (from global settings)")
        }
    }

    private var settingsActions: [SettingsSearchablePicker.Action] {
        switch variant {
        case "Agent setup":
            [
                .init(id: "add-provider", title: L("Add a provider"), icon: "cloud", handler: {}),
                .init(id: "download-model", title: L("Download a model"), icon: "arrow.down.circle", handler: {})
            ]
        case "Agent creation":
            [.init(id: "add-model", title: L("Add Model"), icon: "plus", handler: {})]
        default:
            []
        }
    }
}
/// Explicit design example: preserves multi-section styling coverage without
/// presenting invented options as the configuration of an installed model.
private struct CatalogModelOptionSectionsExample: View {
    @State private var selected: String? = "design-options-example"
    @State private var thinking = false
    @State private var explicit = false
    @State private var values: [String: ModelOptionValue] = [:]
    @State private var size = CGSize(width: 740, height: 480)
    private let item = ModelPickerItem(id: "design-options-example", displayName: "Multiple option sections", source: .local)
    private var options: ModelPickerOptionsControl {
        ModelPickerOptionsControl(capabilities: nil,
            thinking: ModelPickerThinkingControl(isEnabled: thinking, isExplicit: explicit,
                onSetEnabled: { value in thinking = value ?? false; explicit = value != nil },
                supportsUnspecifiedDefault: true),
            options: [ModelOptionDefinition(id: "design-effort", label: "Reasoning effort", kind: .segmented([
                ModelOptionSegment(id: "low", label: "Low"), ModelOptionSegment(id: "high", label: "High")
            ]), help: "Example supporting text for styling option sections.")],
            values: values, defaults: ["design-effort": .string("low")],
            onChange: { key, value in values[key] = value })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Design example · Shows multiple option sections together. Does not change a model’s configuration.")
                .font(.caption).foregroundStyle(.secondary)
            ChatModelPickerCard(providers: [ChatModelPickerProvider(id: "design-local", title: "Local", kind: .local,
                models: [item], availableModels: [item])], selectedModel: $selected,
                optionsControl: options, onExploreLocal: {}, onExploreCloud: {}, onSizeChange: { size = $0 })
                .frame(width: min(size.width, 900), height: size.height)
        }
    }
}
#endif

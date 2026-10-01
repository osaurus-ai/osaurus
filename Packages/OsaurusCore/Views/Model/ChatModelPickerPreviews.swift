//
//  ChatModelPickerPreviews.swift
//  Osaurus
//
//  Interactive, account-free fixtures for the chat model picker. Open this
//  file in Xcode's Canvas to iterate on the five states and light appearance.
//  Every model and capability below is sample data, not a runtime promise.
//

#if DEBUG
import SwiftUI

@MainActor
private struct ChatModelPickerPreview: View {
    enum Scenario: String {
        case localActive, cloudActive, remoteReasoning, localInactive, empty
    }

    let scenario: Scenario
    let light: Bool
    @State private var selectedModel: String?
    @State private var overrides: [String: [String: ModelOptionValue]] = [:]
    @State private var cardSize: CGSize
    @State private var lastAction = ""
    @StateObject private var favorites: FavoriteModelsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ scenario: Scenario, light: Bool = false) {
        self.scenario = scenario
        self.light = light
        let selection: String?
        switch scenario {
        case .localActive: selection = ChatModelPickerPreviewData.localChat.id
        case .cloudActive, .localInactive: selection = ChatModelPickerPreviewData.cloudQuick.id
        case .remoteReasoning: selection = ChatModelPickerPreviewData.remoteReasoner.id
        case .empty: selection = nil
        }
        _selectedModel = State(initialValue: selection)
        _cardSize = State(initialValue: CGSize(width: scenario == .remoteReasoning ? 792 : 532, height: 320))

        // A fresh, explicitly named suite prevents Canvas star clicks from
        // reading or changing the real app's favorites, even in live previews.
        let suite = "com.dinoki.osaurus.preview.chat-model-picker.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Unable to create the isolated model-picker preview preferences")
        }
        let store = FavoriteModelsStore(userDefaults: defaults)
        store.add(ChatModelPickerPreviewData.cloudQuick.favoriteKey)
        _favorites = StateObject(wrappedValue: store)
    }

    private var theme: ThemeProtocol { light ? LightTheme() : DarkTheme() }

    private var availableModels: [ModelPickerItem] {
        let data = ChatModelPickerPreviewData.self
        switch scenario {
        case .localActive:
            return data.localModels
        case .cloudActive:
            return data.localModels + data.cloudModels
        case .remoteReasoning:
            return data.localModels + data.remoteModels
        case .localInactive:
            return data.cloudModels + data.remoteModels
        case .empty:
            return []
        }
    }

    private var providers: [ChatModelPickerProvider] {
        // Use the production projection so Canvas exercises the same ordering,
        // inactive discovery rows, and favorite/current-model policy as chat.
        var shortlist = Set(availableModels.filter { favorites.isFavorite($0.favoriteKey) }.map(\.id))
        if let selectedModel { shortlist.insert(selectedModel) }
        return ChatModelPickerProvider.groups(from: availableModels, cloudModelIDs: shortlist)
    }

    private var optionsControl: ModelPickerOptionsControl? {
        guard let selectedModel else { return nil }
        let hasReasoning = selectedModel == ChatModelPickerPreviewData.remoteReasoner.id
            || selectedModel == ChatModelPickerPreviewData.cloudReasoner.id
        let hasThinking = selectedModel == ChatModelPickerPreviewData.localThinker.id
        guard hasReasoning || hasThinking else { return nil }
        let values = overrides[selectedModel] ?? [:]
        let thinkingOverride = values["sampleThinking"]?.boolValue
        return ModelPickerOptionsControl(
            capabilities: hasReasoning
                ? ModelReasoningCapabilities(
                    levels: [
                        .init(id: "low", description: "Sample level with less reasoning."),
                        .init(id: "medium", description: "Sample balanced reasoning level."),
                        .init(id: "high", description: "Sample level with more reasoning."),
                    ],
                    defaultLevelId: "medium"
                )
                : nil,
            thinking: hasThinking
                ? ModelPickerThinkingControl(
                    isEnabled: thinkingOverride ?? true,
                    isExplicit: thinkingOverride != nil,
                    onSetEnabled: { newValue in
                        setOverride(newValue.map(ModelOptionValue.bool), for: "sampleThinking", model: selectedModel)
                    },
                    supportsUnspecifiedDefault: true
                )
                : nil,
            // The local thinker also carries a segmented and a toggle option so
            // Canvas exercises every section type of the Model options column.
            options: hasReasoning
                ? [
                    ModelOptionDefinition(
                        id: "reasoningEffort",
                        label: "Reasoning effort",
                        icon: "brain",
                        kind: .segmented([
                            ModelOptionSegment(id: "low", label: "Low"),
                            ModelOptionSegment(id: "medium", label: "Medium"),
                            ModelOptionSegment(id: "high", label: "High"),
                        ])
                    )
                ]
                : [
                    ModelOptionDefinition(
                        id: "sampleDepth",
                        label: "Speculative depth",
                        icon: "hare",
                        kind: .segmented([
                            ModelOptionSegment(id: "off", label: "Off"),
                            ModelOptionSegment(id: "auto", label: "Auto"),
                            ModelOptionSegment(id: "2", label: "2"),
                        ]),
                        help: "Sample footnote: depth controls speculation, not sampling."
                    ),
                    ModelOptionDefinition(
                        id: "sampleToggle",
                        label: "Sample toggle",
                        kind: .toggle(default: false)
                    ),
                ],
            values: values,
            defaults: hasReasoning ? ["reasoningEffort": .string("medium")] : ["sampleDepth": .string("off")],
            onChange: { key, value in setOverride(value, for: key, model: selectedModel) }
        )
    }

    private func setOverride(_ value: ModelOptionValue?, for key: String, model: String) {
        var modelValues = overrides[model] ?? [:]
        modelValues[key] = value
        overrides[model] = modelValues
    }

    private var selectionLabel: String {
        providers.flatMap(\.models).first { $0.id == selectedModel }?.displayName ?? "None"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: "Interactive sample data")
                .font(theme.font(size: 14, weight: .medium))
            ChatModelPickerCard(
                providers: providers,
                selectedModel: $selectedModel,
                optionsControl: optionsControl,
                onExploreLocal: { lastAction = "Preview action: browse local models." },
                onExploreCloud: { lastAction = "Preview action: browse cloud models." },
                onSizeChange: { cardSize = $0 },
                favorites: favorites
            )
            .frame(width: cardSize.width, height: cardSize.height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: cardSize)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Selected: \(selectionLabel)")
                if !lastAction.isEmpty { Text(lastAction) }
                Text(verbatim: "Models and capabilities are fictional. These controls do not connect an account or load a model.")
            }
            .font(theme.font(size: 12))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: 792, alignment: .leading)
        }
        .padding(28)
        .frame(width: 848, height: 680, alignment: .topLeading)
        .foregroundStyle(theme.primaryText)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .environment(\.colorScheme, light ? .light : .dark)
    }
}

@MainActor
private enum ChatModelPickerPreviewData {
    // Provider identity is a pure constant; no manager instance is created.
    static let cloudID = RemoteProviderManager.osaurusRouterProviderId
    static let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!

    static let localChat = ModelPickerItem(
        id: "preview/local-chat",
        displayName: "Sample Local Chat",
        source: .local
    )
    static let localThinker = ModelPickerItem(
        id: "preview/local-thinker",
        displayName: "Sample Local Thinker",
        source: .local
    )
    static let cloudQuick = ModelPickerItem(
        id: "preview/cloud-quick",
        displayName: "Sample Cloud Quick",
        source: .remote(providerName: "Osaurus Cloud", providerId: cloudID)
    )
    static let cloudReasoner = ModelPickerItem(
        id: "preview/cloud-reasoner",
        displayName: "Sample Cloud Reasoner",
        source: .remote(providerName: "Osaurus Cloud", providerId: cloudID)
    )
    static let cloudVision = ModelPickerItem(
        id: "preview/cloud-vision",
        displayName: "Sample Cloud Vision",
        source: .remote(providerName: "Osaurus Cloud", providerId: cloudID),
        isVLM: true
    )
    static let remoteReasoner = ModelPickerItem(
        id: "preview/remote-reasoner",
        displayName: "Sample Remote Reasoner",
        source: .remote(providerName: "Sample Remote", providerId: remoteID)
    )
    static let remoteBasic = ModelPickerItem(
        id: "preview/remote-basic",
        displayName: "Sample Remote Basic",
        source: .remote(providerName: "Sample Remote", providerId: remoteID)
    )

    static var localModels: [ModelPickerItem] { [localChat, localThinker] }
    static var cloudModels: [ModelPickerItem] { [cloudQuick, cloudReasoner, cloudVision] }
    static var remoteModels: [ModelPickerItem] { [remoteReasoner, remoteBasic] }

}

#if DEBUG && canImport(PreviewsMacros)
#Preview("1 · Local active, Cloud inactive") {
    ChatModelPickerPreview(.localActive)
}

#Preview("2 · Cloud active") {
    ChatModelPickerPreview(.cloudActive)
}

#Preview("3 · Remote reasoning") {
    ChatModelPickerPreview(.remoteReasoning)
}

#Preview("4 · Local inactive") {
    ChatModelPickerPreview(.localInactive)
}

#Preview("5 · Empty providers") {
    ChatModelPickerPreview(.empty)
}

#Preview("6 · Light appearance") {
    ChatModelPickerPreview(.cloudActive, light: true)
}
#endif

#endif

//
//  ChatModelRolePicker.swift
//  osaurus
//
//  Picker for a model "role" stored in `ChatConfiguration` as a provider /
//  name pair (Core Model, Compaction Model). Empty means "fall back to the
//  chat's model". Saves on change with a load-modify-write that touches only
//  its own pair, so it composes with every other screen that edits
//  `ChatConfiguration`.
//

import SwiftUI

struct ChatModelRolePicker: View {
    @Environment(\.theme) private var theme

    let providerKeyPath: WritableKeyPath<ChatConfiguration, String?>
    let nameKeyPath: WritableKeyPath<ChatConfiguration, String?>
    /// Shown while unset, e.g. "Use chat model (default)".
    let fallbackLabel: String
    /// Explain why a stored model can't run right now (Core Model only:
    /// `CoreModelService` knows the Foundation / disconnected-provider reasons).
    var explainsUnavailable: Bool = false

    @State private var identifier: String = ""
    @State private var items: [ModelPickerItem] = []

    var body: some View {
        let currentItem = items.first { $0.id == identifier }
        let unavailableReason: String? =
            (explainsUnavailable && !identifier.isEmpty && currentItem == nil)
            ? CoreModelService.unavailableReason(modelId: identifier)
            : nil
        VStack(alignment: .trailing, spacing: theme.space.s6) {
            ModelSearchablePicker(
                items: items,
                selection: Binding(get: { identifier.isEmpty ? nil : identifier }, set: { select($0) }),
                noneTitle: NSLocalizedString(fallbackLabel, bundle: .module, comment: ""),
                label: { id in currentItem?.displayName ?? L("\(Self.displayName(id)) (unavailable)") },
                style: .compact
            )
            if let unavailableReason {
                HStack(alignment: .top, spacing: theme.space.s6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(theme.status.warning.foreground)
                    Text(
                        "\(unavailableReason) Until then, your active chat model handles these tasks.",
                        bundle: .module
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: .appConfigurationChanged)) { _ in load() }
        .onReceive(ModelPickerItemCache.shared.$items) { items = $0 }
    }

    /// Display name for an id that isn't in the picker catalog.
    private static func displayName(_ id: String) -> String {
        id.caseInsensitiveCompare(FoundationModelService.serviceId) == .orderedSame ? "Foundation" : id
    }

    private func load() {
        let config = ChatConfigurationStore.load()
        identifier = Self.identifier(
            provider: config[keyPath: providerKeyPath],
            name: config[keyPath: nameKeyPath]
        )
    }

    private func select(_ newValue: String?) {
        let value = newValue ?? ""
        guard value != identifier else { return }
        identifier = value
        let (provider, name) = Self.split(value)
        var config = ChatConfigurationStore.load()
        config[keyPath: providerKeyPath] = provider
        config[keyPath: nameKeyPath] = name
        ChatConfigurationStore.save(config)
    }

    static func identifier(provider: String?, name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        guard let provider, !provider.isEmpty else { return name }
        return "\(provider)/\(name)"
    }

    /// `"provider/name"` → (provider, name); a bare name has no provider; ""
    /// clears both.
    static func split(_ identifier: String) -> (provider: String?, name: String?) {
        guard !identifier.isEmpty else { return (nil, nil) }
        let parts = identifier.split(separator: "/", maxSplits: 1)
        if parts.count == 2 { return (String(parts[0]), String(parts[1])) }
        return (nil, identifier)
    }
}

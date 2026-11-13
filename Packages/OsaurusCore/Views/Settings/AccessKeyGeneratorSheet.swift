//
//  AccessKeyGeneratorSheet.swift
//  osaurus
//
//  Modal sheet for generating a new osk-v1 access key. Hosted from
//  ServerView.AccessKeysSection (global, master-scoped) and from
//  IdentityView's per-agent expansion (agent-scoped).
//
//  Visibility: internal (`struct AccessKeyGeneratorSheet`) so both files in
//  the same target can present it without re-implementing the form.
//

import SwiftUI

struct AccessKeyGeneratorSheet: View {
    let theme: ThemeProtocol
    let title: LocalizedStringKey
    let scopeCaption: LocalizedStringKey?
    @Binding var label: String
    @Binding var expiration: AccessKeyExpiration
    @Binding var isGenerating: Bool
    @Binding var error: String?
    let onGenerate: () -> Void
    let onCancel: () -> Void

    init(
        theme: ThemeProtocol,
        title: LocalizedStringKey = "Generate Access Key",
        scopeCaption: LocalizedStringKey? = nil,
        label: Binding<String>,
        expiration: Binding<AccessKeyExpiration>,
        isGenerating: Binding<Bool>,
        error: Binding<String?>,
        onGenerate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.theme = theme
        self.title = title
        self.scopeCaption = scopeCaption
        self._label = label
        self._expiration = expiration
        self._isGenerating = isGenerating
        self._error = error
        self.onGenerate = onGenerate
        self.onCancel = onCancel
    }

    var body: some View {
        SettingsSheet(
            icon: "key.fill",
            title: title,
            primary: .init(
                label: "Generate",
                isEnabled: !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isLoading: isGenerating,
                handler: onGenerate
            ),
            secondary: .init(label: "Cancel", handler: onCancel),
            onClose: onCancel
        ) {
            if let scopeCaption {
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "scope")
                        .font(SettingsFont.glyphSmall)
                        .foregroundColor(theme.text.link)
                    Text(scopeCaption, bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s6)
                .settingsChrome(.selected)
            }

            SettingsFieldRow(label: "Label") {
                SettingsTextField(placeholder: L("e.g. Cursor, CLI, my-app"), text: $label)
            }

            SettingsFieldRow(label: "Expiration") {
                AssignedBaseSegmentedPicker(selection: $expiration, options: AccessKeyExpiration.allCases.map {
                    .init($0, $0.displayName, verbatim: true)
                })
                .accessibilityLabel(Text("Expiration", bundle: .module))
            }

            if let error {
                Text(error)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.status.error.foreground)
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsChrome(.status(.error))
            }
        }
    }
}

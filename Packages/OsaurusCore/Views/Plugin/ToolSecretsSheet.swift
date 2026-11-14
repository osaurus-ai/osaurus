//
//  ToolSecretsSheet.swift
//  osaurus
//
//  Sheet for configuring plugin secrets (API keys, tokens, etc.). Values
//  are saved in Keys; a blank field keeps the saved value.
//

import AppKit
import SwiftUI

// MARK: - Main View

struct ToolSecretsSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let pluginId: String
    /// nil saves the values for all agents.
    let agentId: UUID?
    let pluginName: String
    let pluginVersion: String?
    let secrets: [PluginManifest.SecretSpec]
    let onSave: () -> Void

    // State for secret values
    @State private var secretValues: [String: String] = [:]
    @State private var savedIds: Set<String> = []
    @State private var validationErrors: Set<String> = []
    @State private var hasAppeared: Bool = false

    init(
        pluginId: String,
        agentId: UUID?,
        pluginName: String,
        pluginVersion: String? = nil,
        secrets: [PluginManifest.SecretSpec],
        onSave: @escaping () -> Void
    ) {
        self.pluginId = pluginId
        self.agentId = agentId
        self.pluginName = pluginName
        self.pluginVersion = pluginVersion
        self.secrets = secrets
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            // Header
            sheetHeader

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s20) {
                    // Info card
                    infoCard
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)

                    // Secrets form
                    secretsForm
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)
                }
                .padding(theme.settingsSheetInset)
            }

            sheetFooter
        }
        .frame(width: SettingsSheetWidth.regular, height: min(400 + CGFloat(secrets.count) * 80, 600))
        .settingsSheetSurface()
        .onAppear {
            loadExistingSecrets()
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        SettingsSheetHeader(
            icon: "key.fill",
            title: "Configure Secrets",
            subtitleText: pluginVersion.map { "\(pluginName) · v\($0)" } ?? pluginName,
            onClose: { dismiss() }
        )
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: "info.circle.fill")
                .glyphSize(.medium)
                .foregroundColor(theme.status.info.foreground)

            Text(
                "This plugin needs these keys to work. They are saved in the Vault, where you can view or change them later.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.info))
    }

    // MARK: - Secrets Form

    private var secretsForm: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            ForEach(Array(secrets.enumerated()), id: \.element.id) { index, spec in
                if index > 0 {
                    ThemeHairlineDivider()
                        .padding(.horizontal, theme.space.s16)
                }

                SecretFieldRow(
                    spec: spec,
                    key: PluginCredentials.slot(pluginId: pluginId, pluginName: pluginName, specId: spec.id)
                        .effectiveKey(),
                    isSet: savedIds.contains(spec.id),
                    value: Binding(
                        get: { secretValues[spec.id] ?? "" },
                        set: { newValue in
                            secretValues[spec.id] = newValue
                            // Clear validation error when user types
                            validationErrors.remove(spec.id)
                        }
                    ),
                    hasError: validationErrors.contains(spec.id),
                    theme: theme
                )
            }
        }
        .settingsChrome(.card)
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        SettingsSheetFooter(
            primary: .init(label: "Save", handler: save),
            secondary: .init(label: "Cancel") { dismiss() },
            warning: validationErrors.isEmpty ? nil : L("Please fill in all required fields")
        )
    }

    // MARK: - Actions

    private func loadExistingSecrets() {
        savedIds = Set(
            secrets.filter {
                PluginCredentials.isSatisfied(pluginId: pluginId, specId: $0.id, agentId: agentId)
            }.map(\.id))
    }

    private func save() {
        let errors = Set(
            secrets.filter { spec in
                spec.required && !savedIds.contains(spec.id)
                    && (secretValues[spec.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
            }.map(\.id))
        if !errors.isEmpty {
            withAnimation(theme.motion.springAnimation) {
                validationErrors = errors
            }
            return
        }

        for spec in secrets {
            let value = secretValues[spec.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { continue }
            let outcome = PluginCredentials.save(value, pluginId: pluginId, specId: spec.id, agentId: agentId)
            if let failure = outcome.failureDescription {
                _ = ToastManager.shared.error(failure)
                return
            }
        }

        onSave()
        dismiss()
    }
}

// MARK: - Secret Field Row

private struct SecretFieldRow: View {
    let spec: PluginManifest.SecretSpec
    let key: String
    let isSet: Bool
    @Binding var value: String
    let hasError: Bool
    let theme: ThemeProtocol

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            // Label
            HStack(spacing: theme.space.s6) {
                Text(spec.label)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)

                if spec.required {
                    Text("*")
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.status.error.foreground)
                }

                Spacer()

                // External link button
                if let urlString = spec.url, let url = URL(string: urlString) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: theme.space.s4) {
                            Text("Get Key", bundle: .module)
                                .font(SettingsFont.smallLabel)
                            Image(systemName: "arrow.up.right")
                                .glyphSize(.tiny, weight: .semibold)
                        }
                        .foregroundColor(theme.text.link)
                        .padding(.horizontal, theme.space.s8)
                        .padding(.vertical, theme.space.s6)
                        .settingsChrome(.selected)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            // Description with markdown support
            if let description = spec.description {
                DescriptionText(text: description, theme: theme)
            }

            CredentialField(
                key: key,
                isSet: isSet,
                value: $value,
                placeholder: L("Enter \(spec.label.lowercased())..."),
                isInvalid: hasError
            )

            // Error message
            if hasError {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .glyphSize(.micro)
                    Text("This field is required", bundle: .module)
                        .font(SettingsFont.rowDescription)
                }
                .foregroundColor(theme.status.error.foreground)
            }
        }
        .padding(theme.space.s16)
    }
}

// MARK: - Description Text with Markdown Links

private struct DescriptionText: View {
    let text: String
    let theme: ThemeProtocol

    var body: some View {
        // Shared renderer: parses `[label](url)` and opens taps in the browser.
        MarkdownLinkText(
            markdown: text,
            style: .caption,
            textColor: theme.text.secondary
        )
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        ToolSecretsSheet(
            pluginId: "dev.example.weather",
            agentId: nil,
            pluginName: "Weather Plugin",
            pluginVersion: "1.0.0",
            secrets: [
                PluginManifest.SecretSpec(
                    id: "api_key",
                    label: "OpenWeather API Key",
                    description: "Get your API key from [OpenWeather](https://openweathermap.org/api)",
                    required: true,
                    url: "https://openweathermap.org/api"
                ),
                PluginManifest.SecretSpec(
                    id: "backup_key",
                    label: "Backup API Key",
                    description: "Optional backup key for failover",
                    required: false,
                    url: nil
                ),
            ],
            onSave: {}
        )
    }
#endif

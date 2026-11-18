//
//  ClaudePluginUserConfigSheet.swift
//  osaurus
//
//  Prompts the user for the `userConfig` values declared by a Claude
//  plugin's `plugin.json`. Modelled on `ToolSecretsSheet` so it feels
//  at home in the Plugins surface. Persists non-sensitive values to
//  `ClaudePluginManifestStore.saveUserConfig`; sensitive ones go to
//  the Keychain via `ClaudePluginInstaller.writeSensitiveUserConfig`
//  (which honours the keychain-disabled gate).
//

import AppKit
import SwiftUI

struct ClaudePluginUserConfigSheet: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let pluginId: String
    let pluginName: String
    let pluginVersion: String?
    let fields: [ClaudePluginUserConfigField]
    let onSave: () -> Void

    @State private var values: [String: String] = [:]
    @State private var validationErrors: Set<String> = []
    @State private var hasAppeared: Bool = false

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s20) {
                    infoCard
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)
                    fieldsForm
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)
                }
                .padding(theme.settingsSheetInset)
            }
            footer
        }
        .frame(width: SettingsSheetWidth.regular, height: min(420 + CGFloat(fields.count) * 80, 640))
        .settingsSheetSurface()
        .onAppear {
            loadExistingValues()
            withAnimation { hasAppeared = true }
        }
    }

    // MARK: - Sections

    private var header: some View {
        SettingsSheetHeader(
            icon: "slider.horizontal.3",
            title: "Configure Plugin",
            subtitleText: pluginVersion.map { "\(pluginName) · v\($0)" } ?? pluginName,
            onClose: { dismiss() }
        )
    }

    private var infoCard: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: "info.circle.fill")
                .glyphSize(.medium)
                .foregroundColor(theme.status.info.foreground)
            Text(
                "This plugin declared configuration options. Non-sensitive values are stored locally; sensitive ones are kept in the system Keychain.",
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

    private var fieldsForm: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            ForEach(Array(fields.enumerated()), id: \.element.key) { index, field in
                if index > 0 {
                    ThemeHairlineDivider()
                        .padding(.horizontal, theme.space.s16)
                }
                UserConfigFieldRow(
                    field: field,
                    value: Binding(
                        get: { values[field.key] ?? "" },
                        set: { newValue in
                            values[field.key] = newValue
                            validationErrors.remove(field.key)
                        }
                    ),
                    hasError: validationErrors.contains(field.key),
                    theme: theme
                )
            }
        }
        .settingsChrome(.card)
    }

    private var footer: some View {
        SettingsSheetFooter(
            primary: .init(label: "Save", handler: save),
            secondary: .init(label: "Cancel") { dismiss() },
            warning: validationErrors.isEmpty ? nil : L("Please fill in all required fields")
        )
    }

    // MARK: - Actions

    private func loadExistingValues() {
        let nonSensitive = ClaudePluginManifestStore.loadUserConfig(pluginId: pluginId)
        for field in fields {
            if field.sensitive {
                // Sensitive values are not shown back to the user — the
                // field appears empty unless they re-type. Same behaviour
                // ToolSecretsSheet uses for secret rotation.
                continue
            }
            if let v = nonSensitive[field.key] {
                values[field.key] = v
            } else if let d = field.defaultValue {
                values[field.key] = d
            }
        }
    }

    private func save() {
        var errors: Set<String> = []
        for field in fields where field.required {
            let v = (values[field.key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty {
                errors.insert(field.key)
            }
        }
        if !errors.isEmpty {
            withAnimation(theme.motion.springAnimation) {
                validationErrors = errors
            }
            return
        }

        var nonSensitiveValues: [String: String] = [:]
        for field in fields {
            let raw = (values[field.key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if field.sensitive {
                if !raw.isEmpty {
                    _ = ClaudePluginInstaller.writeSensitiveUserConfig(
                        pluginId: pluginId,
                        key: field.key,
                        value: raw
                    )
                }
            } else {
                if !raw.isEmpty {
                    nonSensitiveValues[field.key] = raw
                }
            }
        }
        _ = ClaudePluginManifestStore.saveUserConfig(
            pluginId: pluginId,
            values: nonSensitiveValues
        )

        onSave()
        dismiss()
    }
}

// MARK: - Field Row

private struct UserConfigFieldRow: View {
    let field: ClaudePluginUserConfigField
    @Binding var value: String
    let hasError: Bool
    let theme: ThemeProtocol

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(spacing: theme.space.s6) {
                Text(field.title)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                if field.required {
                    Text("*")
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.status.error.foreground)
                }
                Spacer()
                fieldKindBadge
            }

            if !field.description.isEmpty {
                Text(field.description)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputField
        }
        .padding(theme.space.s16)
    }

    @ViewBuilder
    private var fieldKindBadge: some View {
        let badge: String = {
            switch field.type {
            case .string: return field.sensitive ? "Secret" : "Text"
            case .number: return "Number"
            case .boolean: return "Boolean"
            case .directory: return "Directory"
            case .file: return "File"
            }
        }()
        StatusChip(badge, tone: .neutral)
    }

    @ViewBuilder
    private var inputField: some View {
        switch field.type {
        case .boolean:
            HStack {
                Toggle(
                    isOn: Binding(
                        get: { value.lowercased() == "true" },
                        set: { value = $0 ? "true" : "false" }
                    )
                ) {
                    Text(value.lowercased() == "true" ? "Enabled" : "Disabled", bundle: .module)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                }
                .settingsSwitch(showsLabel: true)
                Spacer()
            }
        case .directory, .file:
            HStack(spacing: theme.space.s8) {
                placeholderTextField
                Button(action: pickPath) {
                    Label(L("Choose…"), systemImage: "folder")
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
            }
        case .string where field.sensitive:
            SettingsTextField(
                placeholder: L("Enter \(field.title.lowercased())…"),
                text: $value,
                monospaced: true,
                isSecure: true,
                revealable: true,
                isInvalid: hasError
            )
        case .string, .number:
            placeholderTextField
        }
    }

    private var placeholderTextField: some View {
        SettingsTextField(
            placeholder: L("Enter \(field.title.lowercased())…"),
            text: $value,
            monospaced: true,
            isInvalid: hasError
        )
    }

    private func pickPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = field.type == .directory
        panel.canChooseFiles = field.type == .file
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                value = url.path
            }
        }
    }
}

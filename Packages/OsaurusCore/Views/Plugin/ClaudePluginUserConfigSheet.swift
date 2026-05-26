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
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    infoCard
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)
                    fieldsForm
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 520, height: min(420 + CGFloat(fields.count) * 80, 640))
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            loadExistingValues()
            withAnimation { hasAppeared = true }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.2),
                                theme.accentColor.opacity(0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.7),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Configure Plugin", bundle: .module)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                HStack(spacing: 6) {
                    Text(pluginName)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    if let version = pluginVersion {
                        Text("v\(version)", bundle: .module)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            theme.secondaryBackground
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var infoCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.infoColor)
            Text(
                "This plugin declared configuration options. Non-sensitive values are stored locally; sensitive ones are kept in the system Keychain.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.infoColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.infoColor.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var fieldsForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.key) { index, field in
                if index > 0 {
                    Rectangle()
                        .fill(theme.cardBorder)
                        .frame(height: 1)
                        .padding(.horizontal, 16)
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
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !validationErrors.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                    Text("Please fill in all required fields", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                }
            }
            Spacer()
            Button(action: { dismiss() }) {
                Text("Cancel", bundle: .module)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .buttonStyle(PlainButtonStyle())

            Button(action: save) {
                Text("Save", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .top
                )
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
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
    @State private var showValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(field.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                if field.required {
                    Text("*")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(theme.errorColor)
                }
                Spacer()
                fieldKindBadge
            }

            if !field.description.isEmpty {
                Text(field.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputField
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    hasError
                                        ? theme.errorColor
                                        : (isFocused
                                            ? theme.accentColor.opacity(0.6)
                                            : theme.inputBorder),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .padding(16)
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
        Text(badge)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.tertiaryBackground))
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
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                .toggleStyle(.switch)
                Spacer()
            }
        case .directory, .file:
            HStack(spacing: 8) {
                placeholderTextField
                Button(action: pickPath) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.accentColor.opacity(0.12)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        case .string where field.sensitive:
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if value.isEmpty {
                        Text("Enter \(field.title.lowercased())…", bundle: .module)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                    if showValue {
                        TextField("", text: $value)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                    } else {
                        SecureField("", text: $value)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                    }
                }
                Button(action: { showValue.toggle() }) {
                    Image(systemName: showValue ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(PlainButtonStyle())
            }
        case .string, .number:
            placeholderTextField
        }
    }

    private var placeholderTextField: some View {
        ZStack(alignment: .leading) {
            if value.isEmpty {
                Text("Enter \(field.title.lowercased())…", bundle: .module)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.placeholderText)
                    .allowsHitTesting(false)
            }
            TextField("", text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.primaryText)
        }
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

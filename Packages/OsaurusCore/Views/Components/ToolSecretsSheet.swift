//
//  ToolSecretsSheet.swift
//  osaurus
//
//  Sheet for configuring plugin secrets (API keys, tokens, etc.).
//

import AppKit
import SwiftUI

// MARK: - Main View

struct ToolSecretsSheet: View {
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var theme: ThemeProtocol { themeManager.currentTheme }

    let pluginId: String
    let pluginName: String
    let pluginVersion: String?
    let secrets: [PluginManifest.SecretSpec]
    let onSave: () -> Void

    // State for secret values
    @State private var secretValues: [String: String] = [:]
    @State private var validationErrors: Set<String> = []
    @State private var hasAppeared: Bool = false

    init(
        pluginId: String,
        pluginName: String,
        pluginVersion: String? = nil,
        secrets: [PluginManifest.SecretSpec],
        onSave: @escaping () -> Void
    ) {
        self.pluginId = pluginId
        self.pluginName = pluginName
        self.pluginVersion = pluginVersion
        self.secrets = secrets
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sheetHeader

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Info card
                    infoCard
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)

                    // Secrets form
                    secretsForm
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 10)
                }
                .padding(20)
            }

            // Footer
            sheetFooter
        }
        .frame(width: 500, height: min(400 + CGFloat(secrets.count) * 80, 600))
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
            loadExistingSecrets()
            withAnimation {
                hasAppeared = true
            }
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            // Icon with gradient background
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
                Image(systemName: "key.fill")
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
                Text("Configure Secrets")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 6) {
                    Text(pluginName)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    if let version = pluginVersion {
                        Text("v\(version)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )
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

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.infoColor)

            Text(
                "This plugin requires credentials to function. Your secrets are stored securely in the system Keychain."
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

    // MARK: - Secrets Form

    private var secretsForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(secrets.enumerated()), id: \.element.id) { index, spec in
                if index > 0 {
                    Rectangle()
                        .fill(theme.cardBorder)
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                }

                SecretFieldRow(
                    spec: spec,
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
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            // Validation message
            if !validationErrors.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.errorColor)
                    Text("Please fill in all required fields")
                        .font(.system(size: 12))
                        .foregroundColor(theme.errorColor)
                }
            }

            Spacer()

            // Cancel button
            Button(action: { dismiss() }) {
                Text("Cancel")
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

            // Save button
            Button(action: save) {
                Text("Save")
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

    private func loadExistingSecrets() {
        for spec in secrets {
            if let existingValue = ToolSecretsKeychain.getSecret(id: spec.id, for: pluginId) {
                secretValues[spec.id] = existingValue
            }
        }
    }

    private func save() {
        // Validate required fields
        var errors: Set<String> = []
        for spec in secrets where spec.required {
            let value = secretValues[spec.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty {
                errors.insert(spec.id)
            }
        }

        if !errors.isEmpty {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                validationErrors = errors
            }
            return
        }

        // Save all secrets to Keychain
        for spec in secrets {
            let value = secretValues[spec.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty {
                ToolSecretsKeychain.saveSecret(value, id: spec.id, for: pluginId)
            } else {
                // Delete empty optional secrets
                ToolSecretsKeychain.deleteSecret(id: spec.id, for: pluginId)
            }
        }

        onSave()
        dismiss()
    }
}

// MARK: - Secret Field Row

private struct SecretFieldRow: View {
    let spec: PluginManifest.SecretSpec
    @Binding var value: String
    let hasError: Bool
    let theme: ThemeProtocol

    @State private var isFocused = false
    @State private var showValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Label
            HStack(spacing: 6) {
                Text(spec.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                if spec.required {
                    Text("*")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(theme.errorColor)
                }

                Spacer()

                // External link button
                if let urlString = spec.url, let url = URL(string: urlString) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        HStack(spacing: 4) {
                            Text("Get Key")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.accentColor.opacity(0.1))
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            // Description with markdown support
            if let description = spec.description {
                DescriptionText(text: description, theme: theme)
            }

            // Secret input field
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if value.isEmpty {
                        Text("Enter \(spec.label.lowercased())...")
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

                // Toggle visibility button
                Button(action: { showValue.toggle() }) {
                    Image(systemName: showValue ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .help(showValue ? "Hide value" : "Show value")
            }
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
                                    : isFocused
                                        ? theme.accentColor.opacity(0.5)
                                        : theme.inputBorder,
                                lineWidth: hasError || isFocused ? 1.5 : 1
                            )
                    )
            )

            // Error message
            if hasError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text("This field is required")
                        .font(.system(size: 11))
                }
                .foregroundColor(theme.errorColor)
            }
        }
        .padding(16)
    }
}

// MARK: - Description Text with Markdown Links

private struct DescriptionText: View {
    let text: String
    let theme: ThemeProtocol

    var body: some View {
        if let attributedString = parseMarkdownLinks(text) {
            Text(attributedString)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    }
                )
        } else {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
    }

    /// Parses markdown-style links [text](url) into AttributedString
    private func parseMarkdownLinks(_ input: String) -> AttributedString? {
        var result = AttributedString(input)

        // Pattern to match [text](url)
        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, options: [], range: nsRange)

        // Process matches in reverse order to preserve ranges
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: input),
                let textRange = Range(match.range(at: 1), in: input),
                let urlRange = Range(match.range(at: 2), in: input),
                let url = URL(string: String(input[urlRange]))
            else {
                continue
            }

            let linkText = String(input[textRange])

            // Create attributed string for the link
            var linkString = AttributedString(linkText)
            linkString.foregroundColor = Color.accentColor
            linkString.link = url

            // Replace the markdown syntax with the linked text
            if let attrRange = result.range(of: String(input[fullRange])) {
                result.replaceSubrange(attrRange, with: linkString)
            }
        }

        return result
    }
}

#Preview {
    ToolSecretsSheet(
        pluginId: "dev.example.weather",
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

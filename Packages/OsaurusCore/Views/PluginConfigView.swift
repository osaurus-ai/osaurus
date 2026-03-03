//
//  PluginConfigView.swift
//  osaurus
//
//  Declarative configuration UI for plugins, rendered from PluginManifest.ConfigSpec.
//

import SwiftUI

// MARK: - Main Config View

struct PluginConfigView: View {
    @Environment(\.theme) private var theme

    let pluginId: String
    let configSpec: PluginManifest.ConfigSpec
    let plugin: ExternalPlugin?

    @State private var values: [String: String] = [:]
    @State private var errors: [String: String] = [:]
    @State private var isDirty = false
    @State private var focusedField: String?

    @State private var saveIndicator: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(configSpec.sections.enumerated()), id: \.offset) { _, section in
                configSection(section)
            }

            if isDirty {
                HStack {
                    Spacer()

                    if let indicator = saveIndicator {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text(indicator)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.successColor)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    Button {
                        saveConfig()
                        withAnimation { saveIndicator = "Saved" }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { saveIndicator = nil }
                        }
                    } label: {
                        Text("Save Changes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .onAppear { loadConfig() }
    }

    // MARK: - Section

    @ViewBuilder
    private func configSection(_ section: PluginManifest.ConfigSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(section.title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(spacing: 14) {
                ForEach(Array(section.fields.enumerated()), id: \.offset) { idx, field in
                    if idx > 0 {
                        Divider().opacity(0.3)
                    }
                    configField(field)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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

    // MARK: - Field Dispatch

    @ViewBuilder
    private func configField(_ field: PluginManifest.ConfigField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case .text:
                textField(field)
            case .secret:
                secretField(field)
            case .toggle:
                toggleField(field)
            case .select:
                selectField(field)
            case .multiselect:
                multiselectField(field)
            case .number:
                numberField(field)
            case .readonly:
                readonlyField(field)
            case .status:
                statusField(field)
            }

            if let error = errors[field.key] {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Text Field

    @ViewBuilder
    private func textField(_ field: PluginManifest.ConfigField) -> some View {
        let isFocused = focusedField == field.key
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if (values[field.key] ?? field.default?.stringValue ?? "").isEmpty {
                        Text(field.placeholder ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                    TextField(
                        "",
                        text: binding(for: field.key, default: field.default?.stringValue ?? ""),
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                focusedField = editing ? field.key : nil
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                errors[field.key] != nil
                                    ? Color.red.opacity(0.5)
                                    : isFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }

    // MARK: - Secret Field

    @ViewBuilder
    private func secretField(_ field: PluginManifest.ConfigField) -> some View {
        let isFocused = focusedField == field.key
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Text(field.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if (values[field.key] ?? "").isEmpty {
                        Text(field.placeholder ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                    SecureField(
                        "",
                        text: binding(for: field.key, default: "")
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .onSubmit {
                        withAnimation(.easeOut(duration: 0.15)) {
                            focusedField = nil
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                errors[field.key] != nil
                                    ? Color.red.opacity(0.5)
                                    : isFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }

    // MARK: - Toggle Field

    @ViewBuilder
    private func toggleField(_ field: PluginManifest.ConfigField) -> some View {
        let defaultVal = field.default?.stringValue ?? "false"
        HStack {
            Text(field.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (values[field.key] ?? defaultVal) == "true" },
                    set: { newVal in
                        values[field.key] = newVal ? "true" : "false"
                        isDirty = true
                    }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Select Field

    @ViewBuilder
    private func selectField(_ field: PluginManifest.ConfigField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Picker("", selection: binding(for: field.key, default: field.default?.stringValue ?? "")) {
                ForEach(field.options ?? [], id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: - Multiselect Field

    @ViewBuilder
    private func multiselectField(_ field: PluginManifest.ConfigField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(field.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            let selectedValues = parseMultiselectValues(values[field.key] ?? field.default?.stringValue ?? "[]")

            VStack(spacing: 0) {
                ForEach(Array((field.options ?? []).enumerated()), id: \.element.value) { idx, option in
                    if idx > 0 {
                        Divider().opacity(0.3)
                    }
                    Toggle(
                        isOn: Binding(
                            get: { selectedValues.contains(option.value) },
                            set: { isOn in
                                var current = selectedValues
                                if isOn { current.insert(option.value) } else { current.remove(option.value) }
                                let arr = Array(current)
                                let data = (try? JSONSerialization.data(withJSONObject: arr)) ?? Data()
                                values[field.key] = String(data: data, encoding: .utf8) ?? "[]"
                                isDirty = true
                            }
                        )
                    ) {
                        Text(option.label)
                            .font(.system(size: 12))
                            .foregroundColor(theme.primaryText)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Number Field

    @ViewBuilder
    private func numberField(_ field: PluginManifest.ConfigField) -> some View {
        let isFocused = focusedField == field.key
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if (values[field.key] ?? field.default?.stringValue ?? "").isEmpty {
                        Text(field.placeholder ?? "0")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                    TextField(
                        "",
                        text: binding(for: field.key, default: field.default?.stringValue ?? ""),
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                focusedField = editing ? field.key : nil
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                errors[field.key] != nil
                                    ? Color.red.opacity(0.5)
                                    : isFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
        }
    }

    // MARK: - Readonly Field

    @ViewBuilder
    private func readonlyField(_ field: PluginManifest.ConfigField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)

            HStack {
                let displayValue = resolveTemplate(field.value_template ?? "", pluginId: pluginId)
                Text(displayValue)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)

                Spacer()

                if field.copyable == true {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayValue, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Status Field

    @ViewBuilder
    private func statusField(_ field: PluginManifest.ConfigField) -> some View {
        let isConnected: Bool = {
            guard let connKey = field.connected_when else { return false }
            return values[connKey] != nil && !(values[connKey]?.isEmpty ?? true)
        }()

        HStack(spacing: 12) {
            Text(field.label)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(isConnected ? Color.green : theme.tertiaryText.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(isConnected ? "Connected" : "Not Connected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isConnected ? .green : theme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isConnected ? Color.green.opacity(0.1) : theme.tertiaryBackground)
            )

            if isConnected {
                if let disconnectAction = field.disconnect_action {
                    Button {
                        if let keys = disconnectAction.clear_keys {
                            for key in keys {
                                values.removeValue(forKey: key)
                                ToolSecretsKeychain.deleteSecret(id: key, for: pluginId)
                            }
                        }
                        isDirty = false
                    } label: {
                        Text("Disconnect")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red.opacity(0.1))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            } else {
                if let connectAction = field.connect_action,
                    connectAction.type == "oauth",
                    let routeId = connectAction.url_route
                {
                    Button {
                        let port = Self.loadServerPort()
                        let url = URL(string: "http://127.0.0.1:\(port)/plugins/\(pluginId)/\(routeId)")!
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("Connect")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(theme.accentColor)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    // MARK: - Helpers

    private func binding(for key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? defaultValue },
            set: { newValue in
                values[key] = newValue
                isDirty = true
                validateField(key: key)
            }
        )
    }

    private func loadConfig() {
        let allSecrets = ToolSecretsKeychain.getAllSecrets(for: pluginId)
        values = allSecrets

        // Apply defaults for fields not yet set
        for section in configSpec.sections {
            for field in section.fields {
                if values[field.key] == nil, let def = field.default {
                    values[field.key] = def.stringValue
                }
            }
        }
    }

    private func saveConfig() {
        var hasErrors = false
        for section in configSpec.sections {
            for field in section.fields {
                if !validateField(key: field.key) {
                    hasErrors = true
                }
            }
        }
        guard !hasErrors else { return }

        for (key, value) in values {
            ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId)
            plugin?.notifyConfigChanged(key: key, value: value)
        }
        isDirty = false
    }

    @discardableResult
    private func validateField(key: String) -> Bool {
        guard let field = findField(key: key) else { return true }
        guard let validation = field.validation else {
            errors.removeValue(forKey: key)
            return true
        }

        let value = values[key] ?? ""

        if validation.required == true && value.isEmpty {
            errors[key] = "\(field.label) is required"
            return false
        }

        if let minLen = validation.min_length, value.count < minLen {
            errors[key] = "\(field.label) must be at least \(minLen) characters"
            return false
        }

        if let maxLen = validation.max_length, value.count > maxLen {
            errors[key] = "\(field.label) must be at most \(maxLen) characters"
            return false
        }

        if let pattern = validation.pattern,
            let regex = try? NSRegularExpression(pattern: pattern),
            regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil
        {
            errors[key] = validation.pattern_hint ?? "Invalid format"
            return false
        }

        if field.type == .number, let numVal = Double(value) {
            if let min = validation.min, numVal < min {
                errors[key] = "\(field.label) must be at least \(min)"
                return false
            }
            if let max = validation.max, numVal > max {
                errors[key] = "\(field.label) must be at most \(max)"
                return false
            }
        }

        errors.removeValue(forKey: key)
        return true
    }

    private func findField(key: String) -> PluginManifest.ConfigField? {
        for section in configSpec.sections {
            if let field = section.fields.first(where: { $0.key == key }) {
                return field
            }
        }
        return nil
    }

    private func resolveTemplate(_ template: String, pluginId: String) -> String {
        let port = Self.loadServerPort()
        var result = template
        result = result.replacingOccurrences(of: "{{plugin_url}}", with: "http://127.0.0.1:\(port)/plugins/\(pluginId)")
        result = result.replacingOccurrences(of: "{{plugin_id}}", with: pluginId)

        let tunnelURL = ToolSecretsKeychain.getSecret(id: "tunnel_url", for: pluginId) ?? ""
        result = result.replacingOccurrences(of: "{{tunnel_url}}", with: tunnelURL)

        let configPattern = try? NSRegularExpression(pattern: #"\{\{config\.(\w+)\}\}"#)
        if let matches = configPattern?.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            for match in matches.reversed() {
                if let keyRange = Range(match.range(at: 1), in: result) {
                    let key = String(result[keyRange])
                    let value = values[key] ?? ""
                    if let fullRange = Range(match.range, in: result) {
                        result.replaceSubrange(fullRange, with: value)
                    }
                }
            }
        }

        return result
    }

    private func parseMultiselectValues(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return Set(arr)
    }

    private static func loadServerPort() -> Int {
        let url = OsaurusPaths.serverConfigFile()
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(ServerConfiguration.self, from: data)
        else { return 1337 }
        return config.port
    }
}

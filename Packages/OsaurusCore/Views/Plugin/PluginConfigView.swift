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
    let agentId: UUID
    let configSpec: PluginManifest.ConfigSpec
    let plugin: ExternalPlugin?

    @State private var values: [String: String] = [:]
    @State private var errors: [String: String] = [:]
    @State private var isDirty = false
    @State private var editedSecrets: Set<String> = []

    @State private var saveIndicator: String?

    /// Hash of the last `(key, value)` snapshot we delivered to the plugin
    /// from `loadConfig()`. Used to skip redundant `notifyConfigBatch`
    /// calls when the user opens the config sheet without anything having
    /// changed. The host-side `lastDeliveredConfig` lock would short-circuit
    /// these anyway; this just avoids building the change array.
    @State private var lastDeliveredHash: Int?
    /// Keychain-backed template inputs, loaded once in `loadConfig`. Readonly
    /// fields resolve their `value_template` on every body evaluation, and a
    /// synchronous `SecItemCopyMatching` per render can stall for seconds
    /// under securityd contention (a recurring app-hang source).
    @State private var cachedTunnelURL: String = ""
    @State private var cachedServerPort: Int = 0
    /// Saved values of secret fields. Delivered to the plugin but never put
    /// in the form; a blank secret field keeps the saved value.
    @State private var secretValues: [String: String] = [:]
    /// Keys-page names of the declared secrets, for the field hint.
    @State private var keyNames: [String: String] = [:]

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
                                .glyphSize(10)
                            Text(indicator)
                                .font(SettingsFont.smallLabel)
                        }
                        .foregroundColor(theme.status.success.foreground)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    Button {
                        saveConfig()
                        withAnimation { saveIndicator = "Saved" }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { saveIndicator = nil }
                        }
                    } label: {
                        Text("Save Changes", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.primary)
                }
                .padding(.top, theme.space.s4)
            }
        }
        .onAppear { loadConfig() }
        .onReceive(NotificationCenter.default.publisher(for: .pluginConfigDidChange)) { note in
            guard let info = note.userInfo,
                let id = info["pluginId"] as? String, id == pluginId,
                let key = info["key"] as? String
            else { return }
            if findField(key: key)?.type == .secret {
                secretValues[key] = info["value"] as? String
            } else {
                values[key] = info["value"] as? String
            }
        }
    }

    // MARK: - Section

    private func configSection(_ section: PluginManifest.ConfigSection) -> some View {
        SettingsSection(title: section.title, verbatimTitle: true) {
            ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                configField(field)
            }
        }
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
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.error.foreground)
            }
        }
        .padding(.vertical, field.type.isStacked ? theme.space.s8 : 0)
    }

    // MARK: - Text Field

    private func textField(_ field: PluginManifest.ConfigField) -> some View {
        SettingsFieldRow(label: field.label, verbatimLabel: true) {
            SettingsTextField(
                placeholder: field.placeholder ?? "",
                text: binding(for: field.key, default: field.default?.stringValue ?? ""),
                isInvalid: errors[field.key] != nil
            )
        }
    }

    // MARK: - Secret Field

    @ViewBuilder
    private func secretField(_ field: PluginManifest.ConfigField) -> some View {
        SettingsFieldRow(label: field.label, verbatimLabel: true) {
            if let keyName = keyNames[field.key] {
                CredentialField(
                    key: keyName,
                    isSet: hasStoredSecret(field.key),
                    value: binding(for: field.key, trackSecretEdit: true),
                    placeholder: field.placeholder ?? "",
                    isInvalid: errors[field.key] != nil
                )
            } else {
                SettingsTextField(
                    placeholder: hasStoredSecret(field.key) ? L("Unchanged") : (field.placeholder ?? ""),
                    text: binding(for: field.key, trackSecretEdit: true),
                    icon: "key.fill",
                    isSecure: true,
                    isInvalid: errors[field.key] != nil
                )
            }
        }
    }

    // MARK: - Toggle Field

    private func toggleField(_ field: PluginManifest.ConfigField) -> some View {
        let defaultVal = field.default?.stringValue ?? "false"
        return SettingsToggle(
            title: field.label,
            verbatim: true,
            isOn: Binding(
                get: { (values[field.key] ?? defaultVal) == "true" },
                set: { newVal in
                    values[field.key] = newVal ? "true" : "false"
                    isDirty = true
                }
            )
        )
    }

    // MARK: - Select Field

    private func selectField(_ field: PluginManifest.ConfigField) -> some View {
        SettingsRow(title: field.label, description: "", verbatimTitle: true) {
            SettingsMenuPicker(selection: binding(for: field.key, default: field.default?.stringValue ?? "")) {
                ForEach(field.options ?? [], id: \.value) { option in
                    Text(verbatim: option.label).tag(option.value)
                }
            }
        }
    }

    // MARK: - Multiselect Field

    private func multiselectField(_ field: PluginManifest.ConfigField) -> some View {
        let selectedValues = parseMultiselectValues(values[field.key] ?? field.default?.stringValue ?? "[]")
        return SettingsFieldRow(label: field.label, verbatimLabel: true) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                ForEach(field.options ?? [], id: \.value) { option in
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
                        Text(verbatim: option.label)
                            .font(SettingsFont.body)
                            .foregroundColor(theme.text.primary)
                    }
                    .settingsCheckbox()
                }
            }
        }
    }

    // MARK: - Number Field

    private func numberField(_ field: PluginManifest.ConfigField) -> some View {
        SettingsFieldRow(label: field.label, verbatimLabel: true) {
            SettingsTextField(
                placeholder: field.placeholder ?? "0",
                text: binding(for: field.key, default: field.default?.stringValue ?? ""),
                monospaced: true,
                isInvalid: errors[field.key] != nil
            )
        }
    }

    // MARK: - Readonly Field

    private func readonlyField(_ field: PluginManifest.ConfigField) -> some View {
        SettingsValueRow(
            title: field.label,
            value: resolveTemplate(field.value_template ?? "", pluginId: pluginId),
            monospaced: true,
            copyable: field.copyable == true,
            verbatimTitle: true
        )
    }

    // MARK: - Status Field

    @ViewBuilder
    private func statusField(_ field: PluginManifest.ConfigField) -> some View {
        let isConnected: Bool = {
            guard let connKey = field.connected_when else { return false }
            return values[connKey]?.isEmpty == false || secretValues[connKey]?.isEmpty == false
        }()

        SettingsRow(title: field.label, description: "", verbatimTitle: true) {
            HStack(spacing: theme.space.s8) {
                StatusChip(
                    isConnected ? L("Connected") : L("Not Connected"),
                    tone: isConnected ? .success : .neutral,
                    showsDot: true
                )
                statusAction(field, isConnected: isConnected)
            }
        }
    }

    @ViewBuilder
    private func statusAction(_ field: PluginManifest.ConfigField, isConnected: Bool) -> some View {
        if isConnected {
            if let disconnectAction = field.disconnect_action {
                Button {
                    if let keys = disconnectAction.clear_keys {
                        for key in keys {
                            values.removeValue(forKey: key)
                            secretValues.removeValue(forKey: key)
                        }
                        let pluginId = pluginId
                        let agentId = agentId
                        let plugin = plugin
                        Task { @MainActor in
                            await CredentialStore.current.perform { store in
                                for key in keys
                                where !PluginCredentials.configWrite(
                                    pluginId: pluginId, key: key, value: nil, agentId: agentId, store: store)
                                {
                                    _ = ToolSecretsKeychain.deleteSecret(id: key, for: pluginId, agentId: agentId)
                                }
                            }
                            // Without notifying the plugin, its in-memory
                            // state (HTTP clients, webhook registrations,
                            // OAuth tokens) keeps using the now-deleted
                            // credentials until the next launch. Push the
                            // cleared keys as empty strings so the plugin
                            // can deregister / drop caches synchronously.
                            let cleared: [(key: String, value: String)] =
                                keys.map { (key: $0, value: "") }
                            plugin?.notifyConfigBatch(cleared, agentId: agentId)
                        }
                    }
                    isDirty = false
                } label: {
                    Text("Disconnect", bundle: .module)
                }
                .assignedSettingsButtonStyle(.destructive, size: .compact)
            }
        } else {
            if let connectAction = field.connect_action,
                connectAction.type == "oauth",
                let routeId = connectAction.url_route
            {
                Button {
                    let base = Self.resolveBaseURL(for: pluginId, agentId: agentId)
                    let urlString = "\(base)/plugins/\(pluginId)/\(routeId)"
                    guard let url = URL(string: urlString) else {
                        NSLog(
                            "[PluginConfigView] Skipping OAuth connect — malformed URL: %@",
                            urlString
                        )
                        return
                    }
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Connect", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
            }
        }
    }

    // MARK: - Helpers

    private func binding(
        for key: String,
        default defaultValue: String = "",
        trackSecretEdit: Bool = false
    ) -> Binding<String> {
        Binding(
            get: { values[key] ?? defaultValue },
            set: { newValue in
                values[key] = newValue
                if trackSecretEdit {
                    guard !newValue.isEmpty else {
                        validateField(key: key)
                        return
                    }
                    editedSecrets.insert(key)
                }
                isDirty = true
                validateField(key: key)
            }
        )
    }

    private func hasStoredSecret(_ key: String) -> Bool {
        !editedSecrets.contains(key) && secretValues[key]?.isEmpty == false
    }

    /// The manifest facts `readConfig` needs, without the non-Sendable spec.
    private struct FieldInfo: Sendable {
        let key: String
        let isSecret: Bool
        let loadsStoredValue: Bool
        let connectedWhen: String?
        let defaultValue: String?
    }

    private struct LoadedConfig: Sendable {
        var tunnelURL = ""
        var serverPort = 0
        var values: [String: String] = [:]
        var secretValues: [String: String] = [:]
        var keyNames: [String: String] = [:]
    }

    /// Declared secrets come from Keys; other fields are plugin config.
    nonisolated private static func storedValue(
        _ key: String, pluginId: String, agentId: UUID, store: CredentialStore
    ) -> String? {
        if PluginCredentials.isDeclaredSecret(pluginId: pluginId, key: key) {
            return PluginCredentials.value(pluginId: pluginId, specId: key, agentId: agentId, store: store)
        }
        return ToolSecretsKeychain.getSecret(id: key, for: pluginId, agentId: agentId)
    }

    /// Every Keychain and disk read the form needs. Runs off the main thread.
    nonisolated private static func readConfig(
        pluginId: String, agentId: UUID, fields: [FieldInfo], store: CredentialStore
    ) -> LoadedConfig {
        var loaded = LoadedConfig()
        loaded.tunnelURL = ToolSecretsKeychain.getSecret(id: "tunnel_url", for: pluginId, agentId: agentId) ?? ""
        loaded.serverPort = loadServerPort()
        let secretKeys = Set(fields.filter(\.isSecret).map(\.key))
        for (key, value) in ToolSecretsKeychain.getAllSecrets(for: pluginId, agentId: agentId)
        where !PluginCredentials.isDeclaredSecret(pluginId: pluginId, key: key) {
            if secretKeys.contains(key) { loaded.secretValues[key] = value } else { loaded.values[key] = value }
        }
        for field in fields {
            if field.isSecret {
                if PluginCredentials.isDeclaredSecret(pluginId: pluginId, key: field.key) {
                    loaded.keyNames[field.key] = PluginCredentials.slot(pluginId: pluginId, specId: field.key)
                        .effectiveKey(in: store)
                }
                if loaded.secretValues[field.key] == nil,
                    let value = storedValue(field.key, pluginId: pluginId, agentId: agentId, store: store)
                {
                    loaded.secretValues[field.key] = value
                }
            } else if loaded.values[field.key] == nil, field.loadsStoredValue,
                let value = storedValue(field.key, pluginId: pluginId, agentId: agentId, store: store)
            {
                loaded.values[field.key] = value
            }
            if loaded.values[field.key] == nil, loaded.secretValues[field.key] == nil, let def = field.defaultValue {
                loaded.values[field.key] = def
            }
            if let connKey = field.connectedWhen, !secretKeys.contains(connKey), loaded.values[connKey] == nil,
                let value = storedValue(connKey, pluginId: pluginId, agentId: agentId, store: store)
            {
                loaded.values[connKey] = value
            }
        }
        return loaded
    }

    private func loadConfig() {
        let pluginId = pluginId
        let agentId = agentId
        let fields = configSpec.sections.flatMap(\.fields).map { field in
            FieldInfo(
                key: field.key,
                isSecret: field.type == .secret,
                loadsStoredValue: field.type != .readonly && field.type != .status,
                connectedWhen: field.connected_when,
                defaultValue: field.default?.stringValue)
        }
        Task { @MainActor in
            let loaded = await CredentialStore.current.perform { store in
                Self.readConfig(pluginId: pluginId, agentId: agentId, fields: fields, store: store)
            }
            apply(loaded)
        }
    }

    private func apply(_ loaded: LoadedConfig) {
        cachedTunnelURL = loaded.tunnelURL
        cachedServerPort = loaded.serverPort
        secretValues = loaded.secretValues
        keyNames = loaded.keyNames
        // Edits made while the load was in flight win.
        values = isDirty ? loaded.values.merging(values) { _, edited in edited } : loaded.values

        let changes = values.merging(secretValues) { value, _ in value }.compactMap { (key, value) in
            findField(key: key) != nil ? (key: key, value: value) : nil
        }
        // Skip the round-trip when nothing has changed since the last
        // `loadConfig` for this view instance. We hash the sorted (key,
        // value) pairs so stable orderings produce the same hash.
        var hasher = Hasher()
        for (k, v) in changes.sorted(by: { $0.key < $1.key }) {
            hasher.combine(k)
            hasher.combine(v)
        }
        let snapshotHash = hasher.finalize()
        if snapshotHash != lastDeliveredHash {
            lastDeliveredHash = snapshotHash
            plugin?.notifyConfigBatch(changes, agentId: agentId)
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

        var batch: [(key: String, value: String)] = []
        var writes: [(key: String, value: String)] = []
        for (key, value) in values {
            let isSecret = findField(key: key)?.type == .secret
            if isSecret, hasStoredSecret(key) {
                batch.append((key: key, value: secretValues[key] ?? ""))
                continue
            }
            writes.append((key: key, value: value))
            batch.append((key: key, value: value))
            if isSecret {
                // The saved value moves out of the form, like a loaded one.
                secretValues[key] = value
                values[key] = nil
            }
        }
        editedSecrets.removeAll()
        isDirty = false
        let pluginId = pluginId
        let agentId = agentId
        let plugin = plugin
        let pending = writes
        Task { @MainActor in
            await CredentialStore.current.perform { store in
                for (key, value) in pending
                where !PluginCredentials.configWrite(
                    pluginId: pluginId, key: key, value: value, agentId: agentId, store: store)
                {
                    _ = ToolSecretsKeychain.saveSecret(value, id: key, for: pluginId, agentId: agentId)
                }
            }
            plugin?.notifyConfigBatch(batch, agentId: agentId)
        }
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
            guard !(field.type == .secret && hasStoredSecret(key)) else {
                errors.removeValue(forKey: key)
                return true
            }
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

    private static func resolveBaseURL(for pluginId: String, agentId: UUID) -> String {
        let tunnelURL = ToolSecretsKeychain.getSecret(id: "tunnel_url", for: pluginId, agentId: agentId) ?? ""
        if !tunnelURL.isEmpty { return tunnelURL }
        return "http://127.0.0.1:\(loadServerPort())"
    }

    private func resolveTemplate(_ template: String, pluginId: String) -> String {
        // Runs per body evaluation (readonly fields) — use the state cached in
        // `loadConfig` instead of touching the keychain or disk per render.
        let tunnelURL = cachedTunnelURL
        let baseURL = tunnelURL.isEmpty ? "http://127.0.0.1:\(cachedServerPort)" : tunnelURL

        var result = template
        result = result.replacingOccurrences(of: "{{plugin_url}}", with: "\(baseURL)/plugins/\(pluginId)")
        result = result.replacingOccurrences(of: "{{plugin_id}}", with: pluginId)
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

    nonisolated private static func loadServerPort() -> Int {
        let url = OsaurusPaths.serverConfigFile()
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(ServerConfiguration.self, from: data)
        else { return 1337 }
        return config.port
    }
}

extension PluginManifest.ConfigFieldType {
    /// Label-above-control fields, which need breathing room inside a group
    /// that inline rows get from their min height.
    fileprivate var isStacked: Bool {
        switch self {
        case .text, .secret, .multiselect, .number: return true
        case .toggle, .select, .readonly, .status: return false
        }
    }
}

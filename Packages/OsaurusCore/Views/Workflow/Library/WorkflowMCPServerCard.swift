//
//  WorkflowMCPServerCard.swift
//  osaurus
//
//  One MCP server a workflow template names, in setup. The card says what
//  this Mac has for it (see `MCPServerResolution`) and offers the one step
//  that gets it running without leaving setup: turn on or connect a server
//  that is already here, add it from the MCP Directory, or add it from the
//  template's setup hint. Any configured server can also be picked by hand.
//

import SwiftUI

struct WorkflowMCPServerCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var manager = MCPProviderManager.shared

    /// The server name in the template.
    let name: String
    let template: Template
    let bindings: InstallBindings
    /// Binds the template's server name to a server here; nil unbinds.
    let onBind: (String?) -> Void

    private struct AddRequest: Identifiable {
        let id = UUID()
        var prefill: MCPProviderDraft?
        var start: MCPAddServiceStart
    }

    @State private var adding: AddRequest?
    @State private var editing: MCPProvider?
    @State private var connectError: String?
    @State private var metadataDocumentPublished = false

    var body: some View {
        let candidate = MCPServerResolution.liveCandidate(for: name, in: template, bindings: bindings)
        VStack(alignment: .leading, spacing: theme.space.s10) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "server.rack")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundColor(theme.text.link)
                Text(verbatim: name)
                    .font(SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                Spacer()
                if !manager.configuration.providers.isEmpty { serverPicker }
            }
            status(candidate)
            if let connectError {
                Text(verbatim: connectError)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.space.s12)
        .settingsChrome(.inset)
        .task { metadataDocumentPublished = await MCPOAuthClientMetadata.isDocumentPublished() }
        .sheet(item: $adding) { request in
            ProviderEditSheet(provider: nil, prefill: request.prefill, start: request.start) { provider, token in
                manager.addProvider(provider, token: token)
                if provider.name != name { onBind(provider.name) }
            }
        }
        .sheet(item: $editing) { provider in
            ProviderEditSheet(provider: provider) { updated, token in
                manager.updateProvider(updated, token: token)
                if updated.name != name { onBind(updated.name) }
            }
        }
    }

    private var serverPicker: some View {
        SettingsMenuPicker(
            selection: Binding(
                get: { bindings.mcpServers[name] ?? "" },
                set: { onBind($0.isEmpty ? nil : $0) })
        ) {
            Text("Match automatically", bundle: .module).tag("")
            ForEach(manager.configuration.providers) { provider in
                Text(verbatim: provider.name).tag(provider.name)
            }
            if let bound = bindings.mcpServers[name],
                !manager.configuration.providers.contains(where: { $0.name == bound })
            {
                Text(verbatim: bound).tag(bound)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func status(_ candidate: MCPServerResolution.Candidate) -> some View {
        switch candidate {
        case .ready(let local):
            line(
                "checkmark.circle.fill",
                tint: theme.status.success.foreground,
                local == name ? L("Connected.") : L("Connected, using \(local) on this Mac.")
            )
        case .existing(let server):
            existingRow(server)
        case .directory(let entry):
            action(
                "square.grid.2x2", L("\(entry.displayName) is in the MCP Directory. \(entry.tagline)."),
                button: L("Add \(entry.displayName)")
            ) {
                if entry.requiresClientMetadataDocument && !metadataDocumentPublished {
                    var draft = MCPProviderDraft(name: entry.displayName, url: entry.url, bearerToken: nil)
                    draft.authType = entry.authType
                    adding = AddRequest(prefill: draft, start: .custom)
                } else {
                    adding = AddRequest(prefill: nil, start: .template(entry))
                }
            }
        case .hint(let hint):
            action("wand.and.stars", hintText(hint), button: L("Set Up")) {
                adding = AddRequest(prefill: MCPProviderDraft(hint: hint), start: .custom)
            }
        case .unknown:
            action(
                "questionmark.circle",
                L("Not set up on this Mac, and the template doesn't say how to connect it. Add it by hand, or ask whoever shared the workflow."),
                button: L("Add Server")
            ) {
                adding = AddRequest(prefill: MCPProviderDraft(name: name, url: "", bearerToken: nil), start: .custom)
            }
        }
    }

    @ViewBuilder
    private func existingRow(_ server: MCPServerResolution.LocalServer) -> some View {
        let state = manager.providerStates[server.id]
        let label = server.name == name ? L("This server") : server.name
        if !server.enabled {
            action("power", L("\(label) is set up here but turned off."), button: L("Turn On")) {
                bindIfRenamed(server)
                manager.setEnabled(true, for: server.id)
            }
        } else if state?.isConnecting == true {
            HStack(spacing: theme.space.s8) {
                SettingsSpinner()
                Text(verbatim: L("Connecting to \(server.name)…"))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }
        } else {
            let reason = state?.lastError.map { " " + $0 } ?? ""
            VStack(alignment: .leading, spacing: theme.space.s8) {
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Image(systemName: "bolt.horizontal.circle").foregroundColor(theme.status.warning.foreground)
                    Text(verbatim: L("\(label) is set up here but not connected.") + reason)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: theme.space.s8) {
                    Spacer(minLength: 0)
                    SettingsButton(.secondary, "Edit", size: .compact) {
                        editing = manager.configuration.provider(id: server.id)
                    }
                    SettingsButton(.primary, "Connect", icon: "link", size: .compact) { connect(server) }
                }
            }
        }
    }

    private func hintText(_ hint: MCPServerHint) -> String {
        switch hint.transport {
        case .http:
            return L("The template says it connects to \(hint.url ?? ""). Setup fills that in; you add your own sign-in.")
        case .stdio:
            let command = ([hint.command ?? ""] + hint.args).joined(separator: " ")
            return L("The template says it runs \(command) on this Mac. Setup fills that in; you add your own keys.")
        }
    }

    private func bindIfRenamed(_ server: MCPServerResolution.LocalServer) {
        if server.name != name, bindings.mcpServers[name] != server.name { onBind(server.name) }
    }

    private func connect(_ server: MCPServerResolution.LocalServer) {
        connectError = nil
        bindIfRenamed(server)
        Task { @MainActor in
            do {
                try await manager.connect(providerId: server.id)
            } catch {
                connectError = WorkflowErrorText.text(error)
            }
        }
    }

    // MARK: - Parts

    private func line(_ icon: String, tint: Color, _ text: String) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: icon).foregroundColor(tint)
            Text(verbatim: text)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func action(_ icon: String, _ text: String, button: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: theme.space.s8) {
            Image(systemName: icon).foregroundColor(theme.status.info.foreground)
            Text(verbatim: text)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: perform) {
                Text(verbatim: button).font(SettingsFont.smallLabel)
            }
            .assignedSettingsButtonStyle(.primary)
            .fixedSize()
        }
    }
}

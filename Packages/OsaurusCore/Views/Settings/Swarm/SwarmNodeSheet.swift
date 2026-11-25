//
//  SwarmNodeSheet.swift
//  osaurus
//
//  One node's page: hardware and live use, its model library managed from
//  here (install from a Hugging Face link or copy from another node, load,
//  unload, keep loaded, delete), rename, and Remove Node.
//

import SwiftUI

struct SwarmNodeSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var swarm = SwarmManager.shared
    let nodeId: SwarmNodeID
    let onClose: () -> Void

    @State private var linkText = ""
    /// Set when Install was tried with text that isn't a Hugging Face link;
    /// cleared on the next edit.
    @State private var linkInvalid = false
    @State private var nameText = ""
    @State private var busy: Set<String> = []
    @State private var error: String?
    @State private var confirmDelete: SwarmInstalledModel?
    @State private var confirmRemove = false

    private var node: SwarmNodeSnapshot? { swarm.node(nodeId) }

    var body: some View {
        SettingsSheet(
            icon: "desktopcomputer",
            title: "Manage Node",
            subtitle: nil,
            width: SettingsSheetWidth.wide,
            maxBodyHeight: 560,
            primary: .init(label: "Done", handler: onClose),
            onClose: onClose
        ) {
            if let node {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    if let error {
                        SettingsCallout(
                            icon: "exclamationmark.triangle.fill",
                            title: "Couldn't Do That",
                            message: error,
                            verbatimMessage: true,
                            tone: .error
                        ) {
                            SettingsButton(.tertiary, "Dismiss") { self.error = nil }
                        }
                    }
                    overview(node)
                    installSection(node)
                    librarySection(node)
                    removeSection(node)
                }
                .onAppear { nameText = node.name }
                .onChange(of: linkText) { _, _ in linkInvalid = false }
            } else {
                SettingsEmptyState(inline: "desktopcomputer", title: "This Node Was Removed")
            }
        }
        .subtitle(verbatim: node?.name, lineLimit: 1)
        .alert(
            Text("Delete Model?", bundle: .module),
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { model in
            Button(role: .destructive) {
                run("delete:\(model.modelId)") { try await swarm.deleteModel(model.modelId, on: nodeId) }
            } label: {
                Text("Delete", bundle: .module)
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: { model in
            Text(verbatim: deleteMessage(model))
        }
        .alert(Text("Remove Node?", bundle: .module), isPresented: $confirmRemove) {
            Button(role: .destructive) {
                run("remove") {
                    try await swarm.removeNode(nodeId)
                    onClose()
                }
            } label: {
                Text("Remove", bundle: .module)
            }
            Button(role: .cancel) {
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: {
            Text(
                "Its pairing is revoked and it forgets this Osaurus. Its installed models stay on it. It leaves every pool.",
                bundle: .module
            )
        }
    }

    // MARK: - Sections

    private func overview(_ node: SwarmNodeSnapshot) -> some View {
        SettingsSection(title: "Node") {
            SettingsGroup {
                SettingsRow(title: "Status", description: node.availability.detail ?? "", verbatimDescription: true) {
                    StatusChip(node.availability.label, tone: SwarmFormat.tone(node.availability), showsDot: true)
                }
                SettingsRow(
                    title: "Hardware",
                    description: "\(node.hardware.os) · \(node.hardware.cpu) · TREX \(node.hardware.trexVersion)",
                    verbatimDescription: true
                ) {
                    Text(verbatim: node.hardware.backend.displayName)
                        .font(SettingsFont.smallLabel)
                        .foregroundColor(theme.text.secondary)
                }
                SettingsRow(title: "Memory", description: SwarmFormat.memoryLine(node), verbatimDescription: true) {
                    SettingsProgressBar(
                        value: node.hardware.memoryCapBytes > 0
                            ? Double(node.telemetry.memoryInUseBytes) / Double(node.hardware.memoryCapBytes) : nil
                    )
                    .frame(width: Self.meterWidth)
                }
                SettingsFieldRow(label: "Name") {
                    HStack(spacing: theme.space.s8) {
                        SettingsTextField(placeholder: "Node name", text: $nameText, onSubmit: rename)
                        SettingsButton(.secondary, "Rename", size: .compact, action: rename)
                            .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty || nameText == node.name)
                    }
                }
            }
        }
    }

    private static let meterWidth: CGFloat = 120

    private func installSection(_ node: SwarmNodeSnapshot) -> some View {
        SettingsSection(
            title: "Install a Model",
            subtitle:
                "Paste a Hugging Face link (or org/repo). The node downloads it, checks it fits its memory cap and disk, and adds it to its library.",
            anchorId: "providers.swarm.installModel"
        ) {
            SettingsGroup {
                HStack(spacing: theme.space.s8) {
                    SettingsTextField(
                        placeholder: "https://huggingface.co/org/model",
                        text: $linkText,
                        icon: "link",
                        isInvalid: linkInvalid,
                        onSubmit: install
                    )
                    SettingsButton(
                        .primary,
                        "Install",
                        icon: "arrow.down.circle",
                        isLoading: busy.contains("install"),
                        action: install
                    )
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .settingsRowChrome()
                let copyable = swarm.allInstalledModelIds.filter { node.model($0) == nil }
                if !copyable.isEmpty {
                    SettingsRow(
                        title: "Copy From Another Node",
                        description: "Models other nodes already have. The master picks the closest source."
                    ) {
                        SettingsMenuButton(.secondary, "Copy", icon: "square.on.square", size: .compact) {
                            ForEach(copyable, id: \.self) { modelId in
                                Button(SwarmModelIdentity.shortModelName(modelId)) {
                                    run("copy:\(modelId)") { try await swarm.install(peerModel: modelId, on: nodeId) }
                                }
                            }
                        }
                    }
                }
                ForEach(swarm.installs.values.filter { $0.nodeId == nodeId }.sorted { $0.id < $1.id }) { progress in
                    SwarmInstallRow(progress: progress)
                }
            }
        }
    }

    @ViewBuilder
    private func librarySection(_ node: SwarmNodeSnapshot) -> some View {
        SettingsSection(
            title: "Model Library",
            subtitle: "Keep Loaded preheats a model so the first request skips the load.",
            anchorId: "providers.swarm.preheat"
        ) {
            if node.models.isEmpty {
                SettingsEmptyState(
                    inline: "shippingbox",
                    title: "No Models Installed",
                    hint: "Install one from a Hugging Face link above."
                )
            } else {
                SettingsGroup {
                    ForEach(node.models) { model in
                        modelRow(model)
                    }
                }
            }
        }
        .settingsLandingAnchor("providers.swarm.library")
        .settingsLandingAnchor("providers.swarm.deleteModel")
    }

    private func modelRow(_ model: SwarmInstalledModel) -> some View {
        SettingsRow(
            title: SwarmModelIdentity.shortModelName(model.modelId),
            verbatimTitle: true,
            description: {
                Text(
                    verbatim: [
                        model.modelId, SwarmFormat.bytes(model.sizeBytes), model.loadState.label,
                        poolNames(for: model.modelId),
                    ].filter { !$0.isEmpty }.joined(separator: " · ")
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
            },
            trailing: {
                HStack(spacing: theme.space.s8) {
                    Toggle(
                        isOn: Binding(
                            get: { model.preheat },
                            set: { keep in
                                run("preheat:\(model.modelId)") {
                                    try await swarm.setPreheat(keep, model: model.modelId, on: nodeId)
                                }
                            }
                        )
                    ) {
                        Text("Keep Loaded", bundle: .module)
                    }
                    .settingsCheckbox()
                    switch model.loadState {
                    case .warm:
                        SettingsButton(.secondary, "Unload", size: .compact) {
                            run("load:\(model.modelId)") { try await swarm.unload(model.modelId, on: nodeId) }
                        }
                        .disabled(model.preheat)
                    case .loading:
                        SettingsSpinner(size: .small)
                    case .cold:
                        SettingsButton(
                            .secondary,
                            "Load",
                            isLoading: busy.contains("load:\(model.modelId)"),
                            size: .compact
                        ) {
                            run("load:\(model.modelId)") { try await swarm.load(model.modelId, on: nodeId) }
                        }
                    }
                    SettingsOverflowMenu(help: "Model actions", size: .compact) {
                        Button(role: .destructive) {
                            confirmDelete = model
                        } label: {
                            Label(L("Delete from Node"), systemImage: "trash")
                        }
                    }
                }
            }
        )
    }

    private func removeSection(_ node: SwarmNodeSnapshot) -> some View {
        SettingsSection(title: "Remove", anchorId: "providers.swarm.removeNode") {
            SettingsGroup {
                SettingsRow(
                    title: "Remove Node",
                    description: "Revokes its pairing. Installed models stay on the device."
                ) {
                    SettingsButton(.destructive, "Remove Node", isLoading: busy.contains("remove")) {
                        confirmRemove = true
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func poolNames(for modelId: String) -> String {
        swarm.pools.filter { $0.nodeIds.contains(nodeId) && $0.modelIds.contains(modelId) }.map(\.name)
            .joined(separator: ", ")
    }

    private func deleteMessage(_ model: SwarmInstalledModel) -> String {
        let affected = swarm.poolsAffected(byDeleting: model.modelId, on: nodeId)
        var text = String(
            format: L("%@ is deleted from this node and frees %@."),
            SwarmModelIdentity.shortModelName(model.modelId),
            SwarmFormat.bytes(model.sizeBytes)
        )
        if !affected.isEmpty {
            text +=
                " "
                + String(
                    format: L("The node leaves %@. An active lease finishes first."),
                    affected.map(\.name).joined(separator: ", ")
                )
        }
        return text
    }

    private func install() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        debugLog("[Swarm] install requested on \(nodeId): \(text.debugDescription)")
        guard SwarmInstallSource.huggingFaceRepoId(from: text) != nil else {
            linkInvalid = true
            error = SwarmError.invalidHuggingFaceLink(text).localizedDescription
            return
        }
        linkInvalid = false
        run("install") {
            try await swarm.install(linkOrRepo: text, on: nodeId)
            linkText = ""
        }
    }

    private func rename() {
        let name = nameText
        run("rename") { try await swarm.renameNode(nodeId, to: name) }
    }

    private func run(_ key: String, _ action: @escaping @MainActor () async throws -> Void) {
        busy.insert(key)
        Task { @MainActor in
            defer { busy.remove(key) }
            do {
                try await action()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

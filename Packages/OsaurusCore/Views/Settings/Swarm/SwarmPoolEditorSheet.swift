//
//  SwarmPoolEditorSheet.swift
//  osaurus
//
//  Create or edit a resource pool: its name, the model(s) it serves, the
//  member nodes (only nodes that have every chosen model installed), the
//  default lease duration, the max queue wait before `swarm_pool_busy`, and
//  an optional context length.
//

import SwiftUI

struct SwarmPoolEditorSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var swarm = SwarmManager.shared
    let pool: SwarmPool?
    let onClose: () -> Void

    @State private var draft = SwarmPoolDraft()
    @State private var contextText = ""
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        SettingsSheet(
            icon: "square.stack.3d.up",
            title: pool == nil ? "New Pool" : "Edit Pool",
            subtitle: "Callers ask the pool for a model; the master leases one free node of it.",
            width: SettingsSheetWidth.regular,
            maxBodyHeight: 560,
            primary: .init(label: "Save", isEnabled: canSave, isLoading: saving, handler: save),
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                if let error {
                    SettingsCallout(
                        icon: "exclamationmark.triangle.fill",
                        title: "Couldn't Save the Pool",
                        message: error,
                        verbatimMessage: true,
                        tone: .error
                    )
                }
                SettingsSection(title: "Pool") {
                    SettingsGroup {
                        SettingsFieldRow(label: "Pool Name", anchorId: "providers.swarm.poolName") {
                            SettingsTextField(placeholder: "Raptor Pool #1", text: $draft.name)
                        }
                    }
                }
                modelsSection
                nodesSection
                limitsSection
            }
        }
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.modelIds.isEmpty && !saving
    }

    // MARK: - Sections

    private var modelsSection: some View {
        SettingsSection(
            title: "Models",
            subtitle: "Each model appears in the model pickers as “model · pool”."
        ) {
            let models = Array(Set(swarm.allInstalledModelIds + draft.modelIds)).sorted()
            if models.isEmpty {
                SettingsEmptyState(
                    inline: "shippingbox",
                    title: "No Models Installed",
                    hint: "Install a model on a node first."
                )
            } else {
                SettingsGroup {
                    ForEach(models, id: \.self) { modelId in
                        SettingsToggle(
                            title: SwarmModelIdentity.shortModelName(modelId),
                            description: modelId,
                            style: .checkbox,
                            verbatim: true,
                            isOn: Binding(
                                get: { draft.modelIds.contains(modelId) },
                                set: { on in
                                    if on {
                                        draft.modelIds.append(modelId)
                                    } else {
                                        draft.modelIds.removeAll { $0 == modelId }
                                    }
                                    // Members must have every model the pool serves.
                                    let eligible = Set(swarm.eligibleNodes(forModels: draft.modelIds).map(\.id))
                                    draft.nodeIds.removeAll { !eligible.contains($0) }
                                }
                            )
                        )
                    }
                }
            }
        }
    }

    private var nodesSection: some View {
        SettingsSection(
            title: "Nodes",
            subtitle: "Only nodes with every chosen model installed can join."
        ) {
            let eligible = Set(swarm.eligibleNodes(forModels: draft.modelIds).map(\.id))
            SettingsGroup {
                ForEach(swarm.nodes) { node in
                    let canJoin = !draft.modelIds.isEmpty && eligible.contains(node.id)
                    SettingsToggle(
                        title: node.name,
                        description: canJoin
                            ? "\(node.availability.label) · \(SwarmFormat.modelsLine(node))"
                            : (draft.modelIds.isEmpty
                                ? L("Choose a model first.")
                                : String(
                                    format: L("Missing: %@"),
                                    draft.modelIds.filter { node.model($0) == nil }.map(
                                        SwarmModelIdentity.shortModelName
                                    )
                                    .joined(separator: ", ")
                                )),
                        style: .checkbox,
                        verbatim: true,
                        isOn: Binding(
                            get: { draft.nodeIds.contains(node.id) },
                            set: { on in
                                if on {
                                    if !draft.nodeIds.contains(node.id) { draft.nodeIds.append(node.id) }
                                } else {
                                    draft.nodeIds.removeAll { $0 == node.id }
                                }
                            }
                        )
                    )
                    .disabled(!canJoin)
                }
            }
        }
    }

    private var limitsSection: some View {
        SettingsSection(title: "Leases") {
            SettingsGroup {
                SettingsStepperRow(
                    label: "Lease Duration",
                    help:
                        "How long a caller holds a node. It renews while the caller keeps sending requests, and never cuts off a running generation.",
                    value: $draft.leaseSeconds,
                    range: SwarmPool.leaseSecondsRange,
                    step: 30,
                    unit: "s",
                    anchorId: "providers.swarm.leaseDuration"
                )
                SettingsStepperRow(
                    label: "Max Queue Wait",
                    help:
                        "How long a request waits for a free node before it fails with swarm_pool_busy. 0 fails at once.",
                    value: $draft.maxQueueWaitSeconds,
                    range: SwarmPool.maxQueueWaitSecondsRange,
                    step: 15,
                    unit: "s",
                    anchorId: "providers.swarm.maxQueueWait"
                )
                SettingsFieldRow(
                    label: "Context Length",
                    hint: "Optional. Empty uses each model's own context length.",
                    anchorId: "providers.swarm.contextLength"
                ) {
                    SettingsTextField(
                        placeholder: "Model default",
                        text: $contextText,
                        monospaced: true,
                        isInvalid: !contextText.isEmpty && parsedContext == nil
                    )
                }
            }
        }
    }

    private var parsedContext: Int? {
        guard let value = Int(contextText.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    // MARK: - Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let pool {
            draft = SwarmPoolDraft(pool)
            contextText = pool.contextLength.map(String.init) ?? ""
        } else {
            draft = SwarmPoolDraft(name: String(format: L("Pool %d"), swarm.pools.count + 1))
        }
    }

    private func save() {
        var final = draft
        final.name = final.name.trimmingCharacters(in: .whitespacesAndNewlines)
        final.contextLength = contextText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : parsedContext
        if !contextText.trimmingCharacters(in: .whitespaces).isEmpty, parsedContext == nil {
            error = L("Context length must be a whole number of tokens.")
            return
        }
        // Pool model ids are `osaurus-swarm/<pool-slug>/<model>`: two pools
        // whose names slug the same would claim the same ids.
        let slug = SwarmModelIdentity.slug(forPoolName: final.name)
        if let clash = swarm.pools.first(where: {
            $0.id != pool?.id && SwarmModelIdentity.slug(forPoolName: $0.name) == slug
        }) {
            error = String(
                format: L("“%@” is too close to the pool name “%@”. Pick a different name."),
                final.name,
                clash.name
            )
            return
        }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                if let pool {
                    try await swarm.updatePool(pool.id, final)
                } else {
                    try await swarm.createPool(final)
                }
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

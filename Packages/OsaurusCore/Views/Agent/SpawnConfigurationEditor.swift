//
//  SpawnConfigurationEditor.swift
//  osaurus
//
//  Shared editor for the spawn capability's persisted policy. The custom-agent
//  Subagents tab and the built-in main chat's Settings surface both use this
//  view so target pools, model notes, permissions, worker tools, and budgets
//  cannot drift into two independently maintained control stacks.
//

import SwiftUI

struct SpawnConfigurationEditor: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var modelPickerCache = ModelPickerItemCache.shared

    /// A custom agent cannot spawn itself. `nil` identifies the built-in main
    /// chat, whose picker contains custom agents only.
    let excludedAgentID: UUID?
    let localHandoffEnabled: Bool
    @Binding var modelOverride: String?
    @Binding var spawnableAgentIDs: [UUID]
    @Binding var spawnableModelNames: [String]
    @Binding var spawnableModelNotes: [String: String]
    @Binding var permissionDefaults: SubagentPermissionDefaults
    @Binding var budgets: SubagentBudgets
    @Binding var toolAccess: SpawnToolAccess
    let onChange: () -> Void

    @State private var agentPickerPresented = false
    @State private var modelPickerPresented = false
    @State private var agentSearch = ""
    @State private var modelSearch = ""
    @State private var limitsExpanded = false
    @State private var isRefreshingModels = false
    @State private var connectedSpawnTargetIndex =
        RemoteProviderManager.ConnectedSpawnModelTargetIndex.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelOverrideRow
            divider
            handoffWarning
            allowedAgents
            divider
            allowedModels
            divider
            permissionRow
            divider
            workerToolsRow
            divider
            budgetRows
        }
        .task(id: modelPickerPresented) {
            if modelPickerPresented {
                await refreshModelCandidates()
            } else if modelPickerCache.isLoaded {
                captureConnectedSpawnTargetIndex()
                migrateLegacyRemoteSelections()
            }
        }
    }

    // MARK: - Model and runtime policy

    private var modelOverrideRow: some View {
        controlRow(
            "Agent-target model override",
            subtitle:
                "Optional. Replaces the selected target agent's own model for agent jobs only. Bare model jobs always use the exact allowed model selected by the orchestrator."
        ) {
            Picker("", selection: modelOverrideSelection) {
                Text("Use each target agent's model", bundle: .module).tag("")
                if let current = normalized(modelOverride),
                    modelCandidate(forStoredId: current) == nil
                {
                    Text("\(current) (unavailable)", bundle: .module).tag(current)
                }
                ForEach(selectableModelCandidates, id: \.self) { item in
                    if let targetId = selectionID(for: item) {
                        Text(item.displayName).tag(targetId)
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var handoffWarning: some View {
        if !localHandoffEnabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                Text(
                    "Local Orchestrator Handoff is off. A local target with a different model will be refused; remote targets and the already-loaded local model can still run.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.warningColor.opacity(0.12))
            )
        }
    }

    private var permissionRow: some View {
        controlRow("Permission") {
            Picker("", selection: permissionSelection) {
                ForEach(SubagentPermissionPolicy.allCases, id: \.self) { policy in
                    Text(LocalizedStringKey(policy.displayName), bundle: .module).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
    }

    private var workerToolsRow: some View {
        controlRow(
            "Worker tools",
            subtitle:
                "Configured agents receive the cancellation-audited subset of their enabled tools. Optionally add host read-only file tools so workers can inspect files without copying them into the parent context."
        ) {
            Picker("", selection: toolAccessSelection) {
                Text("Agent tools only", bundle: .module).tag(SpawnToolAccess.none)
                Text("Agent tools + read-only files", bundle: .module)
                    .tag(SpawnToolAccess.readOnly)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
    }

    // MARK: - Allowed agents

    private var allowedAgents: some View {
        let selected = spawnableAgentIDs
        let addable = agentCandidates.filter { candidate in
            !selected.contains(candidate.id)
        }
        return VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Allowed agents")
            if selected.isEmpty {
                emptyHint(
                    "None yet. Add an agent to delegate a task to it (using its own prompt + model)."
                )
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(selected, id: \.self) { id in
                        let candidate = agentCandidates.first { $0.id == id }
                        removableChip(
                            label: candidate?.name ?? id.uuidString,
                            unavailable: candidate == nil
                        ) {
                            setAgent(id, included: false)
                        }
                    }
                }
            }
            if agentCandidates.isEmpty {
                emptyHint(
                    selected.isEmpty
                        ? "No other agents yet — create another agent to make it spawnable."
                        : "Configured agents marked unavailable can still be removed."
                )
            } else {
                addButton(
                    title: "Add agent",
                    isPresented: $agentPickerPresented,
                    disabled: addable.isEmpty
                ) {
                    agentAddList
                }
            }
        }
    }

    private var agentAddList: some View {
        let selected = spawnableAgentIDs
        let query = agentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = agentCandidates.filter { candidate in
            !selected.contains(candidate.id)
                && (query.isEmpty
                    || candidate.name.localizedCaseInsensitiveContains(query)
                    || candidate.description.localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(
                text: $agentSearch,
                placeholder: "Search agents",
                width: 264,
                compact: true
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty {
                        emptyHint("No matching agents.").padding(.vertical, 6)
                    } else {
                        ForEach(filtered) { candidate in
                            addRow(
                                title: candidate.name,
                                subtitle: candidate.description.isEmpty
                                    ? nil : candidate.description
                            ) {
                                setAgent(candidate.id, included: true)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 292)
    }

    // MARK: - Allowed models

    private var allowedModels: some View {
        let selected = spawnableModelNames
        return VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Allowed models")
            if selected.isEmpty {
                emptyHint(
                    "None yet. Add a local or remote model to delegate to it directly, with no agent attached."
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(selected, id: \.self) { id in
                        modelRow(id)
                    }
                }
            }
            addButton(
                title: "Add model",
                isPresented: $modelPickerPresented,
                // A cold cache must not make the only refresh affordance
                // unreachable. Opening the popover performs the authoritative
                // local + connected-provider refresh above.
                disabled: false
            ) {
                modelAddList
            }
        }
    }

    private func modelRow(_ id: String) -> some View {
        let item = modelCandidate(forStoredId: id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item?.displayName ?? id)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                if let badge = modelBadge(item) {
                    badgePill(badge)
                }
                Spacer(minLength: 8)
                Button {
                    setModel(id, included: false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            modelNoteField(id)
        }
        .padding(8)
        .background(roundedSurface(fill: theme.inputBackground, stroke: theme.inputBorder))
    }

    private func modelNoteField(_ id: String) -> some View {
        let binding = modelNoteBinding(id)
        return ZStack(alignment: .leading) {
            if binding.wrappedValue.isEmpty {
                Text("When/how to use this model (optional)", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.placeholderText)
                    .allowsHitTesting(false)
            }
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
        }
    }

    private var modelAddList: some View {
        let selected = spawnableModelNames
        let filtered =
            selectableModelCandidates
            .filter { item in
                guard let targetId = selectionID(for: item) else { return false }
                return !selected.contains(targetId)
            }
            .filter { $0.matches(searchQuery: modelSearch) }
        let grouped = filtered.groupedBySource()
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(
                text: $modelSearch,
                placeholder: "Search models",
                width: 296,
                compact: true
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if isRefreshingModels || !modelPickerCache.isLoaded {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            emptyHint("Refreshing local and connected cloud models…")
                        }
                        .padding(.vertical, 6)
                    } else if grouped.isEmpty, selectableModelCandidates.isEmpty {
                        emptyHint("No local or connected cloud models are available.")
                            .padding(.vertical, 6)
                    } else if grouped.isEmpty,
                        selectableModelCandidates.allSatisfy({ item in
                            selectionID(for: item).map(selected.contains) ?? false
                        })
                    {
                        emptyHint("All available models are already allowed.")
                            .padding(.vertical, 6)
                    } else if grouped.isEmpty {
                        emptyHint("No matching models.").padding(.vertical, 6)
                    } else {
                        ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                            Text(group.source.displayName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.top, 4)
                            ForEach(group.models, id: \.self) { item in
                                addRow(
                                    title: item.displayName,
                                    subtitle: modelSubtitle(item)
                                ) {
                                    if let targetId = selectionID(for: item) {
                                        setModel(targetId, included: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 324)
    }

    // MARK: - Limits

    private var budgetRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    limitsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(limitsExpanded ? 90 : 0))
                    AgentSheetSectionLabel("Limits")
                    Spacer(minLength: 8)
                    if !limitsExpanded {
                        Text(limitsSummary)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if limitsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    budgetStepper(
                        title: "Max output tokens per subagent",
                        keyPath: \.maxDelegateTokens,
                        range: SubagentBudgets.tokenBounds,
                        step: 256
                    )
                    budgetStepper(
                        title: "Max turns",
                        keyPath: \.maxDelegateTurns,
                        range: SubagentBudgets.turnBounds,
                        step: 1
                    )
                    budgetStepper(
                        title: "Max child tool calls (0 = default 8)",
                        keyPath: \.maxToolCalls,
                        range: SubagentBudgets.toolCallBounds,
                        step: 1
                    )
                    budgetStepper(
                        title: "Max seconds",
                        keyPath: \.maxElapsedSeconds,
                        range: SubagentBudgets.elapsedBounds,
                        step: 15
                    )
                    budgetStepper(
                        title: "Max subagents per batch",
                        keyPath: \.maxParallelSpawns,
                        range: SubagentBudgets.parallelSpawnBounds,
                        step: 1
                    )
                    currentLocalExecutionContract
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var limitsSummary: String {
        let normalized = budgets.normalized
        let turns = normalized.maxDelegateTurns
        return
            "\(normalized.maxDelegateTokens.formatted()) tok · "
            + "\(turns) turn\(turns == 1 ? "" : "s") · "
            + "\(normalized.maxElapsedSeconds)s · "
            + "\(normalized.maxParallelSpawns) per batch"
    }

    private var currentLocalExecutionContract: some View {
        let plan = currentLocalCapacityPlan
        return controlRow(
            "Configured same-model local ceiling",
            subtitle: localExecutionContractSubtitle
        ) {
            Text("up to \(plan.localParallelism)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(width: 76, alignment: .trailing)
        }
    }

    private var localExecutionContractSubtitle: LocalizedStringKey {
        if excludedAgentID == nil {
            return
                "Main Chat Spawn and Server Concurrent Sessions persist one configured limit. Existing engine work and RAM-Safety can queue or split it into smaller waves at run time. Different local models run in serial model waves; remote jobs can overlap."
        }
        return
            "This agent and Server Concurrent Sessions persist one configured limit. Existing engine work and RAM-Safety can queue or split it into smaller waves at run time. Different local models run in serial model waves; remote jobs can overlap."
    }

    /// Reuse the runtime admission planner for the static settings-level
    /// ceiling. Target-specific RAM facts are intentionally absent here; the
    /// live preparation path supplies those and may clamp this value further.
    private var currentLocalCapacityPlan: SubagentBatchAdmissionPlan {
        let runtime = ServerRuntimeSettingsStore.snapshot()
        let requested = budgets.normalized.maxParallelSpawns
        let engineSlots = InferenceFeatureFlags.mlxBatchEngineMaxBatchSize(
            in: .standard,
            runtime: runtime
        )
        return SubagentBatchAdmissionPlanner.plan(
            SubagentBatchAdmissionInput(
                localJobCount: requested,
                remoteJobCount: 0,
                agentParallelLimit: requested,
                engineParallelLimit: engineSlots,
                continuousBatchingEnabled: runtime.concurrency.continuousBatching,
                ramSafetyEnabled: false,
                failClosedWhenEstimateUnknown: false,
                memory: nil
            )
        )
    }

    private func budgetStepper(
        title: LocalizedStringKey,
        keyPath: WritableKeyPath<SubagentBudgets, Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        let value = budgetBinding(keyPath)
        return controlRow(title) {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .frame(width: 64, alignment: .trailing)
            }
            .frame(maxWidth: 180)
        }
    }

    // MARK: - Bindings and candidates

    private var agentCandidates: [Agent] {
        agentManager.agents.filter { candidate in
            if let excludedAgentID {
                return candidate.id != excludedAgentID
            }
            return !candidate.isBuiltIn
        }
    }

    private var modelCandidates: [ModelPickerItem] {
        modelPickerCache.items.chatModelCandidates
    }

    /// Spawn persistence uses immutable provider UUIDs for remote rows. Local
    /// and Foundation ids keep their existing picker identity. A stale remote
    /// picker row without a currently connected service is not selectable.
    private var selectableModelCandidates: [ModelPickerItem] {
        modelCandidates.filter { selectionID(for: $0) != nil }
    }

    private func selectionID(for item: ModelPickerItem) -> String? {
        switch item.source {
        case .remote(_, let providerId):
            return connectedSpawnTargetIndex.targetID(
                forPickerModelId: item.id,
                providerId: providerId
            )
        // Claude Code routes locally by its `claude-code/…` picker id (no
        // provider UUID to canonicalize against), so it keys the same way as
        // the other local backends.
        case .local, .foundation, .imageGeneration, .claudeCode:
            return item.id
        }
    }

    /// Resolve a persisted spawn id back to its current picker row. Canonical
    /// remote ids use provider UUID + raw model slug; a legacy name-prefixed id
    /// is accepted only when one current provider owns it. Exact duplicate
    /// picker ids deliberately render unavailable rather than picking `.first`.
    private func modelCandidate(forStoredId id: String) -> ModelPickerItem? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let remote = connectedSpawnTargetIndex.target(forStoredId: trimmed) {
            return selectableModelCandidates.first { item in
                guard case .remote(_, let providerId) = item.source else { return false }
                return providerId == remote.providerId && item.id == remote.pickerModelId
            }
        }

        let exact = selectableModelCandidates.filter { $0.id == trimmed }
        return exact.count == 1 ? exact[0] : nil
    }

    @MainActor
    private func refreshModelCandidates() async {
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        await RemoteProviderManager.shared.refreshConnectedProviders()
        await modelPickerCache.buildModelPickerItems()
        captureConnectedSpawnTargetIndex()
        migrateLegacyRemoteSelections()
    }

    @MainActor
    private func captureConnectedSpawnTargetIndex() {
        connectedSpawnTargetIndex =
            RemoteProviderManager.shared.connectedSpawnModelTargetIndex()
    }

    /// Upgrade only unambiguous legacy remote ids after the live provider
    /// catalog refresh. Notes follow their target. Duplicate provider names /
    /// model slugs remain untouched and unavailable so the user must choose the
    /// intended UUID-backed row explicitly.
    private func migrateLegacyRemoteSelections() {
        var migratedNames = spawnableModelNames
        var migratedNotes = spawnableModelNotes
        var migratedOverride = modelOverride

        func canonicalRemoteID(for id: String) -> String? {
            // Preserve local/Foundation precedence if an old remote picker id
            // happens to collide with a local id.
            if modelCandidates.contains(where: { item in
                guard item.id == id else { return false }
                switch item.source {
                case .local, .foundation, .imageGeneration, .claudeCode: return true
                case .remote: return false
                }
            }) {
                return nil
            }
            guard
                let remote = connectedSpawnTargetIndex.target(forStoredId: id),
                remote.id != id
            else {
                return nil
            }
            return remote.id
        }

        for index in migratedNames.indices {
            let legacy = migratedNames[index]
            guard let canonical = canonicalRemoteID(for: legacy) else { continue }
            migratedNames[index] = canonical
            if let note = migratedNotes.removeValue(forKey: legacy),
                migratedNotes[canonical] == nil
            {
                migratedNotes[canonical] = note
            }
        }
        migratedNames = SubagentConfiguration.normalizedSpawnableModelNames(migratedNames)
        migratedNotes = SubagentConfiguration.normalizedSpawnableModelNotes(
            migratedNotes,
            names: migratedNames
        )

        if let current = normalized(migratedOverride),
            let canonical = canonicalRemoteID(for: current)
        {
            migratedOverride = canonical
        }

        guard
            migratedNames != spawnableModelNames
                || migratedNotes != spawnableModelNotes
                || migratedOverride != modelOverride
        else {
            return
        }
        spawnableModelNames = migratedNames
        spawnableModelNotes = migratedNotes
        modelOverride = migratedOverride
        onChange()
    }

    private var modelOverrideSelection: Binding<String> {
        Binding(
            get: { modelOverride ?? "" },
            set: { newValue in
                modelOverride = normalized(newValue)
                onChange()
            }
        )
    }

    private var permissionSelection: Binding<SubagentPermissionPolicy> {
        Binding(
            get: {
                permissionDefaults.policy(for: SubagentCapabilityRegistry.spawn.id)
            },
            set: { newValue in
                var updated = permissionDefaults
                updated.setPolicy(newValue, for: SubagentCapabilityRegistry.spawn.id)
                permissionDefaults = updated
                onChange()
            }
        )
    }

    private var toolAccessSelection: Binding<SpawnToolAccess> {
        Binding(
            get: { toolAccess },
            set: { newValue in
                toolAccess = newValue
                onChange()
            }
        )
    }

    private func budgetBinding(
        _ keyPath: WritableKeyPath<SubagentBudgets, Int>
    ) -> Binding<Int> {
        Binding(
            get: { budgets[keyPath: keyPath] },
            set: { newValue in
                var updated = budgets
                updated[keyPath: keyPath] = newValue
                budgets = updated.normalized
                onChange()
            }
        )
    }

    private func modelNoteBinding(_ id: String) -> Binding<String> {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return Binding(
            get: { spawnableModelNotes[key] ?? "" },
            set: { newValue in
                var notes = spawnableModelNotes
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes.removeValue(forKey: key)
                } else {
                    notes[key] = newValue
                }
                spawnableModelNotes = notes
                onChange()
            }
        )
    }

    private func setAgent(_ id: UUID, included: Bool) {
        var ids = spawnableAgentIDs.filter { $0 != id }
        if included { ids.append(id) }
        spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(ids)
        onChange()
    }

    private func setModel(_ id: String, included: Bool) {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var names = spawnableModelNames.filter { $0 != key }
        var notes = spawnableModelNotes
        if included {
            names.append(key)
        } else {
            notes.removeValue(forKey: key)
        }
        spawnableModelNames = names
        spawnableModelNotes = notes
        onChange()
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Shared chrome

    private func controlRow<Control: View>(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                if let subtitle {
                    Text(subtitle, bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private var divider: some View {
        Divider().overlay(theme.inputBorder)
    }

    private func roundedSurface(fill: Color, stroke: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removableChip(
        label: String,
        unavailable: Bool = false,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            if unavailable {
                Text("Unavailable", bundle: .module)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.warningColor)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(theme.tertiaryBackground))
        .overlay(Capsule().stroke(theme.inputBorder, lineWidth: 1))
    }

    private func addButton<Content: View>(
        title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        disabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Button {
            isPresented.wrappedValue = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text(title, bundle: .module).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(disabled ? theme.tertiaryText : theme.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            content()
        }
    }

    private func addRow(
        title: String,
        subtitle: String?,
        onAdd: @escaping () -> Void
    ) -> some View {
        Button(action: onAdd) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(theme.accentColor)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    private func modelBadge(_ item: ModelPickerItem?) -> String? {
        guard let item else {
            return isRefreshingModels || !modelPickerCache.isLoaded
                ? L("Checking…")
                : L("Unavailable")
        }
        switch item.source {
        case .remote(let providerName, _): return providerName
        case .local, .foundation: return L("Local")
        case .imageGeneration: return L("Image")
        // Distinct from "Local": it runs through the user's signed-in Claude
        // Code CLI, so its limits and privacy story differ from on-device MLX.
        case .claudeCode: return L("Claude Code")
        }
    }

    private func badgePill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.tertiaryBackground))
    }

    private func modelSubtitle(_ item: ModelPickerItem) -> String? {
        var parts: [String] = []
        if let params = item.parameterCount, !params.isEmpty { parts.append(params) }
        if let quant = item.quantization, !quant.isEmpty { parts.append(quant) }
        if item.isVLM { parts.append(L("Vision")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

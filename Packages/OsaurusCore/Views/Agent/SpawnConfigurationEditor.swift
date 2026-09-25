//
//  SpawnConfigurationEditor.swift
//  osaurus
//
//  Shared editor for the spawn capability's persisted policy. The custom-agent
//  Subagents tab and the Orchestrator's Settings tab both use this view so
//  target pools, permissions, and limits cannot drift into two independently
//  maintained control stacks.
//
//  Layout (top to bottom): Allowed subagents (agents, then teammates' shared
//  agents) → Permission (local, then shared) → Limits (open by default) →
//  Advanced (model override). Every control carries a settings anchor when
//  `anchorPrefix` is set so Management search can scroll to it.
//

import SwiftUI

struct SpawnConfigurationEditor: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var modelPickerCache = ModelPickerItemCache.shared
    /// Shared-agent roster (names, workspace membership, cached presence).
    /// Presence is rendered on the chips ONLY — it never reaches the prompt
    /// or the tool schema, so a teammate going offline cannot reset the KV
    /// prefix (see `SpawnDescriptors.resolveWorkspaceTargets`).
    @ObservedObject private var roster = WorkspaceRosterStore.shared

    /// A custom agent cannot spawn itself. `nil` identifies the built-in
    /// Orchestrator, whose picker contains custom agents only.
    let excludedAgentID: UUID?
    let localHandoffEnabled: Bool
    @Binding var modelOverride: String?
    @Binding var spawnableAgentIDs: [UUID]
    @Binding var spawnableWorkspaceAgents: [WorkspaceAgentRef]
    /// Tombstones for shared agents the user removed (Orchestrator only; the
    /// pool auto-joins roster agents, so a removal must be remembered).
    /// `nil` for custom agents, whose workspace list is manual opt-in.
    var removedWorkspaceAgents: Binding<[WorkspaceAgentRef]>? = nil
    @Binding var permissionDefaults: SubagentPermissionDefaults
    @Binding var budgets: SubagentBudgets
    /// When set (Orchestrator tab), every control gets
    /// `"\(anchorPrefix).<control>"` as its settings landing anchor.
    var anchorPrefix: String? = nil
    let onChange: () -> Void

    @State private var agentPickerPresented = false
    @State private var workspaceAgentPickerPresented = false
    @State private var agentSearch = ""
    @State private var workspaceAgentSearch = ""
    @State private var advancedExpanded = false
    @State private var isRefreshingModels = false
    @State private var connectedSpawnTargetIndex =
        RemoteProviderManager.ConnectedSpawnModelTargetIndex.empty

    private var isOrchestrator: Bool { excludedAgentID == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            allowedSubagentsHeading
            allowedAgents
            divider
            allowedWorkspaceAgents
            divider
            permissionRow
            workspacePermissionRow
            divider
            budgetRows
            divider
            advancedSection
        }
        .task(id: advancedExpanded) {
            if advancedExpanded {
                await refreshModelCandidates()
            } else if modelPickerCache.isLoaded {
                captureConnectedSpawnTargetIndex()
                migrateLegacyRemoteOverride()
            }
        }
        .task(id: workspaceAgentPickerPresented) {
            // Opening the picker is the user's "is this list current?"
            // affordance; the roster otherwise refreshes on its own poll.
            if workspaceAgentPickerPresented {
                await roster.refresh(reason: .manual)
            }
        }
        .onAppear {
            roster.beginObserving()
            pruneMissingAgents()
        }
        .onDisappear { roster.endObserving() }
        .onReceive(agentManager.$agents) { _ in pruneMissingAgents() }
    }

    private func anchor(_ suffix: String) -> String? {
        anchorPrefix.map { "\($0).\(suffix)" }
    }

    // MARK: - Allowed subagents

    private var allowedSubagentsHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Allowed subagents", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                isOrchestrator
                    ? "The agents the Orchestrator may hand a task to. Each runs with its own prompt, model, and tools. New agents join automatically; remove one to keep it out."
                    : "The agents this agent may hand a task to. Each runs with its own prompt, model, and tools. An empty list keeps delegation off.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .settingsLandingAnchor(anchor("allowedSubagents"))
    }

    // MARK: - Allowed agents

    private var allowedAgents: some View {
        let selected = spawnableAgentIDs.filter { id in agentCandidates.contains { $0.id == id } }
        let addable = agentCandidates.filter { candidate in
            !selected.contains(candidate.id)
        }
        return VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Allowed agents")
            if selected.isEmpty {
                emptyHint(
                    isOrchestrator
                        ? "No agents yet. Create starter agents below, or create your own in Agents — every new agent joins this list."
                        : "None yet. Add an agent to delegate a task to it (using its own prompt + model)."
                )
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(selected, id: \.self) { id in
                        if let candidate = agentCandidates.first(where: { $0.id == id }) {
                            removableChip(label: candidate.name) {
                                setAgent(id, included: false)
                            }
                        }
                    }
                }
                emptyHint(
                    isOrchestrator
                        ? "Agents with their own Working Folder read and write files there. Agents without one inherit the Orchestrator's Working Folder for the run."
                        : "Agents with their own Working Folder read and write files there. Agents without one inherit this agent's chat folder for the run."
                )
            }
            HStack(spacing: 14) {
                if agentCandidates.isEmpty {
                    emptyHint("No other agents yet — create one to make it spawnable.")
                } else {
                    addButton(
                        title: "Add agent",
                        isPresented: $agentPickerPresented,
                        disabled: addable.isEmpty
                    ) {
                        agentAddList
                    }
                }
                if isOrchestrator, selected.isEmpty {
                    starterAgentsButton
                }
            }
        }
        .settingsLandingAnchor(anchor("allowedAgents"))
    }

    /// One-click runnable pool for a fresh install: Coder + Researcher +
    /// Writer, on the Orchestrator's own model, auto-joined to the pool.
    private var starterAgentsButton: some View {
        Button {
            let created = agentManager.createStarterAgents()
            guard !created.isEmpty else { return }
            var ids = spawnableAgentIDs
            for agent in created where !ids.contains(agent.id) { ids.append(agent.id) }
            spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(ids)
            onChange()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                Text("Create starter agents", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(.plain)
        .help(L("Creates Coder, Researcher, and Writer agents on your current model and adds them here."))
        .settingsLandingAnchor(anchor("starterAgents"))
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

    // MARK: - Allowed workspace agents

    /// A shared agent the user may delegate to: every roster row minus this
    /// instance's own agents, once per `(workspace, address)`.
    private struct WorkspaceAgentCandidate: Identifiable {
        let ref: WorkspaceAgentRef
        let name: String
        let description: String?
        let workspaceName: String
        let ownerName: String?
        var id: String { ref.key }
    }

    private var workspaceAgentCandidates: [WorkspaceAgentCandidate] {
        var seen = Set<WorkspaceAgentRef>()
        var out: [WorkspaceAgentCandidate] = []
        for entry in roster.rosters {
            for agent in entry.agents where !roster.isHostedHere(address: agent.agentAddress) {
                let ref = WorkspaceAgentRef(workspaceId: entry.id, agentAddress: agent.agentAddress)
                guard seen.insert(ref).inserted else { continue }
                let description = agent.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(
                    WorkspaceAgentCandidate(
                        ref: ref,
                        name: AgentTargetResolver.displayName(for: ref),
                        description: (description?.isEmpty == false) ? description : nil,
                        workspaceName: entry.workspace.name,
                        ownerName: agent.owner?.friendlyName
                    )
                )
            }
        }
        return out
    }

    private var allowedWorkspaceAgents: some View {
        let candidates = workspaceAgentCandidates
        // Once the roster has loaded, a ref it does not list is stale
        // (unshared / teammate left) and must never render as a bare address.
        let selected = spawnableWorkspaceAgents.filter { ref in
            !roster.hasWorkspaces || candidates.contains { $0.ref == ref }
        }
        let addable = candidates.filter { !selected.contains($0.ref) }
        return VStack(alignment: .leading, spacing: 8) {
            AgentSheetSectionLabel("Allowed shared agents")
            if selected.isEmpty {
                emptyHint(
                    isOrchestrator
                        ? "Teammates' shared agents join here automatically. They run on their owner's Mac with their prompt and model; results come back over the relay."
                        : "None yet. Add a teammate's shared agent to delegate a task to it. It runs on their Mac with their prompt and model; results come back over the relay."
                )
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(selected, id: \.key) { ref in
                        let candidate = candidates.first { $0.ref == ref }
                        workspaceAgentChip(ref: ref, candidate: candidate) {
                            setWorkspaceAgent(ref, included: false)
                        }
                    }
                }
            }
            if !roster.hasWorkspaces {
                emptyHint("No workspaces yet — join one in Settings → Workspaces to delegate to shared agents.")
            } else if candidates.isEmpty {
                emptyHint("No teammate agents are shared into your workspaces yet.")
            } else {
                addButton(
                    title: "Add shared agent",
                    isPresented: $workspaceAgentPickerPresented,
                    disabled: addable.isEmpty
                ) {
                    workspaceAgentAddList
                }
            }
        }
        .settingsLandingAnchor(anchor("allowedWorkspaceAgents"))
    }

    /// Chip label: name @ workspace, owner, with a cached presence dot.
    /// Presence is advisory (the spawn-time probe is authoritative) and
    /// UI-only.
    private func workspaceAgentChip(
        ref: WorkspaceAgentRef,
        candidate: WorkspaceAgentCandidate?,
        onRemove: @escaping () -> Void
    ) -> some View {
        let presence = roster.presence(forAddress: ref.agentAddress, workspaceId: ref.workspaceId)
        let name = candidate?.name ?? AgentTargetResolver.displayName(for: ref)
        let workspaceName = candidate?.workspaceName ?? AgentTargetResolver.workspaceName(for: ref)
        return HStack(spacing: 6) {
            if candidate != nil {
                Circle()
                    .fill(presenceColor(presence))
                    .frame(width: 7, height: 7)
                    .help(presenceLabel(presence))
                    .accessibilityLabel(Text(presenceLabel(presence)))
            }
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            if let workspaceName, !workspaceName.isEmpty {
                Text("@\(workspaceName)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            if let owner = candidate?.ownerName, !owner.isEmpty {
                Text("· \(owner)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
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
        .help(ref.agentAddress)
    }

    private func presenceColor(_ presence: WorkspaceRosterStore.Presence) -> Color {
        presence.indicatorColor(theme: theme)
    }

    private func presenceLabel(_ presence: WorkspaceRosterStore.Presence) -> String {
        switch presence {
        case .online: return L("Online")
        case .offline: return L("Offline")
        case .unknown: return L("Presence unknown")
        }
    }

    private var workspaceAgentAddList: some View {
        let selected = spawnableWorkspaceAgents
        let query = workspaceAgentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = workspaceAgentCandidates.filter { candidate in
            !selected.contains(candidate.ref)
                && (query.isEmpty
                    || candidate.name.localizedCaseInsensitiveContains(query)
                    || candidate.workspaceName.localizedCaseInsensitiveContains(query)
                    || (candidate.description ?? "").localizedCaseInsensitiveContains(query)
                    || candidate.ref.agentAddress.localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(
                text: $workspaceAgentSearch,
                placeholder: "Search shared agents",
                width: 296,
                compact: true
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if roster.isLoading, workspaceAgentCandidates.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            emptyHint("Loading workspace rosters…")
                        }
                        .padding(.vertical, 6)
                    } else if filtered.isEmpty {
                        emptyHint("No matching shared agents.").padding(.vertical, 6)
                    } else {
                        ForEach(filtered) { candidate in
                            let presence = roster.presence(
                                forAddress: candidate.ref.agentAddress,
                                workspaceId: candidate.ref.workspaceId
                            )
                            addRow(
                                title: "\(candidate.name)@\(candidate.workspaceName)",
                                subtitle: workspaceAgentSubtitle(candidate, presence: presence)
                            ) {
                                setWorkspaceAgent(candidate.ref, included: true)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 324)
    }

    private func workspaceAgentSubtitle(
        _ candidate: WorkspaceAgentCandidate,
        presence: WorkspaceRosterStore.Presence
    ) -> String {
        var parts: [String] = []
        if let owner = candidate.ownerName, !owner.isEmpty { parts.append(owner) }
        parts.append(presenceLabel(presence))
        if let description = candidate.description { parts.append(description) }
        return parts.joined(separator: " · ")
    }

    private func setWorkspaceAgent(_ ref: WorkspaceAgentRef, included: Bool) {
        var refs = spawnableWorkspaceAgents.filter { $0 != ref }
        if included { refs.append(ref) }
        spawnableWorkspaceAgents = SubagentConfiguration.normalizedWorkspaceAgents(refs)
        if let removed = removedWorkspaceAgents {
            var tombstones = removed.wrappedValue.filter { $0 != ref }
            if !included { tombstones.append(ref) }
            removed.wrappedValue = SubagentConfiguration.normalizedWorkspaceAgents(tombstones)
        }
        onChange()
    }

    // MARK: - Permission

    private var permissionRow: some View {
        controlRow(
            "Permission",
            subtitle:
                "Whether to ask before the Orchestrator's agents run. Always Allow is the default: each agent keeps its own permission cards for anything sensitive."
        ) {
            Picker("", selection: permissionSelection(for: SubagentCapabilityRegistry.spawn.id)) {
                ForEach(SubagentPermissionPolicy.allCases, id: \.self) { policy in
                    Text(LocalizedStringKey(policy.displayName), bundle: .module).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
        .settingsLandingAnchor(anchor("permission"))
    }

    private var workspacePermissionRow: some View {
        controlRow(
            "Permission for shared (workspace) agents",
            subtitle:
                "A shared agent runs on a teammate's Mac and spends that workspace's pool. Ask is the default; one card covers every shared agent in a wave."
        ) {
            Picker(
                "",
                selection: permissionSelection(for: SubagentPermissionDefaults.workspaceSpawnKindId)
            ) {
                ForEach(SubagentPermissionPolicy.allCases, id: \.self) { policy in
                    Text(LocalizedStringKey(policy.displayName), bundle: .module).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
        }
        .settingsLandingAnchor(anchor("workspacePermission"))
    }

    // MARK: - Limits

    private var budgetRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentSheetSectionLabel("Limits")
                Spacer(minLength: 8)
                Text(limitsSummary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            budgetStepper(
                title: "Max output tokens per subagent",
                help: "Output tokens one subagent may produce per turn. Long reports need more.",
                keyPath: \.maxDelegateTokens,
                range: SubagentBudgets.tokenBounds,
                step: 256,
                anchor: "maxTokens"
            )
            budgetStepper(
                title: "Max turns per subagent",
                help: "Model turns (tool-call rounds) one subagent may take before it must answer.",
                keyPath: \.maxDelegateTurns,
                range: SubagentBudgets.turnBounds,
                step: 1,
                anchor: "maxTurns"
            )
            budgetStepper(
                title: "Time limit per subagent (seconds)",
                help: "Wall-clock limit for one subagent, including model loading.",
                keyPath: \.maxElapsedSeconds,
                range: SubagentBudgets.elapsedBounds,
                step: 15,
                anchor: "timeLimit"
            )
            budgetStepper(
                title: "Max local subagents at once",
                help: "Local (on-device) subagents that may run in parallel in one wave. Shares the Server Concurrent Sessions ceiling.",
                keyPath: \.maxParallelSpawns,
                range: SubagentBudgets.parallelSpawnBounds,
                step: 1,
                anchor: "maxLocal"
            )
            budgetStepper(
                title: "Max remote subagents at once",
                help: "Cloud, provider, and shared workspace subagents that may run in parallel in one wave.",
                keyPath: \.maxRemoteParallelSpawns,
                range: SubagentBudgets.remoteParallelSpawnBounds,
                step: 1,
                anchor: "maxRemote"
            )
            currentLocalExecutionContract
        }
        .settingsLandingAnchor(anchor("limits"))
    }

    private var limitsSummary: String {
        let normalized = budgets.normalized
        let turns = normalized.maxDelegateTurns
        return
            "\(normalized.maxDelegateTokens.formatted()) tok · "
            + "\(turns) turn\(turns == 1 ? "" : "s") · "
            + "\(normalized.maxElapsedSeconds)s · "
            + "\(normalized.maxParallelSpawns) local / \(normalized.maxRemoteParallelSpawns) remote"
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
        if isOrchestrator {
            return
                "The Orchestrator and Server Concurrent Sessions share one configured local limit. Existing engine work and the memory check can queue or split it into smaller waves at run time. Different local models run one model at a time. Remote subagents use the separate remote limit and run concurrently."
        }
        return
            "This agent and Server Concurrent Sessions share one configured local limit. Existing engine work and the memory check can queue or split it into smaller waves at run time. Different local models run one model at a time. Remote subagents use the separate remote limit and run concurrently."
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
        help: LocalizedStringKey,
        keyPath: WritableKeyPath<SubagentBudgets, Int>,
        range: ClosedRange<Int>,
        step: Int,
        anchor suffix: String
    ) -> some View {
        let value = budgetBinding(keyPath)
        return controlRow(title, subtitle: help) {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .frame(width: 64, alignment: .trailing)
            }
            .frame(maxWidth: 180)
        }
        .settingsLandingAnchor(anchor(suffix))
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    advancedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                    AgentSheetSectionLabel("Advanced")
                    Spacer(minLength: 8)
                    if !advancedExpanded, let current = normalized(modelOverride) {
                        Text(current)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    modelOverrideRow
                    handoffWarning
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .settingsLandingAnchor(anchor("advanced"))
    }

    private var modelOverrideRow: some View {
        controlRow(
            "Agent-target model override",
            subtitle:
                "Optional. Runs every delegated agent on this model instead of the agent's own. Leave it on \"Use each agent's model\" unless you need one model for all subagents."
        ) {
            Picker("", selection: modelOverrideSelection) {
                Text("Use each agent's model", bundle: .module).tag("")
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
        .settingsLandingAnchor(anchor("modelOverride"))
    }

    @ViewBuilder
    private var handoffWarning: some View {
        if !localHandoffEnabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                Text(
                    "\"Swap local models for subagents\" is off. The invoking model stays loaded while a different local subagent runs, including under Server Strict. This uses more memory; memory checks can still refuse the child without evicting the parent. Change the shared setting in Settings → Orchestrator.",
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

    // MARK: - Bindings and candidates

    private var agentCandidates: [Agent] {
        agentManager.agents.filter { candidate in
            if let excludedAgentID {
                return candidate.id != excludedAgentID
            }
            return !candidate.isBuiltIn
        }
    }

    /// Drop ids that no longer name a live agent from the bound list, so a
    /// deletion that raced this editor can never be re-persisted by its
    /// next save (and never renders as a bare UUID chip).
    private func pruneMissingAgents() {
        // The manager loads synchronously at init, so an empty list means it
        // has not been materialized yet — never prune against nothing.
        guard !agentManager.agents.isEmpty else { return }
        let live = Set(agentManager.agents.map(\.id))
        let pruned = spawnableAgentIDs.filter { live.contains($0) }
        guard pruned.count != spawnableAgentIDs.count else { return }
        spawnableAgentIDs = pruned
        onChange()
    }

    private var modelCandidates: [ModelPickerItem] {
        // Stored projection on the cache (recomputed per rebuild), not
        // `items.chatModelCandidates` — the filter's per-item string matching
        // is too heavy to rerun on every body evaluation.
        modelPickerCache.chatModelCandidates
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

    /// Resolve a persisted override id back to its current picker row.
    /// Canonical remote ids use provider UUID + raw model slug; a legacy
    /// name-prefixed id is accepted only when one current provider owns it.
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
        migrateLegacyRemoteOverride()
    }

    @MainActor
    private func captureConnectedSpawnTargetIndex() {
        connectedSpawnTargetIndex =
            RemoteProviderManager.shared.connectedSpawnModelTargetIndex()
    }

    /// Upgrade an unambiguous legacy remote override id after the live
    /// provider catalog refresh.
    private func migrateLegacyRemoteOverride() {
        guard let current = normalized(modelOverride) else { return }
        // Preserve local/Foundation precedence if an old remote picker id
        // happens to collide with a local id.
        if modelCandidates.contains(where: { item in
            guard item.id == current else { return false }
            switch item.source {
            case .local, .foundation, .imageGeneration, .claudeCode: return true
            case .remote: return false
            }
        }) {
            return
        }
        guard
            let remote = connectedSpawnTargetIndex.target(forStoredId: current),
            remote.id != current
        else { return }
        modelOverride = remote.id
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

    private func permissionSelection(for kindId: String) -> Binding<SubagentPermissionPolicy> {
        Binding(
            get: { permissionDefaults.policy(for: kindId) },
            set: { newValue in
                var updated = permissionDefaults
                updated.setPolicy(newValue, for: kindId)
                permissionDefaults = updated
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

    private func setAgent(_ id: UUID, included: Bool) {
        var ids = spawnableAgentIDs.filter { $0 != id }
        if included { ids.append(id) }
        spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(ids)
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

    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removableChip(
        label: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
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
}

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
    /// `.groupRows` emits each part as a direct child, so a `SettingsGroup`
    /// parent draws them as rows; `.stacked` is one self-contained column.
    var layout: Layout = .stacked
    #if OSAURUS_DESIGN_SYSTEM
    /// Mount only the original picker composition, without roster/model tasks.
    var inspectionDisplay = false
    #endif

    enum Layout {
        case stacked
        case groupRows
    }

    @State private var agentPickerPresented = false
    @State private var workspaceAgentPickerPresented = false
    @State private var agentSearch = ""
    @State private var workspaceAgentSearch = ""
    @State private var advancedExpanded = false
    @State private var isRefreshingModels = false
    @State private var connectedSpawnTargetIndex =
        RemoteProviderManager.ConnectedSpawnModelTargetIndex.empty
    /// Bumped when `server-runtime.json` is saved so the "Configured
    /// same-model local ceiling" row re-reads the runtime snapshot. The
    /// Max-local stepper mirrors into Server Concurrent Sessions
    /// asynchronously (`ServerController.applySpawnBatchLimit`), after this
    /// body has already rendered; without a re-render the row kept showing
    /// the pre-edit ceiling until the user left and came back (live proof,
    /// 2026-09-29: stepper 2, row "up to 1").
    @State private var runtimeSettingsRevision = 0

    private var isOrchestrator: Bool { excludedAgentID == nil }

    var body: some View {
        #if OSAURUS_DESIGN_SYSTEM
        if inspectionDisplay {
            VStack(alignment: .leading, spacing: 12) {
                allowedAgents
                allowedWorkspaceAgents
            }
        } else {
            liveContent
        }
        #else
        liveContent
        #endif
    }

    @ViewBuilder private var liveContent: some View {
        switch layout {
        case .groupRows:
            observingLifecycle(
                VStack(alignment: .leading, spacing: 12) {
                    allowedSubagentsHeading
                    allowedAgents
                }
            )
            allowedWorkspaceAgents
            permissionRow
            workspacePermissionRow
            limitsHeader
            budgetSteppers
            currentLocalExecutionContract
            advancedSection
        case .stacked:
            observingLifecycle(
                VStack(alignment: .leading, spacing: 12) {
                    allowedSubagentsHeading
                    allowedAgents
                    divider
                    allowedWorkspaceAgents
                    divider
                    permissionRow
                    workspacePermissionRow
                    divider
                    VStack(alignment: .leading, spacing: 8) {
                        limitsHeader
                        budgetSteppers
                        currentLocalExecutionContract
                    }
                    divider
                    advancedSection
                }
                .environment(\.settingsInGroup, true)
            )
        }
    }

    /// Attached to exactly one view: in `.groupRows` the body is several
    /// sibling rows, and a modifier on all of them would run once per row.
    private func observingLifecycle<Content: View>(_ content: Content) -> some View {
        content
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
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ServerRuntimeSettingsStore.didSaveNotification
                )
                .receive(on: DispatchQueue.main)
            ) { _ in runtimeSettingsRevision &+= 1 }
    }

    private func anchor(_ suffix: String) -> String? {
        anchorPrefix.map { "\($0).\(suffix)" }
    }

    // MARK: - Allowed subagents

    private var allowedSubagentsHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Allowed subagents", bundle: .module)
                .font(SettingsFont.rowTitle)
                .foregroundColor(theme.text.primary)
            Text(
                isOrchestrator
                    ? "The agents the Orchestrator may hand a task to. Each runs with its own prompt, model, and tools. New agents join automatically; remove one to keep it out."
                    : "The agents this agent may hand a task to. Each runs with its own prompt, model, and tools. An empty list keeps delegation off.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
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
            SettingsFieldLabel("Allowed agents")
            if selected.isEmpty {
                if isOrchestrator, !agentCandidates.isEmpty {
                    // The silent failure state: agents exist but none is in
                    // the pool, so the Orchestrator cannot hand them work.
                    // Say so and offer the one-click repair.
                    emptyPoolNotice(agentCount: agentCandidates.count)
                } else {
                    emptyHint(
                        isOrchestrator
                            ? "No agents yet. Create starter agents below, or create your own in Agents — every new agent joins this list."
                            : "None yet. Add an agent to delegate a task to it (using its own prompt + model)."
                    )
                }
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
                    if !agentCandidates.isEmpty {
                        addAllAgentsButton
                    }
                    starterAgentsButton
                }
            }
        }
        .settingsLandingAnchor(anchor("allowedAgents"))
    }

    /// Orchestrator-only notice for an empty pool while custom agents exist.
    private func emptyPoolNotice(agentCount: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(10, weight: .semibold)
                .foregroundColor(theme.status.warning.foreground)
            Text(
                String(
                    format: L(
                        "None of your %d agents is in this list, so the Orchestrator cannot hand them work. Add them here (or use Add all agents) to turn delegation back on."
                    ),
                    agentCount
                )
            )
            .textStyle(.footnote)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One click puts every existing custom agent back in the pool — the
    /// repair for a pool that ended up empty (a replace-list apply, an old
    /// migration) while the agents themselves still exist.
    private var addAllAgentsButton: some View {
        SettingsButton(
            .tertiary, "Add all agents", icon: "plus.circle", size: .compact,
            help: "Adds every existing agent to the Orchestrator's allowed list."
        ) {
            var ids = spawnableAgentIDs
            for candidate in agentCandidates where !ids.contains(candidate.id) {
                ids.append(candidate.id)
            }
            spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(ids)
            onChange()
        }
        .settingsLandingAnchor(anchor("addAllAgents"))
    }

    /// One-click runnable pool: the day-one team on the Orchestrator's own
    /// model, auto-joined to the pool.
    private var starterAgentsButton: some View {
        SettingsButton(
            .tertiary, "Create starter agents", icon: "sparkles", size: .compact,
            help:
                "Creates the Planner, Courier, Keeper, and Scout teammates (and Builder on a developer Mac) on your current model and adds them here."
        ) {
            Task { @MainActor in
                addToPool(await TeamSeeder.createTeam(developerMac: DeveloperMacSignal.isDeveloperMac()))
            }
        }
        .settingsLandingAnchor(anchor("starterAgents"))
    }

    private func addToPool(_ created: [Agent]) {
        guard !created.isEmpty else { return }
        var ids = spawnableAgentIDs
        for agent in created where !ids.contains(agent.id) { ids.append(agent.id) }
        spawnableAgentIDs = SpawnableAgentIdentity.normalizedIDs(ids)
        onChange()
    }

    private var agentAddList: some View {
        let selected = spawnableAgentIDs
        let query = agentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = agentCandidates.filter { candidate in
            !selected.contains(candidate.id)
                && (query.isEmpty
                    || candidate.name.localizedCaseInsensitiveContains(query)
                    || candidate.displayDescription.localizedCaseInsensitiveContains(query))
        }
        return VStack(alignment: .leading, spacing: AgentPickerInspectionStyle.metric("gap", 8, theme)) {
            SearchField(
                text: $agentSearch,
                placeholder: "Search agents",
                width: 264)
            ScrollView {
                VStack(alignment: .leading, spacing: AgentPickerInspectionStyle.metric("gap", 2, theme)) {
                    if filtered.isEmpty {
                        agentPickerEmptyHint("No matching agents.").padding(.vertical, theme.space.s6)
                    } else {
                        ForEach(filtered) { candidate in
                            addRow(
                                title: candidate.name,
                                subtitle: candidate.displayDescription.isEmpty
                                    ? nil : candidate.displayDescription
                            ) {
                                setAgent(candidate.id, included: true)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(.horizontal, AgentPickerInspectionStyle.metric("padding", 12, theme)).padding(.vertical, AgentPickerInspectionStyle.metric("padding", 12, theme))
        .agentPickerSurface()
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
            SettingsFieldLabel("Allowed shared agents")
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
                emptyHint("No workspaces yet — join one in Sharing → Workspaces to delegate to shared agents.")
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
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            if let workspaceName, !workspaceName.isEmpty {
                Text("@\(workspaceName)")
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }
            if let owner = candidate?.ownerName, !owner.isEmpty {
                Text("· \(owner)")
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }
            SettingsIconButton("xmark", help: "Remove", size: .compact, action: onRemove)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.control)
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
        return VStack(alignment: .leading, spacing: AgentPickerInspectionStyle.metric("gap", 8, theme)) {
            SearchField(
                text: $workspaceAgentSearch,
                placeholder: "Search shared agents",
                width: 296)
            ScrollView {
                VStack(alignment: .leading, spacing: AgentPickerInspectionStyle.metric("gap", 2, theme)) {
                    if roster.isLoading, workspaceAgentCandidates.isEmpty {
                        HStack(spacing: AgentPickerInspectionStyle.metric("gap", 8, theme)) {
                            ProgressView().controlSize(.small)
                            agentPickerEmptyHint("Loading workspace rosters…")
                        }
                        .padding(.vertical, theme.space.s6)
                    } else if filtered.isEmpty {
                        agentPickerEmptyHint("No matching shared agents.").padding(.vertical, theme.space.s6)
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
        .padding(.horizontal, AgentPickerInspectionStyle.metric("padding", 12, theme)).padding(.vertical, AgentPickerInspectionStyle.metric("padding", 12, theme))
        .agentPickerSurface()
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
            AssignedBaseSegmentedPicker(
                selection: permissionSelection(for: SubagentCapabilityRegistry.spawn.id),
                options: SubagentPermissionPolicy.allCases.map { .init($0, $0.displayName) }
            )
            .fixedSize()
            .accessibilityLabel(Text("Permission", bundle: .module))
        }
        .settingsLandingAnchor(anchor("permission"))
    }

    private var workspacePermissionRow: some View {
        controlRow(
            "Permission for shared (workspace) agents",
            subtitle:
                "A shared agent runs on a teammate's Mac and spends that workspace's credits. Ask is the default; one card covers every shared agent in a wave."
        ) {
            AssignedBaseSegmentedPicker(
                selection: permissionSelection(for: SubagentPermissionDefaults.workspaceSpawnKindId),
                options: SubagentPermissionPolicy.allCases.map { .init($0, $0.displayName) }
            )
            .fixedSize()
            .accessibilityLabel(Text("Permission for shared (workspace) agents", bundle: .module))
        }
        .settingsLandingAnchor(anchor("workspacePermission"))
    }

    // MARK: - Limits

    private var limitsHeader: some View {
        SettingsRow(
            title: "Limits",
            description: limitsSummary,
            anchorId: anchor("limits"),
            verbatimDescription: true
        ) {
            EmptyView()
        }
    }

    @ViewBuilder
    private var budgetSteppers: some View {
        budgetStepper(
            title: "Max output tokens per subagent",
            help: "Total generated tokens per model turn, including reasoning and the final answer. Reasoning can use the entire limit; this does not reserve answer tokens or set a separate thinking budget.",
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
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .frame(width: 76, alignment: .trailing)
        }
        // Re-read the runtime snapshot after the mirrored Server save lands.
        .id(runtimeSettingsRevision)
    }

    private var localExecutionContractSubtitle: String {
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
        title: String,
        help: String,
        keyPath: WritableKeyPath<SubagentBudgets, Int>,
        range: ClosedRange<Int>,
        step: Int,
        anchor suffix: String
    ) -> some View {
        SettingsStepperRow(
            label: title,
            help: help,
            value: budgetBinding(keyPath),
            range: range,
            step: step,
            anchorId: anchor(suffix)
        )
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(theme.motion.quick) {
                    advancedExpanded.toggle()
                }
            } label: {
                SettingsRow(
                    title: "Advanced",
                    description: advancedExpanded ? "" : normalized(modelOverride) ?? "",
                    verbatimDescription: true
                ) {
                    SettingsChevron()
                        .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                advancedExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module)
            )

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
            ModelSearchablePicker(
                items: modelCandidates,
                selection: modelOverrideSelection.emptyAsNil,
                noneTitle: L("Use each agent's model"),
                rowID: selectionID(for:),
                label: { id in modelCandidate(forStoredId: id)?.displayName ?? L("\(id) (unavailable)") },
                style: .compact
            )
        }
        .settingsLandingAnchor(anchor("modelOverride"))
    }

    @ViewBuilder
    private var handoffWarning: some View {
        if !localHandoffEnabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .glyphSize(11)
                    .foregroundColor(theme.status.warning.foreground)
                Text(
                    "\"Swap Local Models for Subagents\" is off. The invoking model stays loaded while a different local subagent runs, including under Server Strict. This uses more memory; memory checks can still refuse the child without evicting the parent. Change the shared setting in Settings → Orchestrator.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.status(.warning))
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
        case .local, .foundation, .imageGeneration:
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
            case .local, .foundation, .imageGeneration: return true
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
        _ title: String,
        subtitle: String = "",
        @ViewBuilder control: () -> Control
    ) -> some View {
        SettingsRow(title: title, description: subtitle, trailing: control)
    }

    private var divider: some View {
        SettingsGroupDivider()
    }

    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removableChip(
        label: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        FilterTokenChip(label, onRemove: onRemove)
    }

    private func agentPickerEmptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text, bundle: .module)
            .agentPickerFont(SettingsFont.rowDescription, property: "text")
            .agentPickerInk("secondary", fallback: theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
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
            Label {
                Text(title, bundle: .module)
            } icon: {
                Image(systemName: "plus")
            }
        }
        .assignedSettingsButtonStyle(.tertiary, size: .compact)
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
            HStack(spacing: AgentPickerInspectionStyle.metric("gap", 8, theme)) {
                VStack(alignment: .leading, spacing: AgentPickerInspectionStyle.metric("gap", 2, theme)) {
                    Text(title)
                        .agentPickerFont(SettingsFont.compactLabel, property: "label")
                        .agentPickerInk("foreground", fallback: theme.text.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .agentPickerFont(SettingsFont.footnote, property: "text")
                            .agentPickerInk("secondary", fallback: theme.text.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .glyphSize(13)
                    .agentPickerInk("accent", fallback: theme.text.link)
            }
            .contentShape(Rectangle())
            .agentPickerRowLayout(horizontal: 4, vertical: 4)
        }
        .agentPickerButtonStyle()
    }
}

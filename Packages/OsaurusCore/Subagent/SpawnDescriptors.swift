//
//  SpawnDescriptors.swift
//  OsaurusCore — Subagent framework
//
//  Rich, render-ready descriptions of an agent's spawnable targets, used to
//  build the dynamic `spawn` system-prompt block. The composer resolves the
//  launching agent's spawnable AGENT UUIDs + MODEL ids (from
//  `SubagentToolVisibility`) into these descriptors so the prompt can enumerate
//  what `spawn_agent` / `spawn_model` can actually reach — with locality
//  (local/remote), provider, size/quant, vision, the agent's description, and
//  the user's per-model note — instead of bare names. Pure value types; the
//  `@MainActor` resolver is the only piece that touches live caches.
//

import Foundation

/// Shared schema contract for every text-worker spawn surface.
///
/// Text workers are context-isolated: a bare model has no parent transcript,
/// and an agent receives only its own prompt plus this input. Keeping one
/// description prevents the single and batch tools from drifting into
/// incompatible guidance.
enum SpawnInputContract {
    static let schemaDescription =
        "The complete standalone task for the worker. Include every instruction, input value, "
        + "constraint, and required output format the worker needs; it cannot see the parent chat "
        + "or infer what an opaque label means. Never refer to a previous/earlier message, content "
        + "above, or prior conversation; copy the exact required information into this input."

    static let backgroundParameterDescription =
        "Optional; default false. When true, the tool returns immediately and the helper keeps "
        + "running in the background; its result arrives later as a follow-up message in this "
        + "conversation. Use for long-running work. Do not wait, poll, or re-dispatch the same "
        + "task — acknowledge to the user that the helper will report back."

    /// Enforce only the structural part of the standalone-input contract.
    ///
    /// Whether prose depends on parent-chat state cannot be decided safely by
    /// substring matching: quoted text, translation work, and source code may
    /// legitimately contain phrases such as “previous message”. The schema
    /// description remains the model-facing guidance; execution rejects only a
    /// task that is structurally empty.
    static func validationFailure(
        input: String,
        field: String = "input",
        tool: String
    ) -> String? {
        guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message:
                "The worker task in `\(field)` cannot be blank. Provide the complete standalone "
                + "instructions, input values, constraints, and required output format.",
            field: field,
            expected: "a non-empty standalone worker task",
            tool: tool,
            retryable: true
        )
    }
}

/// One spawnable agent (`spawn_agent` target), resolved for the prompt.
public struct SpawnAgentDescriptor: Sendable, Equatable {
    /// Stable execution/authorization identity.
    public let id: UUID
    public let name: String
    /// The agent's own description (trimmed; nil when blank).
    public let description: String?
    /// The agent's effective model id (nil when none resolved).
    public let modelId: String?
    /// Locality of `modelId`: `true` local, `false` remote, nil when unknown
    /// (cold picker cache / model not currently present).
    public let isLocal: Bool?
    /// Remote provider name when the model is remote (nil otherwise).
    public let providerName: String?

    public init(
        id: UUID,
        name: String,
        description: String?,
        modelId: String?,
        isLocal: Bool?,
        providerName: String?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.modelId = modelId
        self.isLocal = isLocal
        self.providerName = providerName
    }
}

/// One spawnable model (`spawn_model` target), resolved for the prompt.
public struct SpawnModelDescriptor: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// `true` local, `false` remote, nil when unknown.
    public let isLocal: Bool?
    public let providerName: String?
    public let parameterCount: String?
    public let quantization: String?
    public let isVLM: Bool
    /// The user's "when/how to use" note for this model (trimmed; nil when none).
    public let note: String?

    public init(
        id: String,
        displayName: String,
        isLocal: Bool?,
        providerName: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        note: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.isLocal = isLocal
        self.providerName = providerName
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.isVLM = isVLM
        self.note = note
    }
}

/// One spawnable shared WORKSPACE agent (`spawn_agent` target that runs on a
/// teammate's Mac), resolved for the prompt. Deliberately carries NO model
/// and NO presence: the host decides the model (and may change it), and
/// presence flips constantly — either in the prompt would reset the prefix
/// cache on almost every turn. Liveness is probed at spawn time instead
/// (`WorkspaceAgentLiveness`).
public struct SpawnWorkspaceAgentDescriptor: Sendable, Equatable {
    /// Durable identity (`(workspaceId, agentAddress)`); the tool enum value
    /// is `ref.agentAddress`.
    public let ref: WorkspaceAgentRef
    /// The sharer's chosen display name (roster → pairing → last known →
    /// shortened address).
    public let name: String
    /// The roster description (trimmed; nil when blank).
    public let description: String?
    /// Workspace display name, when the roster knows it.
    public let workspaceName: String?
    /// The sharer's friendly name, when the roster knows it.
    public let ownerName: String?

    public init(
        ref: WorkspaceAgentRef,
        name: String,
        description: String?,
        workspaceName: String?,
        ownerName: String?
    ) {
        self.ref = ref
        self.name = name
        self.description = description
        self.workspaceName = workspaceName
        self.ownerName = ownerName
    }
}

/// Request-local execution truth for one configured spawn target. Durable
/// configuration remains untouched so unavailable rows can still be repaired
/// or removed in Settings.
enum SpawnTargetState: Sendable, Equatable {
    case runnable
    case checking
    case disconnected
    case missing
}

struct SpawnAgentTarget: Sendable, Equatable {
    let descriptor: SpawnAgentDescriptor
    let state: SpawnTargetState
}

struct SpawnModelTarget: Sendable, Equatable {
    let descriptor: SpawnModelDescriptor
    let state: SpawnTargetState
}

/// A workspace target is `runnable` or `missing` ONLY (never `checking` /
/// `disconnected`): membership is durable state that changes by user action
/// (unshare, leave workspace, router off), like deleting a local agent.
struct SpawnWorkspaceAgentTarget: Sendable, Equatable {
    let descriptor: SpawnWorkspaceAgentDescriptor
    let state: SpawnTargetState
}

/// One immutable target view shared by prompt prose and every spawn schema for
/// a request. This prevents provider/model changes between composition phases
/// from producing zombie options or prompt/schema drift.
struct SpawnTargetAvailabilitySnapshot: Sendable, Equatable {
    static let empty = SpawnTargetAvailabilitySnapshot(agentTargets: [], modelTargets: [])

    let agentTargets: [SpawnAgentTarget]
    let modelTargets: [SpawnModelTarget]
    let workspaceAgentTargets: [SpawnWorkspaceAgentTarget]

    init(
        agentTargets: [SpawnAgentTarget],
        modelTargets: [SpawnModelTarget],
        workspaceAgentTargets: [SpawnWorkspaceAgentTarget] = []
    ) {
        self.agentTargets = agentTargets
        self.modelTargets = modelTargets
        self.workspaceAgentTargets = workspaceAgentTargets
    }

    var agents: [SpawnAgentDescriptor] {
        agentTargets.compactMap { $0.state == .runnable ? $0.descriptor : nil }
    }

    var models: [SpawnModelDescriptor] {
        modelTargets.compactMap { $0.state == .runnable ? $0.descriptor : nil }
    }

    var workspaceAgents: [SpawnWorkspaceAgentDescriptor] {
        workspaceAgentTargets.compactMap { $0.state == .runnable ? $0.descriptor : nil }
    }

    var runnableAgentIDs: [UUID] { agents.map(\.id) }
    var runnableModelIds: [String] { models.map(\.id) }
    var runnableWorkspaceAgents: [WorkspaceAgentRef] { workspaceAgents.map(\.ref) }
    /// Whether `spawn_agent` has anything to reach (local or workspace).
    var hasRunnableAgentTargets: Bool {
        !runnableAgentIDs.isEmpty || !runnableWorkspaceAgents.isEmpty
    }
}

/// Resolves configured spawn pools against current execution truth.
public enum SpawnDescriptors {
    struct AgentSource: Sendable, Equatable {
        let id: UUID
        let name: String
        let description: String
        let modelId: String?
    }

    /// Durable roster view of one shared workspace agent, for the workspace
    /// spawn line. Built from roster membership + cached names only — never
    /// from presence or the paired provider's connection state, so a
    /// teammate's host going to sleep cannot change composed prompt bytes.
    struct WorkspaceAgentSource: Sendable, Equatable {
        let ref: WorkspaceAgentRef
        let name: String
        let description: String
        let workspaceName: String?
        let ownerName: String?
    }

    /// Resolve a real request against authoritative local installation truth.
    /// Cold discovery suspends off-main instead of blocking the UI or treating
    /// a valid bundle as removed.
    @MainActor
    static func resolveForRequest(
        agentIDs: [UUID],
        modelNames: [String],
        modelNotes: [String: String],
        launcherModelOverride: String?,
        workspaceAgents: [WorkspaceAgentRef] = []
    ) async -> SpawnTargetAvailabilitySnapshot {
        let shouldDiscoverLocalModels = requiresLocalDiscovery(
            agentIDs: agentIDs,
            modelNames: modelNames,
            launcherModelOverride: launcherModelOverride
        )
        let localModels =
            shouldDiscoverLocalModels
            ? await ModelManager.discoverLocalModelsOffMain()
            : []
        return resolve(
            agentIDs: agentIDs,
            modelNames: modelNames,
            modelNotes: modelNotes,
            agentSources: liveAgentSources(),
            localModels: localModels,
            localCatalogIsAuthoritative: !shouldDiscoverLocalModels
                || ModelManager.isLocalModelsCacheWarm,
            pickerItems: ModelPickerItemCache.shared.items,
            connectedRemoteTargets:
                RemoteProviderManager.shared.connectedSpawnModelTargetIndex(),
            remoteProviderNames: Dictionary(
                uniqueKeysWithValues:
                    RemoteProviderManager.shared.configuration.providers.map {
                        ($0.id, $0.name)
                    }
            ),
            foundationAvailable: AppConfiguration.shared.foundationModelAvailable,
            launcherModelOverride: launcherModelOverride,
            workspaceAgents: workspaceAgents,
            workspaceSources: liveWorkspaceAgentSources(for: workspaceAgents)
        )
    }

    /// Whether request composition needs authoritative local-install truth.
    /// Agent-only pools still need discovery because each target agent's own
    /// effective model can be local; a launcher override needs the same check
    /// even when no bare-model targets are configured.
    static func requiresLocalDiscovery(
        agentIDs: [UUID],
        modelNames: [String],
        launcherModelOverride: String?
    ) -> Bool {
        !agentIDs.isEmpty
            || !modelNames.isEmpty
            || !(launcherModelOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
    }

    /// Synchronous context-budget preview. Cold misses remain `checking` and
    /// are not advertised; the real request above completes discovery.
    @MainActor
    static func resolveForPreview(
        agentIDs: [UUID],
        modelNames: [String],
        modelNotes: [String: String],
        launcherModelOverride: String?,
        workspaceAgents: [WorkspaceAgentRef] = []
    ) -> SpawnTargetAvailabilitySnapshot {
        let authoritative = ModelManager.isLocalModelsCacheWarm
        return resolve(
            agentIDs: agentIDs,
            modelNames: modelNames,
            modelNotes: modelNotes,
            agentSources: liveAgentSources(),
            localModels: ModelManager.localModelsSnapshotNonBlocking(),
            localCatalogIsAuthoritative: authoritative,
            pickerItems: ModelPickerItemCache.shared.items,
            connectedRemoteTargets:
                RemoteProviderManager.shared.connectedSpawnModelTargetIndex(),
            remoteProviderNames: Dictionary(
                uniqueKeysWithValues:
                    RemoteProviderManager.shared.configuration.providers.map {
                        ($0.id, $0.name)
                    }
            ),
            foundationAvailable: AppConfiguration.shared.foundationModelAvailable,
            launcherModelOverride: launcherModelOverride,
            workspaceAgents: workspaceAgents,
            workspaceSources: liveWorkspaceAgentSources(for: workspaceAgents)
        )
    }

    /// Compatibility view for callers that only need currently runnable
    /// descriptors. Production request composition uses `resolveForRequest`
    /// so cold local discovery is completed before the schema is frozen.
    @MainActor
    public static func resolve(
        agentIDs: [UUID],
        modelNames: [String],
        modelNotes: [String: String]
    ) -> (agents: [SpawnAgentDescriptor], models: [SpawnModelDescriptor]) {
        let snapshot = resolveForPreview(
            agentIDs: agentIDs,
            modelNames: modelNames,
            modelNotes: modelNotes,
            launcherModelOverride: nil
        )
        return (
            snapshot.agents,
            snapshot.models
        )
    }

    /// Pure classification seam used by focused lifecycle tests.
    @MainActor
    static func resolve(
        agentIDs: [UUID],
        modelNames: [String],
        modelNotes: [String: String],
        agentSources: [AgentSource],
        localModels: [MLXModel],
        localCatalogIsAuthoritative: Bool,
        pickerItems: [ModelPickerItem],
        connectedRemoteTargets: RemoteProviderManager.ConnectedSpawnModelTargetIndex,
        remoteProviderNames: [UUID: String],
        foundationAvailable: Bool,
        launcherModelOverride: String? = nil,
        workspaceAgents: [WorkspaceAgentRef] = [],
        workspaceSources: [WorkspaceAgentSource]? = nil
    ) -> SpawnTargetAvailabilitySnapshot {
        let agentTargets = agentIDs.map { configuredID -> SpawnAgentTarget in
            guard
                let source = agentSources.first(where: { $0.id == configuredID })
            else {
                return SpawnAgentTarget(
                    descriptor: SpawnAgentDescriptor(
                        id: configuredID,
                        name: configuredID.uuidString,
                        description: nil,
                        modelId: nil,
                        isLocal: nil,
                        providerName: nil
                    ),
                    state: .missing
                )
            }
            let effectiveModel = launcherModelOverride ?? source.modelId
            let effectiveTarget = effectiveModel.map {
                resolveModelTarget(
                    id: $0,
                    note: nil,
                    localModels: localModels,
                    localCatalogIsAuthoritative: localCatalogIsAuthoritative,
                    pickerItems: pickerItems,
                    connectedRemoteTargets: connectedRemoteTargets,
                    remoteProviderNames: remoteProviderNames,
                    foundationAvailable: foundationAvailable
                )
            }
            let locality = classify(
                modelId: effectiveModel,
                localModels: localModels,
                pickerItems: pickerItems,
                connectedRemoteTargets: connectedRemoteTargets,
                remoteProviderNames: remoteProviderNames,
                foundationAvailable: foundationAvailable
            )
            let description = source.description.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return SpawnAgentTarget(
                descriptor: SpawnAgentDescriptor(
                    id: source.id,
                    name: source.name,
                    description: description.isEmpty ? nil : description,
                    modelId: locality.normalizedId,
                    isLocal: locality.isLocal,
                    providerName: locality.providerName
                ),
                state: effectiveTarget?.state ?? .missing
            )
        }

        let modelTargets = modelNames.map { configuredId -> SpawnModelTarget in
            resolveModelTarget(
                id: configuredId,
                note: noteFor(configuredId, in: modelNotes),
                localModels: localModels,
                localCatalogIsAuthoritative: localCatalogIsAuthoritative,
                pickerItems: pickerItems,
                connectedRemoteTargets: connectedRemoteTargets,
                remoteProviderNames: remoteProviderNames,
                foundationAvailable: foundationAvailable
            )
        }

        let workspaceTargets = resolveWorkspaceTargets(
            configured: workspaceAgents,
            sources: workspaceSources ?? []
        )

        return SpawnTargetAvailabilitySnapshot(
            agentTargets: agentTargets,
            modelTargets: modelTargets,
            workspaceAgentTargets: workspaceTargets
        )
    }

    /// Pure: a configured workspace ref with a source is `runnable`; one
    /// without is `missing` (unshared, workspace left, or router off — the
    /// source list is built from durable roster membership only).
    static func resolveWorkspaceTargets(
        configured: [WorkspaceAgentRef],
        sources: [WorkspaceAgentSource]
    ) -> [SpawnWorkspaceAgentTarget] {
        SubagentConfiguration.normalizedWorkspaceAgents(configured).map { ref in
            guard let source = sources.first(where: { $0.ref == ref }) else {
                return SpawnWorkspaceAgentTarget(
                    descriptor: SpawnWorkspaceAgentDescriptor(
                        ref: ref,
                        name: OsaurusRouterWorkspacePerson.shortWallet(ref.agentAddress),
                        description: nil,
                        workspaceName: nil,
                        ownerName: nil
                    ),
                    state: .missing
                )
            }
            let description = source.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return SpawnWorkspaceAgentTarget(
                descriptor: SpawnWorkspaceAgentDescriptor(
                    ref: ref,
                    name: source.name,
                    description: description.isEmpty ? nil : description,
                    workspaceName: source.workspaceName,
                    ownerName: source.ownerName
                ),
                state: .runnable
            )
        }
    }

    /// Durable roster view for each configured workspace ref. A ref counts as
    /// known when its workspace roster lists it, OR when the roster for that
    /// workspace has not been loaded yet in this process (cold start: trust the
    /// durable allow-list — execution still probes liveness — rather than
    /// flipping the prompt bytes once the first poll lands). It is unknown
    /// (→ `missing`) only when the roster IS loaded and does not list it, or
    /// the store has refreshed and the workspace itself is gone.
    ///
    /// Reads NO presence (`online`, `forcedOffline`, `hostReachableAt`) and NO
    /// `RemoteProviderManager` connection state, by design.
    @MainActor
    static func liveWorkspaceAgentSources(
        for refs: [WorkspaceAgentRef]
    ) -> [WorkspaceAgentSource] {
        guard !refs.isEmpty else { return [] }
        let roster = WorkspaceRosterStore.shared
        let remoteAgents = RemoteAgentManager.shared
        return refs.compactMap { ref -> WorkspaceAgentSource? in
            let workspaceRoster = roster.rosters.first { $0.id == ref.workspaceId }
            let listed = workspaceRoster?.agents.first {
                $0.agentAddress.lowercased() == ref.agentAddress
            }
            if listed == nil {
                // Loaded roster that omits the agent → unshared.
                if workspaceRoster != nil { return nil }
                // Store refreshed and the workspace is gone → left/removed.
                if roster.lastRefreshedAt != nil { return nil }
            }
            // Never advertise one of this instance's own agents as a target.
            if roster.isOwnAgent(address: ref.agentAddress) { return nil }
            let paired = remoteAgents.remoteAgent(
                forAddress: ref.agentAddress, workspaceId: ref.workspaceId
            )
            let rosterName = listed?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name =
                (rosterName?.isEmpty == false ? rosterName : nil)
                ?? (paired?.name.isEmpty == false ? paired?.name : nil)
                ?? roster.lastKnownName(forAddress: ref.agentAddress)
                ?? OsaurusRouterWorkspacePerson.shortWallet(ref.agentAddress)
            return WorkspaceAgentSource(
                ref: ref,
                name: name,
                description: listed?.description ?? paired?.description ?? "",
                workspaceName: workspaceRoster?.workspace.name,
                ownerName: listed?.owner?.friendlyName
            )
        }
    }

    private static func resolveModelTarget(
        id: String,
        note: String?,
        localModels: [MLXModel],
        localCatalogIsAuthoritative: Bool,
        pickerItems: [ModelPickerItem],
        connectedRemoteTargets: RemoteProviderManager.ConnectedSpawnModelTargetIndex,
        remoteProviderNames: [UUID: String],
        foundationAvailable: Bool
    ) -> SpawnModelTarget {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == ModelPickerItem.foundation().id {
            return SpawnModelTarget(
                descriptor: descriptor(id: trimmed, item: .foundation(), note: note),
                state: foundationAvailable ? .runnable : .missing
            )
        }

        // Match execution order: an installed local id wins before a legacy
        // remote picker id with the same spelling.
        if let local = ModelManager.matchInstalledMLXModel(named: trimmed, in: localModels) {
            return SpawnModelTarget(
                descriptor: descriptor(id: trimmed, item: .fromMLXModel(local), note: note),
                state: .runnable
            )
        }

        if let remote = connectedRemoteTargets.target(forStoredId: trimmed) {
            let item = pickerItems.first { candidate in
                guard case .remote(_, let providerId) = candidate.source else { return false }
                return providerId == remote.providerId
                    && candidate.id == remote.pickerModelId
            }
            return SpawnModelTarget(
                // Preserve the configured id: allow-list authorization is
                // exact, and execution normalizes a connected legacy id only
                // after that check succeeds.
                descriptor: SpawnModelDescriptor(
                    id: trimmed,
                    displayName: item?.displayName ?? shortName(fromModelId: remote.modelId),
                    isLocal: false,
                    providerName: remote.providerName,
                    parameterCount: item?.parameterCount,
                    quantization: item?.quantization,
                    isVLM: item?.isVLM ?? false,
                    note: note
                ),
                state: .runnable
            )
        }

        if let parsed = SpawnRemoteModelIdentity.parse(trimmed) {
            let providerName = remoteProviderNames[parsed.providerId]
            return SpawnModelTarget(
                descriptor: SpawnModelDescriptor(
                    id: trimmed,
                    displayName: shortName(fromModelId: parsed.modelId),
                    isLocal: false,
                    providerName: providerName,
                    parameterCount: nil,
                    quantization: nil,
                    isVLM: false,
                    note: note
                ),
                state: providerName == nil ? .missing : .disconnected
            )
        }

        // Legacy remote ids used the provider's picker prefix. Preserve them
        // while disconnected, but never advertise them as runnable.
        let legacyProviders = remoteProviderNames.filter { _, name in
            trimmed.hasPrefix(RemoteProviderManager.pickerPrefix(for: name) + "/")
        }
        let state: SpawnTargetState =
            !legacyProviders.isEmpty
            ? .disconnected
            : (localCatalogIsAuthoritative ? .missing : .checking)
        return SpawnModelTarget(
            descriptor: SpawnModelDescriptor(
                id: trimmed,
                displayName: shortName(fromModelId: trimmed),
                isLocal: nil,
                providerName: legacyProviders.count == 1
                    ? legacyProviders.first?.value : nil,
                parameterCount: nil,
                quantization: nil,
                isVLM: false,
                note: note
            ),
            state: state
        )
    }

    @MainActor
    private static func liveAgentSources() -> [AgentSource] {
        AgentManager.shared.agents.map { agent in
            AgentSource(
                id: agent.id,
                name: agent.name,
                description: agent.description,
                modelId: AgentManager.shared.effectiveModel(for: agent.id)
            )
        }
    }

    private static func descriptor(
        id: String,
        item: ModelPickerItem,
        note: String?
    ) -> SpawnModelDescriptor {
        let locality = classify(item: item)
        return SpawnModelDescriptor(
            id: id,
            displayName: item.displayName,
            isLocal: locality.isLocal,
            providerName: locality.providerName,
            parameterCount: item.parameterCount,
            quantization: item.quantization,
            isVLM: item.isVLM,
            note: note
        )
    }

    private static func classify(
        modelId: String?,
        localModels: [MLXModel],
        pickerItems: [ModelPickerItem],
        connectedRemoteTargets: RemoteProviderManager.ConnectedSpawnModelTargetIndex,
        remoteProviderNames: [UUID: String],
        foundationAvailable: Bool
    ) -> (isLocal: Bool?, providerName: String?, normalizedId: String?) {
        guard let trimmed = modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return (nil, nil, nil) }
        if trimmed == ModelPickerItem.foundation().id {
            return (foundationAvailable ? true : nil, nil, trimmed)
        }
        if ModelManager.matchInstalledMLXModel(named: trimmed, in: localModels) != nil {
            return (true, nil, trimmed)
        }
        if let remote = connectedRemoteTargets.target(forStoredId: trimmed) {
            return (false, remote.providerName, remote.id)
        }
        if let parsed = SpawnRemoteModelIdentity.parse(trimmed) {
            return (false, remoteProviderNames[parsed.providerId], trimmed)
        }
        if let item = pickerItems.first(where: { $0.id == trimmed }) {
            let locality = classify(item: item)
            return (locality.isLocal, locality.providerName, trimmed)
        }
        return (nil, nil, trimmed)
    }

    private static func classify(item: ModelPickerItem) -> (isLocal: Bool?, providerName: String?) {
        switch item.source {
        case .remote(let providerName, _):
            return (false, providerName)
        case .claudeCode:
            // Not local: the CLI runs on this Mac, but inference happens on
            // Anthropic's servers, so the locality badge must not claim
            // on-device.
            return (false, ModelPickerItem.Source.claudeCode.displayName)
        case .local, .foundation, .imageGeneration:
            return (true, nil)
        }
    }

    private static func shortName(fromModelId id: String) -> String {
        guard let slashIndex = id.lastIndex(of: "/") else { return id }
        return String(id[id.index(after: slashIndex)...])
    }

    private static func noteFor(_ id: String, in notes: [String: String]) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = notes[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !note.isEmpty
        else { return nil }
        return note
    }
}

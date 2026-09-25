//
//  SpawnDescriptors.swift
//  OsaurusCore — Subagent framework
//
//  Rich, render-ready descriptions of an agent's spawnable targets, used to
//  build the dynamic `spawn` system-prompt block. The composer resolves the
//  launching agent's spawnable AGENT UUIDs + workspace refs (from
//  `SubagentToolVisibility`) into these descriptors so the prompt can
//  enumerate what `spawn_agent` can actually reach — with locality
//  (local/remote), provider, the agent's description, and its working folder
//  — instead of bare names. Pure value types; the `@MainActor` resolver is
//  the only piece that touches live caches.
//

import Foundation

/// Shared schema contract for the delegation tool.
///
/// Workers are context-isolated: an agent receives only its own prompt plus
/// this input, never the parent transcript.
enum SpawnInputContract {
    static let schemaDescription =
        "The complete standalone task. The agent cannot see this chat, so include every "
        + "instruction, input value, constraint, and the required output format here."

    static let backgroundParameterDescription =
        "Default false. True returns immediately; the result arrives later as a follow-up "
        + "message. Do not poll or re-send."

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
    /// The agent's own configured Working Folder (`Agent.workingFolderPath`),
    /// nil when none is set. A delegated child runs as a real chat session
    /// of the target agent; when the agent has its own folder the child
    /// works there, otherwise it inherits the launcher's folder
    /// (`AgentDelegationDispatcher`). Surfaced in the spawn guidance so the
    /// orchestrator knows where a worker's files land.
    public let workingFolderPath: String?

    public init(
        id: UUID,
        name: String,
        description: String?,
        modelId: String?,
        isLocal: Bool?,
        providerName: String?,
        workingFolderPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.modelId = modelId
        self.isLocal = isLocal
        self.providerName = providerName
        self.workingFolderPath = workingFolderPath?.isEmpty == false ? workingFolderPath : nil
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

    /// `Name@Workspace` when the workspace name is known, else the name.
    public var qualifiedName: String {
        guard let workspaceName, !workspaceName.isEmpty else { return name }
        return "\(name)@\(workspaceName)"
    }
}

/// Request-local execution truth for one configured spawn target. Durable
/// configuration remains untouched so unavailable rows can still be repaired
/// or removed in Settings.
enum SpawnTargetState: Sendable, Equatable {
    case runnable
    case descriptionRequired
    case checking
    case disconnected
    case missing
}

struct SpawnAgentTarget: Sendable, Equatable {
    let descriptor: SpawnAgentDescriptor
    let state: SpawnTargetState
}

/// A workspace target is `runnable`, `descriptionRequired`, or `missing` (never `checking` /
/// `disconnected`): membership is durable state that changes by user action
/// (unshare, leave workspace, router off), like deleting a local agent.
struct SpawnWorkspaceAgentTarget: Sendable, Equatable {
    let descriptor: SpawnWorkspaceAgentDescriptor
    let state: SpawnTargetState
}

/// One immutable target view shared by prompt prose and the spawn schema for
/// a request. This prevents provider/model changes between composition phases
/// from producing zombie options or prompt/schema drift.
struct SpawnTargetAvailabilitySnapshot: Sendable, Equatable {
    static let empty = SpawnTargetAvailabilitySnapshot(agentTargets: [])

    let agentTargets: [SpawnAgentTarget]
    let workspaceAgentTargets: [SpawnWorkspaceAgentTarget]

    init(
        agentTargets: [SpawnAgentTarget],
        workspaceAgentTargets: [SpawnWorkspaceAgentTarget] = []
    ) {
        self.agentTargets = agentTargets
        self.workspaceAgentTargets = workspaceAgentTargets
    }

    var agents: [SpawnAgentDescriptor] {
        agentTargets.compactMap { $0.state == .runnable ? $0.descriptor : nil }
    }

    var workspaceAgents: [SpawnWorkspaceAgentDescriptor] {
        workspaceAgentTargets.compactMap { $0.state == .runnable ? $0.descriptor : nil }
    }

    var runnableAgentIDs: [UUID] { agents.map(\.id) }
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
        /// The agent's sticky Working Folder path, nil when none is set.
        var workingFolderPath: String? = nil
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
        launcherModelOverride: String?,
        workspaceAgents: [WorkspaceAgentRef] = []
    ) async -> SpawnTargetAvailabilitySnapshot {
        let shouldDiscoverLocalModels = requiresLocalDiscovery(
            agentIDs: agentIDs,
            launcherModelOverride: launcherModelOverride
        )
        let localModels =
            shouldDiscoverLocalModels
            ? await ModelManager.discoverLocalModelsOffMain()
            : []
        return resolve(
            agentIDs: agentIDs,
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
    /// Each target agent's own effective model can be local; a launcher
    /// override needs the same check.
    static func requiresLocalDiscovery(
        agentIDs: [UUID],
        launcherModelOverride: String?
    ) -> Bool {
        !agentIDs.isEmpty
            || !(launcherModelOverride?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
    }

    /// Synchronous context-budget preview. Cold misses remain `checking` and
    /// are not advertised; the real request above completes discovery.
    @MainActor
    static func resolveForPreview(
        agentIDs: [UUID],
        launcherModelOverride: String?,
        workspaceAgents: [WorkspaceAgentRef] = []
    ) -> SpawnTargetAvailabilitySnapshot {
        let authoritative = ModelManager.isLocalModelsCacheWarm
        return resolve(
            agentIDs: agentIDs,
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
    public static func resolve(agentIDs: [UUID]) -> [SpawnAgentDescriptor] {
        resolveForPreview(agentIDs: agentIDs, launcherModelOverride: nil).agents
    }

    /// Pure classification seam used by focused lifecycle tests.
    @MainActor
    static func resolve(
        agentIDs: [UUID],
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
            let modelState = effectiveModel.map {
                resolveModelState(
                    id: $0,
                    localModels: localModels,
                    localCatalogIsAuthoritative: localCatalogIsAuthoritative,
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
                    providerName: locality.providerName,
                    workingFolderPath: source.workingFolderPath
                ),
                state: AgentDescriptionPolicy.violation(in: description) == nil
                    ? (modelState ?? .missing) : .descriptionRequired
            )
        }

        let workspaceTargets = resolveWorkspaceTargets(
            configured: workspaceAgents,
            sources: workspaceSources ?? []
        )

        return SpawnTargetAvailabilitySnapshot(
            agentTargets: agentTargets,
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
                state: AgentDescriptionPolicy.violation(in: description) == nil
                    ? .runnable : .descriptionRequired
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
            if roster.isHostedHere(address: ref.agentAddress) { return nil }
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
                description: workspaceRoutingDescription(listed: listed?.description, paired: paired?.description),
                workspaceName: workspaceRoster?.workspace.name,
                ownerName: listed?.owner?.friendlyName
            )
        }
    }

    /// The optional public roster blurb can predate required descriptions.
    /// Prefer it when usable, otherwise use the paired host's description.
    /// An unusable blurb must not hide a valid description supplied by the host.
    static func workspaceRoutingDescription(listed: String?, paired: String?) -> String {
        for candidate in [listed, paired].compactMap({ $0 }) {
            if let valid = try? AgentDescriptionPolicy.validated(candidate) { return valid }
        }
        return ""
    }

    /// Execution truth for one model id (an agent's effective model): is it
    /// installed / connected right now, disconnected, missing, or still
    /// being discovered?
    private static func resolveModelState(
        id: String,
        localModels: [MLXModel],
        localCatalogIsAuthoritative: Bool,
        connectedRemoteTargets: RemoteProviderManager.ConnectedSpawnModelTargetIndex,
        remoteProviderNames: [UUID: String],
        foundationAvailable: Bool
    ) -> SpawnTargetState {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == ModelPickerItem.foundation().id {
            return foundationAvailable ? .runnable : .missing
        }
        // Match execution order: an installed local id wins before a legacy
        // remote picker id with the same spelling.
        if ModelManager.matchInstalledMLXModel(named: trimmed, in: localModels) != nil {
            return .runnable
        }
        if connectedRemoteTargets.target(forStoredId: trimmed) != nil {
            return .runnable
        }
        if let parsed = SpawnRemoteModelIdentity.parse(trimmed) {
            return remoteProviderNames[parsed.providerId] == nil ? .missing : .disconnected
        }
        // Legacy remote ids used the provider's picker prefix. Preserve them
        // while disconnected, but never advertise them as runnable.
        let legacyProviders = remoteProviderNames.filter { _, name in
            trimmed.hasPrefix(RemoteProviderManager.pickerPrefix(for: name) + "/")
        }
        if !legacyProviders.isEmpty { return .disconnected }
        return localCatalogIsAuthoritative ? .missing : .checking
    }

    @MainActor
    private static func liveAgentSources() -> [AgentSource] {
        AgentManager.shared.agents.map { agent in
            AgentSource(
                id: agent.id,
                name: agent.name,
                description: agent.description,
                modelId: AgentManager.shared.effectiveModel(for: agent.id),
                // Same source of truth as the dispatch-folder fallback
                // (`BackgroundTaskManager.resolveDispatchFolder`), so the
                // folder the prompt advertises is the folder the child runs in.
                workingFolderPath: AgentManager.shared.workingFolder(for: agent.id)?.path
            )
        }
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
}

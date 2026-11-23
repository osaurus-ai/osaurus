//
//  WorkspaceWorkflowCatalog.swift
//  osaurus
//
//  What each of this Mac's workspaces offers: the templates members shared
//  there (`GET /workspaces/:id/workflows` on the store registry) and the
//  workflows teammates' shared agents run for the team on their own Macs
//  (`hosted_workflows`, filled in by `HostedWorkflowDirectory`). Settings →
//  workspace → Workflows, the Workflows window's Workspaces tab and the
//  agent tools all read it, so one fetch serves them all. Results are kept
//  for a few minutes; a suspended workspace or a failed fetch is a state of
//  its own, never an empty list.
//

import Combine
import Foundation

@MainActor
final class WorkspaceWorkflowCatalog: ObservableObject {
    static let shared = WorkspaceWorkflowCatalog(observesWorkspaces: true)

    /// How long a fetch stays fresh before an appearance fetches again.
    static let freshness: TimeInterval = 5 * 60

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        case suspended
        case routerOff
    }

    struct Entry: Equatable {
        var listings: [WorkflowsRegistryWorkspaceItem] = []
        var hosted: [HostedWorkflowOffer] = []
        var state: State = .idle
        var fetchedAt: Date?

        var workflows: [WorkflowsRegistryWorkspaceItem] { listings.filter { $0.kind == .workflow } }
    }

    /// What installing a listing would do on this Mac.
    enum InstallState: Equatable {
        case notInstalled
        /// Installed, but setup never finished.
        case setUp
        case update(from: Int)
        case installed
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private let fetchListings: @MainActor (String) async throws -> [WorkflowsRegistryWorkspaceItem]
    private let fetchHosted: @MainActor (String) async -> [HostedWorkflowOffer]
    private let workspaces: @MainActor () -> [OsaurusRouterWorkspaceSummary]
    private let routerEnabled: @MainActor () -> Bool
    private let now: () -> Date
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var subscription: AnyCancellable?

    init(
        fetchListings: @escaping @MainActor (String) async throws -> [WorkflowsRegistryWorkspaceItem] = {
            try await WorkflowShareService.shared.workspaceWorkflows(workspaceID: $0)
        },
        fetchHosted: @escaping @MainActor (String) async -> [HostedWorkflowOffer] = {
            await HostedWorkflowDirectory.offers(inWorkspace: $0)
        },
        workspaces: @escaping @MainActor () -> [OsaurusRouterWorkspaceSummary] = { WorkspacesService.shared.workspaces },
        routerEnabled: @escaping @MainActor () -> Bool = { RemoteProviderManager.shared.isOsaurusRouterEnabled },
        now: @escaping () -> Date = Date.init,
        observesWorkspaces: Bool = false
    ) {
        self.fetchListings = fetchListings
        self.fetchHosted = fetchHosted
        self.workspaces = workspaces
        self.routerEnabled = routerEnabled
        self.now = now
        if observesWorkspaces {
            // A workspace that's gone takes its listings with it.
            subscription = WorkspacesService.shared.$workspaces
                .receive(on: RunLoop.main)
                .sink { [weak self] list in
                    let ids = Set(list.map(\.id))
                    self?.entries = self?.entries.filter { ids.contains($0.key) } ?? [:]
                }
        }
    }

    func entry(_ workspaceID: String) -> Entry { entries[workspaceID] ?? Entry() }

    /// Fetches unless the last fetch is still fresh (`force` always does).
    func refresh(_ workspaceID: String, force: Bool = false) async {
        if let task = inFlight[workspaceID] { return await task.value }
        let current = entry(workspaceID)
        if !force, current.state == .loaded, let at = current.fetchedAt, now().timeIntervalSince(at) < Self.freshness {
            return
        }
        guard routerEnabled() else {
            entries[workspaceID, default: Entry()].state = .routerOff
            return
        }
        if workspaces().first(where: { $0.id == workspaceID })?.isSuspended == true {
            entries[workspaceID, default: Entry()].state = .suspended
            return
        }
        entries[workspaceID, default: Entry()].state = .loading
        let task = Task { @MainActor in
            async let hosted = fetchHosted(workspaceID)
            do {
                let listings = try await fetchListings(workspaceID)
                entries[workspaceID] = Entry(
                    listings: listings, hosted: await hosted, state: .loaded, fetchedAt: now())
            } catch {
                var failed = entry(workspaceID)
                failed.hosted = await hosted
                failed.state = .failed(WorkflowErrorText.text(error))
                entries[workspaceID] = failed
            }
        }
        inFlight[workspaceID] = task
        await task.value
        inFlight[workspaceID] = nil
    }

    /// Every workspace this Mac belongs to, concurrently.
    func refreshAll(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for workspace in workspaces() {
                group.addTask { await self.refresh(workspace.id, force: force) }
            }
        }
    }

    /// A listing taken out of a workspace leaves the cache at once.
    func removeListing(_ registryID: String, from workspaceID: String) {
        entries[workspaceID]?.listings.removeAll { $0.id == registryID }
    }

    nonisolated static func installState(localVersion: Int?, sharedVersion: Int, needsSetup: Bool = false) -> InstallState {
        guard let localVersion else { return .notInstalled }
        if needsSetup { return .setUp }
        return localVersion < sharedVersion ? .update(from: localVersion) : .installed
    }

    nonisolated static func installState(
        for item: WorkflowsRegistryWorkspaceItem, installed: InstalledWorkflow?
    ) -> InstallState {
        installState(
            localVersion: installed?.templateVersion, sharedVersion: item.latestVersion,
            needsSetup: installed?.needsSetup == true)
    }

    /// A workflow by its install; an agent template by the saved copy.
    func installState(for item: WorkflowsRegistryWorkspaceItem) -> InstallState {
        if item.kind == .agent {
            return Self.installState(
                localVersion: TemplateStore.shared.latest(id: item.templateID)?.version, sharedVersion: item.latestVersion)
        }
        return Self.installState(for: item, installed: InstalledWorkflowStore.shared.workflow(templateID: item.templateID))
    }

    /// A workspace workflow the user could install or add here but hasn't:
    /// what agents are told is available (`osaurus_config` `workflows`).
    struct Available: Equatable, Sendable {
        enum Kind: String, Sendable { case install, runOnTheirMac = "run_on_their_mac", both }
        var name: String
        var summary: String
        var workspaceID: String
        var workspaceName: String
        var author: String
        var kind: Kind
    }

    /// Listings not installed and hosted workflows not added, by workspace
    /// then name. A listing its author also hosts is one entry, `both`.
    func available(
        installedTemplateIDs: Set<UUID> = Set(InstalledWorkflowStore.shared.workflows.map(\.templateID)),
        addedHostedIDs: Set<String> = HostedWorkflowLinkStore.shared.remoteKeys
    ) -> [Available] {
        let names = Dictionary(workspaces().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return entries.keys.sorted().flatMap { workspaceID -> [Available] in
            let entry = entries[workspaceID] ?? Entry()
            return Self.available(
                entry, workspaceID: workspaceID, workspaceName: names[workspaceID] ?? workspaceID,
                installedTemplateIDs: installedTemplateIDs, addedHostedIDs: addedHostedIDs)
        }
    }

    nonisolated static func available(
        _ entry: Entry, workspaceID: String, workspaceName: String,
        installedTemplateIDs: Set<UUID>, addedHostedIDs: Set<String>
    ) -> [Available] {
        var out: [Available] = []
        let hostedByTemplate = Dictionary(
            entry.hosted.map { ($0.templateID, $0) }, uniquingKeysWith: { first, _ in first })
        var covered = Set<String>()
        for item in entry.workflows where !installedTemplateIDs.contains(item.templateID) {
            let hosted = hostedByTemplate[item.templateID].flatMap {
                addedHostedIDs.contains($0.remoteKey) ? nil : $0
            }
            if let hosted { covered.insert(hosted.remoteKey) }
            out.append(
                Available(
                    name: item.name, summary: item.summary, workspaceID: workspaceID, workspaceName: workspaceName,
                    author: item.author.handle, kind: hosted == nil ? .install : .both))
        }
        for offer in entry.hosted
        where !covered.contains(offer.remoteKey) && !addedHostedIDs.contains(offer.remoteKey) {
            out.append(
                Available(
                    name: offer.name, summary: offer.summary ?? "", workspaceID: workspaceID,
                    workspaceName: workspaceName, author: offer.ownerName ?? offer.agentName, kind: .runOnTheirMac))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Name (Workspace)" for each available workflow called `key`, from
    /// what's already fetched.
    func offeredNames(matching key: String) -> [String] {
        let wanted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return available().filter {
            $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame
                || InstalledWorkflow.toolName(for: $0.name) == wanted
        }
        .map { "\($0.name) (\($0.workspaceName))" }
    }
}

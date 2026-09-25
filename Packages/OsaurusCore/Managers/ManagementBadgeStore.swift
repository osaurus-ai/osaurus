//
//  ManagementBadgeStore.swift
//  osaurus
//
//  Aggregates per-tab sidebar badge counts/highlights so `ManagementView`
//  doesn't have to observe nine separate `ObservableObject` singletons
//  (and re-run a synchronous `MemoryDatabase.pinnedFactStats()` SQLite query)
//  every time any of them publishes.
//
//  The store fans in publishes from the managers we used to observe
//  directly, throttles them, and emits a single coalesced snapshot. The
//  expensive metrics are hoisted onto a background task so even the
//  recompute itself doesn't block the main thread. Identity/Keychain state
//  is intentionally not polled here; startup badges must not trigger
//  password prompts or background Keychain reads.
//

import Combine
import Foundation

@MainActor
public final class ManagementBadgeStore: ObservableObject {
    public static let shared = ManagementBadgeStore()

    public struct Snapshot: Equatable {
        public var counts: [ManagementTab: Int] = [:]
        public var highlights: Set<ManagementTab> = []
    }

    @Published public private(set) var snapshot = Snapshot()

    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    /// Throttle window for recomputes triggered by manager `objectWillChange`
    /// bursts (model download progress is the worst-case offender at
    /// ~tens of Hz). 150ms keeps the badge feeling live without re-doing
    /// the array walks on every chunk.
    private static let refreshDebounce: Duration = .milliseconds(150)

    /// How often to re-poll the metrics that we don't have a publisher
    /// for (currently the Memory pinned-facts count). The badge is a
    /// rough indicator, so a minute of staleness is acceptable.
    private static let periodicRefreshInterval: Duration = .seconds(60)

    private init() {
        wireSources()
        scheduleRefresh()
        startPeriodicRefresh()
    }

    /// Force an immediate recompute. Tabs that mutate state can call this
    /// to make their badge feel snappy (e.g. after a successful pin/unpin
    /// in `MemoryView`).
    public func refreshNow() {
        refreshTask?.cancel()
        refreshTask = nil
        recompute()
    }

    // MARK: - Sources

    private func wireSources() {
        // Combine-published managers. Throttled to absorb burst publishes
        // (e.g. model download progress chunks).
        let publishers: [AnyPublisher<Void, Never>] = [
            ModelManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            RemoteProviderManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            AgentManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            // Paired remote agents count toward the Agents badge, like the
            // Agents page header.
            RemoteAgentManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            PluginRepositoryService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SandboxPluginLibrary.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SpeechModelManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ThemeManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            WorkspacesService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(publishers)
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        // NotificationCenter sources for managers we don't observe via
        // Combine (ScheduleManager / WatcherManager are plain classes
        // that post notifications) plus the toolsListChanged signal that
        // affects the Tools badge.
        for name in [
            Notification.Name.toolsListChanged,
            Notification.Name("schedulesChanged"),
            Notification.Name("watchersChanged"),
            Notification.Name.knowledgeCollectionsChanged,
            Notification.Name.knowledgeCurationChanged,
            // Image / video bundles (the Media badge) are announced here
            // after an import or delete.
            Notification.Name.localModelsChanged,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh()
                }
            }
            observers.append(observer)
        }
    }

    // `deinit` deliberately omitted: this is a `.shared` singleton whose
    // lifetime matches the process. The Combine cancellables and
    // NotificationCenter observer tokens we hold would clean themselves
    // up on dealloc anyway, and adding a nonisolated deinit that touches
    // either array trips the Swift 6 Sendable checker.

    // MARK: - Refresh

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.refreshDebounce)
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
            self?.recompute()
        }
    }

    private func startPeriodicRefresh() {
        periodicTask?.cancel()
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicRefreshInterval)
                if Task.isCancelled { break }
                self?.recompute()
            }
        }
    }

    /// Recompute the snapshot. Cheap in-memory counts are gathered on
    /// MainActor; SQLite + Keychain probes are spawned in a detached
    /// task so the recompute itself never blocks the main thread.
    private func recompute() {
        var counts = Self.mainActorCounts(
            connectedInferenceProviders: {
                // Paired Osaurus agents hidden from Cloud Models (their owner
                // shares no models for inference) don't count toward the
                // Cloud Models badge.
                let providerManager = RemoteProviderManager.shared
                return providerManager.configuration.providers.filter {
                    providerManager.providerStates[$0.id]?.isConnected == true
                        && providerManager.exposesModelsForInference($0)
                }.count
            }(),
            sandboxPlugins: SandboxPluginLibrary.shared.plugins.count,
            tools: ToolRegistry.shared.toolCount,
            skills: SkillManager.shared.skills.count,
            customCommands: SlashCommandRegistry.shared.customCommands.count,
            customAgents: AgentManager.shared.agents.filter { !$0.isBuiltIn }.count,
            remoteAgents: RemoteAgentManager.shared.remoteAgents.count,
            schedules: ScheduleManager.shared.schedules.count,
            watchers: WatcherManager.shared.watchers.count,
            knowledgeCollections: KnowledgeManager.shared.collections.count,
            downloadedSpeechModels: SpeechModelManager.shared.downloadedModelsCount,
            installedThemes: ThemeManager.shared.installedThemes.count,
            workspaces: WorkspacesService.shared.workspaces.count,
            observedChannelCount: observedCount(for: .agentChannels)
        )
        // A staged Workspaces deep link (subscription activation or invite link)
        // is waiting for the user's confirmation tap — highlight until it's
        // redeemed or discarded.
        let workspacesActionPending =
            WorkspacesService.shared.pendingActivation != nil || WorkspacesService.shared.pendingJoin != nil

        // Preserve previously-known values for the metrics we'll refresh
        // off-MainActor; otherwise the badge would flicker to 0 every
        // recompute until the background task completes.
        for tab in Self.backgroundResolvedTabs {
            if let prior = snapshot.counts[tab] {
                counts[tab] = prior
            }
        }

        var highlights: Set<ManagementTab> = []
        if workspacesActionPending {
            highlights.insert(.workspaces)
        }
        // Knowledge highlight ("proposals awaiting review") is resolved
        // off-main below; carry the prior value so it doesn't flicker.
        if snapshot.highlights.contains(.knowledge) {
            highlights.insert(.knowledge)
        }

        let next = Snapshot(counts: counts, highlights: highlights)
        if next != snapshot {
            snapshot = next
        }

        // Background metrics. SQLite must not run on the main thread from a
        // SwiftUI body, so we hoist it here. The models count is also
        // resolved here: `isDownloaded` walks the model directory on a cache
        // miss, so doing it inline would block the main thread; the image /
        // video bundle scan for the Media badge is a directory walk too. Do
        // not probe identity/Keychain from this path; startup badge
        // freshness is less important than avoiding password prompts while
        // local chat boots.
        let models = ModelManager.shared.availableModels
        Task.detached(priority: .utility) { [weak self] in
            let downloadedModels = models.filter { $0.isDownloaded }.count
            let imageModels = (try? await ImageGenerationService.shared.availableModels().count) ?? 0
            let pinned = (try? MemoryDatabase.shared.pinnedFactStats()) ?? 0
            // Pending knowledge proposals drive the "review needed"
            // highlight. Only counted when the knowledge database is
            // already open — a badge poll must not trigger the first open.
            let pendingProposals =
                KnowledgeDatabase.shared.isOpen
                ? ((try? KnowledgeDatabase.shared.pendingProposalCount()) ?? 0)
                : 0
            await self?.applyBackgroundBadges(
                downloadedModels: downloadedModels,
                imageModels: imageModels,
                pinnedFacts: pinned,
                pendingKnowledgeProposals: pendingProposals
            )
        }
    }

    /// Tabs whose count is resolved in the detached background task and
    /// therefore carried over between recomputes rather than recalculated.
    nonisolated static let backgroundResolvedTabs: [ManagementTab] = [.models, .imageGeneration, .memory]

    /// The synchronous, main-actor part of the badge computation as a pure
    /// function of the inputs so the "what does each badge count" contract
    /// is unit-testable without seeding a dozen singletons. Every count
    /// mirrors the matching page header: Agents = custom + paired remote,
    /// Themes = every installed theme (built-ins included), Workspaces =
    /// workspaces the user belongs to.
    nonisolated static func mainActorCounts(
        connectedInferenceProviders: Int,
        sandboxPlugins: Int,
        tools: Int,
        skills: Int,
        customCommands: Int,
        customAgents: Int,
        remoteAgents: Int,
        schedules: Int,
        watchers: Int,
        knowledgeCollections: Int,
        downloadedSpeechModels: Int,
        installedThemes: Int,
        workspaces: Int,
        observedChannelCount: Int?
    ) -> [ManagementTab: Int] {
        var counts: [ManagementTab: Int] = [:]
        counts[.providers] = connectedInferenceProviders
        counts[.sandbox] = sandboxPlugins
        counts[.tools] = tools
        counts[.skills] = skills
        counts[.commands] = customCommands
        counts[.agents] = customAgents + remoteAgents
        counts[.schedules] = schedules
        counts[.watchers] = watchers
        counts[.knowledge] = knowledgeCollections
        counts[.voice] = downloadedSpeechModels
        counts[.themes] = installedThemes
        counts[.workspaces] = workspaces
        if let observedChannelCount {
            counts[.agentChannels] = observedChannelCount
        }
        return counts
    }

    // MARK: - Observed counts

    /// Counts the store cannot compute itself. The Channels page header
    /// needs Keychain credential probes to know which native channels are
    /// configured, and this store never touches the Keychain (see the file
    /// header). The page pushes its computed count here whenever it has one;
    /// the value is cached in `UserDefaults` so the badge is right from the
    /// first frame of the next launch instead of blank until the page opens.
    nonisolated static func observedCountDefaultsKey(for tab: ManagementTab) -> String {
        "managementBadge.observedCount.\(tab.rawValue)"
    }

    private func observedCount(for tab: ManagementTab) -> Int? {
        let key = Self.observedCountDefaultsKey(for: tab)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key)
    }

    /// Record a count a settings page computed for its own tab, and
    /// recompute so the badge updates immediately.
    public func setObservedCount(_ count: Int, for tab: ManagementTab) {
        let key = Self.observedCountDefaultsKey(for: tab)
        if UserDefaults.standard.object(forKey: key) != nil,
            UserDefaults.standard.integer(forKey: key) == count
        {
            return
        }
        UserDefaults.standard.set(count, forKey: key)
        refreshNow()
    }

    private func applyBackgroundBadges(
        downloadedModels: Int,
        imageModels: Int,
        pinnedFacts: Int,
        pendingKnowledgeProposals: Int
    ) {
        var counts = snapshot.counts
        counts[.models] = downloadedModels
        counts[.imageGeneration] = imageModels
        counts[.memory] = pinnedFacts

        var highlights = snapshot.highlights
        if pendingKnowledgeProposals > 0 {
            highlights.insert(.knowledge)
        } else if KnowledgeDatabase.shared.isOpen {
            // Authoritative zero (DB was consulted) clears the highlight.
            highlights.remove(.knowledge)
        }

        let next = Snapshot(counts: counts, highlights: highlights)
        if next != snapshot {
            snapshot = next
        }
    }
}

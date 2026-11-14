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

    /// The sidebar badge for `tab`, for its page header's `count:` so the two
    /// never disagree. Nil when the badge is hidden.
    public func headerCount(for tab: ManagementTab) -> Int? {
        guard let count = snapshot.counts[tab], count > 0 else { return nil }
        return count
    }

    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var taskBusToken: TaskBus.Token?
    private var refreshTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    /// In-memory mirror of the observed counts persisted in `UserDefaults`.
    /// `recompute()` runs on the main actor every 60s and after every source
    /// change; reading `UserDefaults` there can synchronously flush pending
    /// preference KVO notifications and hang the main thread, so the hot
    /// path reads this cache instead. Seeded once at init and kept in sync
    /// by `setObservedCount(_:for:)`.
    private var observedCounts: [ManagementTab: Int] = [:]

    /// Tabs whose badge count is pushed in by a settings page rather than
    /// computed by the store.
    private static let observedTabs: [ManagementTab] = [.agentChannels]

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
        loadObservedCounts()
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

    /// "Missing keys" count, pushed by `CredentialRegistry` so this store
    /// never probes the Keychain itself.
    private var missingKeysCount = 0

    func setMissingKeysCount(_ count: Int) {
        guard count != missingKeysCount else { return }
        missingKeysCount = count
        var next = snapshot
        next.counts[.keys] = count
        snapshot = next
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
            // Approvals: raised and settled attention items.
            AttentionCenter.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            // Help: replies from the Osaurus team the user has not opened.
            SupportService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(publishers)
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        // NotificationCenter sources for managers we don't observe via
        // Combine (EventManager posts a notification on every change) plus the toolsListChanged signal that
        // affects the Tools badge.
        for name in [
            Notification.Name.toolsListChanged,
            Notification.Name.eventsChanged,
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

        // Tasks: the live count and the waiting highlight.
        taskBusToken = TaskStore.shared.bus.observe { [weak self] event in
            if case .taskChanged = event { self?.scheduleRefresh() }
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
            tools: ToolRegistry.shared.toolCount,
            skills: SkillManager.shared.skills.count,
            customCommands: SlashCommandRegistry.shared.customCommands.count,
            customAgents: AgentManager.shared.agents.filter { !$0.isBuiltIn }.count,
            remoteAgents: RemoteAgentManager.shared.remoteAgents.count,
            events: EventManager.shared.events.filter { $0.sourceKind != .channelMessage }.count,
            knowledgeCollections: KnowledgeManager.shared.collections.count,
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

        let liveTasks = TaskStore.shared.live.values
        counts[.tasks] = liveTasks.count
        counts[.keys] = missingKeysCount
        // Help counts unread replies only, the same number as the rail dot.
        let unreadSupportReplies = SupportService.shared.unreadCount
        counts[.help] = unreadSupportReplies
        let waitingApprovals = ApprovalPresentation.waiting(in: AttentionCenter.shared)
        counts[.approvals] = waitingApprovals.count

        var highlights: Set<ManagementTab> = []
        if liveTasks.contains(where: { $0.state == .waitingUser }) {
            highlights.insert(.tasks)
        }
        if !waitingApprovals.isEmpty {
            highlights.insert(.approvals)
        }
        if workspacesActionPending {
            highlights.insert(.workspaces)
        }
        if unreadSupportReplies > 0 {
            highlights.insert(.help)
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
        // miss, so doing it inline would block the main thread. Do not probe identity/Keychain from this path; startup badge
        // freshness is less important than avoiding password prompts while
        // local chat boots.
        let inventoryCandidates = ModelManager.shared.deduplicatedModels()
        Task.detached(priority: .utility) { [weak self] in
            let downloadedModels = Self.modelsBadgeCount(inventoryCandidates: inventoryCandidates)
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
                pinnedFacts: pinned,
                pendingKnowledgeProposals: pendingProposals
            )
        }
    }

    /// Tabs whose count is resolved in the detached background task and
    /// therefore carried over between recomputes rather than recalculated.
    nonisolated static let backgroundResolvedTabs: [ManagementTab] = [.models, .memory]

    /// The Local Models badge: the installed inventory, the same
    /// `ModelManager.installedModels(among:)` the Models page header and On
    /// Device tab count. `inventoryCandidates` is
    /// `ModelManager.deduplicatedModels()` captured on the main actor; the
    /// `isDownloaded` probe runs wherever this is called (off main from
    /// `recompute`). Before this the badge counted `availableModels` while the
    /// page counted a differently deduplicated list, and the two disagreed
    /// (91 vs 63) whenever an installed external bundle shared an id with a
    /// catalog suggestion.
    nonisolated static func modelsBadgeCount(inventoryCandidates: [MLXModel]) -> Int {
        ModelManager.installedModels(among: inventoryCandidates).count
    }

    /// The synchronous, main-actor part of the badge computation as a pure
    /// function of the inputs so the "what does each badge count" contract
    /// is unit-testable without seeding a dozen singletons. Every count
    /// mirrors the matching page header: Agents = custom + paired remote,
    /// Workspaces = workspaces the user belongs to. Only pages that list the
    /// user's own items get a badge; status pages (Voice, Images & Video,
    /// Sandbox) do not.
    nonisolated static func mainActorCounts(
        connectedInferenceProviders: Int,
        tools: Int,
        skills: Int,
        customCommands: Int,
        customAgents: Int,
        remoteAgents: Int,
        events: Int,
        knowledgeCollections: Int,
        workspaces: Int,
        observedChannelCount: Int?
    ) -> [ManagementTab: Int] {
        var counts: [ManagementTab: Int] = [:]
        counts[.providers] = connectedInferenceProviders
        counts[.tools] = tools
        counts[.skills] = skills
        counts[.commands] = customCommands
        counts[.agents] = customAgents + remoteAgents
        counts[.automations] = events
        counts[.knowledge] = knowledgeCollections
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

    /// Seed the in-memory cache from `UserDefaults` once, so the badge is
    /// right from the first frame without re-reading defaults on every
    /// recompute.
    private func loadObservedCounts() {
        let defaults = UserDefaults.standard
        observedCounts = [:]
        for tab in Self.observedTabs {
            let key = Self.observedCountDefaultsKey(for: tab)
            if defaults.object(forKey: key) != nil {
                observedCounts[tab] = defaults.integer(forKey: key)
            }
        }
    }

    /// Re-seed the cache from `UserDefaults` and recompute. Not used on the
    /// hot path; lets tests restore the shared store after mutating the
    /// persisted counts directly so no state leaks into later tests.
    func reloadObservedCountsFromDefaults() {
        loadObservedCounts()
        refreshNow()
    }

    private func observedCount(for tab: ManagementTab) -> Int? {
        observedCounts[tab]
    }

    /// Record a count a settings page computed for its own tab, persist it
    /// for the next launch, and recompute so the badge updates immediately.
    public func setObservedCount(_ count: Int, for tab: ManagementTab) {
        guard observedCounts[tab] != count else { return }
        observedCounts[tab] = count
        UserDefaults.standard.set(count, forKey: Self.observedCountDefaultsKey(for: tab))
        refreshNow()
    }

    private func applyBackgroundBadges(
        downloadedModels: Int,
        pinnedFacts: Int,
        pendingKnowledgeProposals: Int
    ) {
        var counts = snapshot.counts
        counts[.models] = downloadedModels
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

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
            PluginRepositoryService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SandboxPluginLibrary.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SpeechModelManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            ThemeManager.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
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
        var counts: [ManagementTab: Int] = [:]
        counts[.providers] =
            RemoteProviderManager.shared.providerStates.values.filter(\.isConnected).count
        counts[.plugins] = PluginRepositoryService.shared.plugins.filter { $0.isInstalled }.count
        counts[.sandbox] = SandboxPluginLibrary.shared.plugins.count
        counts[.tools] = ToolRegistry.shared.toolCount
        counts[.skills] = SkillManager.shared.skills.count
        counts[.commands] = SlashCommandRegistry.shared.customCommands.count
        counts[.agents] = AgentManager.shared.agents.filter { !$0.isBuiltIn }.count
        counts[.schedules] = ScheduleManager.shared.schedules.count
        counts[.watchers] = WatcherManager.shared.watchers.count
        counts[.voice] = SpeechModelManager.shared.downloadedModelsCount
        counts[.themes] = ThemeManager.shared.installedThemes.filter { !$0.isBuiltIn }.count

        // Preserve previously-known values for the metrics we'll refresh
        // off-MainActor; otherwise the badge would flicker to 0 every
        // recompute until the background task completes.
        if let prior = snapshot.counts[.models] {
            counts[.models] = prior
        }
        if let prior = snapshot.counts[.memory] {
            counts[.memory] = prior
        }
        if let prior = snapshot.counts[.identity] {
            counts[.identity] = prior
        }

        var highlights: Set<ManagementTab> = []
        if PluginRepositoryService.shared.updatesAvailableCount > 0 {
            highlights.insert(.plugins)
        }
        if snapshot.highlights.contains(.identity) {
            highlights.insert(.identity)
        }

        let next = Snapshot(counts: counts, highlights: highlights)
        if next != snapshot {
            snapshot = next
        }

        // Background metrics. SQLite must not run on the main thread from a
        // SwiftUI body, so we hoist it here. The models count is also
        // resolved here: `isDownloaded` walks the model directory on a cache
        // miss, so doing it inline would block the main thread. Do not probe
        // identity/Keychain from this path; startup badge freshness is less
        // important than avoiding password prompts while local chat boots.
        let models = ModelManager.shared.availableModels
        Task.detached(priority: .utility) { [weak self] in
            let downloadedModels = models.filter { $0.isDownloaded }.count
            let pinned = (try? MemoryDatabase.shared.pinnedFactStats()) ?? 0
            await self?.applyBackgroundBadges(downloadedModels: downloadedModels, pinnedFacts: pinned)
        }
    }

    private func applyBackgroundBadges(downloadedModels: Int, pinnedFacts: Int) {
        var counts = snapshot.counts
        counts[.models] = downloadedModels
        counts[.memory] = pinnedFacts

        let next = Snapshot(counts: counts, highlights: snapshot.highlights)
        if next != snapshot {
            snapshot = next
        }
    }
}

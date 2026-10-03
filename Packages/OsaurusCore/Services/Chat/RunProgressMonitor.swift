//
//  RunProgressMonitor.swift
//  osaurus
//
//  Owns composer-chip liveness for one chat run: event clock, stream-burst
//  ring, and subscriptions to live exec / subagent / load / sandbox.
//

import Combine
import Foundation

@MainActor
final class RunProgressMonitor: ObservableObject {
    @Published private(set) var state: RunProgressState = .active

    private var lastProgressAt = Date()
    private var streamTimestamps: [Date] = []
    private var clearsLatch = false
    private var poll: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var liveExecSubscriptions: [String: AnyCancellable] = [:]
    private var subagentSubscriptions: [String: AnyCancellable] = [:]

    private var toolCallIds: () -> Set<String> = { [] }
    private var sessionId: () -> String? = { nil }
    private var agentId: () -> UUID? = { nil }

    func note(_ kind: RunProgressKind) {
        lastProgressAt = Date()
        if kind == .stream {
            RunProgressEvaluator.recordStreamTimestamp(
                &streamTimestamps,
                at: lastProgressAt
            )
            clearsLatch = false
            if state == .active { return }
        } else {
            clearsLatch = true
        }
        apply()
    }

    func start(
        toolCallIds: @escaping () -> Set<String>,
        sessionId: @escaping () -> String?,
        agentId: @escaping () -> UUID?
    ) {
        self.toolCallIds = toolCallIds
        self.sessionId = sessionId
        self.agentId = agentId
        resetClock()
        state = .active
        poll?.cancel()
        bindSources()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.syncLiveExec(LiveExecRegistry.shared.currentEntries())
                self.apply()
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        clearSources()
        resetClock()
        state = .active
    }

    private func resetClock() {
        lastProgressAt = Date()
        streamTimestamps = []
        clearsLatch = false
    }

    private func apply() {
        let now = Date()
        let idle = now.timeIntervalSince(lastProgressAt)
        let next = RunProgressEvaluator.state(
            idle: idle,
            previous: state,
            isSustainedStreamBurst: RunProgressEvaluator.isSustainedStreamBurst(
                timestamps: streamTimestamps,
                now: now
            ),
            clearsLatch: clearsLatch,
            loadingPhase: RunProgressLoadingPhase.current(agentId: agentId())
        )
        clearsLatch = false
        guard next != state else { return }
        state = next
        if next == .stalled {
            CrashReportingService.recordBreadcrumb(
                category: "chat.run",
                message: "run stalled: no progress for \(Int(idle))s"
            )
        }
    }

    private func bindSources() {
        clearSources()

        LiveExecRegistry.shared.entriesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] entries in
                self?.syncLiveExec(entries)
            }
            .store(in: &subscriptions)

        SubagentFeedRegistry.shared.feedsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] feeds in
                self?.syncSubagentFeeds(feeds)
            }
            .store(in: &subscriptions)

        let inference = InferenceProgressManager.shared
        observeDiscrete(inference.$prefillProgress, throttleSeconds: 1)
        observeDiscrete(inference.$loadInFlightCount)

        let sandbox = SandboxManager.State.shared
        observeDiscrete(sandbox.$status)
        observeDiscrete(sandbox.$isProvisioning)
        observeDiscrete(sandbox.$provisioningProgress, throttleSeconds: 1)

        syncLiveExec(LiveExecRegistry.shared.currentEntries())
    }

    private func observeDiscrete<P: Publisher>(
        _ publisher: P,
        throttleSeconds: TimeInterval? = nil
    ) where P.Failure == Never {
        let ticks = publisher.dropFirst().map { _ in () }
        let onMain: AnyPublisher<Void, Never>
        if let throttleSeconds {
            onMain = ticks
                .throttle(
                    for: .seconds(throttleSeconds),
                    scheduler: RunLoop.main,
                    latest: true
                )
                .eraseToAnyPublisher()
        } else {
            onMain = ticks.receive(on: RunLoop.main).eraseToAnyPublisher()
        }
        onMain.sink { [weak self] in self?.note(.discrete) }
            .store(in: &subscriptions)
    }

    private func syncLiveExec(_ entries: [String: LiveExecRegistry.Entry]) {
        let owned = toolCallIds()
        let relevant = entries.filter { owned.contains($0.key) }
        syncKeyedSubscriptions(relevant, into: &liveExecSubscriptions) { _, entry in
            entry.outputPublisher
                .receive(on: RunLoop.main)
                .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in self?.note(.discrete) }
        }
    }

    private func syncSubagentFeeds(_ feeds: [String: SubagentFeed]) {
        let sessionKey = sessionId()
        let owned = toolCallIds()
        let relevant = feeds.filter { _, feed in
            if let sessionKey, feed.parentSessionId == sessionKey { return true }
            return owned.contains(feed.toolCallId)
        }
        syncKeyedSubscriptions(relevant, into: &subagentSubscriptions) { _, feed in
            // CurrentValueSubject seeded with `[]` — drop the replay.
            feed.eventsPublisher
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.note(.discrete) }
        }
    }

    private func syncKeyedSubscriptions<Item>(
        _ current: [String: Item],
        into storage: inout [String: AnyCancellable],
        subscribe: (String, Item) -> AnyCancellable
    ) {
        let wanted = Set(current.keys)
        for id in Set(storage.keys).subtracting(wanted) {
            storage[id]?.cancel()
            storage[id] = nil
        }
        for (id, item) in current where storage[id] == nil {
            storage[id] = subscribe(id, item)
        }
    }

    private func clearSources() {
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        liveExecSubscriptions.values.forEach { $0.cancel() }
        liveExecSubscriptions.removeAll()
        subagentSubscriptions.values.forEach { $0.cancel() }
        subagentSubscriptions.removeAll()
    }
}

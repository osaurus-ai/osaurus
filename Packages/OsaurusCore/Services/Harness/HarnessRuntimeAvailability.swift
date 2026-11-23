//
//  HarnessRuntimeAvailability.swift
//  osaurus
//
//  Whether each Claude Code runtime's CLI is installed and signed in, for
//  the chat picker. A check spawns `claude --version` and `claude auth
//  status`, so it runs off the main actor and at most once per
//  `minimumInterval` per runtime; editing a runtime checks it again at once.
//

import Foundation

@MainActor
final class HarnessRuntimeAvailability: ObservableObject {
    enum State: Sendable, Equatable {
        case notInstalled
        case needsSignIn
        /// Signed in, or a CLI too old to report its sign-in (a chat then
        /// surfaces the sign-in error itself).
        case ready
    }

    static let shared = HarnessRuntimeAvailability()
    static let minimumInterval: TimeInterval = 30

    /// Missing until a runtime's first check finishes. Pi runtimes are
    /// never checked.
    @Published private(set) var states: [UUID: State] = [:]

    var check: @Sendable (HarnessRuntime) async -> State = { await HarnessRuntimeAvailability.liveState(of: $0) }
    var now: () -> Date = Date.init

    private var checkedAt: [UUID: Date] = [:]
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// Bumped by a forced check so a superseded result is dropped.
    private var generation: [UUID: Int] = [:]
    private var observer: NSObjectProtocol?

    init(observeRuntimeChanges: Bool = true) {
        guard observeRuntimeChanges else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .harnessRuntimesChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let id = note.object as? UUID
            MainActor.assumeIsolated { self?.runtimesChanged(id) }
        }
    }

    func state(of runtimeId: UUID) -> State? { states[runtimeId] }

    /// Checks each Claude Code runtime not checked within `minimumInterval`
    /// (or every one, with `force`).
    func refresh(_ runtimes: [HarnessRuntime], force: Bool = false) {
        for runtime in runtimes where runtime.kind == .claudeCode {
            let id = runtime.id
            if !force {
                if inFlight[id] != nil { continue }
                if let at = checkedAt[id], now().timeIntervalSince(at) < Self.minimumInterval { continue }
            }
            inFlight[id]?.cancel()
            let token = (generation[id] ?? 0) &+ 1
            generation[id] = token
            let check = self.check
            inFlight[id] = Task { [weak self] in
                let state = await Task.detached { await check(runtime) }.value
                guard let self, self.generation[id] == token else { return }
                self.inFlight[id] = nil
                self.checkedAt[id] = self.now()
                if self.states[id] != state { self.states[id] = state }
            }
        }
    }

    /// Waits for the checks already running.
    func settle() async {
        for task in Array(inFlight.values) { await task.value }
    }

    private func runtimesChanged(_ id: UUID?) {
        let runtimes = HarnessRuntimeStore.shared.all()
        let live = Set(runtimes.map(\.id))
        for stale in states.keys where !live.contains(stale) {
            states[stale] = nil
            checkedAt[stale] = nil
        }
        refresh(runtimes.filter { id == nil || $0.id == id }, force: true)
    }

    nonisolated static func liveState(of runtime: HarnessRuntime) async -> State {
        switch await ClaudeCodeConfiguration.setupState(command: runtime.executable, overlay: runtime.environment) {
        case .notInstalled: return .notInstalled
        case .signedOut: return .needsSignIn
        case .statusUnavailable, .signedIn: return .ready
        }
    }
}

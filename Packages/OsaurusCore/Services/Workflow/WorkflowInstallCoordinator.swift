//
//  WorkflowInstallCoordinator.swift
//  osaurus
//
//  Finishes a workflow install in the background. It downloads every model
//  the plan lists (taking over a download already running rather than
//  starting it again), sets up the sandbox and the workflow's packages,
//  then checks the workflow again: with nothing left blocking it installs
//  it, otherwise it waits for the person. Nothing is installed before that
//  check passes, so a started install is a job, not a half-installed
//  workflow.
//
//  Jobs are saved to disk and resume on launch; both download services skip
//  files already verified, so a resumed download picks up where it was.
//

import Foundation

@MainActor
final class WorkflowInstallCoordinator: ObservableObject {
    static let shared = WorkflowInstallCoordinator(environment: .live())

    typealias Item = WorkflowInstallPlan.Item

    enum Phase: Codable, Equatable, Sendable {
        case running
        /// Everything Osaurus could do is done; something only the person
        /// can answer still blocks.
        case needsYou
        case failed(String)
        case done(installedID: UUID)
    }

    enum ItemState: Codable, Equatable, Sendable {
        case waiting
        case working
        case done
        case failed(String)

        var isSettled: Bool {
            switch self {
            case .done, .failed: return true
            case .waiting, .working: return false
            }
        }
    }

    /// Which service's state a download is read from.
    enum DownloadKey: Codable, Equatable, Hashable, Sendable {
        case chat(String)
        case media(String)
    }

    /// A download as its service reports it.
    struct Transfer: Equatable {
        var state: DownloadState
        var received: Int64?
        var total: Int64?
        var bytesPerSecond: Double?
    }

    struct Job: Identifiable {
        let id: UUID
        var subject: WorkflowSetupSubject
        var items: [Item]
        var states: [String: ItemState]
        var phase: Phase
        /// Downloads this job started (not adopted): the only ones Cancel
        /// stops.
        var started: Set<String> = []
        /// The download each item is read from, once known.
        var keys: [String: DownloadKey] = [:]
        var attempts: [String: Int] = [:]
        var retryAt: [String: Date] = [:]

        // Recomputed every tick; not saved.
        /// Byte-weighted, 0...1.
        var progress: Double = 0
        /// What is happening now, in plain words.
        var activity: String = ""
        /// Smoothed seconds left, refreshed every few seconds. Nil when not
        /// known yet.
        var remaining: TimeInterval?
        fileprivate var rawRemaining: TimeInterval?
        fileprivate var remainingPublishedAt: Date?
        /// Downloads whose start is still resolving the repo.
        fileprivate var starting: Set<String> = []
        /// Sandbox and package work in flight.
        fileprivate var running: Set<String> = []

        var name: String { subject.name }
        var templateID: UUID { subject.template.id }
        var isActive: Bool { phase == .running }

        func state(of item: Item) -> ItemState { states[item.id] ?? .waiting }
    }

    /// Everything the coordinator does to the machine, injectable for tests.
    struct Environment {
        /// Starts a chat model download; returns the key its progress is
        /// read from (an image bundle linked as a chat repo reports as
        /// media).
        var startChat: @MainActor (String) async throws -> DownloadKey
        var startMedia: @MainActor (MediaModelSource) -> Void
        var transfer: @MainActor (DownloadKey) -> Transfer?
        var cancel: @MainActor (DownloadKey) -> Void
        var provisionSandbox: @MainActor () async throws -> Void
        var installPackages: @MainActor ([WorkflowDependency], UUID) async throws -> Void
        var check: @MainActor (WorkflowSetupSubject) -> SetupReport
        /// Installs the workflow; returns its id, or nil when it could not.
        var commit: @MainActor (WorkflowSetupSubject) throws -> UUID?
        /// Drops a rail wizard parked on the same workflow: one owner per
        /// install.
        var clearParked: @MainActor (WorkflowSetupSubject) -> Void = { _ in }
        /// Where jobs are saved; nil keeps them in memory only.
        var storeURL: URL?
        var now: @MainActor () -> Date = { Date() }
        /// How often progress is read while a job runs; nil leaves ticking
        /// to the caller (tests).
        var tickInterval: Duration? = .seconds(1)
        /// Waits before each quiet retry of a failed item.
        var retryDelays: [TimeInterval] = [5, 20, 60]
        /// How often the time left may change on screen.
        var remainingRefresh: TimeInterval = 3
    }

    @Published private(set) var jobs: [Job] = []
    /// Templates whose installer is on screen, so the toast stays away.
    @Published private(set) var presented: Set<UUID> = []

    private let environment: Environment
    private var ticker: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
    }

    func job(id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// The job installing `templateID`, if one exists.
    func job(forTemplate templateID: UUID) -> Job? { jobs.first { $0.templateID == templateID } }

    func setPresented(_ templateID: UUID, _ isPresented: Bool) {
        if isPresented { presented.insert(templateID) } else { presented.remove(templateID) }
    }

    /// The download behind `item`, for its Details line.
    func transfer(of item: Item, in job: Job) -> Transfer? {
        job.keys[item.id].flatMap { environment.transfer($0) }
    }

    /// Reopens `job`'s installer in Workflows.
    static func show(_ job: Job) {
        ManagementStateManager.shared.pendingWorkflowInstall = job.templateID
        AppDelegate.shared?.showManagementWindow(initialTab: .workflows)
    }

    /// Runs the installed workflow's example, or opens its run form.
    static func tryIt(_ job: Job) {
        guard case .done(let id) = job.phase, let workflow = InstalledWorkflowStore.shared.workflow(id: id) else { return }
        if let example = workflow.template.workflow?.examples.first {
            WorkflowRunLauncher.runExample(example, of: workflow)
        } else {
            WorkflowRunLauncher.openTab(workflowID: workflow.id)
        }
    }

    // MARK: - Lifecycle

    /// Starts installing `subject` with the plan's items. A workflow already
    /// being installed keeps its job.
    @discardableResult
    func start(_ subject: WorkflowSetupSubject, items: [Item]) -> UUID {
        if let existing = job(forTemplate: subject.template.id) { return existing.id }
        environment.clearParked(subject)
        let job = Job(
            id: UUID(), subject: subject, items: items, states: Dictionary(uniqueKeysWithValues: items.map { ($0.id, .waiting) }),
            phase: .running)
        jobs.append(job)
        tick()
        ensureTicking()
        return job.id
    }

    /// Stops the job and only the downloads it started; a download that was
    /// already running when it began keeps going.
    func cancel(_ id: UUID) {
        guard let job = job(id: id) else { return }
        for item in job.items where job.started.contains(item.id) && !job.state(of: item).isSettled {
            if let key = job.keys[item.id] { environment.cancel(key) }
        }
        jobs.removeAll { $0.id == id }
        persist()
    }

    /// Forgets a finished or failed job once the person has seen it.
    func dismiss(_ id: UUID) {
        guard let job = job(id: id), !job.isActive else { return }
        jobs.removeAll { $0.id == id }
        persist()
    }

    /// Runs the failed items of a failed job again.
    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        for item in jobs[index].items {
            if case .failed = jobs[index].state(of: item) {
                jobs[index].states[item.id] = .waiting
                jobs[index].attempts[item.id] = nil
                jobs[index].retryAt[item.id] = nil
            }
        }
        jobs[index].phase = .running
        tick()
        ensureTicking()
    }

    /// The person changed the job's answers (a job that needs them).
    func update(_ id: UUID, subject: WorkflowSetupSubject) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].subject = subject
        persist()
    }

    /// Checks a job that needs the person again, installing it once
    /// nothing blocks. Returns the report the check gave.
    @discardableResult
    func recheck(_ id: UUID) -> SetupReport? {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].phase == .needsYou else { return nil }
        let report = settle(&jobs[index])
        persist()
        return report
    }

    /// Saved jobs from the last session, back to running. Called once at
    /// launch.
    func resumeAfterLaunch() {
        guard jobs.isEmpty, let url = environment.storeURL,
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode([Stored].self, from: data)
        else { return }
        jobs = stored.map(\.job)
        tick()
        ensureTicking()
    }

    // MARK: - Ticking

    private func ensureTicking() {
        guard ticker == nil, let interval = environment.tickInterval else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.tick()
                if !self.jobs.contains(where: \.isActive) {
                    self.ticker = nil
                    return
                }
            }
        }
    }

    /// Reads every running job's progress and moves it on: starts what is
    /// due, settles what finished, installs a job whose work is all done.
    func tick() {
        for index in jobs.indices where jobs[index].isActive {
            advance(&jobs[index])
        }
        persistIfChanged()
    }

    private func advance(_ job: inout Job) {
        let now = environment.now()
        for item in job.items {
            switch job.state(of: item) {
            case .waiting:
                if let due = job.retryAt[item.id], due > now { continue }
                job.retryAt[item.id] = nil
                begin(item, in: &job)
            case .working:
                guard let key = job.keys[item.id], !job.starting.contains(item.id) else { continue }
                switch environment.transfer(key)?.state ?? .notStarted {
                case .completed:
                    job.states[item.id] = .done
                case .failed(let error):
                    retryOrFail(item, message: error, in: &job, now: now)
                case .downloading, .paused:
                    break
                case .notStarted:
                    // Stopped from the Models tab: the person meant it.
                    job.states[item.id] = .failed(L("The download was stopped."))
                }
            case .done, .failed:
                continue
            }
        }
        measure(&job, now: now)
        if job.items.allSatisfy({ job.state(of: $0).isSettled }) { settle(&job) }
    }

    private func begin(_ item: Item, in job: inout Job) {
        switch item.work {
        case .chatModel(let repo):
            if let key = adoptable(.chat(repo)) {
                job.keys[item.id] = key
                job.states[item.id] = .working
                return
            }
            job.states[item.id] = .working
            job.started.insert(item.id)
            job.starting.insert(item.id)
            let jobID = job.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let key = try await self.environment.startChat(repo)
                    // Cancelled while the repo was resolving.
                    guard self.job(id: jobID) != nil else {
                        self.environment.cancel(key)
                        return
                    }
                    self.mutate(jobID) {
                        $0.keys[item.id] = key
                        $0.starting.remove(item.id)
                    }
                } catch {
                    self.mutate(jobID) {
                        $0.starting.remove(item.id)
                        self.retryOrFail(item, message: WorkflowErrorText.text(error), in: &$0, now: self.environment.now())
                    }
                }
            }
        case .mediaModel(let source):
            let key = DownloadKey.media(source.id)
            job.keys[item.id] = key
            job.states[item.id] = .working
            if adoptable(key) == nil {
                job.started.insert(item.id)
                environment.startMedia(source)
            }
        case .sandbox, .packages:
            // Packages install into the sandbox, so they wait for it.
            if case .packages = item.work, let sandbox = job.items.first(where: { $0.work == .sandbox }) {
                switch job.state(of: sandbox) {
                case .done: break
                case .failed:
                    job.states[item.id] = .failed(L("These need the sandbox, which could not be set up."))
                    return
                case .waiting, .working: return
                }
            }
            guard !job.running.contains(item.id) else { return }
            job.states[item.id] = .working
            job.running.insert(item.id)
            let jobID = job.id
            let templateID = job.templateID
            let environment = environment
            Task { @MainActor [weak self] in
                let failure: String?
                do {
                    if case .packages(let dependencies) = item.work {
                        try await environment.installPackages(dependencies, templateID)
                    } else {
                        try await environment.provisionSandbox()
                    }
                    failure = nil
                } catch {
                    failure = WorkflowErrorText.text(error)
                }
                guard let self else { return }
                self.mutate(jobID) {
                    $0.running.remove(item.id)
                    if let failure {
                        self.retryOrFail(item, message: failure, in: &$0, now: environment.now())
                    } else {
                        $0.states[item.id] = .done
                    }
                }
                self.tick()
            }
        }
    }

    /// A download of `key` already running or finished.
    private func adoptable(_ key: DownloadKey) -> DownloadKey? {
        switch environment.transfer(key)?.state {
        case .downloading?, .paused?, .completed?: return key
        default: return nil
        }
    }

    private func retryOrFail(_ item: Item, message: String, in job: inout Job, now: Date) {
        let attempt = (job.attempts[item.id] ?? 0) + 1
        job.attempts[item.id] = attempt
        guard attempt <= environment.retryDelays.count else {
            job.states[item.id] = .failed(message)
            return
        }
        job.states[item.id] = .waiting
        job.retryAt[item.id] = now.addingTimeInterval(environment.retryDelays[attempt - 1])
        // A retried download is started again, not read from the failed one.
        if item.work.isDownload { job.keys[item.id] = nil }
    }

    private func mutate(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        persistIfChanged()
    }

    // MARK: - Settling

    /// Every item is done or failed. A failure fails the job; otherwise the
    /// workflow is checked again and installed when nothing blocks.
    @discardableResult
    private func settle(_ job: inout Job) -> SetupReport? {
        let states = job.states
        if let failure = job.items.compactMap({ item -> String? in
            if case .failed(let message)? = states[item.id] { return message }
            return nil
        }).first {
            job.phase = .failed(failure)
            return nil
        }
        let report = environment.check(job.subject)
        guard !report.hasBlockers else {
            job.phase = .needsYou
            return report
        }
        do {
            guard let installedID = try environment.commit(job.subject) else {
                job.phase = .failed(L("The workflow could not be installed."))
                return report
            }
            job.phase = .done(installedID: installedID)
            job.progress = 1
        } catch {
            job.phase = .failed(WorkflowErrorText.text(error))
        }
        return report
    }

    // MARK: - Progress

    /// Work other than downloads counts as this share of the downloads, so
    /// it moves the bar without dwarfing a model.
    private static let setupShare = 0.05

    private func measure(_ job: inout Job, now: Date) {
        var weights: [(weight: Double, done: Double)] = []
        var downloadBytes = 0.0
        var bytesLeft = 0.0
        var speed = 0.0
        var activity: String?
        for item in job.items where item.work.isDownload {
            let transfer = job.keys[item.id].flatMap { environment.transfer($0) }
            let total = Double(transfer?.total ?? item.sizeBytes ?? 0)
            let state = job.state(of: item)
            let fraction: Double
            switch (state, transfer?.state) {
            case (.done, _): fraction = 1
            case (.working, .downloading(let p)?), (.working, .paused(let p)?): fraction = p
            default: fraction = 0
            }
            downloadBytes += total
            weights.append((total, fraction))
            if !state.isSettled {
                bytesLeft += total * (1 - fraction)
                if case .downloading? = transfer?.state { speed += transfer?.bytesPerSecond ?? 0 }
                if activity == nil, state == .working {
                    if case .paused? = transfer?.state {
                        activity = L("Paused")
                    } else {
                        activity = item.activity
                    }
                }
            }
        }
        let setupWeight = downloadBytes > 0 ? downloadBytes * Self.setupShare : 1
        for item in job.items where !item.work.isDownload {
            let state = job.state(of: item)
            weights.append((setupWeight, state == .done ? 1 : 0))
            if activity == nil, state == .working { activity = item.activity }
        }
        let totalWeight = weights.reduce(0) { $0 + $1.weight }
        job.progress = totalWeight > 0 ? weights.reduce(0) { $0 + $1.weight * $1.done } / totalWeight : 0
        if activity == nil, job.items.contains(where: { job.retryAt[$0.id] != nil }) {
            activity = L("Trying again in a moment…")
        }
        job.activity = activity ?? L("Getting ready…")

        if speed > 0, bytesLeft > 0 {
            job.rawRemaining = Self.smoothed(previous: job.rawRemaining, sample: bytesLeft / speed)
        } else if bytesLeft == 0 {
            job.rawRemaining = nil
        }
        let due = job.remainingPublishedAt.map { now.timeIntervalSince($0) >= environment.remainingRefresh } ?? true
        if due || job.remaining == nil {
            job.remaining = job.rawRemaining
            job.remainingPublishedAt = now
        }
    }

    /// An exponential average, so one slow second does not swing the
    /// estimate.
    nonisolated static func smoothed(previous: TimeInterval?, sample: TimeInterval) -> TimeInterval {
        guard let previous else { return sample }
        return previous * 0.7 + sample * 0.3
    }

    /// "About 8 minutes left", rounded so it does not tick every second.
    nonisolated static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return L("Less than a minute left") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 2 { return L("About a minute left") }
        if minutes < 10 { return L("About \(minutes) minutes left") }
        if minutes < 60 { return L("About \(Int((Double(minutes) / 5).rounded()) * 5) minutes left") }
        let hours = (seconds / 3600 * 2).rounded() / 2
        if hours <= 1 { return L("About an hour left") }
        let text = hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(format: "%.1f", hours)
        return L("About \(text) hours left")
    }

    // MARK: - Saving

    private struct Stored: Codable {
        var id: UUID
        var mode: WorkflowSetupSubject.Mode
        var template: Template
        var bindings: InstallBindings
        var name: String
        var agentStepsAllowed: Bool
        var source: InstalledWorkflow.Source?
        var items: [Item]
        var states: [String: ItemState]
        var phase: Phase
        var started: Set<String>
        var keys: [String: DownloadKey]

        init(_ job: Job) {
            id = job.id
            mode = job.subject.mode
            template = job.subject.template
            bindings = job.subject.bindings
            name = job.subject.name
            agentStepsAllowed = job.subject.agentStepsAllowed
            source = job.subject.source
            items = job.items
            states = job.states
            phase = job.phase
            started = job.started
            keys = job.keys
        }

        /// Work that was in flight starts over (the services skip what
        /// already landed), so it is read from the download it starts.
        var job: Job {
            var subject = WorkflowSetupSubject(mode: mode, template: template, bindings: bindings, name: name)
            subject.agentStepsAllowed = agentStepsAllowed
            subject.source = source
            var job = Job(id: id, subject: subject, items: items, states: states, phase: phase, started: started, keys: keys)
            for item in items where job.state(of: item) == .working {
                job.states[item.id] = .waiting
                job.keys[item.id] = nil
            }
            return job
        }
    }

    /// What `persist` writes, to skip writing when nothing changed.
    private struct Signature: Equatable {
        var phase: Phase
        var states: [String: ItemState]
        var keys: [String: DownloadKey]
        var started: Set<String>
        var bindings: InstallBindings
    }

    private var savedSignatures: [UUID: Signature] = [:]

    private func persistIfChanged() {
        let current = Dictionary(
            uniqueKeysWithValues: jobs.map {
                ($0.id, Signature(phase: $0.phase, states: $0.states, keys: $0.keys, started: $0.started, bindings: $0.subject.bindings))
            })
        guard current != savedSignatures else { return }
        persist()
    }

    private func persist() {
        savedSignatures = Dictionary(
            uniqueKeysWithValues: jobs.map {
                ($0.id, Signature(phase: $0.phase, states: $0.states, keys: $0.keys, started: $0.started, bindings: $0.subject.bindings))
            })
        guard let url = environment.storeURL else { return }
        let stored = jobs.filter { job in
            if case .done = job.phase { return false }
            return true
        }.map(Stored.init)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            // Saving is best effort: the job still runs this session.
        }
    }
}

// MARK: - Live

extension WorkflowInstallCoordinator.Environment {
    static func live() -> Self {
        Self(
            startChat: { repo in
                switch await ModelManager.shared.resolveModelForDeepLink(byRepoId: repo) {
                case .model(let model):
                    ModelManager.shared.downloadModel(model)
                    return .chat(model.id)
                case .image(let repoId):
                    let bundle = ImageModelDownload.directoryName(forRepoId: repoId)
                    ImageModelDownloadService.shared.download(repoId: repoId, displayName: bundle)
                    return .media(bundle)
                case .unsupported:
                    throw WorkflowInstallError(L("Hugging Face has no MLX model Osaurus can run at \(repo)."))
                case .registryGated:
                    throw WorkflowInstallError(L("\(repo) isn't in the Osaurus model catalog."))
                }
            },
            startMedia: { ImageModelDownloadService.shared.download(repoId: $0.repoId, displayName: $0.displayName) },
            transfer: { key in
                let state: DownloadState?
                let metrics: ModelDownloadService.DownloadMetrics?
                switch key {
                case .chat(let id):
                    state = ModelDownloadService.shared.downloadStates[id]
                    metrics = ModelDownloadService.shared.downloadMetrics[id]
                case .media(let id):
                    state = ImageModelDownloadService.shared.states[id]
                    metrics = ImageModelDownloadService.shared.metrics[id]
                }
                guard let state else { return nil }
                return .init(
                    state: state, received: metrics?.bytesReceived, total: metrics?.totalBytes,
                    bytesPerSecond: metrics?.bytesPerSecond)
            },
            cancel: { key in
                switch key {
                case .chat(let id): ModelManager.shared.cancelDownload(id)
                case .media(let id): ImageModelDownloadService.shared.cancel(id)
                }
            },
            provisionSandbox: { try await SandboxManager.shared.provision() },
            installPackages: { try await WorkflowSandboxEnvironment.shared.install($0, environmentID: $1) },
            check: { subject in
                let bindings = MCPServerResolution.liveAutoBindings(for: subject.template, bindings: subject.bindings)
                return SetupChecker.check(
                    subject.template, bindings: bindings, subjectId: subject.subjectID, secrets: .install,
                    attended: true)
            },
            commit: { subject in
                var subject = subject
                subject.bindings = MCPServerResolution.liveAutoBindings(for: subject.template, bindings: subject.bindings)
                return try subject.commit()?.id
            },
            clearParked: { subject in
                let state = ManagementStateManager.shared
                guard case .workflow(let parked)? = state.pendingSetupSubject,
                    parked.template.id == subject.template.id
                else { return }
                state.pendingSetupSubject = nil
                ParkedWorkflowSetupWatcher.shared.stop()
            },
            storeURL: OsaurusPaths.workflows().appendingPathComponent("installs.json"))
    }
}

struct WorkflowInstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

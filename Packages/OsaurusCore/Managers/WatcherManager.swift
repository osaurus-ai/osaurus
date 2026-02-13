//
//  WatcherManager.swift
//  osaurus
//
//  Reactive file system watcher engine.
//  Uses a state-based architecture: FSEvents are only a "something changed" signal.
//  The actual work is driven by directory fingerprint diffs. After the LLM acts,
//  re-fingerprint and check for convergence. Recursive loops are structurally
//  impossible because an idempotent LLM on a stable directory produces no changes.
//

import Combine
import CoreServices
import Foundation

/// Notification posted when watchers change
extension Notification.Name {
    public static let watchersChanged = Notification.Name("watchersChanged")
    public static let watcherExecutionCompleted = Notification.Name("watcherExecutionCompleted")
}

/// Manages file system watchers with FSEvents-based monitoring and fingerprint convergence
@MainActor
public final class WatcherManager: ObservableObject {
    public static let shared = WatcherManager()

    // MARK: - Published State

    /// All watchers
    @Published public private(set) var watchers: [Watcher] = []

    /// Currently running tasks (watcher ID -> run info)
    @Published public private(set) var runningTasks: [UUID: WatcherRunInfo] = [:]

    /// Current phase per watcher (for UI display)
    @Published public private(set) var phases: [UUID: WatcherPhase] = [:]

    // MARK: - Private State

    /// Active execution tasks (processing loop per watcher)
    private var executionTasks: [UUID: Task<Void, Never>] = [:]

    /// FSEvent stream reference (nonisolated(unsafe) so deinit can clean it up)
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?

    /// Per-watcher debounce tasks
    private var debouncers: [UUID: Task<Void, Never>] = [:]

    /// Last known fingerprint per watcher (convergence anchor)
    private var lastKnownFingerprints: [UUID: DirectoryFingerprint] = [:]

    // MARK: - Initialization

    private init() {
        refresh()
        startAllEnabledWatchers()
        print("[Osaurus] WatcherManager initialized with \(watchers.count) watchers")
    }

    deinit {
        // Inline cleanup since deinit is nonisolated and can't call @MainActor methods
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Public API

    /// Reload watchers from disk
    public func refresh() {
        watchers = WatcherStore.loadAll()
        objectWillChange.send()
    }

    /// Create a new watcher
    @discardableResult
    public func create(
        name: String,
        instructions: String,
        personaId: UUID? = nil,
        parameters: [String: String] = [:],
        watchPath: String? = nil,
        watchBookmark: Data? = nil,
        folderPath: String? = nil,
        folderBookmark: Data? = nil,
        isEnabled: Bool = true,
        recursive: Bool = false,
        responsiveness: Responsiveness = .balanced
    ) -> Watcher {
        let watcher = Watcher(
            id: UUID(),
            name: name,
            instructions: instructions,
            personaId: personaId,
            parameters: parameters,
            watchPath: watchPath,
            watchBookmark: watchBookmark,
            folderPath: folderPath,
            folderBookmark: folderBookmark,
            isEnabled: isEnabled,
            recursive: recursive,
            responsiveness: responsiveness,
            createdAt: Date(),
            updatedAt: Date()
        )

        WatcherStore.save(watcher)
        refresh()
        rebuildEventStream()

        NotificationCenter.default.post(name: .watchersChanged, object: nil)
        print("[Osaurus] Created watcher: \(watcher.name)")

        return watcher
    }

    /// Update an existing watcher
    public func update(_ watcher: Watcher) {
        var updated = watcher
        updated.updatedAt = Date()
        WatcherStore.save(updated)
        refresh()
        rebuildEventStream()

        NotificationCenter.default.post(name: .watchersChanged, object: nil)
        print("[Osaurus] Updated watcher: \(watcher.name)")
    }

    /// Delete a watcher
    @discardableResult
    public func delete(id: UUID) -> Bool {
        // Cancel any running execution
        executionTasks[id]?.cancel()
        executionTasks.removeValue(forKey: id)
        debouncers[id]?.cancel()
        debouncers.removeValue(forKey: id)
        runningTasks.removeValue(forKey: id)
        phases.removeValue(forKey: id)
        lastKnownFingerprints.removeValue(forKey: id)

        guard WatcherStore.delete(id: id) else { return false }

        refresh()
        rebuildEventStream()

        NotificationCenter.default.post(name: .watchersChanged, object: nil)
        print("[Osaurus] Deleted watcher: \(id)")

        return true
    }

    /// Toggle a watcher's enabled state
    public func setEnabled(_ id: UUID, enabled: Bool) {
        guard var watcher = watchers.first(where: { $0.id == id }) else { return }
        watcher.isEnabled = enabled
        watcher.updatedAt = Date()
        WatcherStore.save(watcher)

        if !enabled {
            // Clean up runtime state when disabling
            debouncers[id]?.cancel()
            debouncers.removeValue(forKey: id)
            executionTasks[id]?.cancel()
            executionTasks.removeValue(forKey: id)
            runningTasks.removeValue(forKey: id)
            phases.removeValue(forKey: id)
            lastKnownFingerprints.removeValue(forKey: id)
        }

        refresh()
        rebuildEventStream()

        NotificationCenter.default.post(name: .watchersChanged, object: nil)
    }

    /// Get a watcher by ID
    public func watcher(for id: UUID) -> Watcher? {
        watchers.first { $0.id == id }
    }

    /// Check if a watcher is currently running (has an active execution task)
    public func isRunning(_ watcherId: UUID) -> Bool {
        let p = phases[watcherId] ?? .idle
        return p == .processing || p == .settling
    }

    /// Get the current phase for a watcher
    public func phase(for watcherId: UUID) -> WatcherPhase {
        phases[watcherId] ?? .idle
    }

    /// Manually trigger a watcher (clears last known fingerprint for full-directory run)
    public func runNow(_ watcherId: UUID) {
        guard let watcher = watchers.first(where: { $0.id == watcherId }) else { return }

        let currentPhase = phases[watcherId] ?? .idle
        guard currentPhase == .idle else {
            print("[Osaurus] runNow skipped for \(watcher.name): phase is \(currentPhase.rawValue)")
            return
        }

        // Cancel any pending debouncer
        debouncers[watcherId]?.cancel()
        debouncers.removeValue(forKey: watcherId)

        // Clear last known fingerprint so the LLM sees the full directory
        lastKnownFingerprints.removeValue(forKey: watcherId)
        processCurrentState(for: watcher)
    }

    /// Cancel a running watcher execution
    public func cancelExecution(_ watcherId: UUID) {
        executionTasks[watcherId]?.cancel()
        executionTasks.removeValue(forKey: watcherId)
        debouncers[watcherId]?.cancel()
        debouncers.removeValue(forKey: watcherId)
        runningTasks.removeValue(forKey: watcherId)
        phases[watcherId] = .idle
    }

    // MARK: - FSEvents Management

    /// Start monitoring all enabled watchers
    private func startAllEnabledWatchers() {
        // Take initial fingerprints for all enabled watchers
        for watcher in watchers where watcher.isEnabled {
            if let path = resolveWatchPath(for: watcher) {
                let url = URL(fileURLWithPath: path)
                let excluded = excludedSubpaths(for: watcher)
                if let fingerprint = try? DirectoryFingerprint.capture(url, excludedSubpaths: excluded) {
                    lastKnownFingerprints[watcher.id] = fingerprint
                }
            }
        }
        rebuildEventStream()
    }

    /// Rebuild the single FSEvent stream for all enabled watchers
    private func rebuildEventStream() {
        stopEventStream()

        let enabledWatchers = watchers.filter { $0.isEnabled }
        guard !enabledWatchers.isEmpty else {
            print("[Osaurus] No enabled watchers, FSEvent stream stopped")
            return
        }

        // Collect all watch paths
        var paths: [String] = []
        for watcher in enabledWatchers {
            if let path = resolveWatchPath(for: watcher) {
                paths.append(path)
            }
        }

        guard !paths.isEmpty else {
            print("[Osaurus] No valid watch paths found")
            return
        }

        let pathsToWatch = paths as CFArray

        // Use a raw pointer to pass self into the C callback
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: pointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Directory-level signals only -- no per-file flags needed.
        // The fingerprint handles change detection.
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard
            let stream = FSEventStreamCreate(
                nil,
                fsEventsCallback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,  // Kernel-level coalescing latency (seconds)
                flags
            )
        else {
            print("[Osaurus] Failed to create FSEvent stream")
            return
        }

        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        print("[Osaurus] FSEvent stream started for \(paths.count) path(s)")
    }

    /// Stop and clean up the FSEvent stream
    private func stopEventStream() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    /// Resolve the watch path from a watcher's bookmark
    private func resolveWatchPath(for watcher: Watcher) -> String? {
        guard let bookmark = watcher.watchBookmark else {
            return watcher.watchPath
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else {
                print("[Osaurus] Watch bookmark is stale for: \(watcher.name)")
                return watcher.watchPath
            }
            _ = url.startAccessingSecurityScopedResource()
            return url.path
        } catch {
            print("[Osaurus] Failed to resolve watch bookmark for \(watcher.name): \(error)")
            return watcher.watchPath
        }
    }

    /// Compute excluded subpaths for a watcher (other watched folders nested within it)
    private func excludedSubpaths(for watcher: Watcher) -> Set<URL> {
        guard let watchPath = resolveWatchPath(for: watcher) else { return [] }
        return Set(
            watchers
                .filter { $0.id != watcher.id && $0.isEnabled }
                .compactMap { resolveWatchPath(for: $0) }
                .filter { $0.hasPrefix(watchPath + "/") }
                .map { URL(fileURLWithPath: $0) }
        )
    }

    // MARK: - FSEvent Handling (Phase-Gated)

    /// Called from the FSEvents callback.
    /// - idle: start debouncing (transition to debouncing)
    /// - debouncing: reset the debounce timer (stay in debouncing)
    /// - processing/settling: ignore entirely (events are self-caused or will be caught post-settle)
    fileprivate func handleFSEvent(paths: [String]) {
        for watcher in watchers where watcher.isEnabled {
            let currentPhase = phases[watcher.id] ?? .idle

            // Only accept events in idle or debouncing phases
            guard currentPhase == .idle || currentPhase == .debouncing else { continue }

            guard let watchPath = resolveWatchPath(for: watcher) else { continue }
            let relevant = paths.contains { $0 == watchPath || $0.hasPrefix(watchPath + "/") }
            guard relevant else { continue }

            // Start or reset debounce timer
            phases[watcher.id] = .debouncing
            signalDebouncer(for: watcher)
        }
    }

    // MARK: - Debouncing

    /// Cancel and restart the debounce timer for a watcher
    private func signalDebouncer(for watcher: Watcher) {
        debouncers[watcher.id]?.cancel()

        let watcherId = watcher.id
        let window = watcher.responsiveness.debounceWindow

        debouncers[watcherId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.debouncerFired(for: watcherId)
            } catch {
                // Task was cancelled (new event reset the timer)
            }
        }
    }

    /// Called when the debounce window expires without new events
    private func debouncerFired(for watcherId: UUID) {
        debouncers.removeValue(forKey: watcherId)

        guard let watcher = watchers.first(where: { $0.id == watcherId && $0.isEnabled }) else {
            phases[watcherId] = .idle
            return
        }

        processCurrentState(for: watcher)
    }

    // MARK: - Core Convergence Loop

    /// Convergence loop. Repeatedly fingerprints the directory, stores the fingerprint
    /// as lastKnown, dispatches the agent, settles, and loops back. Exits when two
    /// consecutive fingerprints match (the directory has stabilized). External changes
    /// during processing are caught on the next iteration because lastKnown represents
    /// the pre-dispatch state, not the post-settle state.
    private func processCurrentState(for watcher: Watcher) {
        let currentPhase = phases[watcher.id] ?? .idle

        // Only enter from debouncing (normal FSEvent path) or idle (runNow path)
        guard currentPhase == .debouncing || currentPhase == .idle else {
            print("[Osaurus] [\(watcher.name)] dispatch skipped: phase is \(currentPhase.rawValue)")
            return
        }

        // Belt-and-suspenders: reject if an execution task already exists
        if executionTasks[watcher.id] != nil {
            print("[Osaurus] [\(watcher.name)] dispatch skipped: execution task exists")
            phases[watcher.id] = .idle
            return
        }

        guard let watchPath = resolveWatchPath(for: watcher) else {
            phases[watcher.id] = .idle
            return
        }

        let watchURL = URL(fileURLWithPath: watchPath)
        let excluded = excludedSubpaths(for: watcher)

        // Quick phantom check before creating the task
        guard let initialFingerprint = try? DirectoryFingerprint.capture(watchURL, excludedSubpaths: excluded) else {
            print("[Osaurus] [\(watcher.name)] fingerprint capture failed")
            phases[watcher.id] = .idle
            return
        }

        if let known = lastKnownFingerprints[watcher.id], !initialFingerprint.changed(from: known) {
            phases[watcher.id] = .idle
            return
        }

        let watcherId = watcher.id

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.executionTasks.removeValue(forKey: watcherId)
                self.runningTasks.removeValue(forKey: watcherId)
                self.phases[watcherId] = .idle
                print("[Osaurus] [\(watcher.name)] phase → idle")
            }

            // ── Convergence loop ──
            // Keep running until two consecutive fingerprints match.
            // First iteration does real work. Subsequent iterations confirm
            // convergence or catch external changes that arrived during processing.
            // Capped to prevent runaway loops (e.g., Dropbox sync, build output).
            let maxIterations = 5
            var iteration = 0

            while !Task.isCancelled {
                iteration += 1

                if iteration > maxIterations {
                    print("[Osaurus] [\(watcher.name)] hit max iterations (\(maxIterations)), forcing idle")
                    if let current = try? DirectoryFingerprint.capture(watchURL, excludedSubpaths: excluded) {
                        self.lastKnownFingerprints[watcherId] = current
                    }
                    break
                }

                // Fingerprint current state
                guard let fingerprint = try? DirectoryFingerprint.capture(watchURL, excludedSubpaths: excluded) else {
                    print("[Osaurus] [\(watcher.name)] fingerprint capture failed (iteration \(iteration))")
                    break
                }

                // Convergence check: does directory match last known state?
                if let known = self.lastKnownFingerprints[watcherId], !fingerprint.changed(from: known) {
                    if iteration > 1 {
                        print("[Osaurus] [\(watcher.name)] converged after \(iteration - 1) iteration(s)")
                    } else {
                        // Phantom event slipped through (race between initial check and task start)
                        print("[Osaurus] [\(watcher.name)] phantom event, skipping")
                    }
                    break
                }

                // Compute change count before overwriting lastKnown
                let changeCount: Int
                if let known = self.lastKnownFingerprints[watcherId] {
                    changeCount = fingerprint.diff(from: known).totalCount
                } else {
                    changeCount = fingerprint.entries.count
                }

                // Store the fingerprint that triggered this dispatch as lastKnown.
                // Post-LLM changes (both self-caused and external) will diff
                // against this, guaranteeing they get processed next iteration.
                self.lastKnownFingerprints[watcherId] = fingerprint

                // Dispatch the agent
                self.phases[watcherId] = .processing

                print("[Osaurus] [\(watcher.name)] phase → processing (iteration \(iteration), \(changeCount) changes)")

                let prompt = self.buildDispatchPrompt(for: watcher, iteration: iteration)

                let request = DispatchRequest(
                    mode: .agent,
                    prompt: prompt,
                    personaId: watcher.personaId,
                    title: watcher.name,
                    parameters: watcher.parameters,
                    folderPath: watcher.effectiveFolderPath,
                    folderBookmark: watcher.effectiveFolderBookmark
                )

                guard let handle = await TaskDispatcher.shared.dispatch(request) else {
                    print("[Osaurus] [\(watcher.name)] dispatch failed (iteration \(iteration))")
                    break
                }

                self.runningTasks[watcherId] = WatcherRunInfo(
                    watcherId: watcher.id,
                    watcherName: watcher.name,
                    personaId: watcher.personaId,
                    chatSessionId: UUID(),
                    changeCount: changeCount
                )

                let result = await TaskDispatcher.shared.awaitCompletion(handle)
                self.runningTasks.removeValue(forKey: watcherId)

                self.handleResult(result, watcher: watcher)

                guard !Task.isCancelled else { break }

                // Settle: wait for self-caused FSEvents to flush
                self.phases[watcherId] = .settling
                print("[Osaurus] [\(watcher.name)] phase → settling (\(watcher.settleSeconds)s)")

                try? await Task.sleep(nanoseconds: UInt64(watcher.settleSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }

                // Loop back. Next iteration fingerprints fresh and compares
                // against the pre-dispatch lastKnown. LLM's own changes will
                // cause a diff → one more dispatch → LLM says "nothing to do"
                // → next iteration matches → converged.
            }

            // defer handles cleanup → idle
        }

        executionTasks[watcher.id] = task
    }

    // MARK: - Result Handling

    /// Update watcher metadata after task completion
    private func handleResult(_ result: DispatchResult, watcher: Watcher) {
        switch result {
        case .completed(let sessionId):
            let chatSessionId = sessionId ?? UUID()

            var updatedWatcher = watcher
            updatedWatcher.lastTriggeredAt = Date()
            updatedWatcher.lastChatSessionId = chatSessionId

            WatcherStore.save(updatedWatcher)
            refresh()

            NotificationCenter.default.post(
                name: .watcherExecutionCompleted,
                object: nil,
                userInfo: [
                    "watcherId": watcher.id,
                    "sessionId": chatSessionId,
                    "personaId": watcher.personaId ?? Persona.defaultId,
                ]
            )
            print("[Osaurus] Watcher completed: \(watcher.name)")

        case .cancelled:
            print("[Osaurus] Watcher cancelled: \(watcher.name)")

        case .failed(let error):
            print("[Osaurus] Watcher failed: \(watcher.name) - \(error)")
        }
    }

    // MARK: - Prompt Builder

    /// Build the dispatch prompt. The agent gets the full directory tree via
    /// AgentFolderContext when the folder is set, so we only need to provide
    /// the user's instructions and the idempotency footer.
    private func buildDispatchPrompt(for watcher: Watcher, iteration: Int = 1) -> String {
        var prompt = watcher.instructions

        if iteration == 1 {
            prompt +=
                "\n\nChanges were detected in the watched folder. Use `file_tree` and other file tools to inspect the current state of the directory and take action.\n"
        } else {
            prompt +=
                "\n\nThis is a follow-up check after a previous organizing pass. Quickly verify the directory state with a single `file_tree` call. If everything looks organized, return immediately without further inspection. Only take action if you see clearly unorganized files.\n"
        }

        prompt +=
            "\nIf all files are already properly organized, return without making changes. Do not re-organize files that are already in their correct location.\n"

        return prompt
    }
}

// MARK: - FSEvents Callback

/// Global FSEvents callback function (C-compatible, cannot be a method)
private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }

    let manager = Unmanaged<WatcherManager>.fromOpaque(info).takeUnretainedValue()

    // eventPaths is a CFArray of CFString when using kFSEventStreamCreateFlagUseCFTypes
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let count = CFArrayGetCount(cfArray)

    var paths: [String] = []
    for i in 0 ..< min(count, numEvents) {
        if let cfStr = CFArrayGetValueAtIndex(cfArray, i) {
            let str = Unmanaged<CFString>.fromOpaque(cfStr).takeUnretainedValue() as String
            paths.append(str)
        }
    }

    // Dispatch to main actor -- paths only, no flags needed
    Task { @MainActor in
        manager.handleFSEvent(paths: paths)
    }
}

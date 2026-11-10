//
//  FolderEventSource.swift
//  osaurus
//
//  Folder source. FSEvents are only a "something changed" signal; the work
//  is driven by directory fingerprint diffs. After a run, the folder is
//  re-fingerprinted and the event fires again until two consecutive
//  fingerprints match, so an idempotent agent on a stable folder converges
//  and a run reacting to its own writes cannot loop (capped at 5 passes).
//
//  The convergence anchor persists in `event_source_state`, so a relaunch
//  diffs against the last fingerprint instead of re-baselining: changes
//  made while the app was closed fire one pass at launch.
//

import CoreServices
import Foundation

@MainActor
final class FolderEventSource: EventSourceAdapter {
    let kind: EventSourceKind = .folder
    private unowned let manager: EventManager

    /// One FSEvent stream for every enabled folder event.
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?
    private var streamPaths: [String] = []
    private var debouncers: [UUID: Task<Void, Never>] = [:]
    private var executionTasks: [UUID: Task<Void, Never>] = [:]
    /// Convergence anchor per event.
    private var lastKnownFingerprints: [UUID: DirectoryFingerprint] = [:]
    /// Resolving a security-scoped bookmark is a synchronous IPC round-trip
    /// that can stall for seconds; resolve once per event per session.
    private var resolvedPaths: [UUID: String] = [:]
    private var canonicalPaths: [UUID: String] = [:]
    private var phases: [UUID: WatcherPhase] = [:]
    private var stopped = false

    static let maxIterations = 5

    init(manager: EventManager) {
        self.manager = manager
    }

    deinit {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Lifecycle

    func stop() {
        stopped = true
        stopEventStream()
        for task in debouncers.values { task.cancel() }
        debouncers.removeAll()
        for task in executionTasks.values { task.cancel() }
        executionTasks.removeAll()
        for id in phases.keys { manager.setFolderPhase(id, .idle) }
        phases.removeAll()
    }

    /// Takes a baseline fingerprint for newly enabled folder events (or
    /// restores the persisted one and fires for changes made while the app
    /// was closed) and rebuilds the stream over every enabled folder.
    func reconcile(_ events: [OsaurusEvent]) async {
        guard !stopped, manager.isStarted else { return }
        let enabled = events.filter { $0.isEnabled && $0.sourceKind == .folder }
        let enabledIds = Set(enabled.map(\.id))
        for id in Array(phases.keys) where !enabledIds.contains(id) { forget(id) }
        for id in Array(lastKnownFingerprints.keys) where !enabledIds.contains(id) {
            lastKnownFingerprints.removeValue(forKey: id)
        }
        // A disabled folder re-baselines when it is turned back on.
        for event in events where event.sourceKind == .folder && !event.isEnabled {
            manager.setSourceState(nil, scope: Self.baselineScope(event.id))
        }
        var offlineChanges: [UUID] = []
        for event in enabled where lastKnownFingerprints[event.id] == nil {
            guard let path = resolvePath(for: event) else { continue }
            guard
                let fingerprint = await Self.captureFingerprint(
                    at: URL(fileURLWithPath: path), excluding: excludedSubpaths(for: event))
            else { continue }
            if let stored = await persistedBaseline(event.id, path: path) {
                lastKnownFingerprints[event.id] = stored
                if fingerprint.changed(from: stored) { offlineChanges.append(event.id) }
            } else {
                setBaseline(event.id, fingerprint, path: path)
            }
        }
        let paths = enabled.compactMap { resolvePath(for: $0) }
        if Set(paths) != Set(streamPaths) || eventStream == nil {
            rebuildEventStream(paths: paths)
        }
        for id in offlineChanges {
            guard let event = manager.event(for: id), event.isEnabled else { continue }
            processCurrentState(for: event, trigger: .source)
        }
    }

    /// Drops all runtime state for an event (deleted, disabled, re-sourced).
    func forget(_ id: UUID) {
        cancel(id)
        lastKnownFingerprints.removeValue(forKey: id)
        resolvedPaths.removeValue(forKey: id)
        canonicalPaths.removeValue(forKey: id)
        manager.setSourceState(nil, scope: Self.baselineScope(id))
    }

    func status(_ eventId: UUID) -> EventSourceStatus {
        manager.sourceStatus[eventId] ?? EventSourceStatus()
    }

    // MARK: - Persisted baseline

    static func baselineScope(_ id: UUID) -> String {
        EventRunDatabase.eventScopePrefix(id) + ":folder"
    }

    private struct Baseline: Codable {
        var path: String
        var fingerprint: DirectoryFingerprint
    }

    /// The stored anchor, when it was taken of the same folder.
    private func persistedBaseline(_ id: UUID, path: String) async -> DirectoryFingerprint? {
        guard let state = await manager.sourceState(scope: Self.baselineScope(id)),
            let baseline = try? state.decoded(as: Baseline.self), baseline.path == path
        else { return nil }
        return baseline.fingerprint
    }

    /// Sets the convergence anchor and persists it.
    private func setBaseline(_ id: UUID, _ fingerprint: DirectoryFingerprint, path: String) {
        lastKnownFingerprints[id] = fingerprint
        guard let state = try? JSONValue(encoding: Baseline(path: path, fingerprint: fingerprint)) else { return }
        manager.setSourceState(state, scope: Self.baselineScope(id))
    }

    func cancel(_ id: UUID) {
        debouncers[id]?.cancel()
        debouncers.removeValue(forKey: id)
        executionTasks[id]?.cancel()
        executionTasks.removeValue(forKey: id)
        setPhase(id, .idle)
    }

    /// Runs the event over the whole folder (no diff), then converges.
    func fireNow(_ event: OsaurusEvent, sample: JSONValue?) async -> EventFireResult {
        guard (phases[event.id] ?? .idle) == .idle else {
            return EventFireResult(runId: UUID(), status: .suppressed, reason: "busy")
        }
        guard resolvePath(for: event) != nil else {
            return EventFireResult(runId: UUID(), status: .suppressed, reason: "folder_unavailable")
        }
        debouncers[event.id]?.cancel()
        debouncers.removeValue(forKey: event.id)
        lastKnownFingerprints.removeValue(forKey: event.id)
        processCurrentState(for: event, trigger: .manual)
        return EventFireResult(runId: UUID(), status: .running, reason: nil)
    }

    // MARK: - FSEvents

    private func rebuildEventStream(paths: [String]) {
        stopEventStream()
        streamPaths = paths
        guard !paths.isEmpty else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: pointer, retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                nil, folderEventsCallback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        else {
            print("[Osaurus] Failed to create FSEvent stream for folder events")
            return
        }
        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func stopEventStream() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
        streamPaths = []
    }

    /// idle → start debouncing; debouncing → reset the timer;
    /// processing/settling → ignore (self-caused, or caught post-settle).
    fileprivate func handleFSEvent(paths: [String]) {
        // A callback queued before `stop()` can land after the manager is gone.
        guard !stopped else { return }
        for event in manager.events where event.isEnabled && event.sourceKind == .folder {
            let phase = phases[event.id] ?? .idle
            guard phase == .idle || phase == .debouncing else { continue }
            guard let watchPath = canonicalPath(for: event) else { continue }
            guard paths.contains(where: { $0 == watchPath || $0.hasPrefix(watchPath + "/") }) else { continue }
            setPhase(event.id, .debouncing)
            signalDebouncer(for: event)
        }
    }

    private func signalDebouncer(for event: OsaurusEvent) {
        debouncers[event.id]?.cancel()
        let id = event.id
        let window = event.source.folder?.responsiveness.debounceWindow ?? 1.0
        debouncers[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.debouncers.removeValue(forKey: id)
            guard let current = self.manager.event(for: id), current.isEnabled else {
                self.setPhase(id, .idle)
                return
            }
            self.processCurrentState(for: current, trigger: .source)
        }
    }

    // MARK: - Convergence loop

    private func processCurrentState(for event: OsaurusEvent, trigger: EventOccurrence.Trigger) {
        let phase = phases[event.id] ?? .idle
        guard phase == .debouncing || phase == .idle, executionTasks[event.id] == nil else { return }
        guard let watchPath = resolvePath(for: event) else {
            setPhase(event.id, .idle)
            return
        }
        let id = event.id
        let watchURL = URL(fileURLWithPath: watchPath)
        let excluded = excludedSubpaths(for: event)

        executionTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.executionTasks.removeValue(forKey: id)
                self.setPhase(id, .idle)
            }
            var iteration = 0
            while !Task.isCancelled {
                iteration += 1
                if iteration > Self.maxIterations {
                    if let current = await Self.captureFingerprint(at: watchURL, excluding: excluded) {
                        self.setBaseline(id, current, path: watchPath)
                    }
                    break
                }
                guard let fingerprint = await Self.captureFingerprint(at: watchURL, excluding: excluded) else {
                    break
                }
                // Converged, or a phantom event.
                if let known = self.lastKnownFingerprints[id], !fingerprint.changed(from: known) { break }

                // The changed paths anchor the prompt and the payload: a run
                // told only "changes were detected" has inspected the wrong
                // folder in the field. Removed paths are marked so nothing
                // tries to read a file that no longer exists.
                let changedPaths: [String]
                let changeCount: Int
                if let known = self.lastKnownFingerprints[id] {
                    let diff = await Task.detached(priority: .userInitiated) { fingerprint.diff(from: known) }.value
                    changeCount = diff.totalCount
                    changedPaths =
                        (Array(diff.added.union(diff.modified)) + diff.removed.map { "\($0) (removed)" }).sorted()
                } else {
                    changeCount = fingerprint.entries.count
                    changedPaths = []
                }
                // The pre-run fingerprint is the anchor: changes made during
                // or after the run diff against it on the next pass.
                self.setBaseline(id, fingerprint, path: watchPath)
                self.setPhase(id, .processing)

                guard let current = self.manager.event(for: id) else { break }
                let now = Date()
                let payload = EventPayload.folder(
                    event: current, firedAt: now, path: watchPath, changedPaths: changedPaths)
                let prompt = current.action.agent.map {
                    Self.buildDispatchPrompt(
                        instructions: EventTemplate.render($0.instructions, payload: payload),
                        iteration: iteration, resolvedWatchPath: watchPath, changedPaths: changedPaths)
                }
                let run = await self.manager.submitAndWait(
                    EventOccurrence(
                        eventId: id,
                        firedAt: now,
                        payload: payload,
                        trigger: iteration == 1 ? trigger : .source,
                        agentPrompt: prompt,
                        folderPath: watchPath,
                        folderBookmark: current.source.folder?.bookmark,
                        loadIntent: trigger == .manual && iteration == 1 ? .interactive : .background,
                        summary: ["iteration": String(iteration), "changed_paths": String(changeCount)]
                    ))
                guard run.status.didRun, !Task.isCancelled else { break }

                // Let self-caused FSEvents flush before fingerprinting again.
                self.setPhase(id, .settling)
                let settle = current.source.folder?.settleSeconds ?? 2.0
                try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            }
        }
    }

    private func setPhase(_ id: UUID, _ phase: WatcherPhase) {
        if phase == .idle {
            phases.removeValue(forKey: id)
        } else {
            phases[id] = phase
        }
        // `stop()` already reset the manager; a cancelled pass's cleanup can
        // outlive it.
        guard !stopped else { return }
        manager.setFolderPhase(id, phase)
    }

    /// Fingerprinting stats every file under the folder; off the main actor.
    private static func captureFingerprint(at url: URL, excluding excluded: Set<URL>) async -> DirectoryFingerprint? {
        await Task.detached(priority: .userInitiated) {
            try? DirectoryFingerprint.capture(url, excludedSubpaths: excluded)
        }.value
    }

    // MARK: - Paths

    func resolvePath(for event: OsaurusEvent) -> String? {
        if let cached = resolvedPaths[event.id] { return cached }
        guard let folder = event.source.folder else { return nil }
        let resolved = Self.resolve(folder, name: event.name)
        if let resolved { resolvedPaths[event.id] = resolved }
        return resolved
    }

    /// The watch path with symlinks resolved: FSEvents reports canonical
    /// paths (`/tmp/x` arrives as `/private/tmp/x`). `realpath`, because
    /// `resolvingSymlinksInPath` maps `/private/tmp` back to `/tmp`.
    func canonicalPath(for event: OsaurusEvent) -> String? {
        if let cached = canonicalPaths[event.id] { return cached }
        guard let path = resolvePath(for: event) else { return nil }
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        canonicalPaths[event.id] = canonical
        return canonical
    }

    private static func resolve(_ folder: FolderSourceConfig, name: String) -> String? {
        guard let bookmark = folder.bookmark else { return folder.path }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            guard !isStale else { return folder.path }
            _ = url.startAccessingSecurityScopedResource()
            return url.path
        } catch {
            print("[Osaurus] Failed to resolve folder bookmark for event \(name): \(error)")
            return folder.path
        }
    }

    /// Other watched folders nested inside this one are left to their own events.
    private func excludedSubpaths(for event: OsaurusEvent) -> Set<URL> {
        guard let watchPath = resolvePath(for: event) else { return [] }
        return Set(
            manager.events
                .filter { $0.id != event.id && $0.isEnabled && $0.sourceKind == .folder }
                .compactMap { resolvePath(for: $0) }
                .filter { $0.hasPrefix(watchPath + "/") }
                .map { URL(fileURLWithPath: $0) })
    }

    // MARK: - Prompt

    /// How many changed paths the prompt names before summarizing the rest.
    static let dispatchPromptChangedPathCap = 20

    /// One changed-path line. File names are untrusted (APFS allows newlines
    /// and control characters), so they are cleaned and backtick-quoted.
    static func promptLine(forChangedPath path: String) -> String {
        let cleaned = String(
            path.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
            })
        return "- `\(cleaned)`\n"
    }

    /// The agent prompt for one pass: the instructions, then the folder it
    /// must work in and what changed. Without the folder anchor an agent has
    /// inspected its own sandbox home and reported the folder empty.
    static func buildDispatchPrompt(
        instructions: String,
        iteration: Int = 1,
        resolvedWatchPath: String?,
        changedPaths: [String] = []
    ) -> String {
        var prompt = instructions
        if let anchor = resolvedWatchPath, !anchor.isEmpty {
            prompt += "\n\n" + watchedFolderLinePrefix + anchor + "\n"
        } else {
            prompt += "\n"
        }
        if !changedPaths.isEmpty {
            let shown = changedPaths.prefix(dispatchPromptChangedPathCap)
            prompt += changedSinceHeader + "\n"
            for path in shown { prompt += promptLine(forChangedPath: path) }
            let overflow = changedPaths.count - shown.count
            if overflow > 0 {
                prompt += changedPathOverflowPrefix + "\(overflow)" + changedPathOverflowSuffix + "\n"
            }
        }
        prompt += "\n" + (iteration == 1 ? firstIterationGuidance : followUpIterationGuidance) + "\n"
        prompt += "\n" + alreadyOrganizedGuidance + "\n"
        return prompt
    }

    /// Fixed prompt fragments, shared with `DispatchEnvelope` (which strips
    /// them for display). Byte-for-byte the historical watcher text, so
    /// chats from before events still parse.
    nonisolated static let watchedFolderLinePrefix = "Watched folder (work HERE, not in any other directory): "
    nonisolated static let changedSinceHeader = "Changed since the last check:"
    nonisolated static let changedPathOverflowPrefix = "…and "
    nonisolated static let changedPathOverflowSuffix = " more changed file(s)."
    nonisolated static let firstIterationGuidance =
        "Changes were detected in the watched folder. Use `file_read` (which lists a directory when given one) and other file tools to inspect the current state of the directory and take action."
    nonisolated static let followUpIterationGuidance =
        "This is a follow-up check after a previous organizing pass. Quickly verify the directory state with a single `file_read` call on the folder. If everything looks organized, return immediately without further inspection. Only take action if you see clearly unorganized files."
    nonisolated static let alreadyOrganizedGuidance =
        "If all files are already properly organized, return without making changes. Do not re-organize files that are already in their correct location."
}

private func folderEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let source = Unmanaged<FolderEventSource>.fromOpaque(info).takeUnretainedValue()
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    for i in 0..<min(CFArrayGetCount(cfArray), numEvents) {
        if let raw = CFArrayGetValueAtIndex(cfArray, i) {
            paths.append(Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String)
        }
    }
    Task { @MainActor in source.handleFSEvent(paths: paths) }
}

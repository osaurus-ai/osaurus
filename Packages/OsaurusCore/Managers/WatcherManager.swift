//
//  WatcherManager.swift
//  osaurus
//
//  Manages file system watchers that monitor directories for changes
//  and dispatch agent tasks with change context.
//  Uses macOS FSEvents for efficient kernel-level file monitoring.
//

import Combine
import CoreServices
import Foundation

/// Notification posted when watchers change
extension Notification.Name {
    public static let watchersChanged = Notification.Name("watchersChanged")
    public static let watcherExecutionCompleted = Notification.Name("watcherExecutionCompleted")
}

/// Manages file system watchers with FSEvents-based monitoring
@MainActor
public final class WatcherManager: ObservableObject {
    public static let shared = WatcherManager()

    // MARK: - Published State

    /// All watchers
    @Published public private(set) var watchers: [Watcher] = []

    /// Currently running tasks (watcher ID -> run info)
    @Published public private(set) var runningTasks: [UUID: WatcherRunInfo] = [:]

    // MARK: - Private State

    /// Active execution tasks
    private var executionTasks: [UUID: Task<Void, Never>] = [:]

    /// FSEvent stream reference (nonisolated(unsafe) so deinit can clean it up)
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?

    /// Per-watcher debounce timers
    private var debounceTimers: [UUID: Task<Void, Never>] = [:]

    /// Accumulated events per watcher (during debounce window)
    private var pendingEvents: [UUID: [FileChangeEvent]] = [:]

    /// Baseline snapshots per watcher (filename -> modification date)
    private var baselineSnapshots: [UUID: [String: Date]] = [:]

    /// Cooldown end times per watcher (after task completion)
    private var cooldownEndTimes: [UUID: Date] = [:]

    /// Cooldown duration after task completion (seconds)
    private let cooldownDuration: TimeInterval = 5.0

    /// Noise patterns to filter out
    private static let noisePatterns: Set<String> = [
        ".DS_Store", ".localized", "Thumbs.db", "desktop.ini",
    ]

    /// Partial download extensions to filter out
    private static let partialDownloadExtensions: Set<String> = [
        "crdownload", "download", "part", "tmp", "partial",
    ]

    /// Hidden file prefixes to filter out
    private static let hiddenPrefixes: [String] = ["._"]

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
        debounceSeconds: TimeInterval = 3.0
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
            debounceSeconds: debounceSeconds,
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
        if let task = executionTasks[id] {
            task.cancel()
            executionTasks.removeValue(forKey: id)
        }
        runningTasks.removeValue(forKey: id)
        debounceTimers[id]?.cancel()
        debounceTimers.removeValue(forKey: id)
        pendingEvents.removeValue(forKey: id)
        baselineSnapshots.removeValue(forKey: id)
        cooldownEndTimes.removeValue(forKey: id)

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
        refresh()
        rebuildEventStream()

        NotificationCenter.default.post(name: .watchersChanged, object: nil)
    }

    /// Get a watcher by ID
    public func watcher(for id: UUID) -> Watcher? {
        watchers.first { $0.id == id }
    }

    /// Check if a watcher is currently running
    public func isRunning(_ watcherId: UUID) -> Bool {
        runningTasks[watcherId] != nil
    }

    /// Manually trigger a watcher to run now (simulates a change detection)
    public func runNow(_ watcherId: UUID) {
        guard let watcher = watchers.first(where: { $0.id == watcherId }) else { return }

        // Build a synthetic event list by scanning the watched folder
        let events = buildSyntheticEvents(for: watcher)
        executeWatcher(watcher, events: events)
    }

    /// Cancel a running watcher execution
    public func cancelExecution(_ watcherId: UUID) {
        if let task = executionTasks[watcherId] {
            task.cancel()
            executionTasks.removeValue(forKey: watcherId)
        }
        runningTasks.removeValue(forKey: watcherId)
    }

    // MARK: - FSEvents Management

    /// Start monitoring all enabled watchers
    private func startAllEnabledWatchers() {
        // Take baseline snapshots for all enabled watchers
        for watcher in watchers where watcher.isEnabled {
            if let path = resolveWatchPath(for: watcher) {
                baselineSnapshots[watcher.id] = takeSnapshot(at: path, recursive: watcher.recursive)
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
                // Take baseline snapshot if not already present
                if baselineSnapshots[watcher.id] == nil {
                    baselineSnapshots[watcher.id] = takeSnapshot(at: path, recursive: watcher.recursive)
                }
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

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagNoDefer)

        guard
            let stream = FSEventStreamCreate(
                nil,
                fsEventsCallback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                2.0,  // Kernel-level coalescing latency (seconds)
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

    // MARK: - Event Processing

    /// Called from the FSEvents callback (on main thread via run loop)
    fileprivate func handleFSEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        let now = Date()

        for (path, eventFlags) in zip(paths, flags) {
            let fileName = (path as NSString).lastPathComponent
            let parentDir = (path as NSString).deletingLastPathComponent

            // Skip noise files
            guard !Self.isNoiseFile(fileName) else { continue }

            // Determine change type from flags
            let changeType = classifyChange(flags: eventFlags, path: path)
            guard let change = changeType else { continue }

            // Find matching watcher(s) for this path
            for watcher in watchers where watcher.isEnabled {
                guard let watchPath = resolveWatchPath(for: watcher) else { continue }

                let matches: Bool
                if watcher.recursive {
                    matches = path.hasPrefix(watchPath)
                } else {
                    // Shallow: only match files directly in the watched directory
                    matches = parentDir == watchPath
                }

                guard matches else { continue }

                // Skip if in cooldown period
                if let cooldownEnd = cooldownEndTimes[watcher.id], now < cooldownEnd {
                    continue
                }

                // Compute relative path
                let relativePath: String
                if path.hasPrefix(watchPath) {
                    let startIndex = path.index(path.startIndex, offsetBy: watchPath.count)
                    var rel = String(path[startIndex...])
                    if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                    relativePath = rel
                } else {
                    relativePath = fileName
                }

                let event = FileChangeEvent(
                    path: relativePath,
                    changeType: change,
                    timestamp: now
                )

                // Accumulate event
                pendingEvents[watcher.id, default: []].append(event)

                // Reset debounce timer for this watcher
                resetDebounceTimer(for: watcher)
            }
        }
    }

    /// Classify a file change from FSEvent flags
    private func classifyChange(flags: FSEventStreamEventFlags, path: String) -> FileChangeEvent.ChangeType? {
        let isFile = (flags & UInt32(kFSEventStreamEventFlagItemIsFile)) != 0
        let isDir = (flags & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0

        // We primarily care about file events (not directories, unless specific)
        guard isFile || isDir else { return nil }

        let created = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
        let removed = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
        let modified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
        let renamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0

        if removed {
            // Verify the file is actually gone
            if !FileManager.default.fileExists(atPath: path) {
                return .deleted
            }
            // File exists despite removed flag (could be rename target)
            return .modified
        }

        if created || renamed {
            // Check if the file actually exists (rename creates the new path)
            if FileManager.default.fileExists(atPath: path) {
                return .added
            }
            // File doesn't exist - this is the "old" side of a rename
            return .deleted
        }

        if modified {
            return .modified
        }

        return nil
    }

    /// Check if a filename should be ignored as noise
    private static func isNoiseFile(_ name: String) -> Bool {
        if noisePatterns.contains(name) { return true }

        let ext = (name as NSString).pathExtension.lowercased()
        if partialDownloadExtensions.contains(ext) { return true }

        for prefix in hiddenPrefixes {
            if name.hasPrefix(prefix) { return true }
        }

        // Skip hidden files (starting with .)
        if name.hasPrefix(".") { return true }

        return false
    }

    // MARK: - Debouncing

    /// Reset the debounce timer for a watcher
    private func resetDebounceTimer(for watcher: Watcher) {
        // Cancel existing timer
        debounceTimers[watcher.id]?.cancel()

        let watcherId = watcher.id
        let debounce = watcher.debounceSeconds

        debounceTimers[watcherId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.debounceTimerFired(for: watcherId)
            } catch {
                // Task was cancelled
            }
        }
    }

    /// Called when a debounce timer fires
    private func debounceTimerFired(for watcherId: UUID) {
        debounceTimers.removeValue(forKey: watcherId)

        guard let watcher = watchers.first(where: { $0.id == watcherId }) else { return }
        guard let events = pendingEvents[watcherId], !events.isEmpty else { return }

        // Dedup events: collapse multiple events on the same path
        let deduped = deduplicateEvents(events)
        pendingEvents[watcherId] = nil

        // Skip dispatch if already running -- events stay cleared, we don't re-queue
        // (a re-scan will catch any remaining changes on next trigger)
        guard !isRunning(watcherId) else {
            print("[Osaurus] Watcher \(watcher.name) is already running, skipping \(deduped.count) events")
            return
        }

        executeWatcher(watcher, events: deduped)
    }

    /// Collapse redundant events on the same path
    private func deduplicateEvents(_ events: [FileChangeEvent]) -> [FileChangeEvent] {
        var byPath: [String: FileChangeEvent] = [:]

        for event in events {
            if let existing = byPath[event.path] {
                // Resolve conflicts:
                // added + modified = added
                // added + deleted = (remove entirely)
                // modified + deleted = deleted
                // deleted + added = modified (file was replaced)
                switch (existing.changeType, event.changeType) {
                case (.added, .modified):
                    // Keep as added
                    break
                case (.added, .deleted):
                    // Cancel out
                    byPath.removeValue(forKey: event.path)
                case (.modified, .deleted):
                    byPath[event.path] = event
                case (.deleted, .added):
                    byPath[event.path] = FileChangeEvent(
                        path: event.path,
                        changeType: .modified,
                        timestamp: event.timestamp
                    )
                default:
                    // Use the latest event
                    byPath[event.path] = event
                }
            } else {
                byPath[event.path] = event
            }
        }

        return Array(byPath.values).sorted { $0.path < $1.path }
    }

    // MARK: - Snapshot

    /// Take a shallow snapshot of a directory (filename -> modification date)
    private func takeSnapshot(at path: String, recursive: Bool) -> [String: Date] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        var snapshot: [String: Date] = [:]

        if recursive {
            guard
                let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            else { return snapshot }

            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard !Self.isNoiseFile(name) else {
                    enumerator.skipDescendants()
                    continue
                }
                if let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                {
                    let relativePath =
                        String(fileURL.path.dropFirst(path.count)).trimmingCharacters(
                            in: CharacterSet(charactersIn: "/")
                        )
                    snapshot[relativePath] = modDate
                }
            }
        } else {
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            else { return snapshot }

            for fileURL in contents {
                let name = fileURL.lastPathComponent
                guard !Self.isNoiseFile(name) else { continue }
                if let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                {
                    snapshot[name] = modDate
                }
            }
        }

        return snapshot
    }

    /// Build synthetic events by diffing current state against baseline
    private func buildSyntheticEvents(for watcher: Watcher) -> [FileChangeEvent] {
        guard let watchPath = resolveWatchPath(for: watcher) else { return [] }

        let currentSnapshot = takeSnapshot(at: watchPath, recursive: watcher.recursive)
        let baseline = baselineSnapshots[watcher.id] ?? [:]
        let now = Date()
        var events: [FileChangeEvent] = []

        // Find added and modified files
        for (path, modDate) in currentSnapshot {
            if let baselineDate = baseline[path] {
                if modDate > baselineDate {
                    events.append(FileChangeEvent(path: path, changeType: .modified, timestamp: now))
                }
            } else {
                events.append(FileChangeEvent(path: path, changeType: .added, timestamp: now))
            }
        }

        // Find deleted files
        for path in baseline.keys where currentSnapshot[path] == nil {
            events.append(FileChangeEvent(path: path, changeType: .deleted, timestamp: now))
        }

        // Update baseline
        baselineSnapshots[watcher.id] = currentSnapshot

        return events.sorted { $0.path < $1.path }
    }

    // MARK: - Execution

    /// Execute a watcher by dispatching to TaskDispatcher
    private func executeWatcher(_ watcher: Watcher, events: [FileChangeEvent]) {
        guard !events.isEmpty else {
            print("[Osaurus] No changes to dispatch for watcher: \(watcher.name)")
            return
        }

        // Build the prompt with change context
        let prompt = buildDispatchPrompt(for: watcher, events: events)

        let request = DispatchRequest(
            mode: .agent,
            prompt: prompt,
            personaId: watcher.personaId,
            title: watcher.name,
            parameters: watcher.parameters,
            folderPath: watcher.effectiveFolderPath,
            folderBookmark: watcher.effectiveFolderBookmark
        )

        print(
            "[Osaurus] Executing watcher: \(watcher.name) with \(events.count) change(s)"
        )

        let task = Task { @MainActor in
            guard let handle = await TaskDispatcher.shared.dispatch(request) else {
                print("[Osaurus] Failed to dispatch watcher: \(watcher.name)")
                return
            }

            self.runningTasks[watcher.id] = WatcherRunInfo(
                watcherId: watcher.id,
                watcherName: watcher.name,
                personaId: watcher.personaId,
                chatSessionId: UUID(),
                changeCount: events.count
            )

            let result = await TaskDispatcher.shared.awaitCompletion(handle)
            self.handleResult(result, watcher: watcher, request: handle.request)
        }

        executionTasks[watcher.id] = task
    }

    // MARK: - Result Handling

    /// Update watcher metadata after task completion
    private func handleResult(_ result: DispatchResult, watcher: Watcher, request: DispatchRequest) {
        defer {
            executionTasks.removeValue(forKey: watcher.id)
            runningTasks.removeValue(forKey: watcher.id)

            // Set cooldown period to ignore self-triggered events
            cooldownEndTimes[watcher.id] = Date().addingTimeInterval(cooldownDuration)

            // Update baseline snapshot after task completes
            if let path = resolveWatchPath(for: watcher) {
                baselineSnapshots[watcher.id] = takeSnapshot(at: path, recursive: watcher.recursive)
            }
        }

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

    // MARK: - Prompt Builder (Tiered Context)

    /// Build the dispatch prompt with file change context
    private func buildDispatchPrompt(for watcher: Watcher, events: [FileChangeEvent]) -> String {
        var prompt = watcher.instructions

        prompt += "\n\n## File Changes Detected\n\n"
        prompt += "The following changes were detected in \(watcher.watchPath ?? "the watched folder"):\n\n"

        // Summary line
        let addedCount = events.filter { $0.changeType == .added }.count
        let modifiedCount = events.filter { $0.changeType == .modified }.count
        let deletedCount = events.filter { $0.changeType == .deleted }.count

        var summaryParts: [String] = []
        if addedCount > 0 { summaryParts.append("\(addedCount) file(s) added") }
        if modifiedCount > 0 { summaryParts.append("\(modifiedCount) file(s) modified") }
        if deletedCount > 0 { summaryParts.append("\(deletedCount) file(s) deleted") }
        prompt += "Summary: \(summaryParts.joined(separator: ", "))\n"

        let totalEvents = events.count

        if totalEvents <= 20 {
            // Tier: Full metadata + text previews for small files
            prompt += buildDetailedChangeList(events: events, watchPath: watcher.watchPath, includePreview: true)
        } else if totalEvents <= 100 {
            // Tier: Full metadata, no previews
            prompt += buildDetailedChangeList(events: events, watchPath: watcher.watchPath, includePreview: false)
        } else {
            // Tier: Grouped summary + first 30 individually
            prompt += buildGroupedChangeSummary(events: events, watchPath: watcher.watchPath)
        }

        prompt +=
            "\nYou have file tools available (file_read, file_move, file_tree, etc.) to inspect and act on these files. The working directory is already set to the watched folder.\n"

        return prompt
    }

    /// Build detailed change list with optional previews
    private func buildDetailedChangeList(
        events: [FileChangeEvent],
        watchPath: String?,
        includePreview: Bool
    ) -> String {
        var result = ""

        let added = events.filter { $0.changeType == .added }
        let modified = events.filter { $0.changeType == .modified }
        let deleted = events.filter { $0.changeType == .deleted }

        if !added.isEmpty {
            result += "\n### Added\n"
            for event in added {
                result += formatFileEntry(event, watchPath: watchPath, includePreview: includePreview)
            }
        }

        if !modified.isEmpty {
            result += "\n### Modified\n"
            for event in modified {
                result += formatFileEntry(event, watchPath: watchPath, includePreview: includePreview)
            }
        }

        if !deleted.isEmpty {
            result += "\n### Deleted\n"
            for event in deleted {
                result += "- \(event.path)\n"
            }
        }

        return result
    }

    /// Format a single file entry with metadata and optional preview
    private func formatFileEntry(
        _ event: FileChangeEvent,
        watchPath: String?,
        includePreview: Bool
    ) -> String {
        var entry = ""
        let fullPath = watchPath.map { ($0 as NSString).appendingPathComponent(event.path) }

        let ext = (event.path as NSString).pathExtension.uppercased()
        let fileType = ext.isEmpty ? "File" : ext

        // Get file size if the file exists
        var sizeStr = ""
        if let fp = fullPath, FileManager.default.fileExists(atPath: fp),
            let attrs = try? FileManager.default.attributesOfItem(atPath: fp),
            let size = attrs[.size] as? Int64
        {
            sizeStr = formatBytes(size)
        }

        if sizeStr.isEmpty {
            entry += "- \(event.path) (\(fileType))\n"
        } else {
            entry += "- \(event.path) (\(fileType), \(sizeStr))\n"
        }

        // Include text preview for small text files
        if includePreview, let fp = fullPath {
            let previewText = getTextPreview(at: fp, maxLines: 20, maxBytes: 4096)
            if let preview = previewText {
                entry += "  Preview:\n"
                for line in preview.components(separatedBy: .newlines).prefix(20) {
                    entry += "  > \(line)\n"
                }
                entry += "\n"
            }
        }

        return entry
    }

    /// Build grouped summary for large change batches (100+)
    private func buildGroupedChangeSummary(events: [FileChangeEvent], watchPath: String?) -> String {
        var result = ""

        let added = events.filter { $0.changeType == .added }
        let modified = events.filter { $0.changeType == .modified }
        let deleted = events.filter { $0.changeType == .deleted }

        // Group by extension
        func groupByExtension(_ items: [FileChangeEvent]) -> [(ext: String, count: Int)] {
            var groups: [String: Int] = [:]
            for item in items {
                let ext = (item.path as NSString).pathExtension.lowercased()
                let key = ext.isEmpty ? "other" : ".\(ext)"
                groups[key, default: 0] += 1
            }
            return groups.sorted { $0.value > $1.value }.map { (ext: $0.key, count: $0.value) }
        }

        if !added.isEmpty {
            result += "\n### Added (\(added.count) files)\n"
            let groups = groupByExtension(added)
            for group in groups {
                result += "- \(group.count) \(group.ext) files\n"
            }
            // List first 30 individually
            result += "\nFirst \(min(30, added.count)) files:\n"
            for event in added.prefix(30) {
                result += "- \(event.path)\n"
            }
            if added.count > 30 {
                result += "- ... and \(added.count - 30) more\n"
            }
        }

        if !modified.isEmpty {
            result += "\n### Modified (\(modified.count) files)\n"
            let groups = groupByExtension(modified)
            for group in groups {
                result += "- \(group.count) \(group.ext) files\n"
            }
        }

        if !deleted.isEmpty {
            result += "\n### Deleted (\(deleted.count) files)\n"
            let groups = groupByExtension(deleted)
            for group in groups {
                result += "- \(group.count) \(group.ext) files\n"
            }
        }

        return result
    }

    /// Try to read a text preview of a file
    private func getTextPreview(at path: String, maxLines: Int, maxBytes: Int) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()

        // Only preview known text file extensions
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "json", "xml", "csv", "tsv",
            "yaml", "yml", "toml", "ini", "cfg", "conf", "log",
            "swift", "py", "js", "ts", "rb", "go", "rs", "java",
            "c", "cpp", "h", "hpp", "cs", "sh", "bash", "zsh",
            "html", "css", "scss", "less", "sql", "r", "m",
        ]

        guard textExtensions.contains(ext) else { return nil }

        // Check file size first
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attrs[.size] as? Int64,
            size <= maxBytes
        else { return nil }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: .newlines)
        let preview = lines.prefix(maxLines).joined(separator: "\n")
        return preview.isEmpty ? nil : preview
    }

    /// Format byte count to human-readable string
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
    var flags: [FSEventStreamEventFlags] = []

    for i in 0 ..< min(count, numEvents) {
        if let cfStr = CFArrayGetValueAtIndex(cfArray, i) {
            let str = Unmanaged<CFString>.fromOpaque(cfStr).takeUnretainedValue() as String
            paths.append(str)
            flags.append(eventFlags[i])
        }
    }

    // Dispatch to main actor
    Task { @MainActor in
        manager.handleFSEvents(paths: paths, flags: flags)
    }
}

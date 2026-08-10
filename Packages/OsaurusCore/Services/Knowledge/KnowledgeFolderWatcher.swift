//
//  KnowledgeFolderWatcher.swift
//  osaurus
//
//  FSEvents monitor over enabled knowledge collection folders. Events
//  are only a "something changed" signal — the index service's
//  content-hash pass decides what actually needs re-indexing, so a
//  burst of events costs one debounced incremental scan per touched
//  collection.
//
//  Deliberately separate from `WatcherManager`: that engine drives
//  user-configured agent runs with fingerprint convergence; this is
//  internal index maintenance with no LLM in the loop.
//

import CoreServices
import Foundation

@MainActor
public final class KnowledgeFolderWatcher {
    public static let shared = KnowledgeFolderWatcher()

    /// Debounce between the last FS event and the index pass, long
    /// enough to coalesce a git checkout / bulk save touching many files.
    private static let debounceSeconds: UInt64 = 5

    private nonisolated(unsafe) var eventStream: FSEventStreamRef?
    /// Collection ids with pending changes, drained by the debounce task.
    private var pendingCollectionIds: Set<UUID> = []
    private var debounceTask: Task<Void, Never>?
    /// Watched folder path (with trailing slash) → collection id.
    private var watchedFolders: [String: UUID] = [:]
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Build the stream over the current enabled collections and follow
    /// registry changes. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: .knowledgeCollectionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildEventStream() }
        }
        rebuildEventStream()
    }

    /// Freeze for app termination: tear down the FSEvent stream and drop
    /// any pending debounce so no new indexing dispatches during quit.
    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingCollectionIds.removeAll()
        stopEventStream()
        started = false
    }

    // MARK: - Stream management

    /// Serial queue owning the FSEvent stream lifecycle. `FSEventStreamStart`
    /// blocks on IPC to fseventsd (`register_with_server`) and has hung the
    /// main thread for seconds at launch, so create/start/stop never run on
    /// main. Callbacks are still delivered on the main queue via
    /// `FSEventStreamSetDispatchQueue`.
    private nonisolated static let streamQueue = DispatchQueue(
        label: "com.dinoki.osaurus.knowledge-fsevents", qos: .utility)

    private func rebuildEventStream() {
        watchedFolders.removeAll()

        for collection in KnowledgeManager.shared.collections where collection.isEnabled {
            guard collection.folderExists else { continue }
            let path = collection.folderURL.standardizedFileURL.path
            let normalized = path.hasSuffix("/") ? path : path + "/"
            watchedFolders[normalized] = collection.id
        }

        let folderPaths = watchedFolders.keys.map { String($0.dropLast()) }
        Self.streamQueue.async { [self] in
            stopEventStreamOnQueue()
            guard !folderPaths.isEmpty else { return }

            let pointer = Unmanaged.passUnretained(self).toOpaque()
            var context = FSEventStreamContext(
                version: 0,
                info: pointer,
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            // Directory-level signals only — the content-hash pass handles
            // change detection.
            let flags: FSEventStreamCreateFlags =
                UInt32(kFSEventStreamCreateFlagUseCFTypes)
                | UInt32(kFSEventStreamCreateFlagNoDefer)

            guard
                let stream = FSEventStreamCreate(
                    nil,
                    knowledgeFSEventsCallback,
                    &context,
                    folderPaths as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    1.0,
                    flags
                )
            else {
                KnowledgeLogger.index.error("Failed to create knowledge FSEvent stream")
                return
            }

            eventStream = stream
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            KnowledgeLogger.index.info(
                "Knowledge FSEvent stream started for \(folderPaths.count) collection folder(s)"
            )
        }
    }

    private func stopEventStream() {
        Self.streamQueue.async { [self] in
            stopEventStreamOnQueue()
        }
    }

    /// Must run on `streamQueue`.
    private nonisolated func stopEventStreamOnQueue() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - Event handling

    func handleFSEvent(paths: [String]) {
        for eventPath in paths {
            let normalized = eventPath.hasSuffix("/") ? eventPath : eventPath + "/"
            for (folder, collectionId) in watchedFolders where normalized.hasPrefix(folder) {
                pendingCollectionIds.insert(collectionId)
            }
        }
        guard !pendingCollectionIds.isEmpty else { return }

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = self.pendingCollectionIds
            self.pendingCollectionIds.removeAll()
            for id in ids {
                if let collection = KnowledgeManager.shared.collection(for: id) {
                    KnowledgeManager.shared.scheduleIndex(of: collection)
                }
            }
        }
    }
}

// MARK: - FSEvents Callback

/// Global FSEvents callback (C-compatible, cannot be a method).
private func knowledgeFSEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<KnowledgeFolderWatcher>.fromOpaque(info).takeUnretainedValue()

    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let count = CFArrayGetCount(cfArray)
    var paths: [String] = []
    for i in 0 ..< min(count, numEvents) {
        if let cfStr = CFArrayGetValueAtIndex(cfArray, i) {
            paths.append(Unmanaged<CFString>.fromOpaque(cfStr).takeUnretainedValue() as String)
        }
    }

    Task { @MainActor in
        watcher.handleFSEvent(paths: paths)
    }
}

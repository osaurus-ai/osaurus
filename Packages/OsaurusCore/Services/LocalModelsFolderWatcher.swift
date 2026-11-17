//
//  LocalModelsFolderWatcher.swift
//  osaurus
//
//  FSEvents monitor over the models directory and the image models root.
//  A bundle added, removed, or moved in Finder invalidates the local model
//  scan and posts `.localModelsChanged`, the same signal an in-app download
//  or delete sends, so the Local Models lists follow the disk without a
//  relaunch. Only bundle-level directory events count: file writes inside a
//  bundle (a download in progress) are ignored.
//

import CoreServices
import Foundation

@MainActor
final class LocalModelsFolderWatcher {
    static let shared = LocalModelsFolderWatcher()

    /// Coalesces a Finder move of several bundles, or a bundle's
    /// create-then-rename, into one rescan.
    private static let debounce: Duration = .seconds(1)

    /// `<root>/<model>`, `<root>/<org>/<model>`, and the scan's third level.
    nonisolated static let maxBundleDepth = 3

    private nonisolated(unsafe) var eventStream: FSEventStreamRef?
    private var watchedRoots: [String] = []
    private var debounceTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var started = false

    private init() {}

    /// Idempotent. Re-arms whenever the models directory changes.
    func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(
            forName: .localModelsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildEventStream() }
        }
        rebuildEventStream()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        debounceTask?.cancel()
        debounceTask = nil
        started = false
        Self.streamQueue.async { [self] in stopEventStreamOnQueue() }
    }

    // MARK: - Stream

    /// Root resolution can resolve a security-scoped bookmark and list
    /// directories, and `FSEventStreamStart` blocks on IPC to fseventsd, so
    /// none of it runs on main. Callbacks arrive on the main queue.
    private nonisolated static let streamQueue = DispatchQueue(
        label: "com.dinoki.osaurus.models-fsevents", qos: .utility)

    private func rebuildEventStream() {
        Self.streamQueue.async { [self] in
            let roots = Self.currentRoots()
            Task { @MainActor in
                guard started, roots != watchedRoots else { return }
                watchedRoots = roots
                Self.streamQueue.async { [self] in startEventStreamOnQueue(roots: roots) }
            }
        }
    }

    /// Existing, symlink-resolved roots; a root inside another is dropped
    /// because the outer stream already covers it.
    nonisolated static func currentRoots() -> [String] {
        let candidates = [
            DirectoryPickerService.effectiveModelsDirectory(),
            ImageGenerationService.imageModelsRoot(),
        ]
        let paths = Set(
            candidates
                .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
                .filter { path in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                })
        return paths.filter { path in
            !paths.contains { $0 != path && path.hasPrefix($0 + "/") }
        }.sorted()
    }

    /// Must run on `streamQueue`.
    private nonisolated func startEventStreamOnQueue(roots: [String]) {
        stopEventStreamOnQueue()
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                nil,
                localModelsFSEventsCallback,
                &context,
                roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.5,
                flags
            )
        else { return }
        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    /// Must run on `streamQueue`.
    private nonisolated func stopEventStreamOnQueue() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - Events

    fileprivate func handle(events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let roots = watchedRoots
        guard events.contains(where: { Self.isInventoryChange(path: $0.path, flags: $0.flags, roots: roots) })
        else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            ModelManager.invalidateLocalModelsCache()
            NotificationCenter.default.post(name: .localModelsChanged, object: nil)
        }
    }

    /// True for a bundle (or publisher) directory created, removed, or
    /// renamed within the scan depth, a change to a watched root itself, or
    /// a dropped-events signal that forces a rescan. Hidden paths (download
    /// staging) and plain file events are ignored.
    nonisolated static func isInventoryChange(
        path: String, flags: FSEventStreamEventFlags, roots: [String]
    ) -> Bool {
        let rescan = FSEventStreamEventFlags(
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        if flags & rescan != 0 { return true }
        guard flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 else { return false }
        let structural = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed)
        guard flags & structural != 0 else { return false }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        for root in roots where normalized.hasPrefix(root + "/") {
            let components = normalized.dropFirst(root.count + 1).split(separator: "/")
            guard (1 ... maxBundleDepth).contains(components.count) else { continue }
            if components.contains(where: { $0.hasPrefix(".") }) { continue }
            return true
        }
        return false
    }
}

/// C-compatible FSEvents callback; delivered on the main queue.
private func localModelsFSEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<LocalModelsFolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
    for i in 0 ..< min(CFArrayGetCount(cfArray), numEvents) {
        guard let raw = CFArrayGetValueAtIndex(cfArray, i) else { continue }
        events.append((Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String, eventFlags[i]))
    }
    MainActor.assumeIsolated { watcher.handle(events: events) }
}

//
//  ClipboardService.swift
//  osaurus
//
//  Service for monitoring the macOS pasteboard and capturing selections.
//

import AppKit
import Combine
import Foundation
import OsaurusObjCSupport

/// Service for monitoring the macOS pasteboard and capturing selections from other apps
@MainActor
public final class ClipboardService: ObservableObject {
    public static let shared = ClipboardService()

    /// Supported content types on the clipboard
    public enum ClipboardContent: Equatable, Sendable {
        case text(String)
        case image(Data)
        case file(URL)

        public var isText: Bool {
            if case .text = self { return true }
            return false
        }

        /// A privacy-preserving description for diagnostics that never includes clipboard payloads.
        public var redactedDiagnosticDescription: String {
            switch self {
            case .text(let text):
                "text(characters: \(text.count))"
            case .image(let data):
                "image(bytes: \(data.count))"
            case .file(let url):
                "file(extension: \(url.pathExtension.isEmpty ? "unknown" : url.pathExtension.lowercased()))"
            }
        }
    }

    /// The current content on the pasteboard
    @Published public private(set) var currentContent: ClipboardContent?

    /// The application that was frontmost when the clipboard last changed
    @Published public private(set) var lastSourceApp: String?

    /// Whether the clipboard content has been "seen" or used
    @Published public var hasNewContent: Bool = false

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: AnyCancellable?
    /// Guards against overlapping pasteboard reads if one outlives the poll interval.
    private var isChecking = false
    private let keyboardService = KeyboardSimulationService.shared

    /// Serializes every `NSPasteboard` access. `NSPasteboard` is not thread-safe:
    /// its internal type cache (`_updateTypeCacheIfNeeded`) is shared mutable state,
    /// so concurrent reads — from independent `Task.detached` jobs on the cooperative
    /// pool and from the main actor — can double-free it (Sentry: malloc "pointer
    /// being freed was not allocated"). Routing all reads through a single serial queue
    /// keeps them off the main thread (preserving the hang fix) while guaranteeing no
    /// two pasteboard touches ever overlap.
    nonisolated private static let pasteboardQueue = DispatchQueue(
        label: "com.dinoki.osaurus.clipboard.pasteboard"
    )

    /// Runs `work` against the shared pasteboard on the serial pasteboard queue,
    /// returning `nil` when the read raises. The serial queue only orders *our*
    /// pasteboard access; `NSPasteboard.general` is a process-wide singleton that
    /// other subsystems (e.g. the Cmd+V paste handler on the main thread) touch
    /// concurrently, and AppKit's non-thread-safe type cache can throw an
    /// `NSRangeException` mid-read. Catching it here degrades a poll to a no-op
    /// instead of terminating the app on an exception Swift can't `catch`.
    nonisolated private static func onPasteboardQueue<T: Sendable>(
        _ work: @escaping @Sendable (NSPasteboard) -> T
    ) async -> T? {
        await withCheckedContinuation { continuation in
            pasteboardQueue.async {
                var result: T?
                let raised = osr_catch_exception {
                    result = work(NSPasteboard.general)
                }
                if let raised {
                    print("[ClipboardService] Pasteboard read raised \(raised.name.rawValue); skipping")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private init() {
        // monitoring is started/stopped by AppDelegate based on window visibility
    }

    /// Start polling the pasteboard for changes
    public func startMonitoring() {
        guard timer == nil else { return }
        print("[ClipboardService] Starting monitoring...")

        // Poll every 0.5 seconds for pasteboard changes
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPasteboard()
            }
    }

    /// Stop polling the pasteboard
    public func stopMonitoring() {
        print("[ClipboardService] Stopping monitoring")
        timer?.cancel()
        timer = nil
    }

    /// Explicitly check the pasteboard for changes.
    ///
    /// Fire-and-forget entry point for the polling timer. The actual reads run off the
    /// main actor (see `refreshFromPasteboardIfChanged`) because `NSPasteboard` reads make
    /// synchronous XPC round-trips to the pasteboard server that can block for seconds and
    /// hang the UI.
    public func checkPasteboard() {
        Task { await refreshFromPasteboardIfChanged() }
    }

    /// Timer entry point: skip if a previous read is still in flight, otherwise refresh.
    private func refreshFromPasteboardIfChanged() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        await performPasteboardRefresh()
    }

    /// Poll the pasteboard and, if its content changed, publish it.
    private func performPasteboardRefresh() async {
        let knownChangeCount = lastChangeCount

        // Both the `changeCount` poll and the content read run off-main: every
        // `NSPasteboard` accessor makes a synchronous XPC round-trip to the pasteboard
        // server that can block for seconds when that server is slow, hanging the UI.
        // The reads only use the typed `string(forType:)`/`data(forType:)` accessors
        // (never `readObjects(forClasses:)`), which are safe to call off the main actor.
        // They run on the shared serial pasteboard queue so they never overlap another
        // pasteboard access and corrupt its internal type cache.
        guard let changeCount = await Self.onPasteboardQueue({ $0.changeCount }) else { return }
        guard changeCount != knownChangeCount else { return }

        print("[ClipboardService] Pasteboard change detected. Count: \(changeCount) (was \(knownChangeCount))")
        lastChangeCount = changeCount

        let detected = await Self.onPasteboardQueue { Self.detectContent(in: $0) } ?? nil
        guard let content = detected else {
            print("[ClipboardService] Change detected but no meaningful content found on pasteboard.")
            return
        }

        // Only update if content actually changed
        guard content != currentContent else {
            print("[ClipboardService] Change detected but content is identical to current.")
            return
        }

        // Build the redacted diagnostic off the main actor: the `.text`
        // variant calls `String.count`, which walks grapheme-cluster
        // boundaries. For a large pasteboard string backed by a foreign
        // `NSString` that walk is O(n) and runs synchronous foreign-scalar
        // alignment, blocking the UI long enough to trip the hang watchdog.
        let summary = await Task.detached(priority: .utility) {
            content.redactedDiagnosticDescription
        }.value
        print("[ClipboardService] New content detected: \(summary)")
        currentContent = content
        hasNewContent = true

        // Identify the source application
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            lastSourceApp = frontmost.localizedName ?? frontmost.bundleIdentifier
            print("[ClipboardService] Source app identified: \(lastSourceApp ?? "unknown")")
        }
    }

    nonisolated private static func detectContent(in pb: NSPasteboard) -> ClipboardContent? {
        // 1. try file URLs (copied files in Finder). Avoid
        // `readObjects(forClasses:)`: Sentry APPLE-MACOS-2N showed AppKit
        // mutating its internal type-conversion array while enumerating there.
        // Reading explicit pasteboard types avoids that conversion path.
        let fileURLTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
        ]
        for type in fileURLTypes {
            guard let raw = pb.string(forType: type), let url = URL(string: raw) else {
                continue
            }
            if url.isFileURL,
                DocumentParser.canParse(url: url) || DocumentParser.isImageFile(url: url)
            {
                return .file(url)
            }
        }

        // 2. try images (direct data)
        if let imageData = pb.data(forType: .png) {
            return .image(imageData)
        }
        if let tiffData = pb.data(forType: .tiff), let nsImage = NSImage(data: tiffData),
            let pngData = nsImage.pngData()
        {
            return .image(pngData)
        }

        // 3. try plain text
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }

        return nil
    }

    /// Attempt to grab the current selection from the active application
    /// by simulating Cmd+C and waiting for the pasteboard to update.
    public func grabSelection() async -> String? {
        guard let startChangeCount = await Self.onPasteboardQueue({ $0.changeCount }) else { return nil }
        print("[ClipboardService] Starting grabSelection. Current changeCount: \(startChangeCount)")

        // 1. simulate Cmd+C
        let posted = keyboardService.copySelection()
        print("[ClipboardService] copySelection() call returned: \(posted)")

        if !posted {
            print("[ClipboardService] FAILED to post Cmd+C event. Likely missing accessibility permissions.")
            return nil
        }

        // 2. wait for update (up to 500ms)
        print("[ClipboardService] Waiting for pasteboard update...")
        for i in 0 ..< 10 {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
            guard let currentChangeCount = await Self.onPasteboardQueue({ $0.changeCount }) else { continue }
            if currentChangeCount != startChangeCount {
                print(
                    "[ClipboardService] Pasteboard update detected at iteration \(i+1). New count: \(currentChangeCount)"
                )
                await performPasteboardRefresh()

                if case .text(let text) = currentContent {
                    return text
                }
                return nil
            }
        }

        print("[ClipboardService] TIMEOUT: Pasteboard did not update after 500ms.")
        return nil
    }

    /// Mark the current clipboard content as "read"
    public func markAsRead() {
        hasNewContent = false
    }
}

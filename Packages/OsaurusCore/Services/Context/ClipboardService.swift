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

    public struct SelectionGrabReport: Equatable, Sendable {
        public enum NonTextKind: String, Equatable, Sendable {
            case image
            case file

            var diagnosticTag: String {
                switch self {
                case .image:
                    return "image"
                case .file:
                    return "file"
                }
            }
        }

        public enum Outcome: Equatable, Sendable {
            case capturedText(characterCount: Int)
            case capturedNonText(kind: NonTextKind)
            case accessibilityDenied
            case pasteboardReadFailed
            case noReadableContent
            case pasteboardUnchanged
        }

        public let outcome: Outcome
        public let sourceApp: String?

        public var needsUserAttention: Bool {
            switch outcome {
            case .capturedText, .capturedNonText:
                return false
            case .accessibilityDenied, .pasteboardReadFailed, .noReadableContent, .pasteboardUnchanged:
                return true
            }
        }

        public var userFacingMessage: String {
            switch outcome {
            case .capturedText(let count):
                return String(format: L("Captured selected text (%lld characters)."), Int64(count))
            case .capturedNonText(let kind):
                switch kind {
                case .image:
                    return L("Captured an image, but only text selections can be inserted automatically.")
                case .file:
                    return L("Captured a file, but only text selections can be inserted automatically.")
                }
            case .accessibilityDenied:
                return L("Osaurus could not request the selection. Enable Accessibility permission, then try again.")
            case .pasteboardReadFailed:
                return L("macOS pasteboard access failed while reading the copied selection. Try again.")
            case .noReadableContent:
                return L("The selection copied, but the pasteboard did not contain readable text.")
            case .pasteboardUnchanged:
                return L("Selection unavailable") + ". "
                    + L("No selection was copied. Select text in the frontmost app and try again.")
            }
        }

        public var redactedDiagnosticDescription: String {
            let source = sourceApp ?? "unknown"
            switch outcome {
            case .capturedText(let count):
                return "selection_grab(outcome: captured_text, characters: \(count), source: \(source))"
            case .capturedNonText(let kind):
                return "selection_grab(outcome: captured_non_text, kind: \(kind.diagnosticTag), source: \(source))"
            case .accessibilityDenied:
                return "selection_grab(outcome: accessibility_denied, source: \(source))"
            case .pasteboardReadFailed:
                return "selection_grab(outcome: pasteboard_read_failed, source: \(source))"
            case .noReadableContent:
                return "selection_grab(outcome: no_readable_content, source: \(source))"
            case .pasteboardUnchanged:
                return "selection_grab(outcome: pasteboard_unchanged, source: \(source))"
            }
        }
    }

    private enum SelectionPasteboardResult: Equatable, Sendable {
        case content(ClipboardContent)
        case noReadableContent
        case readFailed
    }

    /// The current content on the pasteboard
    @Published public private(set) var currentContent: ClipboardContent?

    /// The application that was frontmost when the clipboard last changed
    @Published public private(set) var lastSourceApp: String?

    /// Redacted result from the latest explicit "grab selection" attempt.
    @Published public private(set) var lastSelectionGrabReport: SelectionGrabReport?

    /// Whether the clipboard content has been "seen" or used
    @Published public var hasNewContent: Bool = false

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var currentContentChangeCount: Int?
    private var timer: AnyCancellable?
    /// Guards against overlapping pasteboard reads if one outlives the poll interval.
    private var isChecking = false
    private let selectionCapture: SelectionCaptureTransaction

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
    nonisolated fileprivate static func onPasteboardQueue<T: Sendable>(
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

    private convenience init() {
        self.init(selectionCapture: SelectionCaptureTransaction.live())
    }

    init(selectionCapture: SelectionCaptureTransaction) {
        self.selectionCapture = selectionCapture
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
    @discardableResult
    private func performPasteboardRefresh(markIdenticalAsNew: Bool = false) async -> SelectionPasteboardResult {
        let knownChangeCount = lastChangeCount

        // Both the `changeCount` poll and the content read run off-main: every
        // `NSPasteboard` accessor makes a synchronous XPC round-trip to the pasteboard
        // server that can block for seconds when that server is slow, hanging the UI.
        // The reads only use the typed `string(forType:)`/`data(forType:)` accessors
        // (never `readObjects(forClasses:)`), which are safe to call off the main actor.
        // They run on the shared serial pasteboard queue so they never overlap another
        // pasteboard access and corrupt its internal type cache.
        guard let changeCount = await Self.onPasteboardQueue({ $0.changeCount }) else {
            return .readFailed
        }
        guard changeCount != knownChangeCount else {
            return .noReadableContent
        }

        print("[ClipboardService] Pasteboard change detected. Count: \(changeCount) (was \(knownChangeCount))")
        lastChangeCount = changeCount

        let detected = (await Self.onPasteboardQueue { Self.detectContent(in: $0) }).flatMap { $0 }
        guard let content = detected else {
            print("[ClipboardService] Change detected but no meaningful content found on pasteboard.")
            return .noReadableContent
        }

        // Only update if content actually changed
        guard content != currentContent else {
            print("[ClipboardService] Change detected but content is identical to current.")
            currentContentChangeCount = changeCount
            if markIdenticalAsNew {
                hasNewContent = true
                lastSelectionGrabReport = nil
                if let frontmost = NSWorkspace.shared.frontmostApplication {
                    lastSourceApp = frontmost.localizedName ?? frontmost.bundleIdentifier
                }
            }
            return .content(content)
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
        currentContentChangeCount = changeCount
        hasNewContent = true
        lastSelectionGrabReport = nil

        // Identify the source application
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            lastSourceApp = frontmost.localizedName ?? frontmost.bundleIdentifier
            print("[ClipboardService] Source app identified: \(lastSourceApp ?? "unknown")")
        }
        return .content(content)
    }

    nonisolated fileprivate static func detectContent(in pb: NSPasteboard) -> ClipboardContent? {
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
                DocumentParser.canParse(url: url) || DocumentParser.isImageFile(url: url) {
                return .file(url)
            }
        }

        // 2. try images (direct data)
        if let imageData = pb.data(forType: .png) {
            return .image(imageData)
        }
        if let tiffData = pb.data(forType: .tiff), let nsImage = NSImage(data: tiffData),
            let pngData = nsImage.pngData() {
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
        await grabSelectionResult().text
    }

    /// Attempt to grab the current selection and return a redacted diagnostic report.
    ///
    /// The report never includes selected text. Call `grabSelection()` when the
    /// caller actually needs the selected payload for composer insertion.
    @discardableResult
    public func grabSelectionReport() async -> SelectionGrabReport {
        await grabSelectionResult().report
    }

    private func grabSelectionResult() async -> SelectionCaptureTransaction.Result {
        // Capture before Osaurus takes focus so diagnostics retain the real source app.
        let sourceApp = Self.currentFrontmostApplicationName()
        let result = await selectionCapture.capture(sourceApp: sourceApp)
        if let content = result.content, let changeCount = result.changeCount {
            currentContent = content
            currentContentChangeCount = changeCount
            lastChangeCount = changeCount
            hasNewContent = true
            lastSourceApp = sourceApp
        }
        return finishSelectionGrab(result)
    }

    private static func currentFrontmostApplicationName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func finishSelectionGrab(
        _ result: SelectionCaptureTransaction.Result
    ) -> SelectionCaptureTransaction.Result {
        print("[ClipboardService] \(result.report.redactedDiagnosticDescription)")
        lastSelectionGrabReport = result.report
        return result
    }

    /// Mark the current clipboard content as "read"
    public func markAsRead() {
        hasNewContent = false
        lastSelectionGrabReport = nil
    }

    /// Clear the latest selection-grab diagnostic after the user has seen it.
    public func dismissSelectionGrabReport() {
        lastSelectionGrabReport = nil
    }
}

/// A single Cmd+C transaction with a quiet-drain boundary after timeout.
///
/// The boundary is required because the pasteboard does not identify which
/// keyboard event produced a change. A timed-out response is drained before a
/// later transaction snapshots its baseline, so it cannot be accepted as the
/// later selection.
@MainActor
final class SelectionCaptureTransaction {
    struct Snapshot: Equatable, Sendable {
        let changeCount: Int
        let content: ClipboardService.ClipboardContent?
    }

    struct Result: Equatable, Sendable {
        let report: ClipboardService.SelectionGrabReport
        let text: String?
        let content: ClipboardService.ClipboardContent?
        let changeCount: Int?
    }

    struct Timing: Equatable, Sendable {
        var pollIntervalNanos: UInt64 = 50_000_000
        var captureTimeoutNanos: UInt64 = 500_000_000
        var drainQuietNanos: UInt64 = 500_000_000
        var drainLimitNanos: UInt64 = 1_000_000_000
    }

    struct Dependencies {
        var snapshot: () async -> Snapshot?
        var postCopy: () -> Bool
        var sleep: (UInt64) async -> Void
    }

    private let dependencies: Dependencies
    private let timing: Timing
    private var captureInFlight = false
    private var requiresQuietDrain = false

    init(dependencies: Dependencies, timing: Timing = Timing()) {
        self.dependencies = dependencies
        self.timing = timing
    }

    static func live() -> SelectionCaptureTransaction {
        SelectionCaptureTransaction(
            dependencies: Dependencies(
                snapshot: {
                    await ClipboardService.onPasteboardQueue { pasteboard in
                        Snapshot(
                            changeCount: pasteboard.changeCount,
                            content: ClipboardService.detectContent(in: pasteboard)
                        )
                    }
                },
                postCopy: { KeyboardSimulationService.shared.copySelection() },
                sleep: { nanoseconds in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
            )
        )
    }

    func capture(sourceApp: String?) async -> Result {
        guard !captureInFlight else {
            return failure(.pasteboardUnchanged, sourceApp: sourceApp)
        }
        captureInFlight = true
        defer { captureInFlight = false }

        if requiresQuietDrain {
            guard await drainLateResponse() else {
                return failure(.pasteboardUnchanged, sourceApp: sourceApp)
            }
        }

        guard let baseline = await dependencies.snapshot() else {
            return failure(.pasteboardReadFailed, sourceApp: sourceApp)
        }
        guard dependencies.postCopy() else {
            return failure(.accessibilityDenied, sourceApp: sourceApp)
        }

        var elapsed: UInt64 = 0
        while elapsed < timing.captureTimeoutNanos {
            await dependencies.sleep(timing.pollIntervalNanos)
            elapsed += timing.pollIntervalNanos
            guard let snapshot = await dependencies.snapshot() else {
                return failure(.pasteboardReadFailed, sourceApp: sourceApp)
            }
            guard snapshot.changeCount != baseline.changeCount else { continue }
            requiresQuietDrain = false
            return result(for: snapshot, sourceApp: sourceApp)
        }

        requiresQuietDrain = true
        return failure(.pasteboardUnchanged, sourceApp: sourceApp)
    }

    private func drainLateResponse() async -> Bool {
        guard var previous = await dependencies.snapshot() else { return false }
        var quiet: UInt64 = 0
        var elapsed: UInt64 = 0

        while quiet < timing.drainQuietNanos && elapsed < timing.drainLimitNanos {
            await dependencies.sleep(timing.pollIntervalNanos)
            elapsed += timing.pollIntervalNanos
            guard let current = await dependencies.snapshot() else { return false }
            if current.changeCount == previous.changeCount {
                quiet += timing.pollIntervalNanos
            } else {
                previous = current
                quiet = 0
            }
        }

        let drained = quiet >= timing.drainQuietNanos
        requiresQuietDrain = !drained
        return drained
    }

    private func result(for snapshot: Snapshot, sourceApp: String?) -> Result {
        guard let content = snapshot.content else {
            return failure(.noReadableContent, sourceApp: sourceApp)
        }
        switch content {
        case .text(let text):
            return Result(
                report: ClipboardService.SelectionGrabReport(
                    outcome: .capturedText(characterCount: text.count),
                    sourceApp: sourceApp
                ),
                text: text,
                content: content,
                changeCount: snapshot.changeCount
            )
        case .image:
            return nonTextResult(.image, content: content, snapshot: snapshot, sourceApp: sourceApp)
        case .file:
            return nonTextResult(.file, content: content, snapshot: snapshot, sourceApp: sourceApp)
        }
    }

    private func nonTextResult(
        _ kind: ClipboardService.SelectionGrabReport.NonTextKind,
        content: ClipboardService.ClipboardContent,
        snapshot: Snapshot,
        sourceApp: String?
    ) -> Result {
        Result(
            report: ClipboardService.SelectionGrabReport(
                outcome: .capturedNonText(kind: kind),
                sourceApp: sourceApp
            ),
            text: nil,
            content: content,
            changeCount: snapshot.changeCount
        )
    }

    private func failure(
        _ outcome: ClipboardService.SelectionGrabReport.Outcome,
        sourceApp: String?
    ) -> Result {
        Result(
            report: ClipboardService.SelectionGrabReport(outcome: outcome, sourceApp: sourceApp),
            text: nil,
            content: nil,
            changeCount: nil
        )
    }
}

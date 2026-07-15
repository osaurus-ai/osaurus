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

    struct SelectionSource: Equatable, Sendable {
        let processIdentifier: pid_t
        let displayName: String?
    }

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
        public enum CaptureRoute: String, Equatable, Sendable {
            case nativeAccessibility = "native_accessibility"
            case syntheticCopy = "synthetic_copy"
        }

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
            case secureFieldDenied
            case unverifiedFieldDenied
            case noSelection
            case selectionTooLarge(byteLimit: Int)
        }

        public let outcome: Outcome
        public let sourceApp: String?
        public let captureRoute: CaptureRoute?

        public init(
            outcome: Outcome,
            sourceApp: String?,
            captureRoute: CaptureRoute? = nil
        ) {
            self.outcome = outcome
            self.sourceApp = sourceApp
            self.captureRoute = captureRoute
        }

        public var needsUserAttention: Bool {
            switch outcome {
            case .capturedText, .capturedNonText:
                return false
            case .accessibilityDenied, .pasteboardReadFailed, .noReadableContent, .pasteboardUnchanged,
                .secureFieldDenied, .selectionTooLarge:
                return true
            case .unverifiedFieldDenied, .noSelection:
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
            case .secureFieldDenied:
                return L("Osaurus does not capture text from password or secure fields.")
            case .unverifiedFieldDenied:
                return L("Osaurus could not verify that this field is safe to capture.")
            case .noSelection:
                return L("No text is selected in the frontmost app.")
            case .selectionTooLarge(let byteLimit):
                return String(
                    format: L("The selection is too large. Select less than %lld KB and try again."),
                    Int64(byteLimit / 1024)
                )
            }
        }

        public var redactedDiagnosticDescription: String {
            let source = sourceApp ?? "unknown"
            switch outcome {
            case .capturedText(let count):
                let route = captureRoute?.rawValue ?? "unknown"
                return "selection_grab(outcome: captured_text, characters: \(count), source: \(source), route: \(route))"
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
            case .secureFieldDenied:
                return "selection_grab(outcome: secure_field_denied, source: \(source))"
            case .unverifiedFieldDenied:
                return "selection_grab(outcome: unverified_field_denied, source: \(source))"
            case .noSelection:
                return "selection_grab(outcome: no_selection, source: \(source))"
            case .selectionTooLarge(let byteLimit):
                return "selection_grab(outcome: selection_too_large, byte_limit: \(byteLimit), source: \(source))"
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
    private var selectionCaptureGeneration: UInt64 = 0
    private var isSelectionCaptureInFlight = false
    private let selectionCapture: SelectionCaptureTransaction
    private let nativeSelectionCapture: NativeSelectionCapture
    private let selectionSource: @MainActor () -> SelectionSource?

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
        self.init(
            selectionCapture: SelectionCaptureTransaction.live(),
            nativeSelectionCapture: NativeSelectionCapture.live(),
            selectionSource: Self.liveSelectionSource
        )
    }

    init(
        selectionCapture: SelectionCaptureTransaction,
        nativeSelectionCapture: NativeSelectionCapture,
        selectionSource: @escaping @MainActor () -> SelectionSource?
    ) {
        self.selectionCapture = selectionCapture
        self.nativeSelectionCapture = nativeSelectionCapture
        self.selectionSource = selectionSource
        // monitoring is started/stopped by AppDelegate based on window visibility
    }

    convenience init(selectionCapture: SelectionCaptureTransaction) {
        self.init(
            selectionCapture: selectionCapture,
            nativeSelectionCapture: .unsupported(),
            selectionSource: ClipboardService.liveSelectionSource
        )
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
        guard !isSelectionCaptureInFlight else { return .noReadableContent }
        let observedCaptureGeneration = selectionCaptureGeneration
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

        let detected = (await Self.onPasteboardQueue { Self.detectContent(in: $0) }).flatMap { $0 }
        guard canPublishPasteboardRefresh(observedCaptureGeneration: observedCaptureGeneration) else {
            return .noReadableContent
        }
        print("[ClipboardService] Pasteboard change detected. Count: \(changeCount) (was \(knownChangeCount))")
        guard let content = detected else {
            lastChangeCount = changeCount
            print("[ClipboardService] Change detected but no meaningful content found on pasteboard.")
            return .noReadableContent
        }

        // Only update if content actually changed
        guard content != currentContent else {
            print("[ClipboardService] Change detected but content is identical to current.")
            lastChangeCount = changeCount
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
        guard canPublishPasteboardRefresh(observedCaptureGeneration: observedCaptureGeneration) else {
            return .noReadableContent
        }
        print("[ClipboardService] New content detected: \(summary)")
        lastChangeCount = changeCount
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
    public func grabSelectionReport(
        onCopyAttempted: (@MainActor () -> Void)? = nil
    ) async -> SelectionGrabReport {
        await grabSelectionResult(onCopyAttempted: onCopyAttempted).report
    }

    private func grabSelectionResult(
        onCopyAttempted: (@MainActor () -> Void)? = nil
    ) async -> SelectionCaptureTransaction.Result {
        selectionCaptureGeneration &+= 1
        isSelectionCaptureInFlight = true
        defer { isSelectionCaptureInFlight = false }

        // Capture before Osaurus takes focus so diagnostics retain the real source app.
        let source = selectionSource()
        let sourceApp = source?.displayName
        let result: SelectionCaptureTransaction.Result
        if let source {
            switch await nativeSelectionCapture.capture(pid: source.processIdentifier) {
            case .captured(let text):
                let content = ClipboardContent.text(text)
                // Native AX capture does not mutate the pasteboard. Record its
                // current generation so the overlay's immediate monitor poll
                // cannot replace this selection with an older clipboard item.
                let changeCount = await Self.onPasteboardQueue { $0.changeCount }
                result = SelectionCaptureTransaction.Result(
                    report: SelectionGrabReport(
                        outcome: .capturedText(characterCount: text.count),
                        sourceApp: sourceApp,
                        captureRoute: .nativeAccessibility
                    ),
                    text: text,
                    content: content,
                    changeCount: changeCount
                )
            case .secureField:
                result = SelectionCaptureTransaction.failureResult(
                    .secureFieldDenied,
                    sourceApp: sourceApp
                )
            case .unverifiedField:
                result = SelectionCaptureTransaction.failureResult(
                    .unverifiedFieldDenied,
                    sourceApp: sourceApp
                )
            case .noSelection:
                result = SelectionCaptureTransaction.failureResult(
                    .noSelection,
                    sourceApp: sourceApp
                )
            case .tooLarge(let byteLimit):
                result = SelectionCaptureTransaction.failureResult(
                    .selectionTooLarge(byteLimit: byteLimit),
                    sourceApp: sourceApp
                )
            case .unavailable:
                result = SelectionCaptureTransaction.failureResult(
                    .unverifiedFieldDenied,
                    sourceApp: sourceApp
                )
            }
        } else {
            result = await selectionCapture.capture(
                sourceApp: nil,
                onCopyAttempted: onCopyAttempted
            )
        }
        if let changeCount = result.changeCount {
            currentContentChangeCount = changeCount
            lastChangeCount = changeCount
        }
        if let content = result.content {
            currentContent = content
            if result.changeCount == nil {
                currentContentChangeCount = nil
            }
            hasNewContent = true
            lastSourceApp = sourceApp
        } else {
            // An explicit hotkey attempt owns the selection affordance. Do not
            // leave an older unread clipboard item looking like the failed
            // request succeeded.
            hasNewContent = false
        }
        return finishSelectionGrab(result)
    }

    private func canPublishPasteboardRefresh(observedCaptureGeneration: UInt64) -> Bool {
        Self.canPublishPasteboardRefresh(
            observedCaptureGeneration: observedCaptureGeneration,
            currentCaptureGeneration: selectionCaptureGeneration,
            captureInFlight: isSelectionCaptureInFlight
        )
    }

    nonisolated static func canPublishPasteboardRefresh(
        observedCaptureGeneration: UInt64,
        currentCaptureGeneration: UInt64,
        captureInFlight: Bool
    ) -> Bool {
        !captureInFlight && observedCaptureGeneration == currentCaptureGeneration
    }

    private static func liveSelectionSource() -> SelectionSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return SelectionSource(
            processIdentifier: app.processIdentifier,
            displayName: app.localizedName ?? app.bundleIdentifier
        )
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
        let pasteboardItems: [[String: Data]]
        let pasteboardRestorable: Bool

        init(
            changeCount: Int,
            content: ClipboardService.ClipboardContent?,
            pasteboardItems: [[String: Data]] = [],
            pasteboardRestorable: Bool = true
        ) {
            self.changeCount = changeCount
            self.content = content
            self.pasteboardItems = pasteboardItems
            self.pasteboardRestorable = pasteboardRestorable
        }
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
        var restore: (Snapshot) async -> Int?
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
                        let serialized = serializedPasteboard(in: pasteboard)
                        return Snapshot(
                            changeCount: pasteboard.changeCount,
                            content: ClipboardService.detectContent(in: pasteboard),
                            pasteboardItems: serialized.items,
                            pasteboardRestorable: serialized.complete
                        )
                    }
                },
                postCopy: { KeyboardSimulationService.shared.copySelection() },
                restore: { baseline in
                    let outcome = await ClipboardService.onPasteboardQueue { pasteboard in
                        restore(
                            baselineItems: baseline.pasteboardItems,
                            in: pasteboard
                        )
                    }
                    guard let outcome, outcome.restored else { return nil }
                    return outcome.changeCount
                },
                sleep: { nanoseconds in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
            )
        )
    }

    nonisolated static func serializedItems(in pasteboard: NSPasteboard) -> [[String: Data]] {
        serializedPasteboard(in: pasteboard).items
    }

    nonisolated static func serializedPasteboard(
        in pasteboard: NSPasteboard
    ) -> (items: [[String: Data]], complete: Bool) {
        guard let pasteboardItems = pasteboard.pasteboardItems else { return ([], true) }
        var complete = true
        let items = pasteboardItems.map { item in
            var serialized: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    complete = false
                    continue
                }
                serialized[type.rawValue] = data
            }
            return serialized
        }
        return (items, complete)
    }

    nonisolated static func restore(
        baselineItems: [[String: Data]],
        in pasteboard: NSPasteboard
    ) -> (changeCount: Int, restored: Bool) {
        let fallbackItems = serializedItems(in: pasteboard)
        pasteboard.clearContents()
        guard !baselineItems.isEmpty else {
            return (pasteboard.changeCount, true)
        }
        if pasteboard.writeObjects(makePasteboardItems(from: baselineItems)) {
            return (pasteboard.changeCount, true)
        }
        pasteboard.clearContents()
        if !fallbackItems.isEmpty {
            _ = pasteboard.writeObjects(makePasteboardItems(from: fallbackItems))
        }
        return (pasteboard.changeCount, false)
    }

    nonisolated private static func makePasteboardItems(
        from snapshots: [[String: Data]]
    ) -> [NSPasteboardItem] {
        snapshots.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
    }

    func capture(
        sourceApp: String?,
        onCopyAttempted: (@MainActor () -> Void)? = nil
    ) async -> Result {
        guard !captureInFlight else {
            return failure(.pasteboardUnchanged, sourceApp: sourceApp)
        }
        captureInFlight = true
        defer { captureInFlight = false }

        if requiresQuietDrain {
            guard await drainLateResponse() else {
                requiresQuietDrain = false
                return failure(.pasteboardUnchanged, sourceApp: sourceApp)
            }
        }

        guard let baseline = await dependencies.snapshot() else {
            return failure(.pasteboardReadFailed, sourceApp: sourceApp)
        }
        guard baseline.pasteboardRestorable else {
            return failure(.pasteboardReadFailed, sourceApp: sourceApp)
        }
        let copyPosted = dependencies.postCopy()
        guard copyPosted else {
            return failure(.accessibilityDenied, sourceApp: sourceApp)
        }
        onCopyAttempted?()

        var elapsed: UInt64 = 0
        while elapsed < timing.captureTimeoutNanos {
            await dependencies.sleep(timing.pollIntervalNanos)
            elapsed += timing.pollIntervalNanos
            guard let snapshot = await dependencies.snapshot() else {
                requiresQuietDrain = true
                _ = await drainLateResponse()
                return await restoring(
                    failure(.pasteboardReadFailed, sourceApp: sourceApp),
                    baseline: baseline
                )
            }
            guard snapshot.changeCount != baseline.changeCount else { continue }
            requiresQuietDrain = false
            return await restoring(result(for: snapshot, sourceApp: sourceApp), baseline: baseline)
        }

        requiresQuietDrain = true
        _ = await drainLateResponse()
        return await restoring(
            failure(.pasteboardUnchanged, sourceApp: sourceApp),
            baseline: baseline
        )
    }

    private func restoring(_ result: Result, baseline: Snapshot) async -> Result {
        guard let current = await dependencies.snapshot(),
              current.changeCount != baseline.changeCount
        else {
            return result
        }
        guard let restoredChangeCount = await dependencies.restore(baseline) else {
            let currentChangeCount = await dependencies.snapshot()?.changeCount
            let failed = failure(.pasteboardReadFailed, sourceApp: result.report.sourceApp)
            return Result(
                report: failed.report,
                text: nil,
                content: nil,
                changeCount: currentChangeCount
            )
        }
        return Result(
            report: result.report,
            text: result.text,
            content: result.content,
            changeCount: restoredChangeCount
        )
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
        // A bounded drain failure applies only to this attempt. Keeping the
        // flag armed would permanently lock out capture under a noisy clipboard
        // synchronizer; the next hotkey starts from a fresh baseline instead.
        requiresQuietDrain = false
        return drained
    }

    private func result(for snapshot: Snapshot, sourceApp: String?) -> Result {
        guard let content = snapshot.content else {
            return failure(
                .noReadableContent,
                sourceApp: sourceApp,
                changeCount: snapshot.changeCount
            )
        }
        switch content {
        case .text(let text):
            let byteCount = text.utf8.count
            guard byteCount <= NativeSelectionCapture.maximumUTF8Bytes else {
                return failure(
                    .selectionTooLarge(byteLimit: NativeSelectionCapture.maximumUTF8Bytes),
                    sourceApp: sourceApp,
                    changeCount: snapshot.changeCount
                )
            }
            return Result(
                report: ClipboardService.SelectionGrabReport(
                    outcome: .capturedText(characterCount: text.count),
                    sourceApp: sourceApp,
                    captureRoute: .syntheticCopy
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
                sourceApp: sourceApp,
                captureRoute: .syntheticCopy
            ),
            text: nil,
            content: content,
            changeCount: snapshot.changeCount
        )
    }

    private func failure(
        _ outcome: ClipboardService.SelectionGrabReport.Outcome,
        sourceApp: String?,
        changeCount: Int? = nil
    ) -> Result {
        Self.failureResult(
            outcome,
            sourceApp: sourceApp,
            captureRoute: .syntheticCopy,
            changeCount: changeCount
        )
    }

    static func failureResult(
        _ outcome: ClipboardService.SelectionGrabReport.Outcome,
        sourceApp: String?,
        captureRoute: ClipboardService.SelectionGrabReport.CaptureRoute? = nil,
        changeCount: Int? = nil
    ) -> Result {
        Result(
            report: ClipboardService.SelectionGrabReport(
                outcome: outcome,
                sourceApp: sourceApp,
                captureRoute: captureRoute
            ),
            text: nil,
            content: nil,
            changeCount: changeCount
        )
    }
}

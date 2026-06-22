//
//  Accessibility.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  Accessibility-tree traversal, snapshot-scoped element caching, and the
//  app/window listing helpers the harness perceives the screen through.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - CFTypeRef casts

// AX attribute values arrive as untyped `CFTypeRef`s. CoreFoundation types
// can't be conditionally downcast in Swift (`as?` is rejected as
// always-succeeding), so we verify the concrete CF type id and only then
// force-cast — provably safe, and returning nil for an unexpected type instead
// of trapping. These centralize the unavoidable force-cast behind that check.

private func axElement(_ ref: CFTypeRef?) -> AXUIElement? {
    guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    // swiftlint:disable:next force_cast
    return (ref as! AXUIElement)
}

private func axValue(_ ref: CFTypeRef?) -> AXValue? {
    guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    // swiftlint:disable:next force_cast
    return (ref as! AXValue)
}

// MARK: - Safe numeric conversion

/// Safely convert a CGFloat coordinate/size to Int.
/// AX position/size attributes (and other window-server geometry) can be NaN or
/// infinite for offscreen or malformed elements; `Int(CGFloat)` traps on any
/// non-finite or out-of-range value. Clamp at the conversion boundary instead.
func safeInt(_ value: CGFloat) -> Int {
    guard value.isFinite else { return 0 }
    let rounded = value.rounded()
    if rounded >= CGFloat(Int.max) { return Int.max }
    if rounded <= CGFloat(Int.min) { return Int.min }
    return Int(rounded)
}

// MARK: - Snapshot ID Format

/// Element IDs are scoped to a snapshot so we can distinguish "stale ID from a
/// previous observation" from "element no longer exists".
/// Format: "s{snapshotId}-{elementNumber}" (e.g. "s7-42").
enum SnapshotIdFormat {
    static func format(snapshot: Int, element: Int) -> String {
        return "s\(snapshot)-\(element)"
    }

    static func parse(_ id: String) -> (snapshot: Int, element: Int)? {
        guard id.hasPrefix("s") else { return nil }
        let body = id.dropFirst()
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
            let snap = Int(parts[0]),
            let el = Int(parts[1])
        else { return nil }
        return (snap, el)
    }
}

// MARK: - Element Info

/// Compact representation of an accessibility element for agent consumption.
/// Optional fields are omitted from JSON when nil.
struct ElementInfo: Encodable, Sendable {
    let id: String
    let role: String
    let roleDescription: String?
    let label: String?
    let value: String?
    let selectedText: String?
    let placeholder: String?
    let path: String?
    let windowId: Int?
    let focused: Bool
    let enabled: Bool
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    let actions: [String]
}

// MARK: - Window Summary

struct WindowSummary: Encodable, Sendable {
    let id: Int
    let title: String?
    let focused: Bool
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

// MARK: - Cached Element

/// Internal representation storing AXUIElement reference for later interaction
final class CachedElement: @unchecked Sendable {
    let axElement: AXUIElement
    let role: String
    let supportedActions: [String]
    let pid: Int32

    init(axElement: AXUIElement, role: String, supportedActions: [String], pid: Int32) {
        self.axElement = axElement
        self.role = role
        self.supportedActions = supportedActions
        self.pid = pid
    }

    func getCurrentFrame() -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        if let axPos = axValue(positionValue) {
            AXValueGetValue(axPos, .cgPoint, &position)
        }
        if let axSize = axValue(sizeValue) {
            AXValueGetValue(axSize, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    func supportsAction(_ action: String) -> Bool {
        return supportedActions.contains(action)
    }

    func performAction(_ action: String) -> Bool {
        let result = AXUIElementPerformAction(axElement, action as CFString)
        return result == .success
    }
}

// MARK: - Element Lookup

enum ElementLookup {
    case found(CachedElement)
    /// The id refers to a snapshot we no longer remember. Caller should re-observe.
    case stale(requestedSnapshot: Int, currentSnapshot: Int)
    /// The id is well-formed but the element is gone (UI changed).
    case removed(id: String)
    /// The id string is not parseable as a snapshot id at all.
    case malformed(id: String)
}

// MARK: - Element Filter

/// Filter options for UI element traversal
struct ElementFilter: Decodable {
    var pid: Int32
    var roles: [String]?
    var maxDepth: Int?
    var maxElements: Int?
    var interactiveOnly: Bool?
    /// If true, only traverse the focused window (skip menu bar and other windows).
    var focusedWindowOnly: Bool?
}

/// Search options used by `find_elements`. Reuses the same traversal as `get_ui_elements`.
struct SearchOptions {
    var text: String?
    var enabledOnly: Bool
    var windowId: Int?
    var limit: Int
}

// MARK: - Traversal Result

struct TraversalResult: Encodable, Sendable {
    let snapshotId: Int
    let pid: Int32
    let app: String
    let focusedWindow: String?
    let elementCount: Int
    let truncated: Bool
    let windows: [WindowSummary]
    let elements: [ElementInfo]
}

// MARK: - Accessibility Manager

/// Manages accessibility tree traversal and element caching.
/// IDs are snapshot-scoped strings ("s{snapshot}-{element}"). The last two
/// snapshots are retained so an action immediately after a re-observe still
/// resolves correctly.
final class AccessibilityManager: @unchecked Sendable {
    static let shared = AccessibilityManager()

    /// Maximum time (seconds) any single AX call is allowed to block before it
    /// returns a timeout error. Applied per-app via `axApp` (and globally on the
    /// system-wide element in `init`) so a wedged target app can't stall the
    /// off-main driver queue indefinitely on any one call.
    static let axMessagingTimeout: Float = 1.5

    /// Overall wall-clock budget for a single `traverse`. Even when each AX call
    /// stays under `axMessagingTimeout`, a huge or partially-wedged tree can
    /// accumulate many slow calls; the traversal bails (marking the result
    /// `truncated`) once this elapses so a capture still returns promptly.
    static let traversalDeadline: TimeInterval = 2.0

    /// Osaurus's own process id.
    static let selfPid: Int32 = ProcessInfo.processInfo.processIdentifier

    /// Whether `pid` is Osaurus itself. The native driver must NEVER resolve the
    /// current process's AX tree on the off-main driver queue: querying our own
    /// elements re-enters AppKit/SwiftUI accessibility *in-process*, which
    /// evaluates SwiftUI `body` and trips its main-thread assertion
    /// (`_dispatch_assert_queue_fail`) when it runs off the main thread. We also
    /// never want to perceive or drive our own UI through Computer Use, so every
    /// AX entry point treats self as "nothing to perceive".
    static func isSelf(_ pid: Int32) -> Bool { pid == selfPid }

    private var snapshots: [Int: [String: CachedElement]] = [:]
    private var snapshotPids: [Int: Int32] = [:]
    private var snapshotOrder: [Int] = []
    private var currentSnapshotId: Int = 0
    /// The loop captures several times per agent turn (perceive, every act's
    /// verify, and the reobserve re-perceive), so a 2-deep cache rotates a mark
    /// out from under the model within the same turn it was shown. Retaining a
    /// few more generations keeps a just-shown mark resolvable across those
    /// intra-turn captures without holding meaningfully more memory.
    private static let maxSnapshotsToRetain: Int = 6
    /// Pids we've already nudged into exposing their full AX tree (Electron).
    private var preparedPids: Set<Int32> = []
    /// Pids whose readiness wait we've already run once. The content gate keeps
    /// checking these on every capture (cheap), but never pays the timeout again
    /// — so an app that genuinely exposes no AX text (canvas/WebGL) isn't taxed
    /// the full budget on each capture, only on first touch.
    private var awaitedPids: Set<Int32> = []
    private let lock = NSLock()

    private init() {
        // Apply the global AX timeout once at first access.
        AXUIElementSetMessagingTimeout(
            AXUIElementCreateSystemWide(),
            Self.axMessagingTimeout
        )
    }

    // MARK: Off-main execution

    /// Serializes ALL native-driver AX IPC and input synthesis off the main
    /// thread, so a slow/wedged target app blocks this background queue instead
    /// of the UI run loop. One operation at a time preserves input-event
    /// ordering and AX-cache coherence — the same single-threaded guarantee the
    /// old main-actor hop provided, just off the main thread.
    static let serialQueue = DispatchQueue(
        label: "com.osaurus.computeruse.driver",
        qos: .userInitiated
    )

    /// Run blocking native-driver work (AX IPC, input synthesis) on
    /// `serialQueue` and await its result, keeping the main thread responsive.
    static func runOffMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            serialQueue.async { continuation.resume(returning: body()) }
        }
    }

    /// Create an application AX element with the per-app messaging timeout
    /// applied. Setting the timeout on the system-wide element alone does not
    /// reliably propagate to per-application elements, so every site that needs
    /// an app element goes through here to bound how long a single AX call can
    /// block.
    static func axApp(_ pid: Int32) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        return app
    }

    // MARK: Electron / Chromium accessibility

    /// Nudge a Chromium/Electron/WebKit app into building its full accessibility
    /// tree.
    ///
    /// Two app families hide their tree until an assistive client asks for it:
    /// Chromium/Electron (Slack, VS Code, Discord, Chrome) only materialize their
    /// AX tree when `AXManualAccessibility` is set on the app element, and
    /// WebKit/Safari only expose the web a11y tree when `AXEnhancedUserInterface`
    /// is set. Until then a plain traverse returns almost nothing (a window with
    /// no children, or just the browser chrome). Set BOTH — each app honors the
    /// one it understands and Cocoa apps ignore both harmlessly, so this is safe
    /// to apply to every pid. Idempotent per pid — the first call sets the flags,
    /// the tree then builds asynchronously (see `prepareAndAwaitTree`).
    @discardableResult
    func prepareForAccessibility(pid: Int32) -> Bool {
        // Never poke our own process (see `isSelf`).
        if Self.isSelf(pid) { return false }
        lock.lock()
        if preparedPids.contains(pid) {
            lock.unlock()
            return false
        }
        preparedPids.insert(pid)
        lock.unlock()

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(
            app,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
        return true
    }

    /// Atomically record that `pid`'s readiness wait has run. Returns true if it
    /// had ALREADY run (so the caller skips paying the timeout again). Kept
    /// synchronous so the `NSLock` is never touched from an async context.
    private func markAwaited(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if awaitedPids.contains(pid) { return true }
        awaitedPids.insert(pid)
        return false
    }

    /// Prepare `pid` for accessibility and, when its focused window hasn't
    /// rendered real content yet, briefly wait for the async subtree to build
    /// before the caller traverses.
    ///
    /// Chromium/Electron/WebKit populate their tree asynchronously after the
    /// flags flip (see `prepareForAccessibility`), so a one-shot read — the
    /// ambient screen-context capture, or the loop's first perceive — otherwise
    /// sees just the menu bar / browser chrome (Slack returns nothing; Chrome
    /// returns only the address bar, because its `AXWebArea` doesn't exist in the
    /// tree yet). The gate is `focusedWindowHasContent`, which waits for actual
    /// readable text (a built `webarea`, a focused value, or static body text)
    /// rather than a bare node count — so a browser whose page tree hasn't built
    /// isn't declared "ready" on its toolbar alone.
    ///
    /// Native apps that already expose text return on the first check (instant).
    /// The timeout only elapses for an app that exposes no AX text within the
    /// budget (a blank page, or a canvas/WebGL app), and we pay it at most once
    /// per pid — subsequent captures still re-check cheaply (picking up a page
    /// that built late) but never block again. The poll runs on the off-main
    /// driver queue because it issues blocking AX reads.
    func prepareAndAwaitTree(pid: Int32, timeout: TimeInterval = 1.6) async {
        // Resolving our own focused window re-enters SwiftUI off-main and traps
        // (see `isSelf`); there is nothing of ours to wait for.
        if Self.isSelf(pid) { return }
        prepareForAccessibility(pid: pid)
        if await Self.runOffMain({ Self.focusedWindowHasContent(pid: pid) }) { return }

        // Only pay the timeout once per pid: a contentless app (canvas/blank)
        // shouldn't block every capture, just the first.
        if markAwaited(pid) { return }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if await Self.runOffMain({ Self.focusedWindowHasContent(pid: pid) }) { return }
        }
    }

    /// Whether the focused window already carries readable content — the signal
    /// that it's worth traversing now rather than waiting for an async build.
    /// Ready when ANY of:
    ///   1. the focused element exposes text (a native input/editor — instant);
    ///   2. a `webarea` HAS children — a browser page finished rendering into AX
    ///      (the part that lags well behind the browser chrome);
    ///   3. the window already carries real static/heading/text-area body text
    ///      (a normal Cocoa app showing content).
    /// A bare node count is deliberately NOT enough: a browser's toolbar is dozens
    /// of nodes with no readable text, and treating that as "ready" is exactly
    /// what skipped the wait for the page. Bounded BFS so it stays cheap on huge
    /// trees.
    private static func focusedWindowHasContent(pid: Int32) -> Bool {
        let app = Self.axApp(pid)

        func readableLength(_ element: AXUIElement) -> Int {
            guard let value = axCopyAttribute(element, kAXValueAttribute as String) as? String
            else { return 0 }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).count
        }

        // 1. A focused element that already exposes text → ready immediately.
        if let focused = axElement(axCopyAttribute(app, kAXFocusedUIElementAttribute as String)),
            readableLength(focused) > 0
        {
            return true
        }

        // The focused window (else the first window).
        let window =
            axElement(axCopyAttribute(app, kAXFocusedWindowAttribute as String))
            ?? (axCopyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement])?.first
        guard let window else { return false }

        // ~16 chars of static/heading/text-area body = a couple of words, enough
        // to tell "a normal app showing text" from "browser chrome only".
        let readableThreshold = 16
        let maxVisited = 400
        let maxDepth = 12
        var readable = 0
        var visited = 0
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        while !queue.isEmpty, visited < maxVisited {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if let role = axCopyAttribute(element, kAXRoleAttribute as String) as? String {
                switch normalizeRole(role) {
                case "webarea":
                    // 2. Built page → ready; empty page → still building.
                    if axElementHasChildren(element) { return true }
                case "statictext", "heading", "textarea":
                    // 3. Accumulate real body text.
                    readable += readableLength(element)
                    if readable >= readableThreshold { return true }
                default:
                    break
                }
            }
            if depth < maxDepth {
                for child in axChildren(element) { queue.append((child, depth + 1)) }
            }
        }
        return false
    }

    // MARK: Snapshot lifecycle

    func beginNewSnapshot(pid: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        currentSnapshotId += 1
        let snapId = currentSnapshotId
        snapshots[snapId] = [:]
        snapshotPids[snapId] = pid
        snapshotOrder.append(snapId)
        while snapshotOrder.count > Self.maxSnapshotsToRetain {
            let removed = snapshotOrder.removeFirst()
            snapshots.removeValue(forKey: removed)
            snapshotPids.removeValue(forKey: removed)
        }
        return snapId
    }

    fileprivate func store(snapshotId: Int, elementId: String, cached: CachedElement) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[snapshotId, default: [:]][elementId] = cached
    }

    // MARK: Lookup

    /// Look up a cached element by its snapshot-scoped string id.
    /// Distinguishes between malformed, stale, removed, and found.
    func lookup(id: String) -> ElementLookup {
        lock.lock()
        defer { lock.unlock() }

        guard let parsed = SnapshotIdFormat.parse(id) else {
            return .malformed(id: id)
        }

        guard snapshots[parsed.snapshot] != nil else {
            return .stale(requestedSnapshot: parsed.snapshot, currentSnapshot: currentSnapshotId)
        }

        if let element = snapshots[parsed.snapshot]?[id] {
            return .found(element)
        }
        return .removed(id: id)
    }

    /// Look up an element's pid from its id. Used for delta computation.
    func pid(for id: String) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let parsed = SnapshotIdFormat.parse(id) else { return nil }
        return snapshotPids[parsed.snapshot]
    }

    /// Returns the most-recently traversed pid (for annotated screenshots, etc.)
    func mostRecentPid() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = snapshotOrder.last else { return nil }
        return snapshotPids[last]
    }

    /// Returns elements from the most recent snapshot for a given pid.
    /// Used by annotated screenshots.
    func mostRecentElements(for pid: Int32) -> [(id: String, frame: CGRect)] {
        lock.lock()
        let snapshotId: Int? =
            snapshotOrder.reversed().first { snapshotPids[$0] == pid }
        let cached = snapshotId.flatMap { snapshots[$0] } ?? [:]
        lock.unlock()

        var results: [(id: String, frame: CGRect)] = []
        for (id, element) in cached {
            if let frame = element.getCurrentFrame(), frame.width > 0, frame.height > 0 {
                results.append((id, frame))
            }
        }
        return results
    }

    // MARK: Role normalization

    /// Normalize a role name to the canonical short form (lowercase, no "ax" prefix).
    /// Accepts "AXButton", "Button", "button" - all become "button".
    static func normalizeRole(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("ax") {
            return String(lower.dropFirst(2))
        }
        return lower
    }

    /// Interactive roles (canonical short form) that agents typically want to interact with.
    /// Broadened to include containers/content roles that frequently matter on
    /// web pages and rich apps.
    private static let interactiveRoles: Set<String> = [
        "button",
        "link",
        "textfield",
        "textarea",
        "checkbox",
        "radiobutton",
        "popupbutton",
        "combobox",
        "slider",
        "menuitem",
        "menubutton",
        "menubaritem",
        "tab",
        "tabgroup",
        "disclosuretriangle",
        "incrementor",
        "colorwell",
        "searchfield",
        "securetextfield",
        "row",
        "cell",
        "outline",
        "image",
        "heading",
        "webarea",
        "staticrtext",
    ]

    /// Text-bearing roles whose `kAXSelectedTextAttribute` is worth reading.
    /// Excludes `securetextfield` so a password selection is never captured.
    static let textSelectionRoles: Set<String> = [
        "textfield",
        "textarea",
        "searchfield",
        "combobox",
        "statictext",
        "staticrtext",
        "webarea",
    ]

    // MARK: Traversal entry point

    /// Traverse the accessibility tree for a given PID with filtering and optional search.
    /// Begins a new snapshot. Element IDs in the result are valid until the cache
    /// rotates them out (after the next snapshot beyond the retention limit).
    func traverse(filter: ElementFilter, search: SearchOptions? = nil) -> TraversalResult {
        // Never traverse our own process: resolving Osaurus's AX tree re-enters
        // SwiftUI/AppKit accessibility in-process (evaluating `body`), which
        // traps on the off-main driver queue — and we never perceive our own UI.
        if Self.isSelf(filter.pid) {
            return TraversalResult(
                snapshotId: beginNewSnapshot(pid: filter.pid),
                pid: filter.pid,
                app: getAppName(for: filter.pid) ?? "Osaurus",
                focusedWindow: nil,
                elementCount: 0,
                truncated: false,
                windows: [],
                elements: []
            )
        }

        // Ensure Chromium/Electron targets have been asked to expose their tree.
        // Idempotent and cheap after the first call; covers apps reached via a
        // bare capture (not just `open`). The tree may still be settling on the
        // very first traverse after this flips — the loop's next perceive picks
        // up the populated tree.
        prepareForAccessibility(pid: filter.pid)

        let snapshotId = beginNewSnapshot(pid: filter.pid)

        let app = Self.axApp(filter.pid)
        let appName = getAppName(for: filter.pid) ?? "Unknown"

        // Overall wall-clock budget for this traversal (see `traversalDeadline`).
        let deadline = Date().addingTimeInterval(Self.traversalDeadline)

        let maxDepth = filter.maxDepth ?? 20
        let maxElements: Int = {
            if let lim = search?.limit { return lim }
            return filter.maxElements ?? 150
        }()
        let interactiveOnly = filter.interactiveOnly ?? true
        let allowedRoles: Set<String>? = filter.roles.map { Set($0.map(Self.normalizeRole)) }
        let textNeedle = search?.text?.lowercased()
        let enabledOnly = search?.enabledOnly ?? false

        // Identify focused window and focused element once
        let focusedElement: AXUIElement? = {
            var ref: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                app,
                kAXFocusedUIElementAttribute as CFString,
                &ref
            )
            guard status == .success else { return nil }
            return axElement(ref)
        }()

        let focusedWindowElement: AXUIElement? = {
            var ref: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                app,
                kAXFocusedWindowAttribute as CFString,
                &ref
            )
            guard status == .success else { return nil }
            return axElement(ref)
        }()

        // Enumerate and order windows (focused first)
        var windowSummaries: [WindowSummary] = []
        var orderedWindows: [(element: AXUIElement, summary: WindowSummary)] = []
        if let allWindows = getAttribute(app, kAXWindowsAttribute) as? [AXUIElement] {
            for (idx, windowElement) in allWindows.enumerated() {
                let title = getAttribute(windowElement, kAXTitleAttribute) as? String
                let frame = getFrame(windowElement) ?? .zero
                let isFocused: Bool =
                    focusedWindowElement.map { CFEqual($0, windowElement) } ?? false
                let summary = WindowSummary(
                    id: idx + 1,
                    title: title,
                    focused: isFocused,
                    x: safeInt(frame.origin.x),
                    y: safeInt(frame.origin.y),
                    w: safeInt(frame.size.width),
                    h: safeInt(frame.size.height)
                )
                windowSummaries.append(summary)
                orderedWindows.append((windowElement, summary))
            }
        }
        orderedWindows.sort { lhs, rhs in
            if lhs.summary.focused != rhs.summary.focused { return lhs.summary.focused }
            return lhs.summary.id < rhs.summary.id
        }
        let focusedWindowTitle: String? = orderedWindows.first(where: { $0.summary.focused })?
            .summary.title

        // Optionally restrict to a single window for find_elements
        let restrictWindowId = search?.windowId

        var elements: [ElementInfo] = []
        var nextElementNum: Int = 1
        var truncated = false

        for window in orderedWindows {
            if elements.count >= maxElements || Date() >= deadline {
                truncated = true
                break
            }
            if let restrict = restrictWindowId, window.summary.id != restrict {
                continue
            }
            let basePath: String = {
                if let title = window.summary.title, !title.isEmpty {
                    return "Window[\(title)]"
                }
                return "Window"
            }()
            traverseElement(
                element: window.element,
                depth: 0,
                maxDepth: maxDepth,
                maxElements: maxElements,
                deadline: deadline,
                interactiveOnly: interactiveOnly,
                allowedRoles: allowedRoles,
                textNeedle: textNeedle,
                enabledOnly: enabledOnly,
                windowId: window.summary.id,
                path: basePath,
                focusedElement: focusedElement,
                snapshotId: snapshotId,
                pid: filter.pid,
                nextElementNum: &nextElementNum,
                elements: &elements,
                truncated: &truncated
            )
        }

        // Walk the menu bar last (skip if focusedWindowOnly or restricted to a window)
        let walkMenuBar =
            !(filter.focusedWindowOnly ?? false) && restrictWindowId == nil
        if walkMenuBar, elements.count < maxElements,
            let menuBar = axElement(getAttribute(app, kAXMenuBarAttribute))
        {
            traverseElement(
                element: menuBar,
                depth: 0,
                maxDepth: maxDepth,
                maxElements: maxElements,
                deadline: deadline,
                interactiveOnly: interactiveOnly,
                allowedRoles: allowedRoles,
                textNeedle: textNeedle,
                enabledOnly: enabledOnly,
                windowId: nil,
                path: "MenuBar",
                focusedElement: focusedElement,
                snapshotId: snapshotId,
                pid: filter.pid,
                nextElementNum: &nextElementNum,
                elements: &elements,
                truncated: &truncated
            )
        }

        return TraversalResult(
            snapshotId: snapshotId,
            pid: filter.pid,
            app: appName,
            focusedWindow: focusedWindowTitle,
            elementCount: elements.count,
            truncated: truncated,
            windows: windowSummaries,
            elements: elements
        )
    }

    // MARK: Recursive traversal

    private func traverseElement(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxElements: Int,
        deadline: Date,
        interactiveOnly: Bool,
        allowedRoles: Set<String>?,
        textNeedle: String?,
        enabledOnly: Bool,
        windowId: Int?,
        path: String,
        focusedElement: AXUIElement?,
        snapshotId: Int,
        pid: Int32,
        nextElementNum: inout Int,
        elements: inout [ElementInfo],
        truncated: inout Bool
    ) {
        if depth > maxDepth { return }
        // Stop at the element cap or the overall wall-clock budget — a huge or
        // wedged tree can accrue many slow AX calls even under the per-call
        // timeout, so the deadline still guarantees a prompt (truncated) return.
        if elements.count >= maxElements || Date() >= deadline {
            truncated = true
            return
        }

        guard let rawRole = getAttribute(element, kAXRoleAttribute) as? String else { return }
        let normalizedRole = Self.normalizeRole(rawRole)

        let isInteractive = Self.interactiveRoles.contains(normalizedRole)
        let matchesRoleFilter = allowedRoles == nil || allowedRoles!.contains(normalizedRole)

        // Build label cascade (more thorough than before).
        let title = getAttribute(element, kAXTitleAttribute) as? String
        let description = getAttribute(element, kAXDescriptionAttribute) as? String
        let help = getAttribute(element, kAXHelpAttribute) as? String
        let labelValue = getAttribute(element, "AXLabelValue") as? String
        let pairedTitleValue: String? = {
            if let titleUI = axElement(getAttribute(element, "AXTitleUIElement")) {
                return getAttribute(titleUI, kAXValueAttribute) as? String
                    ?? getAttribute(titleUI, kAXTitleAttribute) as? String
            }
            return nil
        }()
        let label =
            nonEmpty(title) ?? nonEmpty(description) ?? nonEmpty(labelValue)
            ?? nonEmpty(pairedTitleValue) ?? nonEmpty(help)

        let roleDescription = nonEmpty(getAttribute(element, kAXRoleDescriptionAttribute) as? String)
        let value = stringifyValue(getAttribute(element, kAXValueAttribute))
        let placeholder = nonEmpty(getAttribute(element, kAXPlaceholderValueAttribute) as? String)
        // Selection only exists on text-bearing roles; gate the extra AX read
        // to those so a 200-element traversal doesn't pay an IPC per button for
        // an attribute it can't have. Secure fields are excluded so a password
        // selection is never captured.
        let selectedText =
            Self.textSelectionRoles.contains(normalizedRole)
            ? nonEmpty(getAttribute(element, kAXSelectedTextAttribute) as? String)
            : nil

        let actions = getSupportedActions(element)
        let enabled = (getAttribute(element, kAXEnabledAttribute) as? Bool) ?? true

        // Does this element have any meaningful content for the agent to act on?
        let hasContent =
            label != nil || value != nil || placeholder != nil || !actions.isEmpty
            || roleDescription != nil

        // Inclusion gate:
        // - role filter must match
        // - if interactiveOnly: must be in the interactive set OR have actions
        // - must have content the agent can use to identify it
        // - if enabledOnly (search): must be enabled
        // - if textNeedle (search): label/value/placeholder/roleDescription must contain it
        let passesInteractive = !interactiveOnly || isInteractive || !actions.isEmpty
        let passesEnabled = !enabledOnly || enabled
        let passesText: Bool = {
            guard let needle = textNeedle else { return true }
            let candidates: [String?] = [label, value, placeholder, roleDescription]
            for c in candidates {
                if let c = c, c.lowercased().contains(needle) { return true }
            }
            return false
        }()

        if matchesRoleFilter && passesInteractive && hasContent && passesEnabled && passesText {
            if let frame = getFrame(element),
                frame.origin.x.isFinite, frame.origin.y.isFinite,
                frame.width.isFinite, frame.height.isFinite,
                frame.width > 0, frame.height > 0
            {
                let elementNum = nextElementNum
                nextElementNum += 1
                let elementId = SnapshotIdFormat.format(snapshot: snapshotId, element: elementNum)

                let cached = CachedElement(
                    axElement: element,
                    role: rawRole,
                    supportedActions: actions,
                    pid: pid
                )
                store(snapshotId: snapshotId, elementId: elementId, cached: cached)

                let isFocused = focusedElement.map { CFEqual($0, element) } ?? false
                let segmentLabel = label ?? value ?? placeholder
                let nextPath: String = {
                    let segment: String
                    if let segmentLabel = segmentLabel, !segmentLabel.isEmpty {
                        let trimmed = segmentLabel.prefix(40)
                        segment = "\(normalizedRole)[\(trimmed)]"
                    } else {
                        segment = normalizedRole
                    }
                    return path.isEmpty ? segment : "\(path) > \(segment)"
                }()

                let info = ElementInfo(
                    id: elementId,
                    role: normalizedRole,
                    roleDescription: roleDescription,
                    label: label,
                    value: value,
                    selectedText: selectedText,
                    placeholder: placeholder,
                    path: nextPath,
                    windowId: windowId,
                    focused: isFocused,
                    enabled: enabled,
                    x: safeInt(frame.origin.x),
                    y: safeInt(frame.origin.y),
                    w: safeInt(frame.width),
                    h: safeInt(frame.height),
                    actions: actions.map { simplifyAction($0) }
                )
                elements.append(info)
            }
        }

        // Always traverse children even when this element wasn't included so containers
        // don't hide their interactive descendants.
        let childPath: String = {
            let segmentLabel = label ?? value ?? placeholder
            let segment: String
            if let segmentLabel = segmentLabel, !segmentLabel.isEmpty {
                segment = "\(normalizedRole)[\(segmentLabel.prefix(40))]"
            } else {
                segment = normalizedRole
            }
            return path.isEmpty ? segment : "\(path) > \(segment)"
        }()

        guard let children = getAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }

        for child in children {
            if elements.count >= maxElements || Date() >= deadline {
                truncated = true
                break
            }
            traverseElement(
                element: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                maxElements: maxElements,
                deadline: deadline,
                interactiveOnly: interactiveOnly,
                allowedRoles: allowedRoles,
                textNeedle: textNeedle,
                enabledOnly: enabledOnly,
                windowId: windowId,
                path: childPath,
                focusedElement: focusedElement,
                snapshotId: snapshotId,
                pid: pid,
                nextElementNum: &nextElementNum,
                elements: &elements,
                truncated: &truncated
            )
        }
    }

    // MARK: Attribute helpers

    private func getAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func getFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        if let axPos = axValue(positionValue) {
            AXValueGetValue(axPos, .cgPoint, &position)
        }
        if let axSize = axValue(sizeValue) {
            AXValueGetValue(axSize, .cgSize, &size)
        }

        return CGRect(origin: position, size: size)
    }

    private func getSupportedActions(_ element: AXUIElement) -> [String] {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
            let actions = actionsRef as? [String]
        else {
            return []
        }

        let usefulActions: Set<String> = [
            "AXPress", "AXCancel", "AXConfirm", "AXDecrement", "AXIncrement",
            "AXPick", "AXShowMenu",
        ]

        return actions.filter { usefulActions.contains($0) }
    }

    private func simplifyAction(_ action: String) -> String {
        if action.hasPrefix("AX") {
            return String(action.dropFirst(2)).lowercased()
        }
        return action.lowercased()
    }

    private func getAppName(for pid: Int32) -> String? {
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.localizedName
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Stringify an AX value attribute that may be a string, number, or bool.
    private func stringifyValue(_ value: CFTypeRef?) -> String? {
        guard let value = value else { return nil }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let b = value as? Bool {
            return b ? "true" : "false"
        }
        if let n = value as? NSNumber {
            return n.stringValue
        }
        return nil
    }
}

// MARK: - Focus Delta

/// A small "what changed" record returned by action tools so the agent can
/// decide whether to re-observe.
struct FocusDelta: Codable, Sendable {
    let focusedWindow: String?
    let focusedElement: FocusedElementSummary?
}

struct FocusedElementSummary: Codable, Sendable {
    let role: String
    let label: String?
    let value: String?
}

/// Capture the current focused window title and focused element for a given pid.
/// Returns nil if pid is unknown or accessibility query fails.
func computeFocusDelta(pid: Int32) -> FocusDelta? {
    // Never read our own focused element off-main (see `AccessibilityManager.isSelf`).
    if AccessibilityManager.isSelf(pid) { return nil }
    let app = AccessibilityManager.axApp(pid)

    var focusedWindowTitle: String?
    var winRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef)
        == .success,
        let win = axElement(winRef)
    {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            == .success
        {
            focusedWindowTitle = titleRef as? String
        }
    }

    var focused: FocusedElementSummary?
    var elRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &elRef)
        == .success,
        let element = axElement(elRef)
    {
        var roleRef: CFTypeRef?
        var titleRef: CFTypeRef?
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let rawRole = (roleRef as? String) ?? "unknown"
        let role = AccessibilityManager.normalizeRole(rawRole)
        let label = (titleRef as? String).flatMap { $0.isEmpty ? nil : $0 }
        let value: String? = {
            if let s = valueRef as? String { return s.isEmpty ? nil : s }
            return nil
        }()
        focused = FocusedElementSummary(role: role, label: label, value: value)
    }

    if focusedWindowTitle == nil && focused == nil { return nil }
    return FocusDelta(focusedWindow: focusedWindowTitle, focusedElement: focused)
}

// MARK: - Focused Content (screen context)

/// A direct read of the focused UI element's text, captured independently of the
/// bounded snapshot traversal. Internal mirror of the contract's
/// `CUFocusedContent` that `NativeMacDriver` maps across the driver boundary.
struct FocusedContentInfo: Sendable {
    let role: String
    let label: String?
    let placeholder: String?
    let value: String?
    let selectedText: String?
    let viewport: String?
}

/// Read the focused UI element of `pid` directly: role/label/placeholder, the
/// (capped) value, the current selection, and a cursor-centered or visible
/// viewport slice for large text areas. Returns nil when nothing is focused or
/// the element exposes nothing readable, so the distiller can fall back to the
/// traversal's focused element.
///
/// `valueCap` bounds how much of a huge document (e.g. a multi-thousand-line
/// source file's `AXValue`) we copy before slicing — a defensive guard against
/// pulling a multi-MB string into memory. `viewportRadius` is how many UTF-16
/// units around the caret the cursor-centered fallback keeps.
func computeFocusedContent(
    pid: Int32,
    valueCap: Int = 200_000,
    viewportRadius: Int = 1_200
) -> FocusedContentInfo? {
    // Never read our own focused element off-main (see `AccessibilityManager.isSelf`).
    if AccessibilityManager.isSelf(pid) { return nil }
    let app = AccessibilityManager.axApp(pid)

    var elRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &elRef)
            == .success,
        let element = axElement(elRef)
    else { return nil }

    func attr(_ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success
            ? ref : nil
    }
    func trimmed(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    let rawRole = (attr(kAXRoleAttribute) as? String) ?? "unknown"
    let role = AccessibilityManager.normalizeRole(rawRole)

    // Label cascade mirrors the traversal's (title -> description -> paired UI).
    let label =
        trimmed(attr(kAXTitleAttribute) as? String)
        ?? trimmed(attr(kAXDescriptionAttribute) as? String)
        ?? trimmed(attr("AXLabelValue") as? String)
        ?? {
            if let titleUI = axElement(attr("AXTitleUIElement")) {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(titleUI, kAXValueAttribute as CFString, &ref)
                    == .success
                {
                    return trimmed(ref as? String)
                }
            }
            return nil
        }()
    let placeholder = trimmed(attr(kAXPlaceholderValueAttribute) as? String)

    // Never read the contents (value/selection/viewport) of a secure field —
    // that's a password.
    if role == "securetextfield" {
        if role == "unknown", label == nil, placeholder == nil { return nil }
        return FocusedContentInfo(
            role: role,
            label: label,
            placeholder: placeholder,
            value: nil,
            selectedText: nil,
            viewport: nil
        )
    }

    let rawValue = attr(kAXValueAttribute) as? String
    let selectedText = trimmed(attr(kAXSelectedTextAttribute) as? String)
    let viewport = focusedViewport(element: element, rawValue: rawValue, radius: viewportRadius)

    // The `value` field is trimmed and capped (the viewport already used the
    // full string for caret math above).
    var value = trimmed(rawValue)
    if let v = value, v.count > valueCap {
        value = String(v.prefix(valueCap)) + "…"
    }

    if role == "unknown", label == nil, placeholder == nil, value == nil,
        selectedText == nil, viewport == nil
    {
        return nil
    }

    return FocusedContentInfo(
        role: role,
        label: label,
        placeholder: placeholder,
        value: value,
        selectedText: selectedText,
        viewport: viewport
    )
}

/// Extract the "what I'm looking at" slice of a focused text element: the
/// visible character range when the element exposes one, else a window of
/// `radius` units centered on the caret. Returns nil when the value is small
/// enough that the whole thing already IS the viewport (the distiller shows the
/// value in that case).
private func focusedViewport(
    element: AXUIElement,
    rawValue: String?,
    radius: Int
) -> String? {
    // 1) Visible character range -> the exact on-screen text. Preferred because
    // it needs no manual offset math and reflects scroll position.
    if let visible = parameterizedString(
        element: element,
        rangeAttribute: kAXVisibleCharacterRangeAttribute as String,
        stringAttribute: kAXStringForRangeParameterizedAttribute as String
    ) {
        let t = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return visible }
    }

    // 2) Caret-centered slice of the full value. AX offsets are UTF-16, so slice
    // in the UTF-16 view and convert back, guarding surrogate boundaries.
    guard let rawValue = rawValue, !rawValue.isEmpty else { return nil }
    let utf16 = rawValue.utf16
    let total = utf16.count
    // Small enough that the whole value is the viewport; let the distiller show
    // `value` instead of a redundant slice.
    if total <= radius * 2 { return nil }

    var caret = 0
    var rangeRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        == .success,
        let axVal = axValue(rangeRef)
    {
        var cfRange = CFRange()
        if AXValueGetValue(axVal, .cfRange, &cfRange) { caret = cfRange.location }
    }

    let start = max(0, min(caret - radius, max(0, total - radius * 2)))
    let end = min(total, start + radius * 2)
    guard start < end,
        let startU = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
        let endU = utf16.index(utf16.startIndex, offsetBy: end, limitedBy: utf16.endIndex),
        let s = String.Index(startU, within: rawValue),
        let e = String.Index(endU, within: rawValue),
        s < e
    else {
        // A surrogate boundary defeated the conversion — fall back to a prefix.
        return String(rawValue.prefix(radius * 2))
    }
    var slice = String(rawValue[s ..< e])
    if start > 0 { slice = "…" + slice }
    if end < total { slice += "…" }
    return slice
}

/// Read a parameterized string-for-range value (`stringAttribute`) using the
/// element's current range value (`rangeAttribute`, e.g. the visible character
/// range). Returns nil when the element doesn't support these AX APIs. The range
/// length is bounded so a pathologically large "visible" report can't pull the
/// whole document.
private func parameterizedString(
    element: AXUIElement,
    rangeAttribute: String,
    stringAttribute: String,
    maxLength: Int = 4_000
) -> String? {
    var rangeRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(element, rangeAttribute as CFString, &rangeRef) == .success,
        let rangeVal = axValue(rangeRef)
    else { return nil }
    var cfRange = CFRange()
    guard AXValueGetValue(rangeVal, .cfRange, &cfRange), cfRange.length > 0 else { return nil }
    if cfRange.length > maxLength { cfRange.length = maxLength }
    guard let boundedValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
    var strRef: CFTypeRef?
    guard
        AXUIElementCopyParameterizedAttributeValue(
            element,
            stringAttribute as CFString,
            boundedValue,
            &strRef
        ) == .success,
        let s = strRef as? String
    else { return nil }
    return s
}

// MARK: - App Opener

struct MacAppInfo: Encodable, Sendable {
    let pid: Int32
    let bundleId: String?
    let name: String
}

struct MacAppError: Error, Sendable {
    let message: String
}

/// Launch (if needed) and prepare an application for backgrounded driving.
///
/// The default mode is `background: true` — we never call `activate()`,
/// never set `config.activates = true`, and never bring the app's window
/// across Spaces. The user's frontmost app and cursor are untouched.
///
/// Pass `background: false` only when the agent genuinely needs the user
/// to look at the target window (e.g. an interactive demo capture).
func openApplication(
    identifier: String,
    background: Bool = true
) async -> Result<MacAppInfo, MacAppError> {
    let workspace = NSWorkspace.shared
    let runningApps = workspace.runningApplications
    let lowerId = identifier.lowercased()

    if let app = runningApps.first(where: {
        $0.localizedName?.lowercased() == lowerId || $0.bundleIdentifier?.lowercased() == lowerId
    }) {
        if !background {
            app.activate()
        }
        // Flip Chromium/Electron into exposing its full tree BEFORE we wait, so
        // the readiness poll can block until that tree actually populates.
        AccessibilityManager.shared.prepareForAccessibility(pid: app.processIdentifier)
        await waitUntilReady(app: app, requireFrontmost: !background)
        return .success(
            MacAppInfo(
                pid: app.processIdentifier,
                bundleId: app.bundleIdentifier,
                name: app.localizedName ?? identifier
            )
        )
    }

    do {
        let app = try await launchApplication(
            identifier: identifier,
            workspace: workspace,
            background: background
        )
        AccessibilityManager.shared.prepareForAccessibility(pid: app.processIdentifier)
        await waitUntilReady(app: app, isNewLaunch: true, requireFrontmost: !background)
        return .success(
            MacAppInfo(
                pid: app.processIdentifier,
                bundleId: app.bundleIdentifier,
                name: app.localizedName ?? identifier
            )
        )
    } catch {
        return .failure(
            MacAppError(message: "Failed to open application: \(error.localizedDescription)")
        )
    }
}

private func waitUntilReady(
    app: NSRunningApplication,
    isNewLaunch: Bool = false,
    requireFrontmost: Bool = false,
    timeoutSeconds: Double = 5.0
) async {
    let pollInterval: UInt64 = 100_000_000
    let maxAttempts = Int(timeoutSeconds * 10)

    let initialDelay: UInt64 = isNewLaunch ? 500_000_000 : 200_000_000
    try? await Task.sleep(nanoseconds: initialDelay)

    for _ in 0 ..< maxAttempts {
        // In background mode we only need the AX tree to be queryable; the app
        // can stay hidden, occluded, or behind another Space.
        let frontmostOK = !requireFrontmost || app.isActive

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            axApp,
            kAXWindowsAttribute as CFString,
            &windowValue
        )
        let windows = (windowValue as? [AXUIElement]) ?? []
        let hasWindow = windowResult == .success && !windows.isEmpty
        // Chromium/Electron builds its subtree asynchronously once
        // `AXManualAccessibility` is set, so a window can exist while its
        // children are still empty. Wait until at least one window actually has
        // children, otherwise the first capture is just the menu bar. Cocoa apps
        // populate immediately, so this only adds latency for Electron's build.
        let treePopulated = windows.contains { axElementHasChildren($0) }

        if frontmostOK && hasWindow && treePopulated {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return
        }

        try? await Task.sleep(nanoseconds: pollInterval)
    }
}

/// Copy a single AX attribute, returning nil when the element doesn't expose it.
private func axCopyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value
}

/// The element's AX children (empty when it exposes none).
private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axCopyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

/// Whether an AX element reports at least one child. Used to detect that an
/// Electron window's tree has finished building after `AXManualAccessibility`.
private func axElementHasChildren(_ element: AXUIElement) -> Bool {
    !axChildren(element).isEmpty
}

private func launchApplication(
    identifier: String,
    workspace: NSWorkspace,
    background: Bool
) async throws -> NSRunningApplication {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = !background
    // Background launches should not pollute the user's recent files menu
    // or pull the dock's attention. Cooperative; macOS may still ignore
    // these on certain bundle types.
    config.addsToRecentItems = !background
    config.hides = background

    if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
        return try await workspace.openApplication(at: url, configuration: config)
    }

    let searchPaths = [
        "/Applications/\(identifier).app",
        "/System/Applications/\(identifier).app",
        "/System/Applications/Utilities/\(identifier).app",
        NSHomeDirectory() + "/Applications/\(identifier).app",
    ]

    for path in searchPaths where FileManager.default.fileExists(atPath: path) {
        return try await workspace.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: config
        )
    }

    throw MacAppError(message: "Application not found: \(identifier)")
}

// MARK: - Window/App Listing
//
// These exist so a planning agent can target a specific app and window
// without ever bringing it forward. `listRunningApps()` is a snapshot of
// what's running; `listWindowsForPid(_:)` is per-app and includes the
// on-screen `windowId` so callers can pass it straight to a screenshot or
// click.

struct AppListing: Encodable, Sendable {
    let pid: Int32
    let bundleId: String?
    let name: String
    let active: Bool
    let hidden: Bool
}

struct WindowListing: Encodable, Sendable {
    let windowId: Int
    let title: String?
    let focused: Bool
    let minimized: Bool
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

struct AppListResult: Encodable, Sendable {
    let apps: [AppListing]
}

struct WindowListResult: Encodable, Sendable {
    let pid: Int32
    let app: String
    let windows: [WindowListing]
}

func listRunningApps() -> AppListResult {
    let running = NSWorkspace.shared.runningApplications
    let apps: [AppListing] = running.compactMap { app in
        // Only surface "regular" GUI apps. Background-only and UI-element
        // processes can't be driven through AX anyway.
        guard app.activationPolicy == .regular else { return nil }
        return AppListing(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            active: app.isActive,
            hidden: app.isHidden
        )
    }
    return AppListResult(apps: apps.sorted { ($0.name) < ($1.name) })
}

func listWindowsForPid(_ pid: Int32) -> WindowListResult {
    let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown"
    // Never enumerate our own windows off-main (see `AccessibilityManager.isSelf`).
    if AccessibilityManager.isSelf(pid) {
        return WindowListResult(pid: pid, app: appName, windows: [])
    }
    let app = AccessibilityManager.axApp(pid)

    // Focused window for the `focused: true` flag.
    var focusedRef: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef)
    let focusedWindow: AXUIElement? = axElement(focusedRef)

    var windowsRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
        let axWindows = windowsRef as? [AXUIElement]
    else {
        return WindowListResult(pid: pid, app: appName, windows: [])
    }

    // Map AX windows to CGWindowList entries by title+pid+bounds intersection
    // so we can return the real CGWindowID, which is what every other path
    // (screenshot, focus-without-raise) actually expects.
    let cgInfo: [[CFString: Any]] =
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]]) ?? []
    let cgForPid = cgInfo.filter { ($0[kCGWindowOwnerPID] as? Int32) == pid }

    var listings: [WindowListing] = []
    for (idx, win) in axWindows.enumerated() {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let axP = axValue(posRef) { AXValueGetValue(axP, .cgPoint, &pos) }
        if let axS = axValue(sizeRef) { AXValueGetValue(axS, .cgSize, &size) }

        var minimizedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedRef)
        let minimized = (minimizedRef as? Bool) ?? false

        let focused = focusedWindow.map { CFEqual($0, win) } ?? false

        // Try to align with a CGWindowID from the running window list. Fall back
        // to the AX index + 1 (matches the existing `windowId` semantics in
        // `WindowSummary` and `find_elements`'s windowId arg) when we can't
        // find an unambiguous match.
        let cgID: Int = {
            if let match = cgForPid.first(where: { entry in
                guard let bounds = entry[kCGWindowBounds] as? [String: Any],
                    let bx = bounds["X"] as? Double,
                    let by = bounds["Y"] as? Double,
                    let bw = bounds["Width"] as? Double,
                    let bh = bounds["Height"] as? Double
                else { return false }
                // Allow a few pixels of slop — AX position can disagree with
                // CGWindow bounds by the window-server stroke width.
                return abs(bx - pos.x) < 4 && abs(by - pos.y) < 4
                    && abs(bw - size.width) < 4 && abs(bh - size.height) < 4
            }), let n = match[kCGWindowNumber] as? Int {
                return n
            }
            return idx + 1
        }()

        listings.append(
            WindowListing(
                windowId: cgID,
                title: title,
                focused: focused,
                minimized: minimized,
                x: safeInt(pos.x),
                y: safeInt(pos.y),
                w: safeInt(size.width),
                h: safeInt(size.height)
            )
        )
    }

    return WindowListResult(pid: pid, app: appName, windows: listings)
}

// MARK: - Active Window Info

struct MacActiveWindowInfo: Encodable, Sendable {
    let pid: Int32
    let app: String
    let title: String?
    let x: Int
    let y: Int
    let w: Int
    let h: Int
}

func getActiveWindow() -> MacActiveWindowInfo? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        return nil
    }

    let pid = frontApp.processIdentifier
    let appName = frontApp.localizedName ?? "Unknown"

    // When Osaurus itself is frontmost there's no external active window to
    // report, and resolving our own AX tree off-main traps in SwiftUI (see
    // `AccessibilityManager.isSelf`). Returning nil also keeps callers that seed
    // a target pid from the frontmost app (e.g. the Computer Use loop) from
    // ever pointing at ourselves.
    if AccessibilityManager.isSelf(pid) { return nil }

    let app = AccessibilityManager.axApp(pid)

    var windowRef: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef)
            == .success,
        let windowElement = axElement(windowRef)
    else {
        return MacActiveWindowInfo(pid: pid, app: appName, title: nil, x: 0, y: 0, w: 0, h: 0)
    }

    var titleRef: CFTypeRef?
    let title: String?
    if AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
        == .success
    {
        title = titleRef as? String
    } else {
        title = nil
    }

    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    var position = CGPoint.zero
    var size = CGSize.zero

    if AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef)
        == .success,
        let axPos = axValue(positionRef)
    {
        AXValueGetValue(axPos, .cgPoint, &position)
    }

    if AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef)
        == .success,
        let axSize = axValue(sizeRef)
    {
        AXValueGetValue(axSize, .cgSize, &size)
    }

    return MacActiveWindowInfo(
        pid: pid,
        app: appName,
        title: title,
        x: safeInt(position.x),
        y: safeInt(position.y),
        w: safeInt(size.width),
        h: safeInt(size.height)
    )
}

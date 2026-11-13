//
//  NativeToolCallGroupView.swift
//  osaurus
//
//  Pure AppKit replacement for GroupedToolCallsContainerView + InlineToolCallView.
//  Zero NSHostingView overhead; uses CALayer for backgrounds/borders, NSStackView
//  for rows, and NativeMarkdownView for expanded content.
//
//  Expand state is passed externally (coordinator-owned), so toggling one row
//  only invalidates the single row's height — not the entire cell.
//

import AppKit
import Combine
import SwiftUI

// MARK: - JSON Formatting Utility

enum JSONFormatter {
    /// Single `JSONSerialization` parse; returns pretty text, or `nil` if `raw` is not JSON.
    static func prettyPrintedJSONIfValid(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if let dict = obj as? [String: Any], dict.isEmpty {
            return "{}"
        }

        guard
            let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let s = String(data: pretty, encoding: .utf8)
        else { return nil }
        return s
    }

    /// Pretty-print when valid JSON; otherwise returns `raw` unchanged.
    static func prettyJSON(_ raw: String) -> String {
        prettyPrintedJSONIfValid(raw) ?? raw
    }
}

// MARK: - Expand reveal

/// Staggered-ripple reveal for freshly expanded disclosure content (tool
/// rows, thinking blocks, activity groups): the container's sections fade
/// and drift in top-to-bottom, ~120ms apart. Combined with the activity
/// group's batched expand-all, consecutive steps read as a two-level
/// cascading ripple. No-op under Reduce Motion.
enum ExpandFade {
    /// - Parameters:
    ///   - interval: delay between consecutive sections. The activity group
    ///     passes a tighter value — its parts are whole steps, so the default
    ///     cadence reads sluggish on runs with many of them.
    ///   - duration: per-section fade/drift length.
    static func run(
        _ view: NSView, interval: TimeInterval = 0.12, duration: TimeInterval = 0.3
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = 1
            return
        }
        // Freshly built content hasn't been laid out yet — resolve frames
        // first or the top-to-bottom sort below runs on zero rects.
        view.layoutSubtreeIfNeeded()
        // Non-flipped: higher y = higher on screen, so sort descending to
        // get visual top-to-bottom order.
        let parts = view.subviews.sorted { $0.frame.maxY > $1.frame.maxY }
        for (index, part) in parts.enumerated() {
            // `alphaValue` is a no-op on non-layer-backed views — these are
            // plain NSViews, so back them explicitly or the fade silently
            // doesn't render.
            part.wantsLayer = true
            part.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(index)) {
                [weak part] in
                guard let part else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    part.animator().alphaValue = 1
                }
                drift(part, from: -12, duration: duration)
            }
        }
    }

    /// Presentational upward drift from `offset` points below rest (AppKit
    /// non-flipped: positive y is up). Layout and hit-testing see the view
    /// at rest throughout.
    private static func drift(_ view: NSView, from offset: CGFloat, duration: TimeInterval) {
        guard let layer = view.layer else { return }
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = offset
        drift.toValue = 0
        drift.duration = duration
        drift.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(drift, forKey: "expandFade.drift")
    }
}

// MARK: - Tool Category

/// Tool categories for icon selection
enum ToolCategory {
    case file
    case search
    case terminal
    case network
    case database
    case code
    case general

    var icon: String {
        switch self {
        case .file: return "folder.fill"
        case .search: return "magnifyingglass"
        case .terminal: return "terminal.fill"
        case .network: return "globe"
        case .database: return "cylinder.split.1x2.fill"
        case .code: return "curlybraces"
        case .general: return "gearshape.fill"
        }
    }


    static func from(toolName: String) -> ToolCategory {
        let name = toolName.lowercased()

        // File operations
        if name.contains("file") || name.contains("read") || name.contains("write")
            || name.contains("path") || name.contains("directory") || name.contains("folder")
        {
            return .file
        }

        // Search operations
        if name.contains("search") || name.contains("find") || name.contains("query")
            || name.contains("grep") || name.contains("lookup")
        {
            return .search
        }

        // Terminal/command operations
        if name.contains("terminal") || name.contains("command") || name.contains("exec")
            || name.contains("shell") || name.contains("run") || name.contains("bash")
        {
            return .terminal
        }

        // Network operations (includes mail/thread APIs)
        if name.contains("http") || name.contains("api") || name.contains("fetch")
            || name.contains("request") || name.contains("url") || name.contains("web")
            || name.contains("thread") || name.contains("mailbox") || name.contains("mail")
            || name.contains("messages")
        {
            return .network
        }

        // Database operations
        if name.contains("database") || name.contains("sql") || name.contains("db")
            || name.contains("query") || name.contains("table")
        {
            return .database
        }

        // Code operations
        if name.contains("code") || name.contains("edit") || name.contains("replace")
            || name.contains("refactor") || name.contains("lint")
        {
            return .code
        }

        return .general
    }
}

// MARK: - Preview Generator

/// Generates human-readable previews for JSON and text content
enum PreviewGenerator {
    /// The expanded ARGUMENTS body, cut at a line once it passes `limit`.
    /// A `workflow_draft` patch can carry whole prompts, and the markdown
    /// view lays the block out again on every streamed reconfigure.
    static func cappedArguments(_ text: String, limit: Int = 12_000) -> String {
        guard text.count > limit else { return text }
        var head = text.prefix(limit)
        if let lastBreak = head.lastIndex(of: "\n") { head = head[..<lastBreak] }
        return head + "\n… (\(text.count - head.count) more characters)"
    }

    /// Generate a preview for JSON arguments (object)
    static func jsonPreview(_ jsonString: String, maxLength: Int = 60) -> String? {
        guard let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            !json.isEmpty
        else { return nil }

        var parts: [String] = []
        var totalLength = 0

        // Priority keys for preview
        let priorityKeys = ["path", "file", "file_path", "query", "url", "name", "command", "pattern", "content"]

        // Build preview string
        for key in priorityKeys {
            if let value = json[key] {
                let valueStr = formatValue(value)
                let part = "\(key): \(valueStr)"
                if totalLength + part.count > maxLength && !parts.isEmpty {
                    break
                }
                parts.append(part)
                totalLength += part.count + 2
            }
        }

        // If no priority keys found, use first few keys (sorted for stable ordering)
        if parts.isEmpty {
            for key in json.keys.sorted().prefix(3) {
                guard let value = json[key] else { continue }
                let valueStr = formatValue(value)
                let part = "\(key): \(valueStr)"
                if totalLength + part.count > maxLength && !parts.isEmpty {
                    break
                }
                parts.append(part)
                totalLength += part.count + 2
            }
        }

        // Add count if more parameters exist
        let remaining = json.count - parts.count
        if remaining > 0 {
            parts.append("+\(remaining) more")
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Generate a preview for result content (handles JSON arrays, objects, and plain text)
    static func resultPreview(_ text: String, maxLength: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to parse as JSON first
        if let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
        {

            // Handle JSON array
            if let array = json as? [Any] {
                if array.isEmpty {
                    return "Empty array []"
                }
                // Describe array contents
                let itemDescriptions = array.prefix(3).map { formatValue($0) }
                let preview = itemDescriptions.joined(separator: ", ")
                let suffix = array.count > 3 ? " +\(array.count - 3) more" : ""
                let countLabel = array.count == 1 ? "1 item" : "\(array.count) items"
                let result = "[\(countLabel)] \(preview)\(suffix)"
                if result.count > maxLength {
                    return String(result.prefix(maxLength - 3)) + "..."
                }
                return result
            }

            // Handle JSON object
            if let dict = json as? [String: Any] {
                if dict.isEmpty {
                    return "Empty object {}"
                }
                // Use jsonPreview for objects
                if let preview = jsonPreview(trimmed, maxLength: maxLength) {
                    return preview
                }
                return dict.count == 1 ? "{1 key}" : "{\(dict.count) keys}"
            }
        }

        // Plain text - get first meaningful line
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let firstLine = lines.first else {
            return trimmed.isEmpty ? "Empty response" : trimmed
        }

        if firstLine.count <= maxLength {
            if lines.count > 1 {
                let remaining = lines.count - 1
                return remaining == 1
                    ? "\(firstLine) (+1 line)"
                    : "\(firstLine) (+\(remaining) lines)"
            }
            return firstLine
        }

        return String(firstLine.prefix(maxLength - 3)) + "..."
    }

    /// Format size for display
    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }

    /// Count lines in text
    static func lineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }

    private static func formatValue(_ value: Any) -> String {
        switch value {
        case let str as String:
            let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if clean.count > 30 {
                return String(clean.prefix(27)) + "..."
            }
            return clean
        case let num as NSNumber:
            return num.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case let arr as [Any]:
            return arr.count == 1 ? "[1 item]" : "[\(arr.count) items]"
        case let dict as [String: Any]:
            // Try to get a meaningful preview from the dict
            if let name = dict["title"] as? String ?? dict["name"] as? String {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count > 25 {
                    return String(clean.prefix(22)) + "..."
                }
                return clean
            }
            return dict.count == 1 ? "{1 key}" : "{\(dict.count) keys}"
        default:
            return String(describing: value)
        }
    }
}


// MARK: - RailLineView

/// A vertical timeline rail backed by a `CAShapeLayer`, so the "draw" animation
/// is a GPU-driven `strokeEnd` sweep (0→1) rather than a frame/transform change.
/// That keeps it perfectly smooth — it never triggers Auto Layout or per-frame
/// CPU work — and it composes cleanly with the instant (`duration = 0`) row-height
/// updates the table makes when a new tool call appends mid-stream.
///
/// The path is drawn top→bottom, so `strokeEnd` sweeps downward — from the upper
/// (earlier) node toward the lower (newer) one.
final class RailLineView: NSView {
    static let drawDuration: CFTimeInterval = 0.18
    private static let animationKey = "rail.draw"

    private var drawPending = false
    /// Absolute begin time (CACurrentMediaTime()-based) captured when `drawIn`
    /// is called. Stored absolute, not relative, so a deferred layout pass
    /// can't drift the begin time later than the rail/ring/icon animations
    /// scheduled in the same configure() call.
    private var pendingBeginAt: CFTimeInterval = 0

    /// Backing layer (returned from `makeBackingLayer`) — kept typed so we never
    /// need to force-cast `layer`.
    private let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shape.lineWidth = 2
        shape.lineCap = .round
        shape.fillColor = NSColor.clear.cgColor
        shape.strokeEnd = 1
        wantsLayer = true
        // Disable CALayer's default implicit animations on the properties
        // we touch / lay out. Without this, post-finish cell recreation
        // (when the tool call's row goes through teardown + redequeue)
        // triggers 0.25s implicit bounds/position/strokeEnd transitions
        // that look identical to a re-play of the rail draw animation.
        shape.actions = Self.suppressedActions
    }

    private static let suppressedActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "strokeEnd": NSNull(),
        "strokeColor": NSNull(),
        "fillColor": NSNull(),
        "path": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
        "contents": NSNull(),
        "transform": NSNull(),
    ]

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { shape }

    var color: CGColor? {
        get { shape.strokeColor }
        set { shape.strokeColor = newValue }
    }

    override func layout() {
        super.layout()
        updatePath()
        if drawPending { startDrawIfReady() }
    }

    private func updatePath() {
        let x = bounds.midX
        let p = CGMutablePath()
        // Non-flipped view → `maxY` is the top edge. Path runs top→bottom so the
        // `strokeEnd` sweep reads as the rail growing down toward the new node.
        p.move(to: CGPoint(x: x, y: bounds.maxY))
        p.addLine(to: CGPoint(x: x, y: bounds.minY))
        shape.path = p
    }

    /// Animate the rail drawing in at `beginAt` (absolute `CACurrentMediaTime()`
    /// timeline). Safe to call from `configure`: holds at `strokeEnd = 0` until
    /// the begin time, then sweeps to full. Ignores repeat calls while a draw
    /// is already pending/in-flight, so per-token reconfigures can't restart
    /// or cut it short.
    func drawIn(beginAt: CFTimeInterval) {
        if drawPending || shape.animation(forKey: Self.animationKey) != nil { return }
        drawPending = true
        pendingBeginAt = beginAt
        // Hide synchronously WITHOUT triggering CALayer's default 0.25s
        // implicit animation on `strokeEnd`. Before this fix the rail
        // briefly fade-collapsed from 1→0 instead of being invisible,
        // racing the subsequent explicit draw-in animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeEnd = 0
        CATransaction.commit()
        if bounds.height > 0 {
            startDrawIfReady()
        } else {
            needsLayout = true  // bounds not laid out yet — start once `layout()` runs
        }
    }

    /// Show the full rail with no animation (initial load, view reuse, or a rail
    /// that has already drawn). No-op while a draw is pending/in-flight so an
    /// incidental reconfigure never snaps an in-progress sweep to completion.
    func showFull() {
        if drawPending || shape.animation(forKey: Self.animationKey) != nil { return }
        shape.strokeEnd = 1
    }

    private func startDrawIfReady() {
        guard drawPending, bounds.height > 0 else { return }
        drawPending = false
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = Self.drawDuration
        anim.beginTime = pendingBeginAt
        // `.both` + `removedOnCompletion = false` makes the presentation
        // strictly track the animation: hidden (fromValue) before begin,
        // animating during, and pinned to toValue afterwards. We don't
        // rely on the model value matching the presentation.
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Set model to final state with implicit actions disabled so the
        // 1→ assignment doesn't trigger CALayer's default fade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeEnd = 1
        CATransaction.commit()
        shape.add(anim, forKey: Self.animationKey)
    }
}

// MARK: - TimelineNodeView

/// The circular timeline node, backed by a `CAShapeLayer` so its ring can be
/// stroked on progressively (clockwise) the way the rail draws — a plain
/// `CALayer` border can only appear all-at-once. The shape's `fillColor` is the
/// translucent status tint (the disc) and its `strokeColor` is the ring; the
/// category glyph rides on top as a subview. The reveal animates `strokeEnd`
/// (ring drawing clockwise) and fades the fill in alongside it.
final class TimelineNodeView: NSView {
    private static let animationKey = "ring.draw"
    /// Duration of the clockwise ring trace on reveal.
    static let ringDrawDuration: CFTimeInterval = 0.34

    private var drawPending = false
    /// Absolute begin time captured at `drawRing` call site so a deferred
    /// layout pass can't desync the ring's begin from the icon/title
    /// animations scheduled in the same configure() call.
    private var pendingBeginAt: CFTimeInterval = 0
    /// Target disc fill captured synchronously in `drawRing` before the
    /// model value is cleared. We must clear immediately so the disc
    /// doesn't render at the target color in the window between
    /// `drawRing` and `startDrawIfReady` (which can be deferred via
    /// layout) — otherwise the disc pops in before the ring traces.
    private var pendingFillTarget: CGColor?

    /// Backing layer (returned from `makeBackingLayer`) — kept typed so we never
    /// need to force-cast `layer`.
    private let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shape.lineWidth = 1.5
        shape.strokeEnd = 1
        wantsLayer = true
        // See RailLineView.suppressedActions — same rationale.
        shape.actions = Self.suppressedActions
    }

    private static let suppressedActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "strokeEnd": NSNull(),
        "strokeColor": NSNull(),
        "fillColor": NSNull(),
        "path": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
        "contents": NSNull(),
        "transform": NSNull(),
    ]

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { shape }

    var fillColor: CGColor? {
        get { shape.fillColor }
        set { shape.fillColor = newValue }
    }
    var strokeColor: CGColor? {
        get { shape.strokeColor }
        set { shape.strokeColor = newValue }
    }
    var inspectionStrokeWidth: CGFloat {
        get { shape.lineWidth }
        set { shape.lineWidth = newValue; updatePath() }
    }

    override func layout() {
        super.layout()
        updatePath()
        if drawPending { startDrawIfReady() }
    }

    private func updatePath() {
        guard bounds.width > 1 else { return }
        let inset = shape.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // Start at 12 o'clock and sweep clockwise so `strokeEnd` traces the ring
        // clockwise. (Flip `clockwise:` if it ends up reading counter-clockwise.)
        let p = CGMutablePath()
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .pi / 2,
            endAngle: .pi / 2 - 2 * .pi,
            clockwise: true
        )
        shape.path = p
    }

    /// Trace the ring in clockwise (+ fade the fill in) starting at `beginAt`
    /// (absolute `CACurrentMediaTime()` timeline).
    func drawRing(beginAt: CFTimeInterval) {
        if drawPending || shape.animation(forKey: Self.animationKey) != nil { return }
        drawPending = true
        pendingBeginAt = beginAt
        pendingFillTarget = shape.fillColor
        // Hide the disc + ring synchronously (no implicit fades). Before
        // this fix, the disc rendered at its target color during the
        // window between `drawRing` and the deferred `startDrawIfReady`
        // — which manifested as the colored disc popping in before the
        // ring traced over it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeEnd = 0
        shape.fillColor = NSColor.clear.cgColor
        CATransaction.commit()
        if bounds.width > 1 {
            startDrawIfReady()
        } else {
            needsLayout = true
        }
    }

    /// Show the full ring with no animation (load / reuse / already drawn).
    func showRingFull() {
        if drawPending || shape.animation(forKey: Self.animationKey) != nil { return }
        shape.strokeEnd = 1
    }

    private func startDrawIfReady() {
        guard drawPending, bounds.width > 1 else { return }
        drawPending = false
        let begin = pendingBeginAt
        let fillTarget = pendingFillTarget ?? shape.fillColor
        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0
        stroke.toValue = 1
        stroke.fillMode = .both
        stroke.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let fill = CABasicAnimation(keyPath: "fillColor")
        fill.fromValue = NSColor.clear.cgColor
        fill.toValue = fillTarget
        fill.fillMode = .both
        let group = CAAnimationGroup()
        group.animations = [stroke, fill]
        group.duration = Self.ringDrawDuration
        group.beginTime = begin
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        // Restore model to final state (without triggering implicit fades)
        // so subsequent property reads / future animations see the right
        // baseline. The explicit animation drives the presentation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeEnd = 1
        shape.fillColor = fillTarget
        CATransaction.commit()
        shape.add(group, forKey: Self.animationKey)
    }
}

// MARK: - NativeToolCallGroupView

final class NativeToolCallGroupView: NSView {

    // MARK: Subviews

    private let rowStack = NSStackView()
    private var rowViews: [NativeToolCallRowView] = []

    /// pins group height — intrinsic alone is not always honored when only top is pinned to the cell.
    private var groupHeightConstraint: NSLayoutConstraint?

    // MARK: State

    /// Call ids from the previous `configure`, used to detect a genuine
    /// streaming append (ids grew by one, same prefix) so the connecting rail
    /// animates only then — never on initial load, view reuse, or per-token
    /// updates to an existing call.
    private var lastCallIds: [String] = []

    /// Call ids whose node has already bloomed in, so each animates exactly once
    /// and per-token reconfigures don't restart it.
    private var bloomedCallIds: Set<String> = []

    /// First call id of the group last shown — the group's identity. When the
    /// cell is reused for a different group it changes, and we forget the append
    /// / bloom history so nothing leaks across groups.
    private var lastFirstCallId: String?

    private struct GroupInputs: Equatable {
        let calls: [ToolCallItem]
        let expanded: [Bool]
        let width: CGFloat
        let themeFingerprint: Int
    }
    private var lastGroupInputs: GroupInputs?

    /// Sequential delay between the two halves of a new connector (the upper
    /// node's lower rail draws first, then the new node's upper rail), matching
    /// `RailLineView.drawDuration` so the two halves read as one continuous line.
    private static let railPhaseDelay: CFTimeInterval = 0.18

    // MARK: Callbacks

    var onToggle: ((String) -> Void)?
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Configure

    func configure(
        calls: [ToolCallItem],
        expandedIds: Set<String>,
        width: CGFloat,
        theme: any ThemeProtocol,
        isStreaming: Bool,
        onToggle: @escaping (String) -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        let theme = theme.catalogFamily(34)
        rowStack.spacing = max(0, ActivityInspectionStyle.layout("resultCardsGap", "gap", theme.space.s8, theme))
        rowStack.catalogAssignmentTarget([ActivityInspectionStyle.key + "elements.layout.resultCardsGap"], name: "Individual tool result cards", theme: theme)
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged

        let inputs = GroupInputs(
            calls: calls,
            expanded: calls.map { expandedIds.contains($0.call.id) },
            width: width,
            themeFingerprint: theme.renderFingerprint
        )
        if inputs == lastGroupInputs, groupHeightConstraint != nil { return }
        lastGroupInputs = inputs

        // A single call renders as a lone card; 2+ consecutive calls connect
        // via the per-row rail.

        while rowViews.count < calls.count {
            let row = NativeToolCallRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            rowViews.append(row)
        }
        while rowViews.count > calls.count {
            let removed = rowViews.removeLast()
            rowStack.removeArrangedSubview(removed)
            removed.removeFromSuperview()
        }

        let newIds = calls.map { $0.call.id }

        // Group identity = its first call id. When the cell is reused for a
        // different group it changes; forget the append/bloom history so stale
        // tracking can't leak across groups (and falsely animate).
        if newIds.first != lastFirstCallId {
            lastCallIds = []
            bloomedCallIds = []
            lastFirstCallId = newIds.first
        }

        // Detect a genuine streaming append: the previous calls are still present
        // as a prefix and exactly one new call arrived at the end. Only then do we
        // animate the new connector (so loading a saved chat, reuse, or per-token
        // arg updates never trigger it). `connectIndex` is the new call's row.
        let appended =
            !lastCallIds.isEmpty
            && newIds.count == lastCallIds.count + 1
            && Array(newIds.prefix(lastCallIds.count)) == lastCallIds
        let connectIndex = appended ? lastCallIds.count : -1

        let innerWidth = max(0, width)
        for (index, item) in calls.enumerated() {
            let row = rowViews[index]
            let isExpanded = expandedIds.contains(item.call.id)
            // The connector spans the previous-last node's lower rail (draws first)
            // and the new node's upper rail (draws right after) for one downward sweep.
            let drawBelow: CFTimeInterval? = (index == connectIndex - 1) ? 0 : nil
            let drawAbove: CFTimeInterval? = (index == connectIndex) ? Self.railPhaseDelay : nil
            // Reveal each node once, the first time it appears running while
            // streaming — an appended node waits until its connecting rail has
            // arrived (rail begin + draw), a first/lone node reveals immediately.
            // Gating on `isStreaming` + an unresolved result keeps loaded chats
            // and reuse static.
            var appear: CFTimeInterval? = nil
            if isStreaming, item.result == nil, item.unobservedResult == nil, !bloomedCallIds.contains(item.call.id) {
                bloomedCallIds.insert(item.call.id)
                appear =
                    (index == connectIndex)
                    ? Self.railPhaseDelay + RailLineView.drawDuration
                    : 0
            }
            row.configure(
                item: item,
                index: index,
                totalCount: calls.count,
                isExpanded: isExpanded,
                width: innerWidth,
                theme: theme,
                drawRailAboveAfter: drawAbove,
                drawRailBelowAfter: drawBelow,
                animateAppearanceAfter: appear
            ) { [weak self] in
                self?.onToggle?(item.call.id)
            } onHeightChanged: { [weak self] in
                self?.syncGroupHeight()
                self?.onHeightChanged?()
            }
        }
        lastCallIds = newIds
        syncGroupHeight()
    }

    /// The group's height is required, so it must follow every row change,
    /// not only a reconfigure, or a row resizing on its own is squeezed.
    private func syncGroupHeight() {
        let totalH = max(measuredHeight(), 1)
        if let c = groupHeightConstraint {
            guard c.constant != totalH else { return }
            c.constant = totalH
        } else {
            let c = heightAnchor.constraint(equalToConstant: totalH)
            c.priority = .required
            c.isActive = true
            groupHeightConstraint = c
        }
        invalidateIntrinsicContentSize()
    }

    // MARK: Measured height (used by cell coordinator)

    /// Height on screen, following any row's disclosure in motion.
    func measuredHeight() -> CGFloat {
        rowViews.reduce(0) { $0 + $1.displayedHeight() }
            + rowStack.spacing * CGFloat(max(0, rowViews.count - 1))
    }

    // provide intrinsic content size for auto layout
    override var intrinsicContentSize: NSSize {
        let height = measuredHeight()
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: - Private

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.spacing = 0
        rowStack.distribution = .fill
        // default .center horizontally centers subviews in a vertical stack; keep rows flush left
        rowStack.alignment = .leading
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

// MARK: - NativeToolCallRowView

final class NativeToolCallRowView: NSView {

    // MARK: Subviews

    private let headerButton = NSButton()
    /// Category glyph in the node foreground (db cylinder, terminal, file, …).
    /// The node's ring color carries the status; this carries the tool identity.
    private let categoryIcon = NSImageView()
    /// Shown in place of `nameLabel` while the call is running (no result yet,
    /// or a `speak` call still playing) — the title shimmers to signal progress.
    private let shimmerLabel = ShimmerLabel()
    /// Circular timeline node — status-tinted fill + ring, holds the category glyph.
    private let categoryBg = TimelineNodeView()
    /// Vertical rail segments connecting consecutive nodes. `railAbove` runs
    /// from the row top to the node top edge, `railBelow` from the node bottom
    /// edge to the row bottom (so it spans expanded content). Both hidden for a
    /// lone call. They draw in (top→bottom sweep) when a call appends mid-stream.
    private let railAbove = RailLineView()
    private let railBelow = RailLineView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let argPreviewLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    /// "Search settings" deep link shown on the collapsed header when a
    /// `web_search` / `search_and_extract` call failed (including the
    /// NO_RESULTS envelope) — first-time users otherwise never see the
    /// remediation hint, which is only in the model-facing result JSON.
    private let searchSettingsButton = NSButton()
    /// "N files changed" link on a collapsed completed row whose call
    /// changed files (shell commands, moves, deletes…); opens the File
    /// Changes inspector on that change set. Write/edit calls get the diff
    /// card instead.
    private let fileChangesButton = NSButton()
    /// Workflow calls: opens the run's workflow tab. Shares the link slot.
    private let openRunButton = NSButton()
    private let remedyButton = NSButton()
    private var workflowRemedy: WorkflowFailureRemedy?
    private var remedyLeadingToOpenRun: NSLayoutConstraint?
    private var remedyLeadingToName: NSLayoutConstraint?
    private var openRunID: UUID?
    private var openRunRetries = 0
    private var headerLinkPins: [NSButton: [NSLayoutConstraint]] = [:]

    private struct ConfigureInputs: Equatable {
        let item: ToolCallItem
        let index: Int
        let totalCount: Int
        let isExpanded: Bool
        let width: CGFloat
        let themeFingerprint: Int
    }
    private var lastConfigureInputs: ConfigureInputs?
    private var openRunLeadingToName: NSLayoutConstraint?
    private var openRunLeadingToShimmer: NSLayoutConstraint?
    private var fileChangeSet: FileChangeSet?
    private var fileChangeLookupCallId: String?
    nonisolated(unsafe) private var fileChangeObservation: NSObjectProtocol?

    // Expanded content
    private let contentContainer = NSView()
    private let argumentsSectionTitle = NSTextField(labelWithString: L("ARGUMENTS"))
    private var resultSectionTitle: NSTextField?
    private var argsView: NativeMarkdownView?
    private var resultView: NativeMarkdownView?
    /// Cursor-style terminal pane. Mounts in two distinct cases:
    ///   1. .live(entry) — LiveExecRegistry has a running entry for
    ///      this row's tool-call-id. Streams chunks into the view,
    ///      shows [Terminate].
    ///   2. .completed(snapshot) — this row's tool is `sandbox_exec`
    ///      / `shell_run` and the envelope decoded successfully. The
    ///      view renders the static stdout+stderr through the same
    ///      chrome the live pane used.
    /// Mutually exclusive with `resultView` in the layout pin so we
    /// never double-pin contentContainer's bottom.
    private var terminalView: TerminalDisplayView?
    private var terminalBottomConstraint: NSLayoutConstraint?
    private var terminalHeightConstraint: NSLayoutConstraint?
    private var liveExecSubscription: AnyCancellable?
    /// Tool-call-id the live subscription is currently observing.
    /// Avoids re-subscribing on every layout-only `configure(item:)`
    /// pass for the same row.
    private var liveExecBoundCallId: String?
    /// Fixed height for the subagent feed pane (header + a few visible rows;
    /// the list scrolls internally). Kept constant so the row's
    /// `measuredHeight` is predictable as events stream in.
    private static let subagentPaneHeight: CGFloat = 220
    /// Unified subagent activity feed pane. Mounts for ANY subagent row
    /// (spawn / image / computer_use) when
    /// `SubagentFeedRegistry` has a feed for this row's tool-call-id (live run
    /// or grace tail). A SwiftUI `SubagentFeedView` hosted in AppKit. Mutually
    /// exclusive with `terminalView` / `resultView` on the `contentContainer`
    /// bottom pin.
    private var subagentFeedHostingView: NSView?
    private var subagentFeedBottomConstraint: NSLayoutConstraint?
    private var subagentFeedHeightConstraint: NSLayoutConstraint?
    private var subagentFeedSubscription: AnyCancellable?
    private var subagentFeedBoundCallId: String?
    /// Tool-call id the hosted pane was built for; a reused row re-hosts
    /// when it is configured for a different call.
    private var subagentFeedHostedCallId: String?
    private let separatorView = NSView()
    /// pins contentContainer height for hit-testing; toggled when result section is shown
    private var contentBottomToArgs: NSLayoutConstraint?
    private var contentBottomToResult: NSLayoutConstraint?
    private var resultTitleTopToArgs: NSLayoutConstraint?
    private var resultViewTopToTitle: NSLayoutConstraint?

    /// headings + body share the same left/right inset (matches reference: ARGUMENTS/RESULT align with code/result text)
    private static let sectionContentInset: CGFloat = 12
    /// row `contentContainer` is inset 12+12; section content is inset 12+12 → `innerWidth - 48` for markdown
    private static var sectionMarkdownWidthDeduction: CGFloat { 4 * sectionContentInset }

    // MARK: Self-sizing height constraint

    private var rowHeight: NSLayoutConstraint?
    private let heightAnimation = DisclosureHeightAnimation()

    // MARK: State

    private var isExpanded = false
    private var cachedArgs: String?
    /// Present-tense title shown (shimmering) while the call is running.
    /// Computed in `configure` so `applyStatusAndShimmer` (also fired by the TTS
    /// observer) doesn't depend on the not-yet-updated `isExpanded`.
    private var runningTitle: String = ""
    private var currentItemId: String = ""
    private var currentItem: ToolCallItem?
    private var currentWidth: CGFloat = 0
    private var lastConfiguredTheme: (any ThemeProtocol)?
    private var sectionInset: CGFloat { ActivityInspectionStyle.layout("toolInnerPaddingX", "padding", Self.sectionContentInset, lastConfiguredTheme ?? CustomizableTheme.light()) }
    private var outerInset: CGFloat { ActivityInspectionStyle.layout("toolOuterPaddingX", "padding", Self.sectionContentInset, lastConfiguredTheme ?? CustomizableTheme.light()) }
    private var sectionWidthDeduction: CGFloat { 2 * outerInset + 2 * sectionInset }
    private var assignedHeaderHeight: CGFloat { ActivityInspectionStyle.headerHeight(lastConfiguredTheme ?? CustomizableTheme.light()) }
    private let inspectionHeader = InspectorActivityHeaderSurface()
    /// `nonisolated(unsafe)` so deinit can read it; only ever set in
    /// init on the main actor.
    nonisolated(unsafe) private var ttsObservation: NSObjectProtocol?
    nonisolated(unsafe) private var mcpProgressObservation: NSObjectProtocol?

    // MARK: Callbacks

    var onToggle: (() -> Void)?
    var onHeightChanged: (() -> Void)?

    /// Implicit-animation suppression dict for layers we mount in this row
    /// (icon, name, shimmer). Prevents CALayer's default 0.25s `contents`
    /// / `bounds` / `position` / `opacity` transitions from running when
    /// the cell is redequeued post-finish — which otherwise reads as a
    /// spurious re-play of the appearance animation.
    static let suppressedLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "contents": NSNull(),
        "opacity": NSNull(),
        "hidden": NSNull(),
        "transform": NSNull(),
        "backgroundColor": NSNull(),
        "foregroundColor": NSNull(),
    ]

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
        ttsObservation = NotificationCenter.default.addObserver(
            forName: .ttsPlaybackStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyStatusAndShimmer()
            }
        }
        mcpProgressObservation = NotificationCenter.default.addObserver(
            forName: .mcpToolProgressChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let callId = note.object as? String
            MainActor.assumeIsolated {
                guard let self, callId == self.currentItem?.call.id else { return }
                self.applyStatusAndShimmer()
            }
        }
        fileChangeObservation = NotificationCenter.default.addObserver(
            forName: .fileChangesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fileChangeLookupCallId = nil
                self?.refreshFileChangesLink()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observation = ttsObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        if let observation = fileChangeObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        if let observation = mcpProgressObservation {
            NotificationCenter.default.removeObserver(observation)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let h = hit {
            if h === contentContainer && isExpanded {
                if let a = argsView {
                    let pa = convert(point, to: a)
                    if let inner = a.hitTest(pa) { return inner }
                }
                if let r = resultView, !r.isHidden {
                    let pr = convert(point, to: r)
                    if let inner = r.hitTest(pr) { return inner }
                }
            }
            return h
        }
        guard isExpanded else { return nil }
        let pc = convert(point, to: contentContainer)
        return contentContainer.hitTest(pc)
    }

    // MARK: Configure

    func configure(
        item: ToolCallItem,
        index: Int,
        totalCount: Int,
        isExpanded: Bool,
        width: CGFloat,
        theme: any ThemeProtocol,
        // When non-nil, the corresponding rail draws in (sweeps) after this delay
        // instead of appearing fully — set by the group only for the freshly
        // connected segments on a genuine streaming append.
        drawRailAboveAfter: CFTimeInterval? = nil,
        drawRailBelowAfter: CFTimeInterval? = nil,
        // When non-nil, this row is the freshly appended node: its circle + title
        // bloom in (scale + fade) after this delay, timed to land as the rail arrives.
        animateAppearanceAfter: CFTimeInterval? = nil,
        onToggle: @escaping () -> Void,
        onHeightChanged: @escaping () -> Void
    ) {
        let theme = theme.catalogFamily(34)
        self.onToggle = onToggle
        self.onHeightChanged = onHeightChanged
        // Streaming reconfigures the whole group on every sync. An unchanged
        // row must not be touched: rewriting its links ends a click in progress.
        let inputs = ConfigureInputs(
            item: item,
            index: index,
            totalCount: totalCount,
            isExpanded: isExpanded,
            width: width,
            themeFingerprint: theme.renderFingerprint
        )
        if inputs == lastConfigureInputs, drawRailAboveAfter == nil, drawRailBelowAfter == nil,
            animateAppearanceAfter == nil
        {
            return
        }
        lastConfigureInputs = inputs
        heightAnimation.isConfiguring = true
        self.currentWidth = width
        self.lastConfiguredTheme = theme

        let isNew = item.call.id != currentItemId
        if isNew {
            stopRegistryObservation()
            heightAnimation.cancel()
        }
        let argumentsChanged = item.call.function.arguments != currentItem?.call.function.arguments
        if argumentsChanged { cachedArgs = nil }
        currentItemId = item.call.id
        currentItem = item
        let wasExpanded = self.isExpanded
        self.isExpanded = isExpanded

        // Node: category icon shape in the foreground. The icon/circle colors and
        // the running shimmer are applied in `applyStatusAndShimmer()` below.
        // Subagent tools take their glyph from the capability registry (SSOT)
        // instead of the generic gear the substring categorizer would assign.
        let toolName = item.call.function.name
        let category = ToolCategory.from(toolName: toolName)
        let glyph = SubagentCapabilityRegistry.iconName(forToolName: toolName) ?? category.icon
        let cfg = theme.symbolConfiguration(.caption, weight: .semibold)
        // Suppress the default `contents` action so the symbol swap doesn't
        // run its own 0.25s implicit fade alongside `playNodeAppearance`'s
        // explicit opacity animation (the two would race and pop the icon in
        // before the ring finishes tracing).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        categoryIcon.image = SymbolImageCache.image(glyph, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        CATransaction.commit()

        // Rail connects consecutive calls; a lone call (only row) shows none.
        let railColor = NSColor(theme.border.default).cgColor
        separatorView.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor
        chevron.contentTintColor = NSColor(theme.text.tertiary)
        railAbove.color = railColor
        railBelow.color = railColor
        railAbove.isHidden = index == 0
        railBelow.isHidden = index >= totalCount - 1
        // A freshly connected segment (streaming append) sweeps in; everything
        // else shows fully. `showFull`/`drawIn` are no-ops mid-draw, so the
        // per-token reconfigures that follow can't interrupt the animation.
        // Capture `now` once so the rail/ring/icon animations scheduled below
        // share an anchor — deferred-layout starts can't drift the rail or
        // ring later than the icon's already-locked begin time.
        let now = CACurrentMediaTime()
        if let delay = drawRailAboveAfter, !railAbove.isHidden {
            railAbove.drawIn(beginAt: now + delay)
        } else {
            railAbove.showFull()
        }
        if let delay = drawRailBelowAfter, !railBelow.isHidden {
            railBelow.drawIn(beginAt: now + delay)
        } else {
            railBelow.showFull()
        }

        // Collapsed: friendly label. `nameLabel` only shows once the call has
        // completed, so it reads in past tense ("Inserted into the database");
        // the running state shimmers `runningTitle` in present tense instead.
        // Expanded: the raw technical name (monospaced), since that's the detail view.
        if isExpanded {
            nameLabel.stringValue = item.call.function.name
            nameLabel.font = theme.nsFont(.code, weight: .semibold)
            runningTitle = item.call.function.name
            nameLabel.textColor = NSColor(theme.text.primary)
            setHeaderLink(searchSettingsButton, visible: false)
        } else {
            let titleFont = theme.nsFont(.caption, weight: .semibold)
            nameLabel.font = titleFont
            // A completed call that returned an error keeps its red node but must
            // not claim success in the title — reflect the failure verdict here.
            let failed = item.result.map { isErrorResult($0, callId: item.call.id) } ?? false
            let past = item.unobservedResult != nil
                ? "\(item.call.function.name) · \(L("Result not received"))"
                : ToolDisplayName.friendly(
                    for: item.call.function.name,
                    running: false,
                    arguments: item.call.function.arguments,
                    failed: failed
                )
            runningTitle = ToolDisplayName.friendly(
                for: item.call.function.name,
                running: true,
                arguments: item.call.function.arguments
            )
            // A failed search (error or NO_RESULTS envelope) gets a visible
            // remediation link — the actionable "check Settings → Search"
            // hint otherwise lives only in the model-facing result JSON.
            let showSearchLink = failed && ToolDisplayName.isSearchTool(toolName)
            if showSearchLink {
                setHeaderLinkTitle(
                    searchSettingsButton,
                    NSAttributedString(
                        string: L("Search settings"),
                        attributes: [
                            .font: theme.nsFont(.footnote, weight: .semibold),
                            .foregroundColor: NSColor(theme.text.link),
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                        ]
                    )
                )
            }
            setHeaderLink(searchSettingsButton, visible: showSearchLink)
            // Search-source tag for completed search rows: premium (Osaurus
            // hosted) tints accent, the user's own provider reads neutral,
            // and the built-in scrapers stay dimmed — the at-a-glance state
            // the Credits UI elaborates on.
            let sourceTag: (label: String, color: NSColor)? = {
                guard !failed, ToolDisplayName.isSearchTool(toolName),
                    let result = item.result,
                    let source = Self.searchSource(inToolResult: result)
                else { return nil }
                switch source {
                case "premium": return (L("Premium"), NSColor(theme.status.info.foreground))
                case "custom": return (L("Your provider"), NSColor(theme.text.secondary))
                case "free": return (L("Built-in"), NSColor(theme.text.tertiary))
                default: return nil
                }
            }()
            // Append the recorded duration after an interpunct, dimmed.
            if item.duration != nil || sourceTag != nil || item.repeatCount > 1 {
                let s = NSMutableAttributedString(
                    string: past,
                    attributes: [.font: titleFont, .foregroundColor: NSColor(theme.text.primary)]
                )
                if let tag = sourceTag {
                    s.append(
                        NSAttributedString(
                            string: " · \(tag.label)",
                            attributes: [
                                .font: theme.nsFont(.caption, weight: .medium),
                                .foregroundColor: tag.color,
                            ]
                        )
                    )
                }
                if let elapsed = item.duration {
                    s.append(
                        NSAttributedString(
                            string: " · \(Self.formatElapsed(elapsed))",
                            attributes: [
                                .font: theme.nsFont(.caption),
                                .foregroundColor: NSColor(theme.text.tertiary),
                            ]
                        )
                    )
                }
                // Repeat badge: the Nth identical call (name + canonical args)
                // this message. Without it a looping model reads as N distinct
                // productive steps — the observed Raptor 8B run re-executed
                // identical knowledge calls at ~14s each and the transcript
                // showed nothing amiss. Slightly brighter than the duration:
                // a repeat is a signal, not metadata.
                if item.repeatCount > 1 {
                    s.append(
                        NSAttributedString(
                            string: " · ×\(item.repeatCount)",
                            attributes: [
                                .font: theme.nsFont(.caption, weight: .medium),
                                .foregroundColor: NSColor(theme.text.secondary),
                            ]
                        )
                    )
                }
                nameLabel.attributedStringValue = s
            } else {
                nameLabel.stringValue = past
                nameLabel.textColor = NSColor(theme.text.primary)
            }
        }

        if isNew {
            fileChangeLookupCallId = nil
            fileChangeSet = nil
            setHeaderLink(fileChangesButton, visible: false)
        }
        refreshFileChangesLink(expanded: isExpanded)
        if isNew { openRunRetries = 0 }
        refreshOpenRunLink()

        // Node colors (status-driven) + running shimmer on the title.
        applyStatusAndShimmer()

        // Freshly appearing node: stage in the ring → glyph → title. Otherwise
        // (load / reuse / already revealed) show the full ring with no animation.
        if let delay = animateAppearanceAfter {
            playNodeAppearance(beginAt: now + delay)
        } else {
            categoryBg.showRingFull()
        }

        // Argument preview is a technical detail — keep the collapsed chip clean
        // and only surface it when expanded (alongside the full ARGUMENTS section).
        if isExpanded,
            let preview = PreviewGenerator.jsonPreview(item.call.function.arguments, maxLength: 80)
        {
            argPreviewLabel.stringValue = preview
            argPreviewLabel.isHidden = false
        } else {
            argPreviewLabel.isHidden = true
        }
        argPreviewLabel.font = theme.nsFont(.footnote)
        argPreviewLabel.textColor = NSColor(theme.text.tertiary)

        // Same-call collapsed → expanded: fade the details in instead of
        // popping (cell recycling and streaming reconfigures must not fade).
        let expandTransition = !isNew && isExpanded && !wasExpanded
        let toggled = !isNew && isExpanded != wasExpanded
        updateChevron(expanded: isExpanded, animated: toggled)

        let showsContent = isExpanded || toggled || heightAnimation.isRunning
        separatorView.isHidden = !showsContent
        contentContainer.isHidden = !showsContent

        if isExpanded {
            applyToolDetailSectionHeading(to: argumentsSectionTitle, text: "ARGUMENTS", theme: theme)

            let rawArgs = item.call.function.arguments
            if isNew || argumentsChanged || cachedArgs == nil {
                let pretty = JSONFormatter.prettyJSON(rawArgs)
                cachedArgs = PreviewGenerator.cappedArguments(pretty.isEmpty ? rawArgs : pretty)
            }
            if let args = cachedArgs {
                let av = ensureArgsView()
                let textW = max(0, width - sectionWidthDeduction)
                av.configure(
                    text: "```json\n\(args)\n```",
                    width: textW,
                    theme: theme,
                    cacheKey: "args-\(item.call.id)",
                    isStreaming: false
                )
                av.onHeightChanged = { [weak self] in self?.applyHeight() }
            }
            applyResultOrLiveState(width: width, theme: theme)
            // Subscribe so that grace-expiry / late-registration
            // transitions also trigger a re-decision. Subscription
            // dedups on toolCallId, so this is a no-op on the second
            // call for the same row.
            bindLiveOutputIfPresent(toolCallId: item.call.id)
            // Every expanded row watches the unified subagent feed registry so
            // spawn / image / computer_use rows mount the live
            // activity pane as the host registers and drops their feed.
            bindSubagentFeedIfPresent(toolCallId: item.call.id)
        }

        // Tear down panes when the row collapses; a collapse in motion keeps
        // them drawn until it finishes.
        if !showsContent { tearDownCollapsedContent() }

        // After the detail views exist — on a first-ever expand the sections
        // are only built above, and a reveal fired before that would find an
        // empty container and do nothing. Slightly longer per-section fade
        // than the default: the ARGUMENTS/RESULT bodies are dense, and the
        // extra beat makes the reveal register.
        if expandTransition { ExpandFade.run(contentContainer, duration: 0.38) }

        ActivityInspectionStyle.label(nameLabel, property: "label", theme: theme)
        ActivityInspectionStyle.label(argPreviewLabel, property: "caption", theme: theme)
        applyAssignedLayout(theme)
        inspectionHeader.configure(theme: theme, selected: isExpanded)
        heightAnimation.isConfiguring = false
        if toggled {
            heightAnimation.run(
                on: self,
                from: rowHeight?.constant ?? measuredHeight(),
                target: { [weak self] in self?.measuredHeight() ?? 0 },
                apply: { [weak self] in self?.setHeight($0) },
                finish: { [weak self] in
                    guard let self, !self.isExpanded else { return }
                    self.separatorView.isHidden = true
                    self.contentContainer.isHidden = true
                    self.tearDownCollapsedContent()
                }
            )
        } else {
            applyHeight()
        }
    }

    private func tearDownCollapsedContent() {
        stopRegistryObservation()
        tearDownTerminalView()
        tearDownSubagentFeedView()
    }

    private func applyAssignedLayout(_ theme: any ThemeProtocol) {
        let pad = ActivityInspectionStyle.layout("toolHeaderPaddingX", "padding", Self.sectionContentInset, theme)
        let gap = ActivityInspectionStyle.layout("toolContentGap", "gap", theme.space.s8, theme)
        let height = assignedHeaderHeight
        headerButton.catalogAssignmentTarget(["toolHeaderPaddingX", "toolHeaderPaddingY", "toolHeaderIconGap", "toolHeaderMetadataGap"].map { ActivityInspectionStyle.key + "elements.layout." + $0 }, name: "Tool result header", theme: theme)
        contentContainer.catalogAssignmentTarget(["toolOuterPaddingX", "toolInnerPaddingX", "toolContentGap", "toolBottomPadding"].map { ActivityInspectionStyle.key + "elements.layout." + $0 } + [AgentContentSurfaceAssignments.key(34, "toolContent")], name: "Expanded tool arguments and result", theme: theme)
        headerButton.constraints.first { $0.firstAttribute == .height }?.constant = height
        separatorView.constraints.first { $0.firstAttribute == .height }?.constant = ActivityInspectionStyle.metric("borderWidth", 1, theme)
        separatorView.layer?.backgroundColor = NSColor(theme.border.subtle).cgColor
        layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(34, "toolCard", theme)).cgColor
        catalogAssignmentTarget([AgentContentSurfaceAssignments.key(34, "toolCard")], name: "Tool result card", theme: theme)
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(AgentContentSurfaceAssignments.color(34, "toolContent", theme)).cgColor
        layer?.borderColor = NSColor(theme.border.subtle).cgColor
        layer?.borderWidth = ActivityInspectionStyle.metric("borderWidth", 0, theme)
        layer?.cornerRadius = theme.radius.medium
        categoryBg.inspectionStrokeWidth = ActivityInspectionStyle.metric("borderWidth", 1.5, theme)
        for c in constraints {
            let view = c.firstItem as? NSView
            if view === categoryBg, c.firstAttribute == .leading { c.constant = pad }
            if view === categoryBg, c.firstAttribute == .centerY { c.constant = height / 2 }
            if (view === nameLabel || view === shimmerLabel), c.firstAttribute == .leading { c.constant = ActivityInspectionStyle.layout("toolHeaderIconGap", "gap", theme.space.s8, theme) }
            if view === argPreviewLabel, c.firstAttribute == .leading { c.constant = ActivityInspectionStyle.layout("toolHeaderMetadataGap", "gap", theme.space.s8, theme) }
            if view === chevron, c.firstAttribute == .trailing { c.constant = -pad }
            if view === separatorView, c.firstAttribute == .top { c.constant = height }
            if view === separatorView, c.firstAttribute == .leading { c.constant = 2 * pad }
            if view === separatorView, c.firstAttribute == .trailing { c.constant = -2 * pad }
            if view === contentContainer, c.firstAttribute == .leading { c.constant = outerInset }
            if view === contentContainer, c.firstAttribute == .trailing { c.constant = -outerInset }
            if view === contentContainer, c.firstAttribute == .top { c.constant = gap }
        }
        for c in contentContainer.constraints {
            let view = c.firstItem as? NSView
            if c.firstAttribute == .leading, c.secondItem as? NSView === contentContainer { c.constant = sectionInset }
            if c.firstAttribute == .trailing, c.secondItem as? NSView === contentContainer { c.constant = -sectionInset }
            if c.firstAttribute == .top, view !== argumentsSectionTitle { c.constant = gap }
        }
        resultTitleTopToArgs?.constant = gap
        resultViewTopToTitle?.constant = gap
    }

    // MARK: Measured height

    func measuredHeight() -> CGFloat {
        let rowH = assignedHeaderHeight
        let theme = lastConfiguredTheme ?? CustomizableTheme.light()
        guard isExpanded else { return rowH + ActivityInspectionStyle.metric("borderWidth", 1, theme) }
        // matches InlineToolCallView ToolDetailSection header row (~9pt bold + padding)
        let gap = ActivityInspectionStyle.layout("toolContentGap", "gap", theme.space.s8, theme)
        let sectionTitleH = ActivityInspectionStyle.fieldHeight("caption", theme, fallback: 22)
        let textW = max(0, currentWidth - sectionWidthDeduction)
        let argsH = argsView?.measuredHeight(for: textW) ?? 0
        let resultH: CGFloat
        if let rv = resultView, !rv.isHidden {
            resultH = gap + sectionTitleH + rv.measuredHeight(for: textW)
        } else {
            resultH = 0
        }
        // Live mode locks at maxBodyHeight; completed mode uses the
        // view's adaptive measured height (60–140pt body + 30pt header).
        let terminalH: CGFloat
        if let tv = terminalView {
            terminalH = gap + tv.currentMeasuredHeight
        } else {
            terminalH = 0
        }
        let subagentH: CGFloat = subagentFeedHostingView != nil ? (gap + Self.subagentPaneHeight) : 0
        return rowH + ActivityInspectionStyle.metric("borderWidth", 1, theme) + gap + sectionTitleH + argsH + terminalH + subagentH + resultH + ActivityInspectionStyle.layout("toolBottomPadding", "padding", theme.space.s8, theme)
    }

    // MARK: - Terminal pane bindings

    /// Re-evaluate which expanded section to show given the current
    /// `LiveExecRegistry` snapshot AND the tool name. Called from
    /// `configure(item:)` for the initial mount AND from the registry
    /// subscription closure on every entry-change tick.
    ///
    /// Routing:
    ///   - tool is running                    → mount terminal in
    ///                                         .live(entry) mode
    ///   - tool is shell (sandbox_exec/run)  + completed
    ///                                       → mount terminal in
    ///                                         .completed(snapshot) mode
    ///   - any other completed tool           → fall back to the
    ///                                         markdown result section
    /// Live → completed transitions carry the same view through both
    /// modes so the row chrome doesn't visually shift when streaming
    /// ends.
    private func applyResultOrLiveState(width: CGFloat, theme: any ThemeProtocol) {
        guard let item = currentItem else { return }

        // 0) Unified subagent feed: any row whose tool-call-id has a live
        //    (or grace-tail) `SubagentFeed` renders the shared activity pane.
        //    Drives spawn / image / computer_use live rows.
        //    Once the grace tail drops the live feed, a finished Computer Use /
        //    AppleScript run keeps its step log from the saved run log (the
        //    pane header carries the outcome and failure reason); other kinds
        //    fall through to the markdown summary.
        if let feed = SubagentFeedRegistry.shared.feed(for: item.call.id)
            ?? SubagentRunLogArchive.shared.feed(for: item.call.id)
        {
            tearDownResultSection()
            tearDownTerminalView()
            mountSubagentFeedView(feed: feed, theme: theme)
            return
        }
        tearDownSubagentFeedView()

        // 1) Live path takes priority while a tool is actively running.
        if let entry = LiveExecRegistry.shared.currentEntries()[item.call.id],
            entry.currentStatus() == .running
        {
            tearDownResultSection()
            mountTerminalView(mode: .live(entry), theme: theme)
            return
        }

        // 2) Completed shell tool → snapshot rendering through the
        //    same terminal chrome. The factory returns nil for non-
        //    shell tools and error envelopes, which then fall through
        //    to the markdown path below.
        if let result = item.result,
            let snapshot = TerminalSnapshot.from(toolResult: result, item: item)
        {
            tearDownResultSection()
            mountTerminalView(mode: .completed(snapshot), theme: theme)
            return
        }

        // 3) Markdown fallback for everything else.
        tearDownTerminalView()
        guard let result = item.result ?? item.unobservedResult?.localizedUnobservedResult else {
            tearDownResultSection()
            return
        }
        ensureResultSectionTitle(theme: theme).isHidden = false
        let rv = ensureResultView()
        rv.isHidden = false
        let textW = max(0, width - sectionWidthDeduction)
        let resultMarkdown = Self.markdownForToolResultDisplay(
            result, toolName: item.call.function.name)
        rv.configure(
            text: resultMarkdown,
            width: textW,
            theme: theme,
            cacheKey: "result-\(item.call.id)",
            isStreaming: false
        )
        rv.onHeightChanged = { [weak self] in self?.applyHeight() }
        contentBottomToArgs?.isActive = false
        contentBottomToResult?.isActive = true
        applyHeight()
    }

    /// Subscribe to `LiveExecRegistry` and re-run `applyResultOrLiveState`
    /// on every entries snapshot. Handles three transitions:
    ///   - tool registers → live pane mounts
    ///   - tool unregisters mid-grace (rare) → falls through to static
    ///   - 60 s grace expires → falls through to static result if any
    ///
    /// Idempotent on the same id so layout-only re-configures don't
    /// re-subscribe.
    private func bindLiveOutputIfPresent(toolCallId: String) {
        if liveExecBoundCallId == toolCallId, liveExecSubscription != nil {
            return
        }
        liveExecSubscription?.cancel()
        liveExecBoundCallId = toolCallId

        liveExecSubscription = LiveExecRegistry.shared.entriesPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isExpanded, self.currentItemId == toolCallId,
                        let theme = self.lastConfiguredTheme else { return }
                    self.applyResultOrLiveState(width: self.currentWidth, theme: theme)
                }
            }
    }

    /// Lazily install (or reuse) a `TerminalDisplayView` and bind it
    /// in the given mode. The view itself decides between the live
    /// streaming path and the static snapshot render based on the
    /// passed `mode`.
    private func mountTerminalView(
        mode: TerminalDisplayView.Mode,
        theme: any ThemeProtocol
    ) {
        let view: TerminalDisplayView
        if let existing = terminalView {
            view = existing
        } else {
            view = TerminalDisplayView()
            view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(view)
            let av = ensureArgsView()
            // The view itself needs an explicit height because its body
            // is an NSScrollView (no intrinsic size); without this the
            // layout solver gives it 0 height and the row reserves
            // space for nothing. We start at the live-mode max height
            // and adjust per-bind below for completed mode.
            let heightConst = view.heightAnchor.constraint(
                equalToConstant: TerminalDisplayView.liveModeMeasuredHeight()
            )
            terminalHeightConstraint = heightConst
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(
                    equalTo: contentContainer.leadingAnchor,
                    constant: sectionInset
                ),
                view.trailingAnchor.constraint(
                    equalTo: contentContainer.trailingAnchor,
                    constant: -sectionInset
                ),
                view.topAnchor.constraint(equalTo: av.bottomAnchor, constant: 8),
                heightConst,
            ])
            let pin = contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            terminalBottomConstraint = pin
            terminalView = view
        }
        // CRITICAL: this branch runs on EVERY mount — including the
        // "view already exists" path — because `applyResultOrLiveState`
        // → `tearDownResultSection` re-activates `contentBottomToArgs`
        // every tick. Two active bottom pins on `contentContainer`
        // (args AND live) would let Auto Layout silently pick whichever
        // gives the bigger height, and the textView pinned to the
        // shorter live constraint ends up clipped outside the visible
        // contentContainer region. Always swap pins atomically here.
        contentBottomToArgs?.isActive = false
        terminalBottomConstraint?.isActive = true
        view.bind(mode, theme: theme)
        // After bind, `currentMeasuredHeight` reflects the right size
        // for the mode we just bound in (live = locked maxBodyHeight,
        // completed = adaptive 60–140pt body).
        terminalHeightConstraint?.constant = view.currentMeasuredHeight
        applyHeight()
    }

    private func tearDownTerminalView() {
        guard let view = terminalView else { return }
        view.unbind()
        terminalBottomConstraint?.isActive = false
        terminalBottomConstraint = nil
        terminalHeightConstraint = nil
        view.removeFromSuperview()
        terminalView = nil
        // Restore args' bottom pin so contentContainer keeps a single
        // bottom anchor (otherwise the layout becomes ambiguous).
        contentBottomToArgs?.isActive = true
        applyHeight()
    }

    // MARK: - Unified subagent feed pane

    /// Subscribe to `SubagentFeedRegistry` and re-run `applyResultOrLiveState`
    /// on every snapshot so the shared activity pane mounts when the host
    /// registers a run's feed and falls through to the markdown summary once
    /// the grace tail drops it. Idempotent on the same id.
    private func bindSubagentFeedIfPresent(toolCallId: String) {
        if subagentFeedBoundCallId == toolCallId, subagentFeedSubscription != nil { return }
        subagentFeedSubscription?.cancel()
        subagentFeedBoundCallId = toolCallId
        subagentFeedSubscription = SubagentFeedRegistry.shared.feedsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isExpanded, self.currentItemId == toolCallId,
                        let theme = self.lastConfiguredTheme else { return }
                    self.applyResultOrLiveState(width: self.currentWidth, theme: theme)
                }
            }
    }

    /// Observation belongs to the expanded row, including the interval before
    /// dispatch registers a terminal or feed. Removing a pane must not cancel
    /// the observer that will discover its replacement.
    private func stopRegistryObservation() {
        liveExecSubscription?.cancel()
        liveExecSubscription = nil
        liveExecBoundCallId = nil
        subagentFeedSubscription?.cancel()
        subagentFeedSubscription = nil
        subagentFeedBoundCallId = nil
    }

    /// Mount (or reuse) the SwiftUI feed pane for `feed`. Mirrors
    /// `mountTerminalView`'s constraint swap so `contentContainer` never has
    /// two active bottom pins.
    private func mountSubagentFeedView(feed: SubagentFeed, theme: any ThemeProtocol) {
        let host: NSView
        // Rows are reused across tool calls: a pane built for another call
        // (or for this call's live feed, now replaced by its saved log with
        // identical content) must not be shown for a different run.
        if subagentFeedHostingView != nil, subagentFeedHostedCallId != feed.toolCallId {
            removeSubagentFeedHost()
        }
        if let existing = subagentFeedHostingView {
            host = existing
        } else {
            let hosting = NSHostingView(rootView: HostedSubagentFeedView(feed: feed))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(hosting)
            let av = ensureArgsView()
            let heightConst = hosting.heightAnchor.constraint(
                equalToConstant: Self.subagentPaneHeight
            )
            subagentFeedHeightConstraint = heightConst
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(
                    equalTo: contentContainer.leadingAnchor,
                    constant: sectionInset
                ),
                hosting.trailingAnchor.constraint(
                    equalTo: contentContainer.trailingAnchor,
                    constant: -sectionInset
                ),
                hosting.topAnchor.constraint(equalTo: av.bottomAnchor, constant: 8),
                heightConst,
            ])
            let pin = contentContainer.bottomAnchor.constraint(equalTo: hosting.bottomAnchor)
            subagentFeedBottomConstraint = pin
            subagentFeedHostingView = hosting
            subagentFeedHostedCallId = feed.toolCallId
            host = hosting
        }
        // Swap pins atomically (see mountTerminalView for why).
        contentBottomToArgs?.isActive = false
        subagentFeedBottomConstraint?.isActive = true
        _ = host
        applyHeight()
    }

    private func tearDownSubagentFeedView() {
        guard subagentFeedHostingView != nil else { return }
        removeSubagentFeedHost()
        contentBottomToArgs?.isActive = true
        applyHeight()
    }

    /// Remove the hosted pane and its constraints, leaving the registry
    /// subscription intact (used when re-hosting for a different call).
    private func removeSubagentFeedHost() {
        guard let host = subagentFeedHostingView else { return }
        subagentFeedBottomConstraint?.isActive = false
        subagentFeedBottomConstraint = nil
        subagentFeedHeightConstraint = nil
        host.removeFromSuperview()
        subagentFeedHostingView = nil
        subagentFeedHostedCallId = nil
    }

    // MARK: - Private

    /// JSON → fenced `json` block (pretty-printed). Anything else → raw markdown so prose/lists/**bold** render.
    ///
    /// Special case: a `ToolEnvelope` success result whose payload is a
    /// `{"text": "..."}` carrier renders as the prose verbatim (markdown).
    /// This keeps file_read / capability listings readable in the
    /// tool-call card instead of getting buried under a JSON wrapper.
    private static func markdownForToolResultDisplay(
        _ result: String, toolName: String = ""
    ) -> String {
        if ToolEnvelope.isError(result) {
            return result
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        if let payload = ToolEnvelope.successPayload(result) as? [String: Any] {
            // osaurus_config plan/apply payloads are structured — render a
            // readable outcome list (with Settings deep-links for rows the
            // user must finish) instead of the raw JSON envelope.
            if toolName == "osaurus_config",
                let rendered = markdownForConfigResult(payload)
            {
                return rendered
            }
            // Directory listings are structured (`kind: "listing"`) — the
            // model acts on `entries`, but the UI renders a readable tree
            // from the same structure (presentation, not the model's input).
            if payload["kind"] as? String == "listing",
                let entries = payload["entries"] as? [[String: Any]]
            {
                let path = payload["path"] as? String ?? "."
                let truncated = payload["truncated"] as? Bool ?? false
                return markdownForListing(path: path, entries: entries, truncated: truncated)
            }
            // Filename-search results (`kind: "search"`) share the actionable
            // `entries[]` shape; render the candidate list like a listing.
            if payload["kind"] as? String == "search",
                let entries = payload["entries"] as? [[String: Any]]
            {
                let query = payload["query"] as? String ?? ""
                let truncated = payload["truncated"] as? Bool ?? false
                return markdownForSearch(query: query, entries: entries, truncated: truncated)
            }
            if let text = payload["text"] as? String {
                return text
            }
        }
        if let pretty = JSONFormatter.prettyPrintedJSONIfValid(trimmed) {
            return "```json\n\(pretty)\n```"
        }
        return trimmed
    }

    /// Render an `osaurus_config` plan or apply payload as a readable
    /// outcome list. Apply results become per-target status lines with a
    /// `[Open … in Settings](osaurus://settings?tab=…)` link on rows the
    /// user must finish; plan results reuse the plan's own summary text.
    /// Returns nil when the payload doesn't match either shape (schema /
    /// export / templates fall through to the generic rendering).
    /// Internal (not private) so unit tests can pin the rendering contract.
    static func markdownForConfigResult(_ payload: [String: Any]) -> String? {
        // Apply: {"status": ..., "results": [{section, target, status, message}], notes}
        if let rows = payload["results"] as? [[String: Any]], !rows.isEmpty,
            rows.allSatisfy({ $0["section"] is String && $0["status"] is String })
        {
            var lines: [String] = []
            if let status = payload["status"] as? String {
                lines.append("**\(configTopLevelStatusLabel(status))**")
                lines.append("")
            }
            for row in rows {
                let section = row["section"] as? String ?? ""
                let target = row["target"] as? String ?? ""
                let status = row["status"] as? String ?? ""
                var line = "- \(configStatusSymbol(status)) \(section): **\(target)**"
                if let message = row["message"] as? String, !message.isEmpty {
                    line += " — \(message)"
                }
                if status == "needs_user_action" || status == "cancelled",
                    let tab = configSettingsTab(forSection: section)
                {
                    line += " [Open \(tab.label) in Settings](osaurus://settings?tab=\(tab.rawValue))"
                }
                lines.append(line)
            }
            if let notes = payload["notes"] as? [String], !notes.isEmpty {
                lines.append("")
                for note in notes { lines.append("_\(note)_") }
            }
            return lines.joined(separator: "\n")
        }
        // Plan: {"change_count": ..., "actions": [...], "summary": "..."}
        if payload["change_count"] != nil, let summary = payload["summary"] as? String {
            var text = "```\n\(summary)\n```"
            if let note = payload["note"] as? String, !note.isEmpty {
                text += "\n_\(note)_"
            }
            return text
        }
        return nil
    }

    private static func configTopLevelStatusLabel(_ status: String) -> String {
        switch status {
        case "applied": return "Applied"
        case "applied_downloads_running": return "Applied — downloads still running"
        case "partial": return "Partially applied"
        case "no_changes": return "No changes needed"
        default: return status
        }
    }

    private static func configStatusSymbol(_ status: String) -> String {
        switch status {
        case "done": return "✓"
        case "started": return "⏳"
        case "failed": return "✗"
        case "needs_user_action": return "⚠"
        case "cancelled": return "✗"
        default: return "•"
        }
    }

    /// Best-fit Settings tab for a config document section, used for the
    /// deep-link on rows the user must finish by hand.
    private static func configSettingsTab(forSection section: String) -> ManagementTab? {
        switch section {
        case "providers": return .providers
        // MCP servers are managed from the Tools tab's MCP section.
        case "mcp": return .tools
        case "models": return .models
        // Native plugins now live under the Tools tab.
        case "plugins": return .tools
        case "automations", "events", "schedules", "watchers": return .automations
        case "agents", "default_agent", "active_agent", "harness_runtimes": return .agents
        case "configurator": return .configurator
        case "tools": return .tools
        case "search_providers": return .search
        case "server": return .server
        case "memory": return .memory
        case "voice": return .voice
        case "chat": return .chat
        case "app": return .settings
        default: return nil
        }
    }

    /// Render a structured directory listing as an indented tree for display.
    /// Entry `path` values are relative to the working root (or absolute
    /// sandbox paths); we strip the listed root prefix and indent by the
    /// remaining depth so the card reads like a tree without the model ever
    /// seeing one.
    private static func markdownForListing(
        path: String,
        entries: [[String: Any]],
        truncated: Bool
    ) -> String {
        if entries.isEmpty {
            return "`\(path)` — (empty directory)"
        }
        let countLabel = entries.count == 1 ? "1 entry" : "\(entries.count) entries"
        var lines: [String] = ["`\(path)` — \(countLabel)"]
        let prefix: String = {
            guard path != ".", !path.isEmpty else { return "" }
            return path.hasSuffix("/") ? path : path + "/"
        }()
        for entry in entries {
            guard let entryPath = entry["path"] as? String else { continue }
            let isDir = (entry["type"] as? String) == "directory"
            var display = entryPath
            if !prefix.isEmpty, display.hasPrefix(prefix) {
                display = String(display.dropFirst(prefix.count))
            }
            let depth = max(0, display.components(separatedBy: "/").count - 1)
            let indent = String(repeating: "  ", count: depth)
            let leaf = (display as NSString).lastPathComponent
            lines.append("\(indent)- \(leaf)\(isDir ? "/" : "")")
        }
        if truncated {
            lines.append("… (listing truncated — use `file_search` to find a specific file)")
        }
        return lines.joined(separator: "\n")
    }

    /// Render a structured filename-search result (`kind: "search"`) as a flat
    /// candidate list. Mirrors `markdownForListing` but keyed on the query
    /// rather than a directory path; the model picks among the candidates.
    private static func markdownForSearch(
        query: String,
        entries: [[String: Any]],
        truncated: Bool
    ) -> String {
        if entries.isEmpty {
            return "No files matched `\(query)`"
        }
        let countLabel = entries.count == 1 ? "1 match" : "\(entries.count) matches"
        var lines: [String] = ["`\(query)` — \(countLabel)"]
        for entry in entries {
            guard let entryPath = entry["path"] as? String else { continue }
            let isDir = (entry["type"] as? String) == "directory"
            lines.append("- \(entryPath)\(isDir ? "/" : "")")
        }
        if truncated {
            lines.append("… (search truncated — narrow the path or use a more specific token)")
        }
        return lines.joined(separator: "\n")
    }

    /// Height the row occupies now: mid-disclosure the animated value.
    func displayedHeight() -> CGFloat { heightAnimation.height(measured: measuredHeight()) }

    private func applyHeight() {
        guard !heightAnimation.holdsHeight else { return }
        setHeight(measuredHeight())
    }

    private func setHeight(_ height: CGFloat) {
        rowHeight?.constant = height
        invalidateIntrinsicContentSize()
        onHeightChanged?()
    }

    /// Diameter of the circular timeline node.
    private static let nodeSize: CGFloat = 28
    /// Header row height (node + breathing room above/below).
    static let rowHeaderHeight: CGFloat = 48

    private func buildViews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Rail segments sit behind everything else.
        for rail in [railAbove, railBelow] {
            rail.translatesAutoresizingMaskIntoConstraints = false
            rail.wantsLayer = true
            rail.isHidden = true
            addSubview(rail)
        }

        // Circular node — a TimelineNodeView whose CAShapeLayer draws both the
        // tinted disc (fillColor) and the status ring (strokeColor), so the ring
        // can be traced on clockwise during the reveal. Colors set in configure.
        categoryBg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(categoryBg)

        // Category glyph lives inside the node, foreground.
        categoryIcon.translatesAutoresizingMaskIntoConstraints = false
        categoryIcon.wantsLayer = true  // animatable for the staged glyph reveal
        categoryIcon.imageScaling = .scaleProportionallyUpOrDown
        // Suppress implicit CALayer animations on `contents`/`opacity`/`bounds`
        // etc. Post-finish cell teardown + redequeue otherwise rebuilds the
        // image view from zero bounds → 14×14, animating the glyph in over
        // 0.25s and giving the impression the appearance sequence is replaying.
        categoryIcon.layer?.actions = Self.suppressedLayerActions
        categoryBg.addSubview(categoryIcon)

        // Shimmering title (running state); overlays the static nameLabel slot.
        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false
        shimmerLabel.isHidden = true
        shimmerLabel.wantsLayer = true
        shimmerLabel.layer?.actions = Self.suppressedLayerActions
        addSubview(shimmerLabel)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.wantsLayer = true  // animatable for the appended-node title bloom
        nameLabel.layer?.actions = Self.suppressedLayerActions
        nameLabel.isEditable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.maximumNumberOfLines = 1
        nameLabel.alignment = .left
        nameLabel.usesSingleLineMode = true
        // Keep the tool name visible over the arg preview; a shown header
        // link (required) truncates it instead of overlapping it.
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(nameLabel)

        argPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        argPreviewLabel.isEditable = false; argPreviewLabel.isBordered = false
        argPreviewLabel.drawsBackground = false
        argPreviewLabel.lineBreakMode = .byTruncatingTail; argPreviewLabel.maximumNumberOfLines = 1
        argPreviewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        argPreviewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(argPreviewLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.wantsLayer = true
        chevron.image = SymbolImageCache.image(
            "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
        // Down-only scaling + a fixed symbol point size keep the right and
        // down chevrons visually the same size; proportional up-scaling into
        // the square frame inflated whichever glyph was wider.
        chevron.imageScaling = .scaleProportionallyDown
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(chevron)

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.wantsLayer = true
        separatorView.isHidden = true
        addSubview(separatorView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.isHidden = true
        addSubview(contentContainer)

        argumentsSectionTitle.translatesAutoresizingMaskIntoConstraints = false
        argumentsSectionTitle.isEditable = false
        argumentsSectionTitle.isBordered = false
        argumentsSectionTitle.drawsBackground = false
        argumentsSectionTitle.alignment = .left
        contentContainer.addSubview(argumentsSectionTitle)

        NSLayoutConstraint.activate([
            argumentsSectionTitle.leadingAnchor.constraint(
                equalTo: contentContainer.leadingAnchor,
                constant: sectionInset
            ),
            argumentsSectionTitle.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor),
            argumentsSectionTitle.topAnchor.constraint(equalTo: contentContainer.topAnchor),
        ])

        // header button ON TOP — transparent overlay for click handling
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.title = ""
        headerButton.isBordered = false
        headerButton.bezelStyle = .inline
        headerButton.isTransparent = true
        headerButton.focusRingType = .none
        headerButton.target = self; headerButton.action = #selector(tapped)
        addSubview(headerButton)  // added last → front of Z-order

        // Search-failure deep link. Added AFTER the transparent header
        // overlay so its clicks aren't swallowed by the expand/collapse
        // toggle. Hidden by default; `configure` shows it only for failed
        // search-tool rows in the collapsed state.
        searchSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        searchSettingsButton.isBordered = false
        searchSettingsButton.bezelStyle = .inline
        searchSettingsButton.focusRingType = .none
        searchSettingsButton.isHidden = true
        searchSettingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchSettingsButton.target = self
        searchSettingsButton.action = #selector(openSearchSettings)
        addSubview(searchSettingsButton)

        fileChangesButton.translatesAutoresizingMaskIntoConstraints = false
        fileChangesButton.isBordered = false
        fileChangesButton.bezelStyle = .inline
        fileChangesButton.focusRingType = .none
        fileChangesButton.isHidden = true
        fileChangesButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        fileChangesButton.target = self
        fileChangesButton.action = #selector(openFileChanges)
        addSubview(fileChangesButton)

        openRunButton.translatesAutoresizingMaskIntoConstraints = false
        openRunButton.isBordered = false
        openRunButton.bezelStyle = .inline
        openRunButton.focusRingType = .none
        openRunButton.isHidden = true
        openRunButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        openRunButton.target = self
        openRunButton.action = #selector(openWorkflowRun)
        addSubview(openRunButton)

        remedyButton.translatesAutoresizingMaskIntoConstraints = false
        remedyButton.isBordered = false
        remedyButton.bezelStyle = .inline
        remedyButton.focusRingType = .none
        remedyButton.isHidden = true
        remedyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        remedyButton.target = self
        remedyButton.action = #selector(applyWorkflowRemedy)
        addSubview(remedyButton)

        let rowH = assignedHeaderHeight

        inspectionHeader.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inspectionHeader, positioned: .below, relativeTo: categoryBg)
        NSLayoutConstraint.activate([inspectionHeader.leadingAnchor.constraint(equalTo: leadingAnchor), inspectionHeader.trailingAnchor.constraint(equalTo: trailingAnchor), inspectionHeader.topAnchor.constraint(equalTo: topAnchor), inspectionHeader.heightAnchor.constraint(equalTo: headerButton.heightAnchor)])
        // self-sizing height constraint
        let h = heightAnchor.constraint(equalToConstant: rowH + 1)
        h.priority = NSLayoutConstraint.Priority(rawValue: 750)
        h.isActive = true
        rowHeight = h

        NSLayoutConstraint.activate([
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerButton.topAnchor.constraint(equalTo: topAnchor),
            headerButton.heightAnchor.constraint(equalToConstant: rowH),

            // Circular node, leading-aligned with the message text and centered
            // in the header.
            categoryBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryBg.centerYAnchor.constraint(equalTo: topAnchor, constant: rowH / 2),
            categoryBg.widthAnchor.constraint(equalToConstant: Self.nodeSize),
            categoryBg.heightAnchor.constraint(equalToConstant: Self.nodeSize),

            categoryIcon.centerXAnchor.constraint(equalTo: categoryBg.centerXAnchor),
            categoryIcon.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            categoryIcon.widthAnchor.constraint(equalToConstant: 14),
            categoryIcon.heightAnchor.constraint(equalToConstant: 14),

            // Shimmer title occupies the same slot as nameLabel (only one shows).
            shimmerLabel.leadingAnchor.constraint(equalTo: categoryBg.trailingAnchor, constant: 10),
            shimmerLabel.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            shimmerLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            // Rail: a 2pt vertical line centered on the node. It connects the
            // node *edges* (not the center) so it never crosses through a circle.
            railAbove.centerXAnchor.constraint(equalTo: categoryBg.centerXAnchor),
            railAbove.widthAnchor.constraint(equalToConstant: 2),
            railAbove.topAnchor.constraint(equalTo: topAnchor),
            railAbove.bottomAnchor.constraint(equalTo: categoryBg.topAnchor),

            railBelow.centerXAnchor.constraint(equalTo: categoryBg.centerXAnchor),
            railBelow.widthAnchor.constraint(equalToConstant: 2),
            railBelow.topAnchor.constraint(equalTo: categoryBg.bottomAnchor),
            railBelow.bottomAnchor.constraint(equalTo: bottomAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: categoryBg.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            argPreviewLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            argPreviewLabel.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            argPreviewLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),

            searchSettingsButton.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            fileChangesButton.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            openRunButton.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            remedyButton.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: categoryBg.centerYAnchor),
            // 12pt square fits both 10pt chevron orientations (9×11 and 11×9)
            // without downscaling — a 10pt frame shrank whichever was wider.
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),

            // Expanded divider aligns with the ARGUMENTS text (right of the rail).
            separatorView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 12 + sectionInset
            ),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separatorView.topAnchor.constraint(equalTo: topAnchor, constant: rowH),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            // Keep leading at 12 so the markdown width deduction stays valid;
            // sectionContentInset (12) puts the body text flush right of the rail.
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentContainer.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),
        ])

        for link in [searchSettingsButton, fileChangesButton] {
            headerLinkPins[link] = [
                link.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
                link.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            ]
        }
        openRunLeadingToName = openRunButton.leadingAnchor.constraint(
            equalTo: nameLabel.trailingAnchor, constant: 10)
        openRunLeadingToShimmer = openRunButton.leadingAnchor.constraint(
            equalTo: shimmerLabel.trailingAnchor, constant: 10)
        headerLinkPins[openRunButton] = [
            openRunButton.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8)
        ]
        remedyLeadingToOpenRun = remedyButton.leadingAnchor.constraint(
            equalTo: openRunButton.trailingAnchor, constant: 10)
        remedyLeadingToName = remedyButton.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10)
        headerLinkPins[remedyButton] = [
            remedyButton.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8)
        ]
    }

    // MARK: - Header links

    /// Show or hide a header link. Writes only on change: reassigning an
    /// `NSButton`'s state while the mouse is down on it ends the click.
    private func setHeaderLink(_ link: NSButton, visible: Bool) {
        if link.isHidden == visible { link.isHidden = !visible }
        applyHeaderLinkPins()
    }

    private func setHeaderLinkTitle(_ link: NSButton, _ title: NSAttributedString) {
        if !link.attributedTitle.isEqual(to: title) { link.attributedTitle = title }
    }

    /// A link's horizontal pins are active only while it shows. Hidden views
    /// still take part in Auto Layout, and a hidden link's required width
    /// would squeeze the title or push past the chevron.
    private func applyHeaderLinkPins() {
        let openRunVisible = !openRunButton.isHidden
        let toShimmer = openRunVisible && !shimmerLabel.isHidden
        setActive(openRunLeadingToShimmer, toShimmer)
        setActive(openRunLeadingToName, openRunVisible && !toShimmer)
        let remedyVisible = !remedyButton.isHidden
        setActive(remedyLeadingToOpenRun, remedyVisible && openRunVisible)
        setActive(remedyLeadingToName, remedyVisible && !openRunVisible)
        for (link, pins) in headerLinkPins {
            for pin in pins { setActive(pin, !link.isHidden) }
        }
    }

    private func setActive(_ constraint: NSLayoutConstraint?, _ active: Bool) {
        guard let constraint, constraint.isActive != active else { return }
        constraint.isActive = active
    }

    private func ensureArgsView() -> NativeMarkdownView {
        if let v = argsView { return v }
        let v = NativeMarkdownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.onHeightChanged = { [weak self] in self?.applyHeight() }
        contentContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: sectionInset),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -sectionInset),
            v.topAnchor.constraint(equalTo: argumentsSectionTitle.bottomAnchor, constant: 4),
        ])
        argsView = v

        let pinArgs = contentContainer.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        pinArgs.isActive = true
        contentBottomToArgs = pinArgs
        return v
    }

    private func ensureResultSectionTitle(theme: any ThemeProtocol) -> NSTextField {
        let resultLabel = L("RESULT")
        if let t = resultSectionTitle {
            applyToolDetailSectionHeading(to: t, text: resultLabel, theme: theme)
            return t
        }
        let t = NSTextField(labelWithString: resultLabel)
        t.translatesAutoresizingMaskIntoConstraints = false
        t.isEditable = false
        t.isBordered = false
        t.drawsBackground = false
        t.alignment = .left
        applyToolDetailSectionHeading(to: t, text: resultLabel, theme: theme)
        contentContainer.addSubview(t)
        let av = ensureArgsView()
        let top = t.topAnchor.constraint(equalTo: av.bottomAnchor, constant: 8)
        top.isActive = true
        resultTitleTopToArgs = top
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: sectionInset),
            t.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor),
        ])
        resultSectionTitle = t
        return t
    }

    private func ensureResultView() -> NativeMarkdownView {
        if let v = resultView { return v }
        // Lazily create args / result-title if missing (defensive against unexpected
        // call ordering during rapid cell reconfiguration or reuse).
        if resultSectionTitle == nil || argsView == nil {
            assertionFailure("ensureResultView: expected ensureResultSectionTitle to be called first")
            if argsView == nil {
                _ = ensureArgsView()
            }
            if resultSectionTitle == nil {
                _ = ensureResultSectionTitle(theme: lastConfiguredTheme ?? CustomizableTheme.light())
            }
        }
        guard let rt = resultSectionTitle else {
            // Should never reach here after the above, but return a detached view
            // rather than crashing in production.
            let v = NativeMarkdownView()
            resultView = v
            return v
        }
        let v = NativeMarkdownView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.onHeightChanged = { [weak self] in self?.applyHeight() }
        contentContainer.addSubview(v)

        contentBottomToArgs?.isActive = false
        let pinResult = contentContainer.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        pinResult.isActive = true
        contentBottomToResult = pinResult

        let topToTitle = v.topAnchor.constraint(equalTo: rt.bottomAnchor, constant: 4)
        topToTitle.isActive = true
        resultViewTopToTitle = topToTitle

        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: sectionInset),
            v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -sectionInset),
        ])
        resultView = v
        return v
    }

    /// removes result UI so the args section can own `contentContainer.bottom` without conflicting constraints
    private func applyToolDetailSectionHeading(to field: NSTextField, text: String, theme: any ThemeProtocol) {
        // An all-caps eyebrow: micro bold, opened up so the capitals stay legible.
        var attributes = theme.textAttributes(.micro, color: NSColor(theme.text.tertiary))
        attributes[.font] = theme.nsFont(.micro, weight: .bold)
        attributes[.kern] = 0.8
        field.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        ActivityInspectionStyle.label(field, property: "caption", theme: theme)
    }

    private func tearDownResultSection() {
        resultTitleTopToArgs?.isActive = false
        resultViewTopToTitle?.isActive = false
        resultTitleTopToArgs = nil
        resultViewTopToTitle = nil

        contentBottomToResult?.isActive = false
        contentBottomToResult = nil

        resultSectionTitle?.removeFromSuperview()
        resultSectionTitle = nil
        resultView?.removeFromSuperview()
        resultView = nil

        contentBottomToArgs?.isActive = true
    }

    /// Compact elapsed-time label: "320ms", "1.2s", or "1m 5s".
    private static func formatElapsed(_ t: TimeInterval) -> String {
        if t < 1 { return "\(Int((t * 1000).rounded()))ms" }
        if t < 60 { return String(format: "%.1fs", t) }
        return "\(Int(t) / 60)m \(Int(t) % 60)s"
    }

    /// A call is "running" while it has no result yet, or while a `speak` call
    /// is still playing its audio (matched via `TTSService.activeSpeakCallId`).
    private func isRunning(_ item: ToolCallItem) -> Bool {
        if item.unobservedResult != nil { return false }
        if item.result == nil { return true }
        return item.call.function.name == "speak"
            && TTSService.shared.activeSpeakCallId == item.call.id
    }

    /// Memoized `ToolEnvelope.isError` verdict. The sniff scans the whole result
    /// string, which gets expensive for large tool results, and the status color is
    /// recomputed on every cell (re)configure tick while a response streams. Results
    /// are write-once per call, so the verdict is keyed by (call id, byte length).
    private var cachedErrorVerdict: (callId: String, resultBytes: Int, isError: Bool)?

    /// Sniff the `search_source` classification a search tool stamped on its
    /// success payload. Substring scan (tolerating compact and pretty JSON)
    /// rather than a full decode — results can be large and this runs on the
    /// collapsed row only.
    static func searchSource(inToolResult result: String) -> String? {
        for source in ["premium", "custom", "free"] {
            if result.contains("\"search_source\":\"\(source)\"")
                || result.contains("\"search_source\" : \"\(source)\"")
                || result.contains("\"search_source\": \"\(source)\"")
            {
                return source
            }
        }
        return nil
    }

    private func isErrorResult(_ result: String, callId: String) -> Bool {
        let bytes = result.utf8.count
        if let cached = cachedErrorVerdict,
            cached.callId == callId, cached.resultBytes == bytes
        {
            return cached.isError
        }
        let verdict = ToolEnvelope.isError(result)
        cachedErrorVerdict = (callId, bytes, verdict)
        return verdict
    }

    /// Color of the node (icon + fill tint + ring), driven by run status:
    /// running = accent, error = red, success = green.
    private func nodeStatusColor(item: ToolCallItem, theme: any ThemeProtocol) -> NSColor {
        if item.unobservedResult != nil { return NSColor(theme.text.secondary) }
        if isRunning(item) { return NSColor(theme.status.info.foreground) }
        if let r = item.result, isErrorResult(r, callId: item.call.id) {
            return NSColor(theme.status.error.foreground)
        }
        return NSColor(theme.status.success.foreground)
    }

    /// Apply status colors to the node and, while running, shimmer the title
    /// (swapping `nameLabel` for the animated `shimmerLabel`). Idempotent —
    /// also called from the TTS observer so a `speak` call's running state
    /// flips when playback starts/stops.
    private func applyStatusAndShimmer() {
        guard let item = currentItem, let theme = lastConfiguredTheme else { return }
        let color = nodeStatusColor(item: item, theme: theme)
        // Suppress CALayer's default property actions. Setting `fillColor` /
        // `strokeColor` / `contentTintColor` otherwise spins up implicit
        // 0.25s fades on the disc and tint, which race the explicit ring /
        // icon / title appearance animations scheduled in
        // `playNodeAppearance` and read as the node glitch-popping in.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        categoryIcon.contentTintColor = color
        let backing = NSColor(theme.surface.raised)
        categoryBg.fillColor = (backing.blended(withFraction: 0.14, of: color) ?? backing).cgColor
        categoryBg.strokeColor = (backing.blended(withFraction: 0.55, of: color) ?? color).cgColor
        CATransaction.commit()

        if isRunning(item) {
            let progress = MCPToolProgressRegistry.shared.message(for: item.call.id)
            let titleTracking = theme.assignedTracking(ActivityInspectionStyle.key + "label")
            let titleLineHeight: CGFloat? = theme.assignedLineHeight(ActivityInspectionStyle.key + "label", fallback: 18)
            shimmerLabel.configure(
                text: progress.map { "\(runningTitle) · \($0)" } ?? runningTitle,
                font: theme.assignedNativeFont(ActivityInspectionStyle.key + "label", fallback: nameLabel.font ?? theme.nsFont(.caption, weight: .semibold)),
                baseColor: NSColor(theme.text.tertiary),
                highlightColor: NSColor(theme.text.primary),
                tracking: titleTracking,
                lineHeight: titleLineHeight
            )
            nameLabel.isHidden = true
            shimmerLabel.isHidden = false
            shimmerLabel.start()
        } else {
            shimmerLabel.stop()
            shimmerLabel.isHidden = true
            nameLabel.isHidden = false
        }
        applyHeaderLinkPins()
    }

    /// Reveals a freshly appearing node as a staged sequence — the ring traces
    /// in clockwise, then the glyph settles, then the title fades in — so the
    /// node reads as "building itself" in step with the drawn-in rail. `delay`
    /// is when the reveal starts (for an appended node, just after its rail arrives).
    ///
    /// Purely presentational: model values stay at rest and `fillMode = .backwards`
    /// holds each stage hidden until its begin time, so there's no pre-flash and
    /// the per-token reconfigures that follow can't disturb an in-flight reveal.
    private func playNodeAppearance(beginAt begin: CFTimeInterval) {
        let ringDuration = TimelineNodeView.ringDrawDuration
        let iconDuration: CFTimeInterval = 0.20
        let titleDuration: CFTimeInterval = 0.24

        // Strict sequencing: rail (already done by `begin`) → ring →
        // icon → title, each waiting for the previous to fully complete.
        // The earlier overlap (icon at ring*0.75, title 0.16s after that)
        // read as "rushing" — stages stepped on each other instead of
        // letting the eye track one element at a time.
        let iconBegin = begin + ringDuration
        let titleBegin = iconBegin + iconDuration

        // 1) Ring traces in clockwise (the disc fill fades in alongside it).
        // Passing the absolute begin time (rather than a relative delay)
        // guarantees the ring's begin matches the icon/title begin even
        // if the node's layout pass is deferred a frame.
        categoryBg.drawRing(beginAt: begin)

        // 2) Glyph settles in — subtle fade + slight scale — after the ring.
        // `fillMode = .backwards` is set on both the group AND each child
        // so the layer reliably presents `fromValue` (opacity 0, scaled
        // 0.6) before `beginTime` regardless of CAAnimationGroup-vs-child
        // fillMode inheritance quirks.
        if let iconLayer = categoryIcon.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.fillMode = .backwards
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.6
            scale.toValue = 1.0
            scale.fillMode = .backwards
            let group = CAAnimationGroup()
            group.animations = [fade, scale]
            group.duration = iconDuration
            group.beginTime = iconBegin
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            iconLayer.add(group, forKey: "icon.appear")
        }

        // 3) Title (shimmer while running) fades + slides in last.
        let titleView: NSView = shimmerLabel.isHidden ? nameLabel : shimmerLabel
        if let titleLayer = titleView.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.fillMode = .backwards
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = -8.0
            slide.toValue = 0.0
            slide.fillMode = .backwards
            let group = CAAnimationGroup()
            group.animations = [fade, slide]
            group.duration = titleDuration
            group.beginTime = titleBegin
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            titleLayer.add(group, forKey: "title.appear")
        }
    }

    private func updateChevron(expanded: Bool, animated: Bool) {
        // Swap the symbol instead of rotating the layer: table-cell relayout
        // resets layer transforms, leaving an expanded row with a right-
        // pointing chevron (mirrors NativeFileDiffView's collapse chevron).
        // The down state is the right chevron rotated (not chevron.down, a
        // differently-proportioned glyph) so both states are the same size.
        chevron.image =
            expanded
            ? SymbolImageCache.rotatedDownChevron(pointSize: 10, weight: .semibold)
            : SymbolImageCache.image(
                "chevron.right", accessibilityDescription: nil, pointSize: 10, weight: .semibold)
    }

    @objc private func tapped() { onToggle?() }

    @objc private func openSearchSettings() {
        AppDelegate.shared?.showManagementWindow(initialTab: .search)
    }

    // MARK: - File changes link

    private func refreshFileChangesLink(expanded: Bool? = nil) {
        guard let item = currentItem, item.result != nil, !(expanded ?? isExpanded),
            !FileDiff.diffProducingToolNames.contains(item.call.function.name)
        else {
            setHeaderLink(fileChangesButton, visible: false)
            return
        }
        let callId = item.call.id
        guard fileChangeLookupCallId != callId else {
            applyFileChangesLink()
            return
        }
        fileChangeLookupCallId = callId
        Task { @MainActor [weak self] in
            let set = await FileChangeJournal.shared.changeSet(forToolCallId: callId)
            guard let self, self.currentItemId == callId else { return }
            self.fileChangeSet = set
            self.applyFileChangesLink()
        }
    }

    private func applyFileChangesLink() {
        guard let set = fileChangeSet, !isExpanded, openRunButton.isHidden, remedyButton.isHidden,
            let theme = lastConfiguredTheme,
            !set.entries.isEmpty || set.status == .untracked
        else {
            setHeaderLink(fileChangesButton, visible: false)
            return
        }
        let count = set.entries.count
        var title: String
        switch set.status {
        case .untracked: title = L("Changes not tracked")
        default: title = count == 1 ? L("1 file changed") : L("\(count) files changed")
        }
        if set.status == .reverted { title += " · " + L("reverted") }
        setHeaderLinkTitle(
            fileChangesButton,
            NSAttributedString(
                string: title,
                attributes: [
                    .font: theme.nsFont(.footnote, weight: .semibold),
                    .foregroundColor: NSColor(set.status == .reverted ? theme.text.tertiary : theme.text.link),
                ]
            )
        )
        fileChangesButton.toolTip = L("Show in File Changes")
        setHeaderLink(fileChangesButton, visible: true)
    }

    @objc private func openFileChanges() {
        guard let set = fileChangeSet else { return }
        FileChangeSummaryStore.requestPanel(sessionId: set.sessionId, focusing: set.id)
    }

    // MARK: - Workflow run link

    private func refreshOpenRunLink() {
        refreshRemedyLink()
        guard let item = currentItem, WorkflowToolCall.isWorkflowCall(item.call.function.name), !isExpanded else {
            setHeaderLink(openRunButton, visible: false)
            openRunID = nil
            return
        }
        openRunID =
            item.result.flatMap(WorkflowToolCall.runID(inResult:))
            ?? WorkflowRunService.shared.liveRunID(forToolCall: item.call.id)
        guard openRunID != nil else {
            setHeaderLink(openRunButton, visible: false)
            // The run starts just after the row appears; look again shortly.
            if item.result == nil, openRunRetries < 10 {
                openRunRetries += 1
                let callId = item.call.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.currentItemId == callId else { return }
                    self.refreshOpenRunLink()
                }
            }
            return
        }
        let theme = lastConfiguredTheme
        setHeaderLinkTitle(
            openRunButton,
            NSAttributedString(
                string: L("Open Run"),
                attributes: [
                    .font: (theme ?? ThemeManager.shared.chatTheme).nsFont(.footnote, weight: .semibold),
                    .foregroundColor: theme.map { NSColor($0.text.link) } ?? NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
        )
        setHeaderLink(fileChangesButton, visible: false)
        setHeaderLink(openRunButton, visible: true)
    }

    @objc private func openWorkflowRun() {
        guard let openRunID, window != nil else { return }
        WorkflowRunLauncher.open(runID: openRunID)
    }

    /// A failed workflow call's fix, when the person can make it: a
    /// permission, a folder, search, or a model.
    private func refreshRemedyLink() {
        guard let item = currentItem, WorkflowToolCall.isWorkflowCall(item.call.function.name), !isExpanded,
            let result = item.result, let remedy = WorkflowFailureRemedy.from(result: result)
        else {
            workflowRemedy = nil
            setHeaderLink(remedyButton, visible: false)
            return
        }
        workflowRemedy = remedy
        let theme = lastConfiguredTheme ?? ThemeManager.shared.chatTheme
        setHeaderLinkTitle(
            remedyButton,
            NSAttributedString(
                string: remedy.title,
                attributes: [
                    .font: theme.nsFont(.footnote, weight: .semibold),
                    .foregroundColor: NSColor(theme.text.link),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
        )
        setHeaderLink(fileChangesButton, visible: false)
        setHeaderLink(remedyButton, visible: true)
    }

    @objc private func applyWorkflowRemedy() {
        workflowRemedy?.perform(over: window)
    }
}

//
//  NativeMarkdownView.swift
//  osaurus
//
//  Pure-AppKit markdown renderer for chat cells.
//  For content with no code blocks / images / math (the vast majority of streaming
//  paragraphs), renders directly into a SelectableNSTextView — zero NSHostingView.
//  For mixed-content segments each segment type gets its own native view.
//
//  Height lifecycle:
//  1. `configure()` sets text, optionally rebuilds attributed string.
//  2. `measuredHeight(for:)` calls layoutManager.usedRect for an exact height.
//  3. Coordinator caches the height and calls noteHeightOfRows only on delta > 2pt.
//

import AppKit
import Foundation

// MARK: - NativeMarkdownView

final class NativeMarkdownView: NSView {

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    nonisolated static func makeRemoteImageSession() -> URLSession {
        GlobalProxySettings.sharedSession()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let sub = super.hitTest(point) { return sub }
        // when the container is taller than the laid-out text (or timing leaves super.hitTest nil),
        // route into the text view so drags and clicks still start selection
        if let tv = textView {
            let pInTv = convert(point, to: tv)
            if let hit = tv.hitTest(pInTv) { return hit }
        }
        for entry in segmentViews.reversed() {
            let pInSeg = convert(point, to: entry.view)
            if let hit = entry.view.hitTest(pInSeg) { return hit }
        }
        if NSPointInRect(point, bounds) { return self }
        return nil
    }

    // MARK: Subviews

    /// Primary text view — used when all segments are plain text.
    private var textView: SelectableNSTextView?
    /// Per-segment views (code blocks, images, math blocks).
    private var segmentViews: [(view: NSView, key: String)] = []
    /// only used in mixed segment layout — needed for correct height (spacingBefore between segments).
    private var lastMixedSegments: [ContentSegment] = []
    /// Layout signature (segment ids + spacing, in order) of the constraint
    /// chain currently installed by `applyMixedSegments`. When the next pass
    /// produces the same signature — the common case while content streams
    /// into existing segments — the vertical chain is already correct and the
    /// teardown/re-pin is skipped, so steady-state streaming performs no
    /// constraint mutations at all.
    private var installedSegmentLayoutSignature: [String] = []
    private var heightConstraint: NSLayoutConstraint?

    // MARK: State

    private var coordinator = SelectableTextView.Coordinator()
    private let fader = TrailingTextFader()
    /// Blinking interpunct shown at the trailing edge of streaming text
    /// **only during quiet gaps** — when the SSE source has stopped
    /// emitting tokens for a moment but the stream is still alive. While
    /// text is actively being revealed, the cursor stays hidden so it
    /// doesn't race the moving text. Cleared when streaming ends.
    private var streamingCursor: StreamingCursorOverlay?
    /// Timestamp of the last text-storage mutation made while streaming.
    /// `nil` means we haven't received a streaming reveal yet.
    private var lastTextRevealAt: Date?
    /// Idle-check timer (~50ms) that flips the cursor on whenever
    /// `now - lastTextRevealAt > pauseThreshold`. Lives only while
    /// `isStreaming == true`.
    private var idleTimer: Timer?
    /// Captured at `enterStreamingMode` so `idleTick` doesn't need to
    /// re-resolve the theme on every tick.
    private var streamingCursorColor: NSColor?
    /// How long the stream must be silent before the cursor blinks on.
    /// 150ms is short enough that it appears during real network gaps
    /// (200-500ms typical) but long enough that brief sync hiccups don't
    /// flash it during a steady reveal.
    private static let cursorPauseThreshold: TimeInterval = 0.15
    private var lastText: String = ""
    private var lastBlocks: [SelectableTextBlock] = []
    private var lastWidth: CGFloat = 0
    private var lastThemeFingerprint: String = ""
    private var lastIsStreaming: Bool = false
    private var parseTask: Task<Void, Never>?
    /// Cell-supplied original -> redaction map. Re-applied via
    /// `RedactionHighlighter` after every textStorage edit on the
    /// pure-text path, the mixed-segment text path, and any nested
    /// `NativeMarkdownView` (math/image segments don't carry text).
    /// Empty dict short-circuits the highlighter, so the property
    /// has no perf cost in chats that never trigger the filter.
    private var redactionHighlights: [String: RedactionHighlight] = [:]
    /// Last set of applied highlight ranges, in textStorage
    /// coordinates. The hover controller reads this list (instead of
    /// re-scanning the storage) when picking the popover target.
    private(set) var appliedHighlightRanges: [AppliedRedactionRange] = []
    /// Highest text-storage location the highlighter has finished
    /// painting in the current text. Streaming deltas reuse this as
    /// the start of an incremental scan window so chunk N+1 only
    /// scans the appended tail (plus a small lookback to catch
    /// originals that straddle the boundary).
    /// Reset to 0 when:
    ///   * `redactionHighlights` changes (different key set ⇒ full
    ///     re-scan from the top),
    ///   * the storage is mutated NOT by append (configureWithBlocks
    ///     swaps the attributed string wholesale),
    ///   * the text view is rebuilt.
    private var redactionHighlightAppliedThrough: Int = 0
    /// Fingerprint of the last `redactionHighlights` dict so we can
    /// distinguish "same map, more text" (incremental safe) from
    /// "different map, must redo" (full apply).
    private var lastRedactionHighlightsHash: Int = 0
    /// Hover controller attached to `textView`. Created lazily the
    /// first time `redactionHighlights` becomes non-empty; reused
    /// across updates so the NSTrackingArea stays installed.
    private var hoverController: RedactionHoverController?
    /// cancels stale loads when segment id is reused with a new URL or view is removed
    private var imageLoadTasks: [String: (UUID, Task<Void, Never>)] = [:]
    /// Per-image height constraint, updated to match the loaded image's
    /// aspect ratio at the current layout width so wide banners render
    /// short/full-width instead of being letterboxed in a fixed-height box.
    private var imageHeightConstraints: [String: NSLayoutConstraint] = [:]
    /// width / height of each loaded image, keyed by segment id.
    private var imageAspectRatios: [String: CGFloat] = [:]
    /// Height used before an image loads, and the ceiling once it has.
    private static let imagePlaceholderHeight: CGFloat = 160
    private static let imageMaxHeight: CGFloat = 360
    /// invalid until first layout pass with positive width — drives remeasure in `layout()`
    private var lastLayoutWidthForHeight: CGFloat = -1
    /// avoids re-entrant `measuredHeight` when `layoutSubtreeIfNeeded` runs during tool-row expand (same instance)
    private var measurementDepth = 0

    // MARK: Callback

    /// Called after the attributed string is set and height can be measured.
    var onHeightChanged: (() -> Void)?

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        // small placeholder until configure() runs measuredHeight (pure text path used to skip that and left 100pt)
        let hc = heightAnchor.constraint(equalToConstant: 8)
        hc.isActive = true
        heightConstraint = hc
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // first `measuredHeight` often runs before `bounds.width` exists; remeasure once width is real
        // so row height and text wrapping match (avoids clipped last line + trailing edge mismatch).
        let w = bounds.width
        guard textView != nil, w > 0.5 else { return }
        if streamingCursor != nil {
            repositionStreamingCursor()
        }
        guard abs(w - lastLayoutWidthForHeight) > 0.5 else { return }
        lastLayoutWidthForHeight = w
        let before = heightConstraint?.constant ?? 0
        let newH = measuredHeight(for: lastWidth)
        if abs(newH - before) > 0.5 {
            onHeightChanged?()
        }
    }

    // provide intrinsic content size based on height constraint
    override var intrinsicContentSize: NSSize {
        let height = heightConstraint?.constant ?? 8
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: Configure (text-based entry point)

    /// Set the cell's current original -> placeholder map. Stored
    /// on the view so streaming updates re-apply the highlighter
    /// pass on every textStorage edit. Cell layer also forwards
    /// this into nested `NativeMarkdownView`s via the mixed-segment
    /// path. Idempotent — re-setting the same dict triggers a
    /// re-paint, which is harmless because the highlighter is
    /// keyed on character ranges.
    func setRedactionHighlights(
        _ highlights: [String: RedactionHighlight],
        theme: any ThemeProtocol
    ) {
        let changed = highlights != redactionHighlights
        redactionHighlights = highlights
        if changed || !highlights.isEmpty {
            applyRedactionHighlightsIfNeeded(theme: theme)
        }
        // Propagate to mixed-segment children so a code/text/image
        // assistant turn highlights uniformly across all segments.
        for entry in segmentViews {
            if let child = entry.view as? NativeMarkdownView {
                child.setRedactionHighlights(highlights, theme: theme)
            }
        }
    }

    /// Re-paint highlights on the current textStorage. Called from
    /// `setRedactionHighlights` and from every place we mutate
    /// `textStorage` (pure text + configureWithBlocks paths).
    ///
    /// Uses the incremental highlighter path when the set of
    /// `redactionHighlights` is unchanged from the previous call
    /// AND the storage has only grown (typical streaming delta
    /// shape — `setAttributedString` calls in the wholesale path
    /// reset the cursor via `resetIncrementalHighlightCursor`).
    /// Cross-painted state is detected by reading the existing
    /// `.redactionPlaceholder` attribute runs, so a partial scan
    /// can't double-paint a range.
    private func applyRedactionHighlightsIfNeeded(theme: any ThemeProtocol) {
        guard let tv = textView, let storage = tv.textStorage else {
            appliedHighlightRanges = []
            redactionHighlightAppliedThrough = 0
            return
        }
        if redactionHighlights.isEmpty {
            appliedHighlightRanges = []
            redactionHighlightAppliedThrough = 0
            lastRedactionHighlightsHash = 0
            hoverController?.detach()
            hoverController = nil
            return
        }
        let accent = NSColor(theme.accentColor)
        let dictHash = highlightsFingerprint(redactionHighlights)
        let canIncrement =
            dictHash == lastRedactionHighlightsHash
            && redactionHighlightAppliedThrough > 0
            && redactionHighlightAppliedThrough <= storage.length

        let applied: [AppliedRedactionRange]
        if canIncrement {
            let delta = RedactionHighlighter.applyIncremental(
                on: storage,
                appliedThrough: redactionHighlightAppliedThrough,
                highlights: redactionHighlights,
                accentColor: accent,
                a11yLabelBuilder: { highlight in
                    Self.accessibilityLabel(for: highlight)
                }
            )
            applied = appliedHighlightRanges + delta
        } else {
            applied = RedactionHighlighter.apply(
                on: storage,
                highlights: redactionHighlights,
                accentColor: accent,
                a11yLabelBuilder: { highlight in
                    Self.accessibilityLabel(for: highlight)
                }
            )
        }
        appliedHighlightRanges = applied
        redactionHighlightAppliedThrough = storage.length
        lastRedactionHighlightsHash = dictHash

        if hoverController == nil {
            hoverController = RedactionHoverController()
        }
        hoverController?.attach(to: tv, theme: theme, ranges: applied)
    }

    /// Cheap hash so we can detect a change in the highlight dict
    /// across two calls. We can't use `Dictionary.hashValue` because
    /// it isn't stable across launches (Foundation seeds it), but
    /// any process-stable hash is fine here — we only compare two
    /// values inside one view's lifetime.
    private func highlightsFingerprint(_ dict: [String: RedactionHighlight]) -> Int {
        var hasher = Hasher()
        hasher.combine(dict.count)
        for key in dict.keys.sorted() {
            hasher.combine(key)
            if let value = dict[key] {
                hasher.combine(value.placeholderToken)
                hasher.combine(value.direction.rawValue)
            }
        }
        return hasher.finalize()
    }

    /// Drop the incremental cursor so the next
    /// `applyRedactionHighlightsIfNeeded` re-scans the whole
    /// storage. Call this whenever the storage is mutated NOT by
    /// append (block re-layout, full replace).
    private func resetIncrementalHighlightCursor() {
        redactionHighlightAppliedThrough = 0
        appliedHighlightRanges = []
    }

    /// Localized a11y label for VoiceOver. Outbound: "Redacted before
    /// sending. Sent to cloud as [TOKEN]". Inbound: "Restored from
    /// [TOKEN]". Falls back to the placeholder token when the
    /// xcstrings catalog is missing.
    private static func accessibilityLabel(for highlight: RedactionHighlight) -> String {
        let key: String
        switch highlight.direction {
        case .outbound: key = "privacy.highlight.a11y.outbound"
        case .inbound: key = "privacy.highlight.a11y.inbound"
        case .preview: key = "privacy.highlight.a11y.preview"
        }
        let format = String(localized: String.LocalizationValue(key), bundle: .module)
        if format == key { return highlight.placeholderToken }
        return String(format: format, highlight.placeholderToken)
    }

    func configure(
        text: String,
        width: CGFloat,
        theme: any ThemeProtocol,
        cacheKey: String?,
        isStreaming: Bool
    ) {
        ChatPerfTrace.shared.count("markdown.configure.called")
        let themeFingerprint = makeThemeFingerprint(theme)
        let textChanged = text != lastText
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = themeFingerprint != lastThemeFingerprint
        let streamingChanged = isStreaming != lastIsStreaming

        // must re-run layout when streaming ends even if text matches the last delta — otherwise
        // configure() returns early, measuredHeight/onHeightChanged never fire, height cache is
        // empty, and the table falls back to NativeCellHeightEstimator (too small).
        guard textChanged || widthChanged || themeChanged || streamingChanged else {
            ChatPerfTrace.shared.count("markdown.configure.noOp")
            return
        }
        ChatPerfTrace.shared.count("markdown.configure.applied")

        lastWidth = width
        lastThemeFingerprint = themeFingerprint
        lastIsStreaming = isStreaming

        // hide raw inline delimiters that haven't received their closer yet
        let parseInput = StreamingMarkdownBalancer.balance(text)

        if let cached = ThreadCache.shared.markdown(for: parseInput) {
            applySegments(
                cached.segments,
                cacheKey: cacheKey,
                textChanged: textChanged || themeChanged,
                widthChanged: widthChanged,
                width: width,
                theme: theme,
                isStreaming: isStreaming
            )
            lastText = text
            return
        }

        let blocks = parseBlocks(parseInput)
        let segs = groupBlocksIntoSegments(blocks)
        ThreadCache.shared.setMarkdown(blocks: blocks, segments: segs, for: parseInput)
        applySegments(
            segs,
            cacheKey: cacheKey,
            textChanged: true,
            widthChanged: false,
            width: width,
            theme: theme,
            isStreaming: isStreaming
        )
        lastText = text
    }

    // MARK: Configure (pre-parsed blocks entry point, used by applyMixedSegments)

    func configureWithBlocks(
        _ blocks: [SelectableTextBlock],
        width: CGFloat,
        theme: any ThemeProtocol,
        cacheKey: String?,
        isStreaming: Bool = false
    ) {
        let themeFingerprint = makeThemeFingerprint(theme)
        let textChanged = blocks != lastBlocks
        let widthChanged = abs(width - lastWidth) > 0.5
        let themeChanged = themeFingerprint != lastThemeFingerprint
        // A demoted text segment (was the last/streaming segment, now followed
        // by newer text after a code block) keeps the same blocks but flips to
        // `isStreaming: false`. Without tracking this we'd early-return and skip
        // the `exitStreamingMode()` below, leaving its cursor + idle timer alive
        // — the "two blinking cursors at once" bug.
        let streamingChanged = isStreaming != lastIsStreaming

        guard textChanged || widthChanged || themeChanged || streamingChanged else { return }

        lastWidth = width
        lastThemeFingerprint = themeFingerprint
        lastIsStreaming = isStreaming

        removeSegmentViews()
        let tv = ensureTextView(width: width, theme: theme)

        updateTextViewColors(tv, theme: theme)

        if textChanged || widthChanged || themeChanged {
            coordinator.cacheKey = cacheKey
            let stv = SelectableTextView(blocks: blocks, baseWidth: width, theme: theme)
            let incrementalPath = !widthChanged && !lastBlocks.isEmpty
            if incrementalPath {
                stv.updateTextStorageIncrementally(
                    textView: tv,
                    oldBlocks: lastBlocks,
                    newBlocks: blocks,
                    coordinator: coordinator
                )
            } else {
                tv.textStorage?.setAttributedString(stv.buildAttributedString(coordinator: coordinator))
                resetIncrementalHighlightCursor()
            }
            lastBlocks = blocks
            updateFader(textView: tv, isStreaming: isStreaming, incrementalPath: incrementalPath)
            // incremental path sets a bounded tail rect internally. only the
            // full rebuild path needs to mark the whole view dirty
            if !incrementalPath {
                tv.needsDisplay = true
            }
            applyRedactionHighlightsIfNeeded(theme: theme)
            if isStreaming && textChanged {
                notifyTextReveal()
            }
        }

        // nested NativeMarkdownView (text segment inside mixed content) must update heightConstraint
        // or the default 100pt sticks and following segments overlap the text.
        _ = measuredHeight(for: width)
        if isStreaming {
            enterStreamingMode(theme: theme)
        } else {
            exitStreamingMode()
        }
        onHeightChanged?()
    }

    // MARK: Height

    /// Width for `NSLayoutManager` measurement — use the *narrowest* positive candidate so we never
    /// underestimate line count (stale configure width alone can be wider than laid-out bounds → too-short height).
    private func measurementContentWidth(fallbackWidth: CGFloat) -> CGFloat {
        var candidates: [CGFloat] = []
        if bounds.width > 0.5 { candidates.append(bounds.width) }
        if let tv = textView, tv.bounds.width > 0.5 { candidates.append(tv.bounds.width) }
        if fallbackWidth > 0.5 { candidates.append(fallbackWidth) }
        guard !candidates.isEmpty else { return max(fallbackWidth, 1) }
        return candidates.min() ?? max(fallbackWidth, 1)
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        if measurementDepth > 0 {
            return heightConstraint?.constant ?? 20
        }
        measurementDepth += 1
        defer { measurementDepth -= 1 }

        if let tv = textView {
            // widthTracksTextView syncs the container to the text view; before first layout, bounds can
            // be 0 and usedRect height is far too small (clipped text). For measurement only, apply an
            // explicit width (laid-out bounds when available, else configure width). do not call
            // layoutSubtreeIfNeeded() — it can re-enter during subview enumeration (tool row tap).
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return 0 }
            let measureW = measurementContentWidth(fallbackWidth: width)
            let wasTracking = tc.widthTracksTextView
            tc.widthTracksTextView = false
            tc.containerSize = NSSize(width: measureW, height: CGFloat.greatestFiniteMagnitude)
            defer { tc.widthTracksTextView = wasTracking }
            lm.ensureLayout(for: tc)
            // +8: text view top/bottom inset (4+4) to superview; +4: slack for font leading / subpixel glyph bounds
            let h = ceil(lm.usedRect(for: tc).height) + 8 + 4
            heightConstraint?.constant = max(h, 8)  // ensure minimum height
            invalidateIntrinsicContentSize()
            return max(h, 8)
        }

        // multi segment: match applyMixedSegments — 4pt top, then each segment's spacingBefore + height.
        var totalH: CGFloat = 4
        for seg in lastMixedSegments {
            guard let entry = segmentViews.first(where: { $0.key == seg.id }) else { continue }
            totalH += seg.spacingBefore
            totalH += measureMixedSegmentHeight(entry.view, key: entry.key, width: width)
        }
        totalH += 4
        totalH = max(totalH, 20)

        heightConstraint?.constant = totalH
        invalidateIntrinsicContentSize()
        return totalH
    }

    private func measureMixedSegmentHeight(_ view: NSView, key: String, width: CGFloat) -> CGFloat {
        if let nmv = view as? NativeMarkdownView {
            return nmv.measuredHeight(for: width)
        }
        if let cb = view as? NativeCodeBlockView {
            return cb.measureHeightForOuterWidth(width)
        }
        if let tb = view as? NativeMarkdownTableView {
            return tb.measuredHeight()
        }
        if view is NSImageView {
            return imageHeight(forSegmentId: key, width: width)
        }
        if let field = view as? NSTextField {
            if width > 0.5 {
                field.preferredMaxLayoutWidth = width
            }
            let h = field.attributedStringValue.boundingRect(
                with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
            if h.isFinite, h > 0 { return ceil(h) + 4 }
            let ic = field.intrinsicContentSize.height
            if ic > 0 && ic != NSView.noIntrinsicMetric { return ic }
            return 24
        }
        let ic = view.intrinsicContentSize.height
        if ic > 0 && ic != NSView.noIntrinsicMetric { return ic }
        return max(view.bounds.height, 0)
    }

    // MARK: - Private: Unified Segment Dispatch

    private func applySegments(
        _ segments: [ContentSegment],
        cacheKey: String?,
        textChanged: Bool,
        widthChanged: Bool,
        width: CGFloat,
        theme: any ThemeProtocol,
        isStreaming: Bool
    ) {
        let isPureText = segments.allSatisfy {
            if case .textGroup = $0.kind { return true }; return false
        }

        if isPureText {
            // collect all text blocks from every text-group segment
            var allBlocks: [SelectableTextBlock] = []
            for seg in segments {
                if case .textGroup(let blocks) = seg.kind { allBlocks.append(contentsOf: blocks) }
            }
            applyPureTextBlocks(
                allBlocks,
                cacheKey: cacheKey,
                textChanged: textChanged,
                widthChanged: widthChanged,
                width: width,
                theme: theme,
                isStreaming: isStreaming
            )
        } else {
            applyMixedSegments(segments, cacheKey: cacheKey, width: width, theme: theme, isStreaming: isStreaming)
        }
    }

    // MARK: - Private: Pure Text Path

    private func applyPureTextBlocks(
        _ blocks: [SelectableTextBlock],
        cacheKey: String?,
        textChanged: Bool,
        widthChanged: Bool,
        width: CGFloat,
        theme: any ThemeProtocol,
        isStreaming: Bool
    ) {
        removeSegmentViews()

        let tv = ensureTextView(width: width, theme: theme)

        updateTextViewColors(tv, theme: theme)

        if textChanged || widthChanged {
            coordinator.cacheKey = cacheKey
            let stv = SelectableTextView(blocks: blocks, baseWidth: width, theme: theme)
            let incrementalPath = !widthChanged && !lastBlocks.isEmpty
            if incrementalPath {
                stv.updateTextStorageIncrementally(
                    textView: tv,
                    oldBlocks: lastBlocks,
                    newBlocks: blocks,
                    coordinator: coordinator
                )
            } else {
                tv.textStorage?.setAttributedString(stv.buildAttributedString(coordinator: coordinator))
                resetIncrementalHighlightCursor()
            }
            lastBlocks = blocks
            updateFader(textView: tv, isStreaming: isStreaming, incrementalPath: incrementalPath)
            if !incrementalPath {
                tv.needsDisplay = true
            }
            applyRedactionHighlightsIfNeeded(theme: theme)
            if isStreaming && textChanged {
                notifyTextReveal()
            }
        }

        // must update heightConstraint — init leaves 100pt; otherwise user bubbles stay artificially tall
        _ = measuredHeight(for: width)
        if isStreaming {
            enterStreamingMode(theme: theme)
        } else {
            exitStreamingMode()
        }
        onHeightChanged?()
    }

    /// Drives the streaming fade. Called after every textStorage edit on the
    /// pure-text path and the mixed-segment text path.
    private func updateFader(textView: SelectableNSTextView, isStreaming: Bool, incrementalPath: Bool) {
        if !isStreaming {
            // Streaming ended (or never started for this update) — settle any in-flight fade.
            fader.snap()
            return
        }
        if incrementalPath {
            // Real append: animate the diff.
            fader.recordAppend(textView: textView)
        } else {
            // Full rebuild (first paint, width change, theme change)
            fader.resync(textView: textView)
        }
    }

    // MARK: - Private: Mixed Segment Path

    private func applyMixedSegments(
        _ segments: [ContentSegment],
        cacheKey: String?,
        width: CGFloat,
        theme: any ThemeProtocol,
        isStreaming: Bool
    ) {
        removeTextView()
        lastMixedSegments = segments

        let requiredKeys = segments.map { $0.id }
        // remove stale segment views
        segmentViews = segmentViews.filter { entry in
            if requiredKeys.contains(entry.key) { return true }
            cancelImageLoadTask(forSegmentId: entry.key)
            imageHeightConstraints.removeValue(forKey: entry.key)
            imageAspectRatios.removeValue(forKey: entry.key)
            entry.view.removeFromSuperview()
            return false
        }

        // When the segment structure (ids, order, spacing) matches what's already
        // installed and every segment view survived the stale sweep, the vertical
        // chain is correct as-is — only segment *content* changed. Skipping the
        // teardown/re-pin keeps streaming ticks from churning the window's layout
        // engine (the AutoLayout solve is the dominant main-thread cost while a
        // long code-heavy reply streams).
        let layoutSignature = segments.map { "\($0.id)|\($0.spacingBefore)" }
        let structureUnchanged =
            layoutSignature == installedSegmentLayoutSignature
            && segmentViews.map { $0.key } == requiredKeys

        if !structureUnchanged {
            // this prevents conflicts as segments move or get pinned/unpinned from bottom.
            let subviewPointers = Set(subviews.map { Unmanaged.passUnretained($0).toOpaque() })
            let verticalConstraints = constraints.filter { c in
                if c.firstAttribute == .top || c.firstAttribute == .bottom {
                    if let first = c.firstItem as? NSView,
                        subviewPointers.contains(Unmanaged.passUnretained(first).toOpaque())
                    {
                        return true
                    }
                }
                return false
            }
            removeConstraints(verticalConstraints)
        }
        installedSegmentLayoutSignature = layoutSignature

        var prevAnchor: NSLayoutYAxisAnchor = topAnchor
        var prevOffset: CGFloat = 4

        // The streaming cursor is a text-view overlay, so it can only live on a
        // `.textGroup` segment — and only on the *trailing* one. If the document
        // currently ends in a non-text segment (a code block / table / image /
        // math that is still streaming), the preceding text is already settled;
        // parking the cursor there would put it ahead of the segment that's
        // actually growing. In that case no text segment blinks.
        let lastTextSegmentId: String? = {
            guard case .textGroup = segments.last?.kind else { return nil }
            return segments.last?.id
        }()

        for seg in segments {
            let existingEntry = segmentViews.first(where: { $0.key == seg.id })
            let segView: NSView

            switch seg.kind {
            case .textGroup(let blocks):
                // use configureWithBlocks — passes exact blocks, no re-parsing
                let mv: NativeMarkdownView
                if let existing = existingEntry?.view as? NativeMarkdownView {
                    mv = existing
                } else {
                    mv = NativeMarkdownView()
                    mv.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(mv)
                }
                mv.onHeightChanged = { [weak self] in
                    self?.onHeightChanged?()
                }
                let segIsStreaming = isStreaming && (seg.id == lastTextSegmentId)
                mv.configureWithBlocks(
                    blocks,
                    width: width,
                    theme: theme,
                    cacheKey: cacheKey,
                    isStreaming: segIsStreaming
                )
                segView = mv

            case .codeBlock(let code, let language):
                let cv: NativeCodeBlockView
                if let existing = existingEntry?.view as? NativeCodeBlockView {
                    cv = existing
                } else {
                    cv = NativeCodeBlockView()
                    cv.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(cv)
                }
                cv.onHeightChanged = { [weak self] in
                    self?.onHeightChanged?()
                }
                cv.configure(code: code, language: language, width: width, theme: theme)
                segView = cv

            case .image(let urlString, _):
                let iv: NSImageView
                if let existing = existingEntry?.view as? NSImageView {
                    iv = existing
                } else {
                    iv = MarkdownSegmentImageView()
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    iv.imageScaling = .scaleProportionallyUpOrDown
                    iv.imageAlignment = .alignLeft
                    iv.wantsLayer = true
                    iv.layer?.cornerRadius = 6
                    iv.layer?.masksToBounds = true
                    // Don't let the image's intrinsic size fight the pinned
                    // width/height constraints (a 1500px banner must not blow
                    // out the layout).
                    iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    iv.setContentHuggingPriority(.defaultLow, for: .vertical)
                    iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                    let hc = iv.heightAnchor.constraint(
                        equalToConstant: Self.imagePlaceholderHeight
                    )
                    hc.isActive = true
                    imageHeightConstraints[seg.id] = hc
                    addSubview(iv)
                }
                applyImageHeight(segmentId: seg.id, width: width)
                scheduleImageLoad(segmentId: seg.id, urlString: urlString, imageView: iv)
                segView = iv

            case .math:
                let lv: NSTextField
                if let existing = existingEntry?.view as? NSTextField {
                    lv = existing
                } else {
                    lv = NSTextField(labelWithString: "")
                    lv.translatesAutoresizingMaskIntoConstraints = false
                    lv.isEditable = false; lv.isSelectable = true; lv.isBordered = false; lv.drawsBackground = false
                    lv.font = NSFont.monospacedSystemFont(ofSize: CGFloat(theme.codeSize), weight: .regular)
                    lv.textColor = NSColor(theme.primaryText)
                    lv.maximumNumberOfLines = 0
                    lv.lineBreakMode = .byWordWrapping
                    addSubview(lv)
                }
                if case .math(let latex) = seg.kind { lv.stringValue = latex }
                segView = lv

            case .table(let headers, let rows):
                let tv: NativeMarkdownTableView
                if let existing = existingEntry?.view as? NativeMarkdownTableView {
                    tv = existing
                } else {
                    tv = NativeMarkdownTableView()
                    addSubview(tv)
                }
                tv.onHeightChanged = { [weak self] in
                    self?.onHeightChanged?()
                }
                tv.configure(headers: headers, rows: rows, width: width, theme: theme)
                segView = tv
            }

            // Horizontal pins are created once, when the segment view first joins
            // the hierarchy. The teardown above only strips the vertical chain, so
            // re-activating leading/trailing here on every pass would pile duplicate
            // constraints into the window's layout engine on each streaming tick,
            // progressively slowing every subsequent layout solve to a crawl.
            if existingEntry == nil {
                NSLayoutConstraint.activate([
                    segView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    segView.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
            }
            if !structureUnchanged {
                NSLayoutConstraint.activate([
                    segView.topAnchor.constraint(equalTo: prevAnchor, constant: prevOffset + seg.spacingBefore)
                ])
            }

            if existingEntry == nil {
                segmentViews.append((view: segView, key: seg.id))
            }

            prevAnchor = segView.bottomAnchor
            prevOffset = 0
        }
        _ = measuredHeight(for: width)
        onHeightChanged?()
    }

    // MARK: - Private: Text View

    private func ensureTextView(width: CGFloat, theme: any ThemeProtocol) -> SelectableNSTextView {
        if let tv = textView { return tv }

        let tv = SelectableNSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        // disable idle-time text features (spell/grammar/link/data/substitution).
        // These run against textStorage on every edit which is pure overhead for read-only
        // streaming model output
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        // fixed container width + stale configure() width makes lines wrap too wide vs visible bounds
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.translatesAutoresizingMaskIntoConstraints = false

        updateTextViewColors(tv, theme: theme)

        addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: trailingAnchor),
            tv.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            tv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        self.textView = tv
        return tv
    }

    private func updateTextViewColors(_ tv: SelectableNSTextView, theme: any ThemeProtocol) {
        tv.isEditable = false
        tv.isSelectable = true
        tv.selectedTextAttributes = [.backgroundColor: NSColor(theme.selectionColor)]
        tv.insertionPointColor = NSColor(theme.cursorColor)
        tv.accentColor = NSColor(theme.accentColor)
        tv.blockquoteBarColor = NSColor(theme.accentColor).withAlphaComponent(0.6)
        tv.secondaryBackgroundColor = NSColor(theme.secondaryBackground)
    }

    private func scheduleBackgroundParse(text: String) {
        parseTask?.cancel()
        parseTask = Task {
            let (blocks, segs) = await Task.detached(priority: .userInitiated) {
                let b = parseBlocks(text)
                return (b, groupBlocksIntoSegments(b))
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                ThreadCache.shared.setMarkdown(blocks: blocks, segments: segs, for: text)
            }
        }
    }

    // MARK: - Cleanup

    /// Deterministic teardown for the owning cell's `removeAllContentViews`.
    /// AppKit recycles message cells aggressively and a `NativeMarkdownView`
    /// can linger in an autorelease pool after `removeFromSuperview`, so
    /// relying on dealloc to detach the redaction hover controller (and
    /// clear the text view's `.mouseMoved` tracking flag) is too late —
    /// exactly the teardown window where the launch SIGABRT was observed.
    /// Calling this before dropping the view releases the hover area +
    /// closures synchronously.
    func tearDownForReuse() {
        removeTextView()
    }

    private func removeTextView() {
        fader.reset()
        hoverController?.detach()
        hoverController = nil
        appliedHighlightRanges = []
        redactionHighlightAppliedThrough = 0
        lastRedactionHighlightsHash = 0
        textView?.removeFromSuperview()
        textView = nil
        // Tear down the streaming cursor + idle timer if they were
        // attached to this textView. Re-arms cleanly if streaming resumes
        // (mixed-segment ↔ pure-text transitions).
        exitStreamingMode()
        lastBlocks = []
        lastLayoutWidthForHeight = -1
    }

    private func removeSegmentViews() {
        cancelAllImageLoadTasks()
        for entry in segmentViews { entry.view.removeFromSuperview() }
        segmentViews = []
        lastMixedSegments = []
        installedSegmentLayoutSignature = []
        imageHeightConstraints.removeAll()
        imageAspectRatios.removeAll()
    }

    private func cancelAllImageLoadTasks() {
        for (_, (_, t)) in imageLoadTasks { t.cancel() }
        imageLoadTasks.removeAll()
    }

    private func cancelImageLoadTask(forSegmentId id: String) {
        if let (_, t) = imageLoadTasks[id] { t.cancel() }
        imageLoadTasks[id] = nil
    }

    /// loads image data off the main thread; ignores stale completions when URL or layout changes
    private func scheduleImageLoad(segmentId: String, urlString: String, imageView: NSImageView) {
        cancelImageLoadTask(forSegmentId: segmentId)
        guard let url = URL(string: urlString) else {
            imageView.image = nil
            return
        }

        let token = UUID()
        let task = Task { [weak self, weak imageView] in
            let data: Data?
            if url.isFileURL {
                let fileURL = url
                data = try? await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: fileURL)
                }.value
            } else {
                do {
                    let (d, _) = try await Self.makeRemoteImageSession().data(from: url)
                    data = d
                } catch {
                    data = nil
                }
            }
            guard !Task.isCancelled else { return }
            guard let data, let img = NSImage(data: data) else {
                await MainActor.run {
                    guard let self, let imageView else { return }
                    guard self.imageLoadTasks[segmentId]?.0 == token else { return }
                    guard self.segmentViews.contains(where: { $0.key == segmentId && $0.view === imageView }) else {
                        return
                    }
                    imageView.image = nil
                    self.imageLoadTasks.removeValue(forKey: segmentId)
                }
                return
            }
            await MainActor.run {
                guard let self, let imageView else { return }
                guard self.imageLoadTasks[segmentId]?.0 == token else { return }
                guard self.segmentViews.contains(where: { $0.key == segmentId && $0.view === imageView }) else {
                    return
                }
                imageView.image = img
                self.imageLoadTasks.removeValue(forKey: segmentId)
                let size = img.size
                if size.width > 0, size.height > 0 {
                    self.imageAspectRatios[segmentId] = size.width / size.height
                }
                self.applyImageHeight(segmentId: segmentId, width: self.lastWidth)
                self.onHeightChanged?()
            }
        }
        imageLoadTasks[segmentId] = (token, task)
    }

    /// Height an image segment should occupy at `width`: the aspect-correct
    /// height once the image has loaded (capped), otherwise a placeholder.
    private func imageHeight(forSegmentId id: String, width: CGFloat) -> CGFloat {
        guard let aspect = imageAspectRatios[id], aspect > 0, width > 0.5 else {
            return Self.imagePlaceholderHeight
        }
        return min(Self.imageMaxHeight, max(1, width / aspect))
    }

    /// Sync an image segment's height constraint to `imageHeight(...)` and
    /// reposition its overlaid download button to the displayed image's right
    /// edge (the view is full-width while the image is left-aligned and scaled).
    private func applyImageHeight(segmentId: String, width: CGFloat) {
        guard let constraint = imageHeightConstraints[segmentId] else { return }
        let target = imageHeight(forSegmentId: segmentId, width: width)
        if abs(constraint.constant - target) > 0.5 {
            constraint.constant = target
        }
        if let view = segmentViews.first(where: { $0.key == segmentId })?.view
            as? MarkdownSegmentImageView
        {
            let displayedWidth: CGFloat
            if let aspect = imageAspectRatios[segmentId], aspect > 0 {
                displayedWidth = min(width, target * aspect)
            } else {
                displayedWidth = width
            }
            view.setImageRightEdge(displayedWidth)
        }
    }

    // MARK: - Theme Fingerprint

    private func makeThemeFingerprint(_ theme: any ThemeProtocol) -> String {
        "\(theme.primaryFontName)|\(theme.bodySize)|\(theme.codeSize)"
    }

    // MARK: - Streaming Cursor (interpunct)

    /// Enter "streaming" lifecycle: start the idle-check timer that flips
    /// the cursor on whenever tokens have been quiet for the threshold.
    /// Does **not** show the cursor itself — that's gated on the idle
    /// elapsed time, decided by `idleTick`.
    fileprivate func enterStreamingMode(theme: any ThemeProtocol) {
        streamingCursorColor = NSColor(theme.primaryText)
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.idleTick()
            }
        }
    }

    /// Exit "streaming" lifecycle: stop the idle timer, remove the cursor,
    /// and clear the reveal timestamp so a future stream starts fresh.
    fileprivate func exitStreamingMode() {
        idleTimer?.invalidate()
        idleTimer = nil
        lastTextRevealAt = nil
        streamingCursor?.removeFromSuperview()
        streamingCursor = nil
    }

    /// Called from the text-update paths when text storage actually
    /// changed during streaming. Stamps the reveal time and *removes*
    /// the cursor if it was visible — active reveal is the opposite of
    /// "still waiting."
    fileprivate func notifyTextReveal() {
        lastTextRevealAt = Date()
        if streamingCursor != nil {
            streamingCursor?.removeFromSuperview()
            streamingCursor = nil
        }
    }

    /// Idle-check tick. If the stream has been quiet long enough, show
    /// (or refresh) the cursor at the trailing edge. Otherwise ensure
    /// it's hidden.
    private func idleTick() {
        guard idleTimer != nil else { return }
        let elapsed: TimeInterval
        if let last = lastTextRevealAt {
            elapsed = Date().timeIntervalSince(last)
        } else {
            // Stream started, no token yet. Treat as paused so the user
            // sees the cursor while waiting for TTFT to elapse.
            elapsed = Self.cursorPauseThreshold + 1
        }
        if elapsed > Self.cursorPauseThreshold {
            installCursorIfNeeded()
            repositionStreamingCursor()
        } else {
            if streamingCursor != nil {
                streamingCursor?.removeFromSuperview()
                streamingCursor = nil
            }
        }
    }

    private func installCursorIfNeeded() {
        guard textView != nil, let color = streamingCursorColor else { return }
        if streamingCursor == nil {
            let cv = StreamingCursorOverlay()
            cv.updateColor(color)
            addSubview(cv)
            streamingCursor = cv
        } else {
            streamingCursor?.updateColor(color)
        }
    }

    /// Position the cursor frame to vertically align with the line that
    /// contains the last character of the text storage, with horizontal
    /// padding past the trailing glyph. Uses the line fragment's used
    /// rect (not `boundingRect(forGlyphRange:)`) so soft-wrapped
    /// trailing whitespace doesn't pull the cursor back to the previous
    /// line. Converts the top AND bottom of the line through
    /// `tv.convert(_:to:)` so it works whether the NSTextView is flipped
    /// or not — `frame.origin.y` in a non-flipped parent must be the
    /// **lower** of the two converted y values.
    fileprivate func repositionStreamingCursor() {
        guard let cursor = streamingCursor, let tv = textView else { return }
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)

        let storageLength = tv.textStorage?.length ?? 0
        let origin = tv.textContainerOrigin
        let font = tv.font ?? .systemFont(ofSize: 13)
        let trailingPadding: CGFloat = 6
        let slotWidth: CGFloat = StreamingCursorOverlay.dotDiameter + 4
        let slotHeight: CGFloat = StreamingCursorOverlay.dotDiameter

        // Work from the text BASELINE rather than the line's top/bottom.
        // The baseline is the only metric that lets us derive the text's
        // true optical mid-line from the font itself; line-rect math drags
        // in leading and ascender/descender asymmetry, which is what left
        // the dot sitting above the line.
        let trailingX: CGFloat
        let baselineInTV: CGFloat

        if storageLength == 0 {
            trailingX = origin.x + trailingPadding
            baselineInTV = origin.y + font.ascender
        } else {
            let lastCharIdx = storageLength - 1
            let lastGlyphIdx = lm.glyphIndexForCharacter(at: lastCharIdx)
            // Used rect (not bounding rect) so soft-wrapped trailing
            // whitespace doesn't pull the dot back to the previous line.
            let usedRect = lm.lineFragmentUsedRect(
                forGlyphAt: lastGlyphIdx,
                effectiveRange: nil
            )
            let lineFragRect = lm.lineFragmentRect(
                forGlyphAt: lastGlyphIdx,
                effectiveRange: nil
            )
            // `location(forGlyphAt:)` returns the glyph origin relative to
            // its line fragment; its y is the baseline offset from the
            // fragment top.
            let baselineOffset = lm.location(forGlyphAt: lastGlyphIdx).y
            trailingX = usedRect.maxX + origin.x + trailingPadding
            baselineInTV = lineFragRect.minY + baselineOffset + origin.y
        }

        // The dot's center axis lands on the midpoint of the cap-height
        // band above the baseline — the line's optical center for running
        // text. Deriving the offset from `font.capHeight` keeps it aligned
        // across font sizes, where the old fixed nudge drifted off-axis.
        let textMiddleInTV = baselineInTV - font.capHeight / 2

        // Convert just the mid-line point and center the symmetric slot on
        // it: this is independent of whether `self` is flipped, so we no
        // longer have to reason about which converted edge is the lower y.
        let centerInSelf = tv.convert(
            NSPoint(x: trailingX, y: textMiddleInTV),
            to: self
        )
        cursor.frame = NSRect(
            x: centerInSelf.x,
            y: centerInSelf.y - slotHeight / 2,
            width: slotWidth,
            height: slotHeight
        )
    }
}

// MARK: - StreamingCursorOverlay

/// Tiny overlay view that renders a blinking dot. Used by
/// `NativeMarkdownView` to indicate "still streaming" during the SSE
/// quiet gaps that no amount of pacing can fully smooth over.
private final class StreamingCursorOverlay: NSView {

    /// Diameter of the dot in points. Tuned to read as a deliberate
    /// "still going" pulse without competing with the body text.
    static let dotDiameter: CGFloat = 12

    private let dotLayer = CAShapeLayer()
    private static let suppressedActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "path": NSNull(),
        "fillColor": NSNull(),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Frame-based positioning — caller sets the frame each time the
        // trailing glyph rect changes. Auto Layout would otherwise pin the
        // overlay to (0, 0) at its zero intrinsic size and ignore our
        // frame writes.
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        layer?.actions = Self.suppressedActions
        dotLayer.actions = Self.suppressedActions
        layer?.addSublayer(dotLayer)
        startBlinking()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Center the dot within the overlay view.
        let d = Self.dotDiameter
        let dotFrame = CGRect(
            x: (bounds.width - d) / 2,
            y: (bounds.height - d) / 2,
            width: d,
            height: d
        )
        dotLayer.frame = dotFrame
        dotLayer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: dotFrame.size), transform: nil)
        CATransaction.commit()
    }

    func updateColor(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.fillColor = color.cgColor
        CATransaction.commit()
    }

    private func startBlinking() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.2
        anim.duration = 0.65
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        layer?.add(anim, forKey: "blink")
    }
}

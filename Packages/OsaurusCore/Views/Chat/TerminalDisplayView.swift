//
//  TerminalDisplayView.swift
//  osaurus
//
//  Cursor-style inline terminal hosted inside a tool-call card. Two
//  binding modes:
//    .live(entry)     — streams from a `LiveExecRegistry.Entry`,
//                       shows [Terminate] + a live elapsed clock,
//                       locks to a fixed 140pt body height to avoid
//                       streaming-time row jitter.
//    .completed(snap) — renders a finished command's full output once
//                       through the same line tracker, hides
//                       [Terminate], shows the static "exit N" /
//                       "killed" pill. Body adapts in [60, 140] pt.
//
//  Branching on the mode keeps chrome consistent so the row doesn't
//  visually shift when streaming ends and the snapshot takes over.
//
//  The streaming hot path lives in `TerminalStreamRenderer`, which the
//  view holds as a child object. The view focuses on AppKit chrome
//  (header strip, status pill, copy / terminate buttons, scroll-
//  position tracking) and binding lifecycle.
//

import AppKit
import Combine
import Foundation

@MainActor
final class TerminalDisplayView: NSView {

    /// Binding mode. Set via `bind(_:theme:)`.
    enum Mode {
        case live(LiveExecRegistry.Entry)
        case completed(TerminalSnapshot)
    }

    // MARK: Layout constants

    /// Hard ceiling for the body. Beyond this, content scrolls inside
    /// the embedded `NSScrollView` rather than growing the row, so
    /// the chat layout stays stable when a session emits 10 MB. 140pt
    /// is roughly 8 lines of monospaced 11pt — feels like a terminal
    /// without dominating the chat for short commands.
    static let maxBodyHeight: CGFloat = 140
    /// Floor for completed-mode adaptive height. Below this the pane
    /// would lose its "this is a terminal" feel.
    static let minCompletedBodyHeight: CGFloat = 60
    static let headerHeight: CGFloat = 30
    private static let bodyFont: NSFont = ThemeManager.shared.chatTheme.nsFont(.code)
    private static let promptFont: NSFont = ThemeManager.shared.chatTheme.nsFont(.code)
    /// Approximate per-line height for the body font. Used by the
    /// completed-mode adaptive sizer; close enough for a heuristic
    /// that just picks a height bucket between min and max.
    private static let approxLineHeight: CGFloat = 14
    private static let bodyVerticalPadding: CGFloat = 16

    // MARK: Subviews

    private let headerStrip = NSView()
    private static let statusDotSize: CGFloat = 8
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "running")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let copyButton = TerminalDisplayView.makeIconButton(
        symbol: "doc.on.doc",
        accessibility: "Copy output"
    )
    private let terminateButton = TerminalDisplayView.makeIconButton(
        symbol: "stop.circle.fill",
        accessibility: "Terminate"
    )
    private let headerDivider = NSView()

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    // MARK: State

    private var liveEntry: LiveExecRegistry.Entry?
    private var cancellables = Set<AnyCancellable>()
    private var stickyToBottom = true
    private var currentTheme: (any ThemeProtocol)?
    private var inspectionStyleFingerprint: Int?
    private var elapsedTimer: Timer?
    /// Cached per-instance height for the current binding. Live mode
    /// is always `headerHeight + maxBodyHeight`; completed mode is
    /// driven by content. `NativeToolCallRowView` reads this after
    /// every bind to size the row.
    private(set) var currentMeasuredHeight: CGFloat =
        TerminalDisplayView.headerHeight + TerminalDisplayView.maxBodyHeight

    /// Streaming pipeline (buffer → coalesce → ANSI strip → line
    /// track → textStorage update). Lazily created so it can capture
    /// the configured `textView`. Owners reset it on rebind via
    /// `renderer.reset()`.
    private lazy var renderer: TerminalStreamRenderer = {
        let r = TerminalStreamRenderer(
            textView: textView,
            bodyAttrs: Self.defaultBodyAttrs,
            markerAttrs: Self.defaultMarkerAttrs
        )
        r.stickyToBottom = { [weak self] in self?.stickyToBottom ?? true }
        return r
    }()

    /// Cached attribute dicts for body / prompt / marker text.
    /// Recomputed on theme change and pushed into the renderer.
    private var bodyAttrs: [NSAttributedString.Key: Any] = TerminalDisplayView.defaultBodyAttrs
    private var promptAttrs: [NSAttributedString.Key: Any] = TerminalDisplayView.defaultPromptAttrs
    private var markerAttrs: [NSAttributedString.Key: Any] = TerminalDisplayView.defaultMarkerAttrs

    private static let defaultBodyAttrs: [NSAttributedString.Key: Any] = [
        .font: TerminalDisplayView.bodyFont,
        .foregroundColor: NSColor(ThemeManager.shared.chatTheme.text.primary),
    ]
    private static let defaultPromptAttrs: [NSAttributedString.Key: Any] = [
        .font: TerminalDisplayView.promptFont,
        .foregroundColor: NSColor(ThemeManager.shared.chatTheme.text.secondary),
    ]
    private static let defaultMarkerAttrs: [NSAttributedString.Key: Any] = [
        .font: TerminalDisplayView.bodyFont,
        .foregroundColor: NSColor(ThemeManager.shared.chatTheme.text.secondary),
    ]

    private var statusTheme: any ThemeProtocol { currentTheme ?? ThemeManager.shared.chatTheme }

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // Drop the bounds-changed observer registered in `buildViews()`.
        // AppKit auto-deregisters selector observers on dealloc on modern
        // macOS, but we remove it explicitly so the contract is local and
        // doesn't silently regress if this view is reused or the registration
        // pattern changes. `AnyCancellable`s in `cancellables` still cancel
        // themselves when the set is released during ARC.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Bind / Unbind

    /// Bind the view to a mode. Replaces any previous binding —
    /// callers don't need to call `unbind()` first. Idempotent on
    /// the same live entry id (cheap re-bind during cell layout
    /// passes); always fully re-renders for a completed snapshot.
    func bind(_ mode: Mode, theme: any ThemeProtocol) {
        let theme = theme.catalogFamily(39)
        switch mode {
        case .live(let entry):
            bindLive(entry, theme: theme)
        case .completed(let snap):
            bindCompleted(snap, theme: theme)
        }
    }

    private func bindLive(
        _ entry: LiveExecRegistry.Entry,
        theme: any ThemeProtocol
    ) {
        // Same entry, just a layout refresh — no need to tear down.
        if liveEntry?.toolCallId == entry.toolCallId, currentTheme != nil {
            applyTheme(theme)
            return
        }

        prepareForRebind(theme: theme)
        liveEntry = entry

        terminateButton.isHidden = false
        statusLabel.stringValue = "running"
        elapsedLabel.stringValue = "0:00"
        elapsedLabel.isHidden = false
        refreshInspectionLabels()
        currentMeasuredHeight = assignedHeaderHeight + Self.maxBodyHeight

        appendPromptLine(for: entry.command)
        startElapsedTimer(startedAt: entry.startedAt)

        // Seed first so the user sees the existing tail before live
        // chunks arrive. Inherits MainActor isolation from the @MainActor
        // scope; the post-await resume lands back on main without an
        // explicit hop. Routes through `renderer.enqueue` so the line
        // tracker sees the seed too.
        let pinnedId = entry.toolCallId
        Task { [weak self] in
            let seed = await entry.seed()
            guard let self, self.liveEntry?.toolCallId == pinnedId else { return }
            self.renderer.enqueue(seed)
        }

        entry.outputPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] data in
                guard let self, self.liveEntry?.toolCallId == pinnedId else { return }
                self.renderer.enqueue(data)
            }
            .store(in: &cancellables)

        entry.statusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.liveEntry?.toolCallId == pinnedId else { return }
                self.applyLiveStatus(status)
            }
            .store(in: &cancellables)
    }

    private func bindCompleted(
        _ snap: TerminalSnapshot,
        theme: any ThemeProtocol
    ) {
        prepareForRebind(theme: theme)

        terminateButton.isHidden = true
        appendPromptLine(for: snap.command)
        renderer.renderSnapshot(snap.output)
        applyCompletedStatus(exitCode: snap.exitCode, killedByUser: snap.killedByUser)
        applyCompletedDuration(snap.duration)

        currentMeasuredHeight = adaptiveHeightForCompletedBody()
    }

    /// Cancel subscriptions and clear all per-binding state. Called
    /// when the row recycles to a different tool call OR on remove.
    func unbind() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        liveEntry = nil
        renderer.reset()
        currentMeasuredHeight = assignedHeaderHeight + Self.maxBodyHeight
    }

    /// Shared reset path for both binding modes. Tears down the
    /// previous binding, applies the theme, and clears the textView /
    /// renderer state so the caller can immediately append fresh
    /// content.
    private func prepareForRebind(theme: any ThemeProtocol) {
        unbind()
        currentTheme = theme
        applyTheme(theme)
        textView.string = ""
        renderer.reset()
    }

    // MARK: Measurement

    /// Static maximum height the row should reserve for a live binding.
    /// Live mode locks here so streaming chunks can't jitter the row
    /// height. Completed mode uses `currentMeasuredHeight` after bind.
    static func liveModeMeasuredHeight(theme: (any ThemeProtocol)? = nil) -> CGFloat {
        inspectionHeaderHeight(theme ?? ThemeManager.shared.chatTheme) + maxBodyHeight
    }
    static func inspectionHeaderHeight(_ theme: any ThemeProtocol) -> CGFloat {
        let font = theme.assignedNativeFont(NativeComponentInspectionStyle.key(39, "caption"), fallback: theme.nsFont(.caption))
        let line = max(ceil(font.ascender - font.descender + font.leading), theme.assignedLineHeight(NativeComponentInspectionStyle.key(39, "caption"), fallback: 16))
        return max(NativeComponentInspectionStyle.metric(39, "height", headerHeight, theme), line + 2 * NativeComponentInspectionStyle.metric(39, "padding", theme.space.s0, theme))
    }
    private var assignedHeaderHeight: CGFloat { Self.inspectionHeaderHeight(statusTheme) }
    private func refreshInspectionLabels() {
        NativeComponentInspectionStyle.label(statusLabel, family: 39, property: "caption", theme: statusTheme)
        NativeComponentInspectionStyle.label(elapsedLabel, family: 39, property: "caption", theme: statusTheme)
    }

    // MARK: Append helpers

    private func appendPromptLine(for command: String) {
        let displayCommand = Self.stripPipefailWrap(command)
        textView.textStorage?.append(
            NSAttributedString(
                string: "$ \(displayCommand)\n",
                attributes: promptAttrs
            )
        )
        textView.needsDisplay = true
    }

    /// Pick a row height between [minCompletedBodyHeight, maxBodyHeight]
    /// based on the body content's actual line count. Keeps short
    /// commands compact while letting chatty ones scroll inside the cap.
    private func adaptiveHeightForCompletedBody() -> CGFloat {
        let body = textView.textStorage?.string ?? ""
        // `\n` boundary count (ignores visual wraps). Slight under-
        // estimate for very wide lines is fine because we cap at
        // maxBodyHeight anyway.
        let lineCount = max(1, body.components(separatedBy: "\n").count)
        let estimatedBody = CGFloat(lineCount) * statusTheme.assignedLineHeight(NativeComponentInspectionStyle.key(39, "code"), fallback: Self.approxLineHeight) + 2 * NativeComponentInspectionStyle.metric(39, "padding", Self.bodyVerticalPadding / 2, statusTheme)
        let bodyHeight = min(
            Self.maxBodyHeight,
            max(Self.minCompletedBodyHeight, estimatedBody)
        )
        return assignedHeaderHeight + bodyHeight
    }

    // MARK: Status

    private func applyLiveStatus(_ status: LiveExecRegistry.LiveExecStatus) {
        defer { refreshInspectionLabels() }
        switch status {
        case .running:
            statusLabel.stringValue = "running"
            statusDot.layer?.backgroundColor = NSColor(statusTheme.status.success.foreground).cgColor
            terminateButton.isHidden = false
        case .exited(let code):
            statusLabel.stringValue = code == 0 ? "exited" : "exited (\(code))"
            statusDot.layer?.backgroundColor =
                NSColor(code == 0 ? statusTheme.text.tertiary : statusTheme.status.error.foreground).cgColor
            terminateButton.isHidden = true
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        case .killed(let reason):
            statusLabel.stringValue = "terminated (\(reason))"
            statusDot.layer?.backgroundColor = NSColor(statusTheme.status.warning.foreground).cgColor
            terminateButton.isHidden = true
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    private func applyCompletedStatus(exitCode: Int32, killedByUser: Bool) {
        defer { refreshInspectionLabels() }
        if killedByUser {
            statusLabel.stringValue = "terminated (user)"
            statusDot.layer?.backgroundColor = NSColor(statusTheme.status.warning.foreground).cgColor
        } else if exitCode == 0 {
            statusLabel.stringValue = "exited"
            statusDot.layer?.backgroundColor = NSColor(statusTheme.text.tertiary).cgColor
        } else {
            statusLabel.stringValue = "exited (\(exitCode))"
            statusDot.layer?.backgroundColor = NSColor(statusTheme.status.error.foreground).cgColor
        }
    }

    private func applyCompletedDuration(_ duration: TimeInterval?) {
        guard let duration else {
            elapsedLabel.isHidden = true
            elapsedLabel.stringValue = ""
            return
        }
        elapsedLabel.isHidden = false
        elapsedLabel.stringValue = Self.formatElapsed(duration)
        refreshInspectionLabels()
    }

    // MARK: Elapsed timer (live mode)

    private func startElapsedTimer(startedAt: Date) {
        elapsedTimer?.invalidate()
        elapsedLabel.stringValue = Self.formatElapsed(0)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let secs = Date().timeIntervalSince(startedAt)
                self.elapsedLabel.stringValue = Self.formatElapsed(secs)
                self.refreshInspectionLabels()
            }
        }
    }

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Theme

    private func applyTheme(_ theme: any ThemeProtocol) {
        currentTheme = theme
        wantsLayer = true
        layer?.backgroundColor = NSColor(theme.surface.code).cgColor
        layer?.cornerRadius = theme.radius.small
        layer?.borderColor = NSColor(theme.border.default).cgColor
        layer?.borderWidth = theme.hairline(for: self)

        statusLabel.textColor = NSColor(theme.text.tertiary)
        statusLabel.font = theme.nsFont(.footnote, weight: .medium)
        elapsedLabel.textColor = NSColor(theme.text.tertiary)
        elapsedLabel.font = theme.nsFont(.caption, monospacedDigit: true)

        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor =
            NSColor(theme.border.subtle).cgColor

        bodyAttrs = [
            .font: Self.bodyFont,
            .foregroundColor: NSColor(theme.text.primary),
        ]
        promptAttrs = [
            .font: Self.promptFont,
            .foregroundColor: NSColor(theme.text.tertiary),
        ]
        markerAttrs = [
            .font: Self.bodyFont,
            .foregroundColor: NSColor(theme.text.tertiary),
        ]
        // Push body / marker attrs into the renderer so the next chunk
        // appends with the right colors.
        renderer.bodyAttrs = bodyAttrs
        renderer.markerAttrs = markerAttrs

        copyButton.contentTintColor = NSColor(theme.text.tertiary)
        terminateButton.contentTintColor = .systemRed
        layer?.borderWidth = theme.stroke.default
        let pad = NativeComponentInspectionStyle.metric(39, "padding", theme.space.s8, theme)
        let gap = NativeComponentInspectionStyle.metric(39, "gap", theme.space.s8, theme)
        textView.textContainerInset = NSSize(width: pad, height: pad)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection.background)]
        headerStrip.constraints.first { $0.firstAttribute == .height }?.constant = assignedHeaderHeight
        for c in headerStrip.constraints {
            let view = c.firstItem as? NSView
            if view === statusDot, c.firstAttribute == .leading { c.constant = pad }
            if (view === statusLabel || view === elapsedLabel), c.firstAttribute == .leading { c.constant = gap }
            if view === copyButton, c.firstAttribute == .trailing { c.constant = -pad }
            if view === terminateButton, c.firstAttribute == .trailing { c.constant = -gap }
        }
        headerDivider.constraints.first { $0.firstAttribute == .height }?.constant = theme.stroke.default
        headerDivider.layer?.backgroundColor = NSColor(theme.border.default).cgColor
        let styleChanged = inspectionStyleFingerprint != theme.renderFingerprint
        inspectionStyleFingerprint = theme.renderFingerprint
        let part = NSAttributedString.Key("inspectorTerminalPart")
        let font = theme.assignedNativeFont(NativeComponentInspectionStyle.key(39, "code"), fallback: theme.nsFont(.code))
        let paragraph = theme.paragraphStyle(.code)
        let tracking = theme.assignedTracking(NativeComponentInspectionStyle.key(39, "code")) ?? 0
        for name in ["body", "prompt", "marker"] {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .kern: tracking, .foregroundColor: NSColor(name == "body" ? theme.text.primary : theme.text.secondary), part: name]
            switch name { case "prompt": promptAttrs = attributes; case "marker": markerAttrs = attributes; default: bodyAttrs = attributes }
        }
        renderer.bodyAttrs = bodyAttrs; renderer.markerAttrs = markerAttrs
        if styleChanged, let storage = textView.textStorage, storage.length > 0 {
            let range = NSRange(location: 0, length: storage.length)
            var runs: [(String, NSRange)] = []
            storage.enumerateAttribute(part, in: range) { value, range, _ in runs.append((value as? String ?? "body", range)) }
            storage.beginEditing()
            for (name, range) in runs { storage.addAttributes(name == "prompt" ? promptAttrs : name == "marker" ? markerAttrs : bodyAttrs, range: range) }
            storage.endEditing()
        }
        if styleChanged { textView.font = font }
        terminateButton.contentTintColor = NSColor(theme.status.error.foreground)
        refreshInspectionLabels()
        if let entry = liveEntry { applyLiveStatus(entry.currentStatus()); currentMeasuredHeight = assignedHeaderHeight + Self.maxBodyHeight }
    }

    // MARK: Layout

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false

        headerStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStrip)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor(statusTheme.status.success.foreground).cgColor
        statusDot.layer?.cornerRadius = Self.statusDotSize / 2
        headerStrip.addSubview(statusDot)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.addSubview(statusLabel)

        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        headerStrip.addSubview(elapsedLabel)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        headerStrip.addSubview(copyButton)

        terminateButton.translatesAutoresizingMaskIntoConstraints = false
        terminateButton.target = self
        terminateButton.action = #selector(handleTerminate)
        headerStrip.addSubview(terminateButton)

        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerDivider)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        // The textView gets a valid initial frame AND a non-zero
        // textContainer.containerSize. Without both, text appended to
        // the storage has zero layout area and renders invisibly —
        // the silent blank-body bug from early screenshots.
        let initialContent = NSSize(width: 200, height: Self.maxBodyHeight)
        textView.frame = NSRect(origin: .zero, size: initialContent)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = ThemeManager.shared.chatTheme.nsFont(.footnote, family: .code)
        textView.textContainer?.containerSize = NSSize(
            width: initialContent.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLayoutConstraint.activate([
            headerStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerStrip.topAnchor.constraint(equalTo: topAnchor),
            headerStrip.heightAnchor.constraint(equalToConstant: assignedHeaderHeight),

            statusDot.leadingAnchor.constraint(equalTo: headerStrip.leadingAnchor, constant: 12),
            statusDot.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: Self.statusDotSize),
            statusDot.heightAnchor.constraint(equalToConstant: Self.statusDotSize),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),

            elapsedLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            elapsedLabel.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),

            // Copy is pinned to the trailing edge so its position is
            // identical whether or not the terminate button is visible
            // (terminate is hidden in completed mode). Terminate sits
            // to its left when present.
            copyButton.trailingAnchor.constraint(
                equalTo: headerStrip.trailingAnchor,
                constant: -10
            ),
            copyButton.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 16),
            copyButton.heightAnchor.constraint(equalToConstant: 16),

            terminateButton.trailingAnchor.constraint(
                equalTo: copyButton.leadingAnchor,
                constant: -10
            ),
            terminateButton.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            terminateButton.widthAnchor.constraint(equalToConstant: 18),
            terminateButton.heightAnchor.constraint(equalToConstant: 18),

            headerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerDivider.topAnchor.constraint(equalTo: headerStrip.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Borderless icon button backed by an SF Symbol. Avoids the
    /// bezeled NSButton chrome that fights the dark terminal aesthetic.
    private static func makeIconButton(symbol: String, accessibility: String) -> NSButton {
        let btn = NSButton(
            image: SymbolImageCache.image(symbol, accessibilityDescription: accessibility)
                ?? NSImage(),
            target: nil,
            action: nil
        )
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyUpOrDown
        btn.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular
        )
        return btn
    }

    /// Strip the `set -o pipefail; ` prefix `SandboxExecTool` /
    /// `ShellRunTool` add before invoking the model's command. Pure
    /// UI cleanup — the underlying execution still runs the wrapped
    /// form.
    private static func stripPipefailWrap(_ command: String) -> String {
        let prefix = "set -o pipefail; "
        return command.hasPrefix(prefix)
            ? String(command.dropFirst(prefix.count))
            : command
    }

    // MARK: Actions

    @objc private func handleCopy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
    }

    @objc private func handleTerminate() {
        guard let entry = liveEntry else { return }
        Task { await entry.terminate(3) }
    }

    @objc private func handleScrollChange() {
        guard let documentView = scrollView.documentView else { return }
        let visibleMaxY = scrollView.contentView.bounds.maxY
        let documentMaxY = documentView.bounds.maxY
        // Within 12pt of the bottom counts as "still pinned".
        stickyToBottom = (documentMaxY - visibleMaxY) <= 12
    }
}

#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Local publishers exercise original running/elapsed/Terminate chrome.
/// No command, subprocess, registry entry or runtime request is created.
private final class InspectorTerminalDisplayState: ObservableObject, @unchecked Sendable {
    let status = CurrentValueSubject<LiveExecRegistry.LiveExecStatus, Never>(.running)
    lazy var entry = LiveExecRegistry.Entry(toolCallId: "inspector-local-terminal", pid: "", command: "local display only", startedAt: Date(), outputPublisher: Empty<Data, Never>().eraseToAnyPublisher(), statusPublisher: status.eraseToAnyPublisher(), currentStatus: { [self] in status.value }, seed: { Data("Local terminal display\nNo command was executed.\n".utf8) }, terminate: { [self] _ in status.send(.killed(reason: "user")) })
}

struct InspectorTerminalLiveVerification: View {
    @Environment(\.theme) private var theme
    @StateObject private var state = InspectorTerminalDisplayState()
    @State private var phase = "Running"
    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text(verbatim: "Chat · command output returned by an agent tool")
            Picker("Command state", selection: $phase) {
                ForEach(["Running", "Completed", "Failed", "Stopped"], id: \.self) { Text($0).tag($0) }
            }.onChange(of: phase) { _, value in
                switch value {
                case "Running": state.status.send(.running)
                case "Stopped": state.status.send(.killed(reason: "user"))
                case "Failed": state.status.send(.exited(1))
                default: state.status.send(.exited(0))
                }
            }
            InspectorTerminalLiveHost(state: state)
            Text(verbatim: "Terminate changes only the local display status. No command or process is running.")
                .font(SettingsFont.caption)
        }
    }
}

private struct InspectorTerminalLiveHost: NSViewRepresentable {
    let state: InspectorTerminalDisplayState
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> TerminalDisplayView { TerminalDisplayView() }
    func updateNSView(_ view: TerminalDisplayView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        view.bind(.live(state.entry), theme: theme)
        view.catalogAssignmentTarget(["background", "foreground", "secondary", "border", "borderWidth", "radius", "padding", "gap", "height", "code"].map { "component.library.39." + $0 }, name: "Terminal output", theme: theme)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalDisplayView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 760, height: nsView.currentMeasuredHeight)
    }
}
#endif

// MARK: - Test hooks
//
// `@testable internal` accessors so unit tests can exercise both the
// view's chrome and the streaming hot path without driving a real
// RunLoop / live publisher. Production code never calls these — they
// live on a dedicated extension to keep the production class surface
// clean.
extension TerminalDisplayView {
    var _test_pendingChunkCount: Int { renderer._test_pendingChunkCount }
    var _test_flushCount: Int { renderer.flushCount }
    var _test_textStorageString: String { textView.textStorage?.string ?? "" }
    var _test_textStorageLength: Int { textView.textStorage?.length ?? 0 }
    var _test_truncationMarkerInserted: Bool { renderer._test_truncationMarkerInserted }
    var _test_trailingLiveLineLength: Int { renderer._test_trailingLiveLineLength }
    var _test_statusLabelString: String { statusLabel.stringValue }
    var _test_terminateHidden: Bool { terminateButton.isHidden }
    var _test_elapsedHidden: Bool { elapsedLabel.isHidden }
    var _test_elapsedLabelString: String { elapsedLabel.stringValue }
    var _test_currentMeasuredHeight: CGFloat { currentMeasuredHeight }

    func _test_enqueue(_ data: Data) { renderer.enqueue(data) }
    func _test_flushNow() { renderer.flushPendingChunks() }
    /// Test-only minimal bind that skips the seed `Task` and the
    /// publisher subscriptions (which would otherwise need a live
    /// LiveExecRegistry.Entry). Sets up the body for direct enqueues.
    func _test_prepareForStreaming(theme: any ThemeProtocol) {
        currentTheme = theme
        applyTheme(theme)
        textView.string = ""
        renderer.reset()
    }
}

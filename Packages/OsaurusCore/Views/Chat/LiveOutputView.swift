//
//  LiveOutputView.swift
//  osaurus
//
//  Cursor-style inline terminal that lives inside a tool-call card
//  while a `sandbox_exec` / `shell_run` invocation is streaming. Pulls
//  bytes from a `LiveExecRegistry.Entry` (one per live tool call),
//  appends them to a monospaced NSTextView, and exposes a header strip
//  with status + [Terminate] + [Copy].
//
//  The body is never blank — even before any output arrives, the first
//  line is a `$ <command>` prompt so the user always sees what's being
//  executed. The `set -o pipefail; ` wrap our shell prefix adds is
//  stripped from this prompt so it matches what the user actually wrote.
//
//  Lifecycle:
//    bind(to:) — replays the seed snapshot, then subscribes to
//    outputPublisher + statusPublisher. unbind() cancels both. The
//    owning `NativeToolCallRowView` calls bind/unbind on configure-with
//    -new-item to handle cell recycling cleanly. The pane is mounted
//    only while `entry.currentStatus() == .running`; once the tool
//    exits the row swaps it for the static result envelope.
//
//  Auto-scroll:
//    Tracks a `stickyToBottom` flag. Every time the user scrolls up
//    >12pt from the bottom we flip it off; when they scroll back down
//    we flip it on. New chunks always append; only the scroll position
//    auto-jumps when sticky.
//

import AppKit
import Combine
import Foundation

@MainActor
final class LiveOutputView: NSView {

    // MARK: Layout constants

    /// Height ceiling for the body. Beyond this, content scrolls
    /// inside the embedded `NSScrollView` rather than growing the row,
    /// so the chat layout stays stable when a session emits 10 MB.
    /// 140pt is roughly 8 lines of monospaced 11pt — enough to feel
    /// like a terminal without dominating the chat for short commands.
    private static let maxBodyHeight: CGFloat = 140
    private static let headerHeight: CGFloat = 30
    private static let bodyFont: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let promptFont: NSFont = .monospacedSystemFont(ofSize: 11, weight: .semibold)

    // MARK: Subviews

    private let headerStrip = NSView()
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "running")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let copyButton = LiveOutputView.makeIconButton(
        symbol: "doc.on.doc",
        accessibility: "Copy output"
    )
    private let terminateButton = LiveOutputView.makeIconButton(
        symbol: "stop.circle.fill",
        accessibility: "Terminate"
    )
    private let headerDivider = NSView()

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    // MARK: State

    private var entry: LiveExecRegistry.Entry?
    private var cancellables = Set<AnyCancellable>()
    private var stickyToBottom = true
    private var currentTheme: (any ThemeProtocol)?
    private var elapsedTimer: Timer?
    /// When non-nil, the textView has already had its `$ <cmd>` prompt
    /// line laid down. Used to keep the prompt at the top across
    /// re-binds and to preserve it when the body is otherwise cleared.
    private var hasPrompt = false

    /// Cached attribute dicts for `append(data:)` and the prompt
    /// header. Recomputed on theme change so we don't allocate per-chunk.
    private var bodyAttrs: [NSAttributedString.Key: Any] = [
        .font: LiveOutputView.bodyFont,
        .foregroundColor: NSColor.labelColor,
    ]
    private var promptAttrs: [NSAttributedString.Key: Any] = [
        .font: LiveOutputView.promptFont,
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // No explicit deinit: each `AnyCancellable` cancels itself when
    // released, so dropping the `cancellables` set during ARC is enough.

    // MARK: Bind / Unbind

    /// Bind to a registry entry. Replaces any previous binding —
    /// callers don't need to call `unbind()` first. Idempotent on the
    /// same entry (cheap re-bind during cell layout passes).
    func bind(to entry: LiveExecRegistry.Entry, theme: any ThemeProtocol) {
        // Same entry, just a layout refresh — no need to tear down.
        if self.entry?.toolCallId == entry.toolCallId, currentTheme != nil {
            applyTheme(theme)
            return
        }

        unbind()
        self.entry = entry
        currentTheme = theme
        applyTheme(theme)

        statusLabel.stringValue = "running"
        elapsedLabel.stringValue = "0:00"
        textView.string = ""
        hasPrompt = false

        // Lay down the `$ <cmd>` prompt line so the body never starts
        // out blank. Strip our internal pipefail wrap so the user sees
        // what they actually wrote. Force a display + layout pass —
        // NSTextView's lazy text-system will otherwise leave the body
        // visually blank until the user scrolls/clicks.
        let displayCommand = Self.stripPipefailWrap(entry.command)
        textView.textStorage?.append(
            NSAttributedString(
                string: "$ \(displayCommand)\n",
                attributes: promptAttrs
            )
        )
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.needsDisplay = true
        hasPrompt = true

        startElapsedTimer(startedAt: entry.startedAt)

        // Seed first so the user sees the existing tail before we start
        // appending live chunks. Inherits MainActor isolation from
        // `bind(to:)`'s @MainActor scope, so the post-await resume
        // lands back on main without an explicit hop.
        let pinnedId = entry.toolCallId
        Task { [weak self] in
            let seed = await entry.seed()
            guard let self, self.entry?.toolCallId == pinnedId else { return }
            self.append(data: seed)
        }

        entry.outputPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] data in
                guard let self, self.entry?.toolCallId == pinnedId else { return }
                self.append(data: data)
            }
            .store(in: &cancellables)

        entry.statusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.entry?.toolCallId == pinnedId else { return }
                self.applyStatus(status)
            }
            .store(in: &cancellables)
    }

    /// Cancel subscriptions and clear bound state. Called when the row
    /// recycles to a different tool call OR when the row is removed.
    func unbind() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        entry = nil
        hasPrompt = false
    }

    /// Stable height the row should reserve for this view. Static so
    /// `NativeToolCallRowView.measuredHeight()` can query it without
    /// instantiating a view.
    static func measuredHeight() -> CGFloat {
        headerHeight + maxBodyHeight
    }

    // MARK: Append

    private func append(data: Data) {
        guard !data.isEmpty,
            let text = String(data: data, encoding: .utf8)
        else { return }
        let stripped = ANSIStripper.strip(text)
        textView.textStorage?
            .append(NSAttributedString(string: stripped, attributes: bodyAttrs))
        // Force the layout manager to reify the new glyphs and the
        // scroll view to refresh. NSTextView normally does this lazily;
        // on a row that just mounted, the lazy path can leave the body
        // visually empty until the user interacts.
        textView.needsDisplay = true
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if stickyToBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: Status

    private func applyStatus(_ status: LiveExecRegistry.LiveExecStatus) {
        switch status {
        case .running:
            statusLabel.stringValue = "running"
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            terminateButton.isHidden = false
        case .exited(let code):
            statusLabel.stringValue = code == 0 ? "exited" : "exited (\(code))"
            statusDot.layer?.backgroundColor =
                (code == 0 ? NSColor.systemGray : NSColor.systemRed).cgColor
            terminateButton.isHidden = true
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        case .killed(let reason):
            statusLabel.stringValue = "terminated (\(reason))"
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            terminateButton.isHidden = true
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    // MARK: Elapsed timer

    private func startElapsedTimer(startedAt: Date) {
        elapsedTimer?.invalidate()
        elapsedLabel.stringValue = Self.formatElapsed(0)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let secs = Date().timeIntervalSince(startedAt)
                self.elapsedLabel.stringValue = Self.formatElapsed(secs)
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
        layer?.backgroundColor = NSColor(theme.codeBlockBackground).cgColor
        layer?.cornerRadius = 6
        layer?.borderColor = NSColor(theme.cardBorder).cgColor
        layer?.borderWidth = 0.5

        statusLabel.textColor = NSColor(theme.tertiaryText)
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        elapsedLabel.textColor = NSColor(theme.tertiaryText)
        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor =
            NSColor(theme.cardBorder).withAlphaComponent(0.5).cgColor

        bodyAttrs = [
            .font: Self.bodyFont,
            .foregroundColor: NSColor(theme.primaryText),
        ]
        promptAttrs = [
            .font: Self.promptFont,
            .foregroundColor: NSColor(theme.tertiaryText),
        ]

        copyButton.contentTintColor = NSColor(theme.tertiaryText)
        terminateButton.contentTintColor = .systemRed
    }

    // MARK: Layout

    private func buildViews() {
        translatesAutoresizingMaskIntoConstraints = false

        headerStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStrip)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.layer?.cornerRadius = 4
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

        // Standard scroll-view-hosted NSTextView setup. The textView
        // gets a valid initial frame (matching the scrollView's
        // contentSize) AND a non-zero textContainer.containerSize.
        // Without both, text appended to the storage has zero layout
        // area and renders invisibly — which was the silent blank-body
        // bug visible in early screenshots.
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
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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
            headerStrip.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            statusDot.leadingAnchor.constraint(equalTo: headerStrip.leadingAnchor, constant: 12),
            statusDot.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),

            elapsedLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            elapsedLabel.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),

            terminateButton.trailingAnchor.constraint(
                equalTo: headerStrip.trailingAnchor,
                constant: -10
            ),
            terminateButton.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            terminateButton.widthAnchor.constraint(equalToConstant: 18),
            terminateButton.heightAnchor.constraint(equalToConstant: 18),

            copyButton.trailingAnchor.constraint(
                equalTo: terminateButton.leadingAnchor,
                constant: -10
            ),
            copyButton.centerYAnchor.constraint(equalTo: headerStrip.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 16),
            copyButton.heightAnchor.constraint(equalToConstant: 16),

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

    /// Build a borderless icon button backed by an SF Symbol. Clean
    /// look that doesn't fight the dark terminal aesthetic the way a
    /// bezeled `NSButton` does.
    private static func makeIconButton(symbol: String, accessibility: String) -> NSButton {
        let btn = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
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

    /// Strip the `set -o pipefail; ` prefix `SandboxExecTool` adds
    /// before invoking the model's command. Pure UI cleanup — the
    /// underlying execution still runs the wrapped form.
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
        guard let entry else { return }
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

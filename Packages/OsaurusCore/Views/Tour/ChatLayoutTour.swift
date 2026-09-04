//
//  ChatLayoutTour.swift
//  osaurus
//
//  Coachmark tour for the agent-first chat layout: spotlights the live UI
//  (sidebar, tab strip, overflow menu) with a short callout per stop so
//  users updating from the old layout learn that nothing was removed, only
//  moved. Self-contained: its own once-per-user gate, its own auto-trigger
//  when a chat window first appears, and a Help-menu replay. Independent of
//  the What's New carousel.
//
//  Anchors are reported from the real views via `TourAnchorMarker` in
//  WINDOW coordinates (AppKit, bottom-left origin) so the overlay — a
//  borderless child window covering the whole chat window, title bar
//  included — can cut a spotlight exactly around toolbar items, which live
//  outside the SwiftUI content view.
//

import AppKit
import SwiftUI

// MARK: - Anchors and stops

/// The UI elements the tour points at.
public enum ChatTourAnchor: String, Sendable {
    case sidebar
    case tabStrip
    case overflowMenu
}

struct ChatTourStop: Identifiable {
    let id: String
    let anchor: ChatTourAnchor
    let title: String
    let body: String
    /// Keyboard shortcut chips shown under the body.
    let chips: [String]
}

extension ChatTourStop {
    /// The four stops, in order. Copy leads with "moved / still here" so the
    /// message is reassurance, not a feature pitch.
    @MainActor static var all: [ChatTourStop] {
        [
            ChatTourStop(
                id: "agents",
                anchor: .sidebar,
                title: L("Agents come first now"),
                body: L(
                    "The sidebar lists your agents. Pick one to open it in its own tab, hover a row for its settings, and switch to Projects with the tab above. The selected agent shows which chat is open."
                ),
                chips: []
            ),
            ChatTourStop(
                id: "history",
                anchor: .overflowMenu,
                title: L("Your chats didn\u{2019}t go anywhere"),
                body: L(
                    "Chat history moved out of the sidebar into this menu. See History lists every conversation for the selected agent, with search, import, and the same actions as before."
                ),
                chips: []
            ),
            ChatTourStop(
                id: "tabs",
                anchor: .tabStrip,
                title: L("Every chat is a tab"),
                body: L(
                    "Open several chats side by side, like a browser. A reply keeps streaming in a background tab, and you can drag tabs to reorder them."
                ),
                chips: ["⌘T", "⌘W", "⇧⌘T", "⌃Tab"]
            ),
            ChatTourStop(
                id: "menu",
                anchor: .overflowMenu,
                title: L("Pin Window and Settings moved too"),
                body: L(
                    "The pin and settings buttons now live under the same menu as history, so the title bar stays clear for your tabs."
                ),
                chips: []
            ),
        ]
    }
}

// MARK: - Tour controller

@MainActor
public final class ChatLayoutTour: ObservableObject {
    public static let shared = ChatLayoutTour()

    /// Once-per-user gate. Set when the tour finishes or is skipped, and
    /// silently on fresh installs (no prior chats: nothing "moved" for them).
    private static let completedKey = "chatLayoutTourCompleted"

    /// The chat window the tour is running in, or nil when inactive.
    @Published private(set) var windowId: UUID?
    @Published private(set) var stepIndex: Int = 0
    /// Latest reported frame per anchor, per window (window coordinates).
    @Published private(set) var anchors: [UUID: [ChatTourAnchor: CGRect]] = [:]

    let stops = ChatTourStop.all

    private var overlayWindow: NSWindow?
    private var overlayHost: NSHostingView<ChatTourOverlayView>?
    private var windowObservers: [NSObjectProtocol] = []
    private var escapeMonitor: Any?
    private var didAutoCheckThisLaunch = false

    private init() {}

    public var isActive: Bool { windowId != nil }

    var currentStop: ChatTourStop? {
        guard isActive, stops.indices.contains(stepIndex) else { return nil }
        return stops[stepIndex]
    }

    // MARK: Eligibility

    /// Auto-offer once, to users who already had chats before this layout
    /// (an update); fresh installs are marked done without a tour. Called
    /// when a chat window becomes key; runs at most once per launch.
    func autoStartIfEligible(windowId: UUID) {
        guard !didAutoCheckThisLaunch else { return }
        didAutoCheckThisLaunch = true
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.completedKey) else { return }
        guard !ChatSessionsManager.shared.sessions.isEmpty else {
            defaults.set(true, forKey: Self.completedKey)
            return
        }
        // Let the first layout pass settle so anchors are reported.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.start(in: windowId)
        }
    }

    // MARK: Lifecycle

    /// Start (or restart) the tour in `windowId`, or in the last focused
    /// chat window, creating one when none exists. Help ▸ Chat Layout Tour.
    public func start(in requestedWindowId: UUID? = nil) {
        if isActive { finish(markCompleted: false) }
        let manager = ChatWindowManager.shared
        let targetId: UUID
        if let requestedWindowId, manager.getNSWindow(id: requestedWindowId) != nil {
            targetId = requestedWindowId
        } else if let last = manager.lastFocusedWindowId, manager.getNSWindow(id: last) != nil {
            targetId = last
        } else {
            targetId = manager.createWindow()
        }
        manager.showWindow(id: targetId)
        guard let state = manager.windowState(id: targetId) else { return }
        // Stop 1 points at the sidebar; make sure it is open. The project
        // page hides the tabs and trims the menu, so leave it too.
        state.openProjectId = nil
        withAnimation(state.theme.animationQuick()) { state.showSidebar = true }
        windowId = targetId
        stepIndex = 0
        presentOverlay(for: targetId)
    }

    func next() {
        guard isActive else { return }
        if stepIndex + 1 < stops.count {
            stepIndex += 1
        } else {
            finish(markCompleted: true)
        }
    }

    func back() {
        guard isActive, stepIndex > 0 else { return }
        stepIndex -= 1
    }

    func skip() {
        finish(markCompleted: true)
    }

    private func finish(markCompleted: Bool) {
        if markCompleted {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
        }
        windowId = nil
        stepIndex = 0
        dismissOverlay()
    }

    // MARK: Anchors

    /// Called by `TourAnchorMarker` whenever an anchored view lays out.
    func report(anchor: ChatTourAnchor, frame: CGRect, in window: NSWindow) {
        guard let id = ChatWindowManager.shared.windowId(for: window) else { return }
        var perWindow = anchors[id] ?? [:]
        if let existing = perWindow[anchor], existing.equalTo(frame) { return }
        perWindow[anchor] = frame
        anchors[id] = perWindow
    }

    func clear(anchor: ChatTourAnchor, in window: NSWindow) {
        guard let id = ChatWindowManager.shared.windowId(for: window) else { return }
        anchors[id]?[anchor] = nil
    }

    func frame(of anchor: ChatTourAnchor) -> CGRect? {
        guard let windowId else { return nil }
        return anchors[windowId]?[anchor]
    }

    // MARK: Overlay window

    private func presentOverlay(for id: UUID) {
        guard let chatWindow = ChatWindowManager.shared.getNSWindow(id: id) else { return }
        let overlay = TourOverlayWindow(
            contentRect: chatWindow.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = false
        overlay.isReleasedWhenClosed = false
        overlay.level = chatWindow.level
        overlay.collectionBehavior = [.fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: ChatTourOverlayView(tour: self, windowId: id))
        host.frame = NSRect(origin: .zero, size: chatWindow.frame.size)
        host.autoresizingMask = [.width, .height]
        overlay.contentView = host
        chatWindow.addChildWindow(overlay, ordered: .above)
        overlay.makeKeyAndOrderFront(nil)
        overlayWindow = overlay
        overlayHost = host

        // Track the chat window so the overlay stays glued to it, and end
        // the tour if the window goes away.
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: chatWindow, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.syncOverlayFrame() }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: chatWindow, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.syncOverlayFrame() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: chatWindow, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.finish(markCompleted: false) }
            },
        ]
        // Esc skips, wherever keyboard focus is.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.skip() }
            return nil
        }
    }

    private func syncOverlayFrame() {
        guard let windowId, let chatWindow = ChatWindowManager.shared.getNSWindow(id: windowId),
            let overlayWindow
        else { return }
        overlayWindow.setFrame(chatWindow.frame, display: true)
    }

    private func dismissOverlay() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let overlayWindow {
            overlayWindow.parent?.removeChildWindow(overlayWindow)
            overlayWindow.orderOut(nil)
        }
        overlayWindow = nil
        overlayHost = nil
    }
}

// MARK: - Anchor marker

/// Invisible view that reports its host's frame (in window coordinates) to
/// the tour. Attach as a `.background` of the element to spotlight so the
/// marker's bounds equal the element's.
struct TourAnchorMarker: NSViewRepresentable {
    let anchor: ChatTourAnchor

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(anchor: anchor)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        let anchor: ChatTourAnchor

        init(anchor: ChatTourAnchor) {
            self.anchor = anchor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let window {
                let anchor = self.anchor
                DispatchQueue.main.async {
                    ChatLayoutTour.shared.clear(anchor: anchor, in: window)
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func report() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let frame = convert(bounds, to: nil)
            let anchor = self.anchor
            // Defer: `layout` runs mid-layout-pass; publishing state from
            // inside it re-enters SwiftUI.
            DispatchQueue.main.async {
                ChatLayoutTour.shared.report(anchor: anchor, frame: frame, in: window)
            }
        }
    }
}

// MARK: - Overlay

/// Dimmed scrim with a spotlight cutout around the current stop's anchor
/// and a callout card beside it.
struct ChatTourOverlayView: View {
    @ObservedObject var tour: ChatLayoutTour
    let windowId: UUID

    private var theme: ThemeProtocol {
        ChatWindowManager.shared.windowState(id: windowId)?.theme ?? ThemeManager.shared.currentTheme
    }

    private static let spotlightPadding: CGFloat = 6
    private static let cardWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let stop = tour.currentStop
            // Window coords are bottom-left; SwiftUI is top-left.
            let spotlight: CGRect? = stop.flatMap { tour.frame(of: $0.anchor) }.map { f in
                CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
                    .insetBy(dx: -Self.spotlightPadding, dy: -Self.spotlightPadding)
            }
            ZStack(alignment: .topLeading) {
                scrim(cutout: spotlight, in: size)
                if let stop {
                    if let spotlight {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.accentColor.opacity(0.9), lineWidth: 2)
                            .frame(width: spotlight.width, height: spotlight.height)
                            .offset(x: spotlight.minX, y: spotlight.minY)
                            .allowsHitTesting(false)
                    }
                    card(for: stop)
                        .frame(width: Self.cardWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(cardOffset(spotlight: spotlight, in: size))
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(theme.springAnimation(responseMultiplier: 0.9), value: tour.stepIndex)
            .animation(theme.springAnimation(responseMultiplier: 0.9), value: spotlight)
        }
        .environment(\.theme, theme)
    }

    private func scrim(cutout: CGRect?, in size: CGSize) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.45))
            .mask {
                ZStack {
                    Rectangle()
                    if let cutout {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .frame(width: cutout.width, height: cutout.height)
                            .position(x: cutout.midX, y: cutout.midY)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
            }
            .frame(width: size.width, height: size.height)
            // The scrim swallows clicks so the user follows the tour; the
            // spotlighted control is explained, not driven, at each stop.
            .contentShape(Rectangle())
            .onTapGesture {}
    }

    /// Place the card under the spotlight when there is room, else above,
    /// clamped inside the window horizontally. With no anchor (not laid out
    /// yet or hidden) the card sits centred.
    private func cardOffset(spotlight: CGRect?, in size: CGSize) -> CGSize {
        let cardHeight: CGFloat = 200
        let gap: CGFloat = 12
        guard let s = spotlight else {
            return CGSize(width: (size.width - Self.cardWidth) / 2, height: (size.height - cardHeight) / 2)
        }
        var x = s.midX - Self.cardWidth / 2
        x = min(max(x, 16), size.width - Self.cardWidth - 16)
        let below = s.maxY + gap
        let y = below + cardHeight <= size.height ? below : max(16, s.minY - gap - cardHeight)
        return CGSize(width: x, height: y)
    }

    private func card(for stop: ChatTourStop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: stop.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(verbatim: stop.body)
                .font(.system(size: 12.5))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !stop.chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(stop.chips, id: \.self) { chip in
                        Text(verbatim: chip)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(theme.tertiaryBackground.opacity(0.8))
                            )
                    }
                }
            }
            HStack(spacing: 8) {
                Text(verbatim: "\(tour.stepIndex + 1) / \(tour.stops.count)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Button { tour.skip() } label: {
                    Text("Skip", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                if tour.stepIndex > 0 {
                    Button { tour.back() } label: {
                        Text("Back", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                Button { tour.next() } label: {
                    Text(tour.stepIndex + 1 == tour.stops.count ? "Done" : "Next", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .shadow(color: theme.shadowColor.opacity(0.35), radius: 24, y: 8)
    }
}

/// Borderless windows refuse key status by default; the overlay takes it
/// so its buttons respond to the first click and Return advances.
private final class TourOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

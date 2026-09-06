//
//  ChatLayoutTour.swift
//  osaurus
//
//  Coachmark tour for the agent-first chat layout: spotlights the live UI
//  (sidebar, tab strip, history and pin buttons, settings) with a short
//  callout per stop so users updating from the old layout learn that nothing was removed, only
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
    /// The Agents | Projects lens switcher at the top of the sidebar.
    case sidebarLensBar
    case tabStrip
    case historyButton
}

struct ChatTourStop: Identifiable {
    let id: String
    let anchor: ChatTourAnchor
    let title: String
    let body: String
}

extension ChatTourStop {
    /// The three stops, in order. Copy leads with "moved / still here" so the
    /// message is reassurance, not a feature pitch.
    @MainActor static var all: [ChatTourStop] {
        [
            ChatTourStop(
                id: "agents",
                anchor: .sidebarLensBar,
                title: L("Chats are now organized by agent"),
                body: L(
                    "Choose an agent to continue your conversation.\n\nYou can start a new chat with that agent anytime."
                )
            ),
            ChatTourStop(
                id: "tabs",
                anchor: .tabStrip,
                title: L("Every chat is a tab"),
                body: L(
                    "Open multiple chats and switch between them like browser tabs, without interrupting responses in progress."
                )
            ),
            ChatTourStop(
                id: "history",
                anchor: .historyButton,
                title: L("Your chat history"),
                body: L("View and search past chats with this agent.")
            ),
        ]
    }
}

// MARK: - Tour controller

@MainActor
public final class ChatLayoutTour: ObservableObject {
    public static let shared = ChatLayoutTour()

    /// Once-per-user gate. Set when the tour finishes or is dismissed.
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

    /// Auto-offer once per user: existing users get it as a "here's what
    /// moved" walkthrough, fresh installs as a first-run intro to the same
    /// layout. Called when a chat window becomes key; runs at most once per
    /// launch, and never again once finished or dismissed.
    func autoStartIfEligible(windowId: UUID) {
        guard !didAutoCheckThisLaunch else { return }
        didAutoCheckThisLaunch = true
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
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

    // MARK: Spotlight morph

    /// The spotlight rect currently ON SCREEN, in window coordinates. The
    /// morph between stops is interpolated here on a common-mode timer so it
    /// keeps running while menus or other tracking loops are active.
    @Published private(set) var displayedCutout: CGRect?
    private var morphTimer: Timer?
    private static let morphDuration: TimeInterval = 0.25

    /// Move the spotlight to `target`: instantly (first layout, resize, or
    /// when there was no spotlight before) or as a short ease-out morph.
    func setSpotlight(_ target: CGRect?, animated: Bool) {
        morphTimer?.invalidate()
        morphTimer = nil
        guard animated, let from = displayedCutout, let to = target, from != to else {
            displayedCutout = target
            return
        }
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, Date().timeIntervalSince(start) / Self.morphDuration)
                let e = 1 - pow(1 - t, 3)  // ease-out cubic, no overshoot
                let rect = CGRect(
                    x: from.minX + (to.minX - from.minX) * e,
                    y: from.minY + (to.minY - from.minY) * e,
                    width: from.width + (to.width - from.width) * e,
                    height: from.height + (to.height - from.height) * e)
                self.displayedCutout = rect
                if t >= 1 {
                    self.morphTimer?.invalidate()
                    self.morphTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        morphTimer = timer
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
        overlay.orderFront(nil)
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
        morphTimer?.invalidate()
        morphTimer = nil
        displayedCutout = nil
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

    /// Measured card size, so placement above an anchor uses the real
    /// height instead of a guess (a short card floated far above its target).
    @State private var cardSize: CGSize = .zero


    private var theme: ThemeProtocol {
        ChatWindowManager.shared.windowState(id: windowId)?.theme ?? ThemeManager.shared.currentTheme
    }

    private static let spotlightPadding: CGFloat = 6

    /// Pad the reported anchor frame into the spotlight. The tab strip's
    /// reported frame runs a little left of the chips (the strip's own
    /// leading inset and the active tab's flare) and stops short of the
    /// plus button's hit circle, so it gets an asymmetric correction.
    private static func calibrated(_ frame: CGRect, for anchor: ChatTourAnchor) -> CGRect {
        let p = spotlightPadding
        switch anchor {
        case .tabStrip:
            return CGRect(
                x: frame.minX + 12, y: frame.minY - p,
                width: frame.width - 12 + 10, height: frame.height + 2 * p)
        default:
            return frame.insetBy(dx: -p, dy: -p)
        }
    }
    private static let cardWidth: CGFloat = 320

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let stop = tour.currentStop
            // Window coords are bottom-left; SwiftUI is top-left.
            // Anchors are in AppKit (bottom-left) window coordinates; the
            // scrim and card draw in SwiftUI (top-left).
            let targetCutout: CGRect? = stop.flatMap { s in
                tour.frame(of: s.anchor).map { Self.calibrated($0, for: s.anchor) }
            }
            // What is drawn is the controller's interpolated rect; the
            // target only tells it where to go.
            let spotlight: CGRect? = tour.displayedCutout.map { f in
                CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
            }
            let cardTarget: CGRect? = targetCutout.map { f in
                CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)
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
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        // The card heads straight for the destination on the same
                        // clock as the morph.
                        .offset(cardOffset(spotlight: cardTarget, in: size))
                        .animation(.easeOut(duration: 0.25), value: tour.stepIndex)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { tour.setSpotlight(targetCutout, animated: false) }
            // Step change: morph. Anchor re-measure or window resize: snap,
            // so the spotlight never lags a live resize.
            // One handler for both triggers so their relative order can't
            // matter: a step change morphs, anything else snaps.
            .onChange(of: SpotlightKey(step: tour.stepIndex, target: targetCutout)) { old, new in
                tour.setSpotlight(new.target, animated: new.step != old.step)
            }
            .onChange(of: size) { _, _ in tour.setSpotlight(targetCutout, animated: false) }
        }
        .environment(\.theme, theme)
    }

    private func scrim(cutout: CGRect?, in size: CGSize) -> some View {
        Rectangle()
            // A light tint is all the dimming there is: the UI stays fully
            // readable in context, and the outline + card carry the focus.
            .fill(Color.black.opacity(theme.isDark ? 0.14 : 0.07))
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
        // Fall back to a typical height until the first measurement lands.
        let cardHeight: CGFloat = cardSize.height > 0 ? cardSize.height : 200
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
            // Footer: progress on the left, navigation on the right. No Skip:
            // four short stops don't need one (Esc still bails out).
            HStack(spacing: 12) {
                Text(verbatim: "\(tour.stepIndex + 1) / \(tour.stops.count)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Spacer(minLength: 16)
                if tour.stepIndex > 0 {
                    Button { tour.back() } label: {
                        Text("Back", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().stroke(theme.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                let isLast = tour.stepIndex + 1 == tour.stops.count
                    Button { tour.next() } label: {
                        Text(isLast ? "Done" : "Next", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(theme.accentColor))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
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
        // Lifted well off the backdrop.
        .shadow(color: Color.black.opacity(0.28), radius: 30, y: 14)
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
    }
}

/// The overlay never takes key: the chat window stays key so its hover
/// tracking (the action-driven stop) keeps working underneath the cutout.
/// Mouse events at fully transparent pixels of a non-opaque window pass
/// through to the window below, which is how the cutout stays live.
private final class TourOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Change key for the spotlight: which stop is showing and where its anchor
/// currently is.
private struct SpotlightKey: Equatable {
    let step: Int
    let target: CGRect?
}

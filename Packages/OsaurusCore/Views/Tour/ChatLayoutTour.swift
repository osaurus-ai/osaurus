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
    /// The Agents | Projects lens switcher at the top of the sidebar.
    case sidebarLensBar
    case sidebar
    case tabStrip
    case overflowMenu
}

struct ChatTourShortcut: Hashable {
    let keys: String
    let label: String
}

struct ChatTourStop: Identifiable {
    let id: String
    let anchor: ChatTourAnchor
    let title: String
    let body: String
    /// Keyboard shortcuts listed under the body, one per row.
    var shortcuts: [ChatTourShortcut] = []
    /// Action-driven stop: no Next button; it completes when the user
    /// performs the spotlighted action (see `ChatLayoutTour.noteAction`).
    var requiresAction: Bool = false
    /// Hint shown instead of Next while an action is awaited.
    var actionHint: String? = nil
}

extension ChatTourStop {
    /// The four stops, in order. Copy leads with "moved / still here" so the
    /// message is reassurance, not a feature pitch.
    @MainActor static var all: [ChatTourStop] {
        [
            ChatTourStop(
                id: "agents",
                anchor: .sidebarLensBar,
                title: L("Agents come first now"),
                body: L(
                    "The sidebar now lists your agents, with Projects one tab over.\n\nPick an agent to open it in its own tab, and hover a row for its settings.\n\nThe selected agent shows which chat is open."
                )
            ),
            ChatTourStop(
                id: "tabs",
                anchor: .tabStrip,
                title: L("Every chat is a tab"),
                body: L(
                    "Open several chats side by side, like a browser.\n\nA reply keeps streaming in a background tab.\n\nDrag tabs to reorder them."
                ),
                shortcuts: [
                    ChatTourShortcut(keys: "⌘T", label: L("New tab")),
                    ChatTourShortcut(keys: "⌘W", label: L("Close tab")),
                    ChatTourShortcut(keys: "⇧⌘T", label: L("Reopen the last closed tab")),
                    ChatTourShortcut(keys: "⌃Tab", label: L("Next tab")),
                ]
            ),
            ChatTourStop(
                id: "history",
                anchor: .overflowMenu,
                title: L("Your chats didn’t go anywhere"),
                body: L(
                    "Chat history moved out of the sidebar into this menu.\n\nSee History lists every conversation for the selected agent, with search, import, and the same actions as before."
                ),
                requiresAction: true,
                actionHint: L("Hover the ⋯ button to open the menu")
            ),
            ChatTourStop(
                id: "menu",
                anchor: .overflowMenu,
                title: L("Pin Window and Settings moved too"),
                body: L(
                    "The pin and settings buttons now live under the same menu as history.\n\nThat keeps the title bar clear for your tabs."
                )
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
    /// Height of the overflow menu while it is open, so the last stop's
    /// card can sit BELOW the menu instead of behind it. Reset per step.
    @Published private(set) var overflowMenuHeight: CGFloat = 0
    /// True while the next card is being held back after an action-driven
    /// stop completes, so it doesn't snap in the instant the pointer reaches
    /// the button. Driven by a run-loop timer in common modes: the overflow
    /// menu's tracking loop would starve a main-actor `Task.sleep` until the
    /// menu closed.
    @Published private(set) var cardRevealPending = false
    private var cardRevealTimer: Timer?

    let stops = ChatTourStop.all

    private var overlayWindow: NSWindow?
    private var overlayHost: NSHostingView<ChatTourOverlayView>?
    private var blurView: NSVisualEffectView?
    /// Current spotlight in window coordinates, for the pass-through check.
    private var currentCutout: CGRect?
    private var passThroughTimer: Timer?
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
        overflowMenuHeight = 0
        cardRevealTimer?.invalidate()
        cardRevealPending = false
        if stepIndex + 1 < stops.count {
            stepIndex += 1
            } else {
            finish(markCompleted: true)
        }
    }

    func back() {
        guard isActive, stepIndex > 0 else { return }
        overflowMenuHeight = 0
        cardRevealTimer?.invalidate()
        cardRevealPending = false
        stepIndex -= 1
    }

    func skip() {
        finish(markCompleted: true)
    }

    /// Action-driven stop: completes the moment the pointer reaches the
    /// overflow button (the hover that opens its menu), so the card is gone
    /// by the time the menu appears.
    func noteOverflowHovered() {
        guard let stop = currentStop, stop.requiresAction, stop.anchor == .overflowMenu else { return }
        next()
        cardRevealPending = true
        cardRevealTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.35)) { self.cardRevealPending = false }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardRevealTimer = timer
    }

    /// Called just before the overflow menu pops up (its size is known then).
    func noteOverflowMenuWillOpen(height: CGFloat) {
        guard isActive else { return }
        overflowMenuHeight = height
    }

    func noteOverflowMenuDidClose() {
        guard isActive else { return }
        overflowMenuHeight = 0
    }

    /// Blur everything behind the overlay except the spotlight. The blur is
    /// an `NSVisualEffectView` (behind-window) whose mask clears the cutout;
    /// the cleared region is fully transparent, so hover and clicks there
    /// reach the chat window (which the action-driven stop relies on).
    func updateBlurMask(cutout: CGRect?) {
        currentCutout = cutout
        guard let blurView, let overlayWindow else { return }
        let size = overlayWindow.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            if let cutout {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(roundedRect: cutout, xRadius: 10, yRadius: 10).fill()
            }
            return true
        }
        image.resizingMode = .stretch
        blurView.maskImage = image
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
        // Blur layer (behind-window) under the SwiftUI scrim + card.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: chatWindow.frame.size))
        blur.blendingMode = .behindWindow
        blur.material = .hudWindow
        blur.state = .active
        // Partial opacity softens the blur so the layout underneath stays
        // recognisable; the card's shadow carries the focus instead.
        blur.alphaValue = 0.92
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: ChatTourOverlayView(tour: self, windowId: id))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        overlay.contentView = blur
        blurView = blur
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
        // Mouse pass-through: an overlay window swallows events even where
        // it is transparent, so while the cursor sits inside the spotlight
        // the whole overlay steps aside (`ignoresMouseEvents`) and the real
        // control underneath gets the hover/click — the action-driven stop
        // depends on it. Polled: mouse-moved events aren't delivered to a
        // window that ignores them, so a monitor can't see the cursor leave.
        passThroughTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePassThrough() }
        }
        // Esc skips, wherever keyboard focus is.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.skip() }
            return nil
        }
    }

    private func updatePassThrough() {
        guard let overlayWindow, let cutout = currentCutout else { return }
        let screenCutout = cutout.offsetBy(dx: overlayWindow.frame.minX, dy: overlayWindow.frame.minY)
        let inside = screenCutout.contains(NSEvent.mouseLocation)
        if overlayWindow.ignoresMouseEvents != inside {
            overlayWindow.ignoresMouseEvents = inside
        }
    }

    private func syncOverlayFrame() {
        guard let windowId, let chatWindow = ChatWindowManager.shared.getNSWindow(id: windowId),
            let overlayWindow
        else { return }
        overlayWindow.setFrame(chatWindow.frame, display: true)
    }

    private func dismissOverlay() {
        passThroughTimer?.invalidate()
        passThroughTimer = nil
        cardRevealTimer?.invalidate()
        cardRevealTimer = nil
        cardRevealPending = false
        currentCutout = nil
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
        blurView = nil
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
            // AppKit (bottom-left) cutout for the blur mask, SwiftUI (top-left)
            // for the scrim and card.
            let appKitCutout: CGRect? = stop.flatMap { s in
                tour.frame(of: s.anchor).map { Self.calibrated($0, for: s.anchor) }
            }
            let spotlight: CGRect? = appKitCutout.map { f in
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
                        .opacity(tour.cardRevealPending ? 0 : 1)
                        .allowsHitTesting(!tour.cardRevealPending)
                        .offset(cardOffset(spotlight: spotlight, in: size, clearance: tour.overflowMenuHeight))
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(theme.springAnimation(responseMultiplier: 0.9), value: tour.stepIndex)
            .animation(theme.springAnimation(responseMultiplier: 0.9), value: spotlight)
            .onAppear { tour.updateBlurMask(cutout: appKitCutout) }
            .onChange(of: appKitCutout) { _, cutout in tour.updateBlurMask(cutout: cutout) }
            .onChange(of: size) { _, _ in tour.updateBlurMask(cutout: appKitCutout) }
        }
        .environment(\.theme, theme)
    }

    private func scrim(cutout: CGRect?, in size: CGSize) -> some View {
        Rectangle()
            // Light tint only: the behind-window blur underneath does the
            // work of pulling focus to the card.
            .fill(Color.black.opacity(theme.isDark ? 0.25 : 0.12))
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
    private func cardOffset(spotlight: CGRect?, in size: CGSize, clearance: CGFloat = 0) -> CGSize {
        let cardHeight: CGFloat = 240
        // `clearance`: an open menu hanging under the anchor; the card drops
        // below it (menus pop up ~16pt under the pointer, hence the slack).
        let gap: CGFloat = 12 + (clearance > 0 ? clearance + 16 : 0)
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
            if !stop.shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(stop.shortcuts, id: \.self) { shortcut in
                        HStack(spacing: 10) {
                            Text(verbatim: shortcut.keys)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.primaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .frame(minWidth: 56)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(theme.tertiaryBackground.opacity(0.8))
                                )
                            Text(verbatim: shortcut.label)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
                .padding(.top, 2)
            }
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
                if stop.requiresAction {
                    // Action-driven: the user performs the spotlighted action
                    // to move on; the hint replaces Next.
                    HStack(spacing: 5) {
                        Image(systemName: "hand.point.up.left")
                            .font(.system(size: 11, weight: .medium))
                        Text(verbatim: stop.actionHint ?? "")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.accentColor.opacity(0.14)))
                    .overlay(Capsule().stroke(theme.accentColor.opacity(0.35), lineWidth: 1))
                    .modifier(TourShimmer())
                } else {
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
        // Lifted well off the blurred backdrop.
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

/// A soft highlight that sweeps across the view on a loop, to draw the eye
/// to the one control the user has to act on. Static under Reduce Motion.
private struct TourShimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        let w = proxy.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.35), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: w * 0.6)
                        .offset(x: phase * w)
                        .blendMode(.plusLighter)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

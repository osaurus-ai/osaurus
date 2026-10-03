//
//  AnchoredCardPresenter.swift
//  Osaurus
//
//  A transient, arrowless SwiftUI card attached to its source control.
//

import AppKit
import QuartzCore
import SwiftUI

extension View {
    /// Presents a card above this view, falling back below when the display
    /// has more room there. Content receives the actual screen-constrained
    /// size and owns its surface, border and corner treatment. A zero height
    /// lets content report its measured size before the card first appears.
    /// Shadow padding extends only the transparent drawing surface, not layout.
    func anchoredCard<Card: View>(
        isPresented: Binding<Bool>,
        size: CGSize,
        alignment: HorizontalAlignment = .leading,
        constrainToWindow: Bool = false,
        takesFocus: Bool = true,
        shadowPadding: CGFloat = 0,
        accessibilityLabel: String = "Options",
        @ViewBuilder content: () -> Card
    ) -> some View {
        background(
            AnchoredCardAnchor(
                isPresented: isPresented,
                size: size,
                alignment: alignment,
                constrainToWindow: constrainToWindow,
                takesFocus: takesFocus,
                shadowPadding: shadowPadding,
                accessibilityLabel: accessibilityLabel,
                content: content()
            )
        )
    }
}

/// A preview stays open while either side of the trigger-to-panel handoff
/// is hovered. Check this again when a delayed dismissal fires: hover callbacks
/// from separate windows can arrive in either order.
struct HoverPreviewPresence {
    var isOverTrigger = false
    var isOverPanel = false

    func shouldDismiss(isPinned: Bool) -> Bool {
        !isPinned && !isOverTrigger && !isOverPanel
    }
}

/// Screen coordinates use AppKit's bottom-left origin. Keep this calculation
/// independent of the window so edge cases can be checked without showing UI.
enum AnchoredCardPlacement {
    static func availableFrame(visibleFrame: CGRect, containerFrame: CGRect? = nil) -> CGRect {
        let intersection = containerFrame.map { visibleFrame.intersection($0) } ?? visibleFrame
        let bounds = intersection.isEmpty ? visibleFrame : intersection
        return bounds.insetBy(dx: min(12, bounds.width / 4), dy: min(12, bounds.height / 4))
    }

    static func frame(
        anchor: CGRect,
        size: CGSize,
        visibleFrame: CGRect,
        rightToLeft: Bool = false,
        trailingAligned: Bool = false,
        containerFrame: CGRect? = nil,
        preferAbove: Bool? = nil
    ) -> CGRect {
        let gap: CGFloat = 8
        let safe = availableFrame(visibleFrame: visibleFrame, containerFrame: containerFrame)
        let width = min(max(1, size.width), safe.width)
        let desiredHeight = max(1, size.height)
        let above = max(0, safe.maxY - anchor.maxY - gap)
        let below = max(0, anchor.minY - gap - safe.minY)
        let placeAbove = preferAbove ?? (above >= desiredHeight || (below < desiredHeight && above >= below))
        let height = min(desiredHeight, max(1, placeAbove ? above : below))
        let alignRight = rightToLeft != trailingAligned
        let preferredX = alignRight ? anchor.maxX - width : anchor.minX
        let preferredY = placeAbove ? anchor.maxY + gap : anchor.minY - gap - height
        return CGRect(
            x: min(max(preferredX, safe.minX), safe.maxX - width),
            y: min(max(preferredY, safe.minY), safe.maxY - height),
            width: width,
            height: height
        )
    }
}

/// The visible card and its SwiftUI content share one presentation size.
/// Transparent shadow padding is excluded from these layout metrics. Content
/// can clip a retiring column without maintaining a second animation.
struct AnchoredCardMetrics: Equatable {
    var visibleSize: CGSize
    var targetSize: CGSize
    var availableSize: CGSize
    var isAnimating: Bool
}

private struct AnchoredCardMetricsKey: EnvironmentKey {
    static let defaultValue: AnchoredCardMetrics? = nil
}

extension EnvironmentValues {
    var anchoredCardMetrics: AnchoredCardMetrics? {
        get { self[AnchoredCardMetricsKey.self] }
        set { self[AnchoredCardMetricsKey.self] = newValue }
    }
}

@MainActor
private final class AnchoredCardPresentation: ObservableObject {
    var content: (AnchoredCardMetrics) -> AnyView
    var metrics: AnchoredCardMetrics
    var shadowPadding: CGFloat

    init(content: @escaping (AnchoredCardMetrics) -> AnyView, metrics: AnchoredCardMetrics, shadowPadding: CGFloat) {
        self.content = content
        self.metrics = metrics
        self.shadowPadding = shadowPadding
    }

    func update(content: @escaping (AnchoredCardMetrics) -> AnyView, metrics: AnchoredCardMetrics, shadowPadding: CGFloat) {
        objectWillChange.send()
        self.content = content
        self.metrics = metrics
        self.shadowPadding = shadowPadding
    }
}

private struct AnchoredCardRoot: View {
    @ObservedObject var presentation: AnchoredCardPresentation

    var body: some View {
        presentation.content(presentation.metrics)
            .frame(width: presentation.metrics.visibleSize.width, height: presentation.metrics.visibleSize.height)
            // The card's layout and anchor use its visible bounds. Only the
            // transparent native drawing surface grows to contain the shadow.
            .padding(presentation.shadowPadding)
            .transaction {
                // The native viewport is the only animation clock. Letting
                // SwiftUI animate layout again would lag behind the surface.
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

private struct AnchoredCardAnchor<Card: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let size: CGSize
    let alignment: HorizontalAlignment
    let constrainToWindow: Bool
    let takesFocus: Bool
    let shadowPadding: CGFloat
    let accessibilityLabel: String
    let content: Card

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale

    func makeCoordinator() -> AnchoredCardCoordinator { AnchoredCardCoordinator() }

    func makeNSView(context: Context) -> AnchoredCardMarkerView {
        let view = AnchoredCardMarkerView()
        context.coordinator.anchor = view
        view.onGeometryChange = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleUpdate()
        }
        return view
    }

    func updateNSView(_ view: AnchoredCardMarkerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        coordinator.requestedSize = size
        coordinator.accessibilityLabel = accessibilityLabel
        coordinator.rightToLeft = layoutDirection == .rightToLeft
        coordinator.trailingAligned = alignment == .trailing
        coordinator.constrainToWindow = constrainToWindow
        coordinator.takesFocus = takesFocus
        coordinator.shadowPadding = max(0, shadowPadding)
        coordinator.content = { metrics in
            AnyView(content
                .environment(\.anchoredCardMetrics, metrics)
                // A separate hosting window needs its own focus environment.
                // Forward visual values rather than the parent's focus bridge.
                .environment(\.theme, theme)
                .environment(\.colorScheme, colorScheme)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.locale, locale)
                .tint(theme.accentColor))
        }
        coordinator.scheduleUpdate()
    }

    static func dismantleNSView(_ view: AnchoredCardMarkerView, coordinator: AnchoredCardCoordinator) {
        view.onGeometryChange = nil
        coordinator.tearDown(restoreFocus: false)
        coordinator.anchor = nil
        coordinator.isPresented = nil
    }
}

@MainActor
private final class AnchoredCardCoordinator {
    weak var anchor: AnchoredCardMarkerView?
    var isPresented: Binding<Bool>?
    var requestedSize: CGSize = .zero
    var accessibilityLabel = ""
    var rightToLeft = false
    var trailingAligned = false
    var constrainToWindow = false
    var takesFocus = true
    var shadowPadding: CGFloat = 0
    var content: (AnchoredCardMetrics) -> AnyView = { _ in AnyView(EmptyView()) }

    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var panel: AnchoredCardPanel?
    private var host: NSHostingView<AnchoredCardRoot>?
    private var presentation: AnchoredCardPresentation?
    private var resizeTransition: AnchoredCardResizeTransition?
    private var resizeTimer: Timer?
    private var availableSize: CGSize = .zero
    private var lastAnchorFrame: CGRect?
    private var prefersAbove: Bool?
    private var suppressNextAnimation = false
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var updateScheduled = false
    /// Visible card bounds, excluding the transparent shadow margin.
    private var presentedFrame = NSRect.zero

    private func windowFrame(for cardFrame: CGRect) -> CGRect {
        cardFrame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
    }

    // NSViewRepresentable updates and layout callbacks may occur during a
    // SwiftUI render. Defer panel mutations and binding writes one turn.
    func scheduleUpdate(animateResize: Bool = true) {
        if !animateResize { suppressNextAnimation = true }
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updatePresentation()
        }
    }

    private func updatePresentation() {
        guard isPresented?.wrappedValue == true else {
            tearDown(restoreFocus: true)
            return
        }
        guard let anchor, let window = anchor.window, window.isVisible,
            !window.isMiniaturized, NSApp.isActive
        else {
            if panel != nil { dismiss(restoreFocus: false) }
            return
        }
        guard anchor.bounds.width > 0, anchor.bounds.height > 0 else { return }

        if let parent, parent !== window {
            tearDown(restoreFocus: false)
        }
        let placement = placement(anchor: anchor, window: window)
        let frame = placement.frame
        availableSize = placement.availableSize
        // A model label can change the chip's width without moving its
        // origin. That is a selection resize, not a window move to snap.
        let anchorMoved = lastAnchorFrame.map { $0.origin != placement.anchorFrame.origin } ?? false
        lastAnchorFrame = placement.anchorFrame
        if requestedSize.height > 0 { prefersAbove = frame.minY >= placement.anchorFrame.maxY }
        let skipAnimation = suppressNextAnimation || anchorMoved
        suppressNextAnimation = false
        if panel == nil {
            present(in: window, frame: frame)
        }
        guard let panel else { return }
        let firstPresentation = panel.alphaValue == 0
        panel.becomesKeyOnlyIfNeeded = !takesFocus
        panel.setAccessibilityLabel(accessibilityLabel)
        panel.title = accessibilityLabel
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if !skipAnimation, !reduceMotion, resizeTransition?.to == frame {
            // Provider refreshes and option edits must not restart a resize.
            updateContent(target: frame.size, isAnimating: true)
            return
        }
        if presentedFrame == frame {
            stopResize()
            applyFrame(frame, target: frame.size, isAnimating: false)
            showWhenReady()
            return
        }
        let changesSize = presentedFrame.size != frame.size
        if changesSize && !firstPresentation && !skipAnimation && !reduceMotion {
            // Retarget from the last frame actually drawn, including when the
            // user reverses direction before the previous resize finishes.
            resizeTransition = AnchoredCardResizeTransition(
                from: presentedFrame, to: frame, startTime: CACurrentMediaTime()
            )
            updateContent(target: frame.size, isAnimating: true)
            if resizeTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.advanceResize() }
                }
                resizeTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            stopResize()
            applyFrame(frame, target: frame.size, isAnimating: false)
        }
        showWhenReady()
    }

    private func showWhenReady() {
        guard let panel else { return }
        // SwiftUI measures ScrollView content only after the host participates
        // in a visible window. Keep that first layout transparent, non-key,
        // and out of hit testing and accessibility until its size is known.
        guard requestedSize.height > 0 else {
            if !panel.isVisible { panel.orderFront(nil) }
            host?.layoutSubtreeIfNeeded()
            return
        }
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.setAccessibilityHidden(false)
        if takesFocus {
            if !panel.isVisible || !belongsToCard(NSApp.keyWindow) { panel.makeKeyAndOrderFront(nil) }
        } else if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func advanceResize() {
        guard let transition = resizeTransition, panel != nil else {
            stopResize()
            return
        }
        let now = CACurrentMediaTime()
        let finished = transition.isComplete(at: now)
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frame = finished ? transition.to : transition.frame(at: now)
        if finished { stopResize() }
        applyFrame(frame, target: transition.to.size, isAnimating: !finished)
    }

    private func applyFrame(_ frame: CGRect, target: CGSize, isAnimating: Bool) {
        guard let panel else { return }
        presentedFrame = frame
        panel.setFrame(windowFrame(for: frame), display: false)
        updateContent(target: target, isAnimating: isAnimating)
        host?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private func updateContent(target: CGSize, isAnimating: Bool) {
        presentation?.update(
            content: content,
            metrics: AnchoredCardMetrics(
                visibleSize: presentedFrame.size,
                targetSize: target,
                availableSize: availableSize,
                isAnimating: isAnimating
            ),
            shadowPadding: shadowPadding
        )
    }

    private func stopResize() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        resizeTransition = nil
    }

    private func placement(anchor: NSView, window: NSWindow) -> (frame: CGRect, anchorFrame: CGRect, availableSize: CGSize) {
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)) }
            ?? window.screen
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? window.frame
        let containerFrame = constrainToWindow ? window.convertToScreen(window.contentLayoutRect) : nil
        let safeFrame = AnchoredCardPlacement.availableFrame(
            visibleFrame: visibleFrame, containerFrame: containerFrame
        )
        return (
            AnchoredCardPlacement.frame(
                anchor: anchorFrame,
                size: requestedSize,
                visibleFrame: visibleFrame,
                rightToLeft: rightToLeft,
                trailingAligned: trailingAligned,
                containerFrame: containerFrame,
                preferAbove: !suppressNextAnimation && lastAnchorFrame?.origin == anchorFrame.origin ? prefersAbove : nil
            ),
            anchorFrame,
            safeFrame.size
        )
    }

    private func present(in parent: NSWindow, frame: NSRect) {
        self.parent = parent
        previousResponder = parent.firstResponder
        let drawingFrame = windowFrame(for: frame)
        let panel = AnchoredCardPanel(
            contentRect: drawingFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.setAccessibilityHidden(true)
        // AppKit's shadow includes a bright rim on macOS. Let the card's
        // themed stroke own its edge instead of stacking native chrome.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = !takesFocus
        panel.level = parent.level
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }

        let presentation = AnchoredCardPresentation(
            content: content,
            metrics: AnchoredCardMetrics(
                visibleSize: frame.size, targetSize: frame.size,
                availableSize: availableSize, isAnimating: false
            ),
            shadowPadding: shadowPadding
        )
        let host = NSHostingView(rootView: AnchoredCardRoot(presentation: presentation))
        self.presentation = presentation
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: drawingFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        self.host = host
        presentedFrame = frame
        installObservers(parent: parent, panel: panel)
        parent.addChildWindow(panel, ordered: .above)
        panel.recalculateKeyViewLoop()
    }

    private func installObservers(parent: NSWindow, panel: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate(animateResize: false) }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        })
        // Allow a nested native popover or sheet to become key. Evaluate
        // after the current event so AppKit has installed the new key window.
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel != nil else { return }
                if !self.belongsToCard(NSApp.keyWindow) {
                    self.dismiss(restoreFocus: false)
                }
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel != nil else { return }
                if !self.belongsToCard(NSApp.keyWindow),
                    self.takesFocus || NSApp.keyWindow !== self.parent
                {
                    self.dismiss(restoreFocus: false)
                }
            }
        })
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    private func belongsToCard(_ window: NSWindow?) -> Bool {
        guard let panel else { return false }
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent ?? current.sheetParent
        }
        return false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel else { return event }
        if event.type == .keyDown {
            // Parent chat windows have their own Escape-to-close shortcut.
            // Keep focus here and consume Escape before it can reach that.
            if event.keyCode == 53,
                event.window === panel || (!takesFocus && event.window === parent)
            {
                dismiss(restoreFocus: true)
                return nil
            }
            return event
        }
        if event.window === panel {
            let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
            if !presentedFrame.contains(screenPoint) {
                // Drawing space is not part of the menu. Route clicks through
                // to chat, including the source chip underneath the shadow.
                if let parent, parent.frame.contains(screenPoint),
                    let forwarded = NSEvent.mouseEvent(
                        with: event.type,
                        location: parent.convertPoint(fromScreen: screenPoint),
                        modifierFlags: event.modifierFlags,
                        timestamp: event.timestamp,
                        windowNumber: parent.windowNumber,
                        context: nil,
                        eventNumber: event.eventNumber,
                        clickCount: event.clickCount,
                        pressure: event.pressure
                    )
                {
                    NSApp.postEvent(forwarded, atStart: true)
                } else {
                    dismiss(restoreFocus: true)
                }
                return nil
            }
        }
        guard !belongsToCard(event.window) else { return event }
        if let anchor, let parent, event.window === parent {
            let point = anchor.convert(event.locationInWindow, from: nil)
            // Let a second click on the source button toggle its binding.
            // Closing before the button's action would immediately reopen it.
            if anchor.bounds.contains(point) { return event }
        }
        // The outside click keeps its normal action and focus destination.
        dismiss(restoreFocus: false)
        return event
    }

    private func dismiss(restoreFocus: Bool) {
        let binding = isPresented
        tearDown(restoreFocus: restoreFocus)
        if binding?.wrappedValue == true { binding?.wrappedValue = false }
    }

    func tearDown(restoreFocus: Bool) {
        stopResize()
        lastAnchorFrame = nil
        prefersAbove = nil
        suppressNextAnimation = false
        guard let panel else { return }
        let shouldRestore = restoreFocus && NSApp.isActive && belongsToCard(NSApp.keyWindow)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        panel.onCancel = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        host = nil
        presentation = nil
        if shouldRestore, let parent, parent.isVisible, !parent.isMiniaturized {
            parent.makeKey()
            if let previousResponder { parent.makeFirstResponder(previousResponder) }
        }
        parent = nil
        previousResponder = nil
    }
}

private final class AnchoredCardMarkerView: NSView {
    var onGeometryChange: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onGeometryChange?()
    }

    override func layout() {
        super.layout()
        onGeometryChange?()
    }
}

private final class AnchoredCardPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

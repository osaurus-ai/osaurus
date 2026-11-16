import AppKit
import SwiftUI

/// A borderless, opaque-content presentation for the existing menu content.
/// NSMenu owns its visual materials, so a separate surface is needed for the
/// inspector's colors and corners. No options, tags or callbacks are recreated.
@MainActor
final class AssignedMenuPanelPresenter {
    private var panel: MenuPanel?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var anchor: NSView?
    private var didClose: (() -> Void)?
    private var presentationID = UUID()
    private var restoresAnchorFocus = true
    private var contextPointAnchor: NSView?
    private var isShowing = false
    var isPresented: Bool { panel?.isVisible == true }
    /// `show` calls that reached the panel.
    private(set) var showCount = 0

    /// Render an existing AppKit action menu through the shared component.
    /// Keep its targets, selectors, validation, checks and submenus intact.
    func showContextMenu(_ menu: NSMenu, from anchor: NSView, theme: any ThemeProtocol, at point: NSPoint? = nil) {
        guard anchor.window != nil else { return }
        contextPointAnchor?.removeFromSuperview()
        contextPointAnchor = nil
        let presentationAnchor: NSView
        if let point {
            let view = NSView(frame: NSRect(origin: point, size: .zero))
            view.setAccessibilityElement(false)
            anchor.addSubview(view)
            contextPointAnchor = view
            presentationAnchor = view
        } else { presentationAnchor = anchor }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        let content = AssignedMenuSurface(content: AssignedNativeMenuItems(menu: menu, dismiss: { [weak self] in self?.close(restoreFocus: true) }))
            .environment(\.theme, theme)
            .environment(\.assignedMenuAppearance, .chatContext)
        show(AnyView(content), from: presentationAnchor, constrainToWindow: true, onClose: {})
    }

    func show(_ content: AnyView, from anchor: NSView, prefersAbove: Bool = false, gap: CGFloat = 0, constrainToWindow: Bool = false, besideAnchor: Bool = false, restoresAnchorFocus: Bool = true, onClose: @escaping () -> Void) {
        guard let parent = anchor.window, !isShowing else { return }
        // Ordering the panel front changes the key window, which re-renders
        // SwiftUI content that may ask to show this menu again mid-show.
        isShowing = true
        defer { isShowing = false }
        showCount += 1
        self.anchor = anchor
        self.restoresAnchorFocus = restoresAnchorFocus
        didClose = onClose
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.appearance?.name != parent.effectiveAppearance.name { panel.appearance = parent.effectiveAppearance }
        if !panel.isVisible { presentationID = UUID() }
        let visibleContent = AnyView(content.id(presentationID))
        // Keep the graph while visible: replacing the hosting view destroys
        // nested presenters during SwiftUI's own state invalidation.
        let host: NSHostingView<AnyView>
        if let existing = panel.contentView as? NSHostingView<AnyView> {
            host = existing; host.rootView = visibleContent
        } else {
            host = NSHostingView(rootView: visibleContent)
            host.sizingOptions = [.intrinsicContentSize]
            panel.contentView = host
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? rect
        let frame: CGRect
        if constrainToWindow {
            // Submenus are child panels. Walk back to the app window rather
            // than treating the parent menu as the available layout area.
            var owner = parent
            while let ancestor = owner.parent { owner = ancestor }
            let container = owner.convertToScreen(owner.contentLayoutRect)
            let safe = AnchoredCardPlacement.availableFrame(visibleFrame: screen, containerFrame: container)
            let opensLeft = besideAnchor && safe.maxX - rect.maxX < size.width + 8
                && rect.minX - safe.minX > safe.maxX - rect.maxX
            // Menus drop down, like native ones, and flip above only when
            // the space below can't hold them (the composer's menus).
            let fitsBelow = rect.minY - 8 - safe.minY >= size.height
            frame = AnchoredCardPlacement.frame(anchor: rect, size: size, visibleFrame: screen,
                rightToLeft: opensLeft, containerFrame: container, preferAbove: fitsBelow ? false : nil,
                besideAnchor: besideAnchor)
        } else {
            let width = min(max(1, size.width), screen.width)
            let height = min(max(1, size.height), screen.height)
            var origin = NSPoint(x: rect.minX, y: prefersAbove ? rect.maxY + gap : rect.minY - height - gap)
            if origin.y < screen.minY { origin.y = min(rect.maxY + gap, screen.maxY - height) }
            if origin.y + height > screen.maxY { origin.y = max(screen.minY, rect.minY - height - gap) }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - width)
            frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        }
        let width = frame.width
        let height = frame.height
        if size.height > height {
            host.rootView = AnyView(ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    visibleContent.environment(\.assignedMenuScrollTo, { index in proxy.scrollTo(index, anchor: .center) })
                }.frame(width: width, height: height)
            })
        }
        // A reopened panel still holds its last drawing; display it fresh
        // before ordering it front even when the frame is unchanged.
        if !panel.isVisible || panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            parent.addChildWindow(panel, ordered: .above)
            installObservers(parent: parent)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = L("Menu options")
        panel.isExcludedFromWindowsMenu = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = false
        panel.closeMenu = { [weak self] in self?.close(restoreFocus: true) }
        return panel
    }

    private func installObservers(parent: NSWindow) {
        removeObservers()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self {
                var window = event.window
                while let current = window, current !== self.panel { window = current.parent }
                if window == nil { self.close(restoreFocus: false) }
            }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoreFocus: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(restoreFocus: false) }
        })
    }

    func close(restoreFocus: Bool = false, notify: Bool = true) {
        guard let panel else { return }
        let wasVisible = panel.isVisible
        guard wasVisible else { removeObservers(); return }
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        // Closing posts willClose, so descendant presenters dismiss and remove
        // their own event monitors rather than retaining hidden child menus.
        panel.close()
        removeObservers()
        contextPointAnchor?.removeFromSuperview()
        contextPointAnchor = nil
        if restoreFocus, let parent {
            parent.makeKeyAndOrderFront(nil)
            if restoresAnchorFocus, let anchor, anchor.acceptsFirstResponder { parent.makeFirstResponder(anchor) }
        }
        let action = didClose
        didClose = nil
        if notify, let action { DispatchQueue.main.async { action() } }
    }

    private func removeObservers() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private final class MenuPanel: NSPanel {
        var closeMenu: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, event.keyCode == 53 { closeMenu?(); return }
            super.sendEvent(event)
        }
        override func cancelOperation(_ sender: Any?) { closeMenu?() }
    }
}

struct AssignedMenuPanelAnchor<Content: View>: NSViewRepresentable {
    @Binding var presented: Bool
    let content: Content
    var prefersAbove: Bool = false
    var gap: CGFloat = 0
    @Environment(\.self) private var environment
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView(); view.setAccessibilityElement(false); return view
    }
    func makeCoordinator() -> AssignedMenuPanelPresenter { AssignedMenuPanelPresenter() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let presented = $presented
        let content = AnyView(content.environment(\.self, environment))
        DispatchQueue.main.async { [weak view] in
            guard let view, presented.wrappedValue != coordinator.isPresented else { return }
            if presented.wrappedValue {
                coordinator.show(content, from: view, prefersAbove: prefersAbove, gap: gap) { presented.wrappedValue = false }
            } else { coordinator.close(notify: false) }
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: AssignedMenuPanelPresenter) { coordinator.close(notify: false) }
}

enum AssignedMenuAppearance { case catalog, chatContext }
private struct AssignedMenuAppearanceKey: EnvironmentKey {
    static let defaultValue = AssignedMenuAppearance.chatContext
}
extension EnvironmentValues {
    var assignedMenuAppearance: AssignedMenuAppearance {
        get { self[AssignedMenuAppearanceKey.self] }
        set { self[AssignedMenuAppearanceKey.self] = newValue }
    }
}

struct AssignedMenuSurface<Content: View>: View {
    @Environment(\.assignedMenuAppearance) private var appearance
    @Environment(\.theme) private var theme
    let content: Content
    @ViewBuilder var body: some View {
        if appearance == .chatContext {
            // The native menu adapter supplies the same ChatContextMenu used
            // by Add to chat; do not wrap it in a second surface or stack.
            content
        } else {
        let radius = theme.assignedMetric("component.library.5.radius", fallback: theme.radius.medium)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: theme.assignedMetric("component.library.5.gap", fallback: theme.space.s2)) { content }
            .padding(theme.assignedMetric("component.library.5.padding", fallback: theme.space.s6))
            .fixedSize(horizontal: true, vertical: true)
            .background(shape.fill(theme.assignedColor("component.library.5.background", fallback: theme.surface.raised)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.assignedColor("component.library.5.border", fallback: theme.border.default), lineWidth: theme.assignedMetric("component.library.5.borderWidth", fallback: theme.stroke.default)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Menu options")
        }
    }
}

private struct AssignedMenuDismissKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable () -> Void)? = nil }
private struct AssignedMenuScrollKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable (Int) -> Void)? = nil }
private struct AssignedMenuSelectedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var assignedMenuDismissAction: (@MainActor @Sendable () -> Void)? {
        get { self[AssignedMenuDismissKey.self] }
        set { self[AssignedMenuDismissKey.self] = newValue }
    }
    var assignedMenuScrollTo: (@MainActor @Sendable (Int) -> Void)? {
        get { self[AssignedMenuScrollKey.self] }
        set { self[AssignedMenuScrollKey.self] = newValue }
    }
    var assignedMenuRowSelected: Bool {
        get { self[AssignedMenuSelectedKey.self] }
        set { self[AssignedMenuSelectedKey.self] = newValue }
    }
}

struct AssignedMenuRowStyle: ButtonStyle {
    @Environment(\.assignedMenuAppearance) private var appearance
    @Environment(\.assignedMenuRowSelected) private var selected
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if appearance == .chatContext {
            ChatContextMenuRowStyle(selected: selected).makeBody(configuration: configuration)
        } else {
            AssignedMenuRow(configuration: configuration)
        }
    }
    private struct AssignedMenuRow: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.assignedMenuRowSelected) private var selected
        @Environment(\.assignedMenuButtonInteraction) private var nativeInteraction
        @State private var hovered = false
        @Environment(\.isFocused) private var focused
        let configuration: ButtonStyleConfiguration
        var body: some View {
            let radius = theme.assignedMetric("component.library.5.elements.row.radius", fallback: theme.radius.medium)
            configuration.label
                .assignedTypography("component.library.5.elements.row.text", fallback: SettingsFont.rowTitle)
                .foregroundStyle(theme.assignedColor("component.library.5.elements.row." + (!enabled ? "disabledForeground" : configuration.role == .destructive ? "error" : "foreground"), fallback: theme.text.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, theme.assignedMetric("component.library.5.elements.row.padding", fallback: theme.space.s6))
                .padding(.trailing, theme.assignedMetric("component.library.5.elements.row.padding", fallback: theme.space.s6))
                .padding(.vertical, theme.assignedMetric("component.library.5.elements.row.padding", fallback: theme.space.s6))
                .frame(minHeight: theme.assignedMetric("component.library.5.elements.row.height", fallback: theme.controlSize.defaultHeight))
                .background(RoundedRectangle(cornerRadius: radius).fill(theme.assignedColor("component.library.5.elements.row." + (!enabled ? "disabledBackground" : (nativeInteraction?.focused ?? focused) || selected || (nativeInteraction?.pressed ?? configuration.isPressed) ? "selected" : (nativeInteraction?.hovered ?? hovered) ? "hover" : "background"), fallback: theme.surface.raised)))
                .contentShape(Rectangle())
                .focusEffectDisabled()
                .onHover { hovered = $0 }
        }
    }
}

private struct AssignedMenuTriggerInContent: ViewModifier {
    @Environment(\.assignedMenuDismissAction) private var parentDismiss
    @ViewBuilder func body(content: Content) -> some View {
        if parentDismiss != nil { content.buttonStyle(AssignedMenuRowStyle()) }
        else { content }
    }
}

/// The public native menu bridge retains the original SwiftUI content and
/// callbacks; only its presentation uses the assigned opaque surface.
struct AssignedActionMenu<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    let accessibilityLabel: String
    let appearance: AssignedMenuAppearance?
    @Environment(\.assignedMenuAppearance) private var inheritedAppearance
    @Environment(\.isEnabled) private var enabled
    @Environment(\.assignedMenuDismissAction) private var parentDismiss
    @State private var focused = false
    init(accessibilityLabel: String, appearance: AssignedMenuAppearance? = .chatContext, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content(); self.label = label(); self.accessibilityLabel = accessibilityLabel; self.appearance = appearance
    }
    var body: some View {
        AssignedActionMenuInput(
            graphic: { state in AnyView(Button(action: {}) { label }
                .modifier(AssignedMenuTriggerInContent())
                .assignedActionMenuVisualState(state)
                .allowsHitTesting(false).accessibilityHidden(true)) },
            content: AnyView(content), nativeMenu: nil, enabled: enabled, accessibilityLabel: accessibilityLabel,
            parentDismiss: parentDismiss, onFocusChange: { focused = $0 })
            .claimsEnclosingTap()
            .environment(\.assignedMenuAppearance, appearance ?? inheritedAppearance)
            .preference(key: AssignedDescendantFocusKey.self, value: focused)
    }
}

/// Same native input contract as the Picker trigger, with the existing
/// SwiftUI button label/style used solely for its appearance.
struct AssignedExistingActionMenu<Label: View>: View {
    let accessibilityLabel: String
    let makeMenu: @MainActor () -> NSMenu
    let label: Label
    @Environment(\.isEnabled) private var enabled
    @Environment(\.assignedMenuDismissAction) private var parentDismiss
    @State private var focused = false
    var body: some View {
        AssignedActionMenuInput(graphic: { state in
            AnyView(Button(action: {}) { label }.assignedActionMenuVisualState(state).allowsHitTesting(false).accessibilityHidden(true))
        }, content: nil, nativeMenu: makeMenu(), enabled: enabled, accessibilityLabel: accessibilityLabel,
           parentDismiss: parentDismiss, onFocusChange: { focused = $0 })
            .claimsEnclosingTap()
            .environment(\.assignedMenuAppearance, .chatContext)
            .preference(key: AssignedDescendantFocusKey.self, value: focused)
    }
}

private extension View {
    /// The AppKit trigger opens on mouse-down, but SwiftUI still delivers the
    /// same click to an enclosing `onTapGesture` (a library row's open). The
    /// innermost tap gesture wins, so this one keeps the row from also
    /// acting and tearing down or covering the menu as it opens.
    func claimsEnclosingTap() -> some View { onTapGesture {} }
}

struct AssignedActionMenuInput: NSViewRepresentable {
    let graphic: (AssignedMenuButtonInteraction) -> AnyView
    let content: AnyView?
    let nativeMenu: NSMenu?
    let enabled: Bool
    let accessibilityLabel: String
    let parentDismiss: (@MainActor @Sendable () -> Void)?
    let onFocusChange: (Bool) -> Void
    var activationRequest: UUID? = nil
    @Environment(\.self) private var environment
    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.setAccessibilityElement(true); view.setAccessibilityRole(.popUpButton)
        return view
    }
    func updateNSView(_ view: InputView, context: Context) {
        view.enabled = enabled; view.onFocusChange = onFocusChange; view.parentDismiss = parentDismiss
        view.menuAppearance = environment.assignedMenuAppearance
        let environment = environment
        view.graphic = { state in AnyView(graphic(state).environment(\.self, environment)) }
        if let content {
            view.menuRoot = { AnyView(content.environment(\.self, environment)) }
        } else {
            view.menuRoot = nil
        }
        view.nativeMenu = nativeMenu
        view.makeMenuContent = { [weak view] menu in
            AnyView(AssignedMenuSurface(content: AssignedNativeMenuItems(menu: menu, dismiss: { view?.dismissAll() }))
                // A new panel must own its focus environment. Copy only the
                // content values it needs, as the native Picker adapter does.
                .environment(\.theme, environment.theme)
                .environment(\.locale, environment.locale)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.assignedMenuAppearance, environment.assignedMenuAppearance))
        }
        view.setAccessibilityLabel(accessibilityLabel); view.setAccessibilityEnabled(enabled)
        // An open menu keeps the content it opened with: re-showing it from
        // here rebuilt the panel on every parent render, and opening the
        // panel itself re-renders the parent (key window change).
        view.renderGraphic()
        if !enabled { view.cancelPresentation() }
        if let activationRequest, view.lastActivationRequest != activationRequest {
            view.lastActivationRequest = activationRequest
            DispatchQueue.main.async { [weak view] in view?.activateFromKeyboard() }
        }
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.cancelPresentation() }
    /// The trigger's hosting view, reporting size changes to its container.
    final class GraphicHostingView: NSHostingView<AnyView> {
        weak var owner: NSView?
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            owner?.invalidateIntrinsicContentSize()
        }
    }
    /// A plain container around the trigger's hosting view, as the Picker
    /// adapter uses: swapping a hosting view's root from inside its own
    /// parent's update re-dirties the window's constraint pass.
    final class InputView: NSView {
        let presenter = AssignedMenuPanelPresenter()
        private let host = GraphicHostingView(rootView: AnyView(EmptyView()))
        var nativeMenu: NSMenu?
        /// Built into a new `NSHostingMenu` only when the menu opens: triggers
        /// update with every parent render.
        var menuRoot: (() -> AnyView)?
        /// The menu the open panel lists.
        private(set) var openMenu: NSMenu?
        var menuAppearance = AssignedMenuAppearance.chatContext
        var makeMenuContent: ((NSMenu) -> AnyView)?
        var graphic: ((AssignedMenuButtonInteraction) -> AnyView)?
        var parentDismiss: (@MainActor @Sendable () -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var enabled = true
        var lastActivationRequest: UUID?
        private var hovered = false
        private var pressed = false
        private var hasFocus = false
        private var renderedState: AssignedMenuButtonInteraction?
        private var reportedFocus: Bool?
        private var openedUsingKeyboard = false
        private var tracking: NSTrackingArea?
        init() {
            super.init(frame: .zero)
            host.sizingOptions = [.intrinsicContentSize]
            // A trigger that touches a transparent titlebar (page headers)
            // would otherwise inset its own content by the overlap and sit
            // lower than the SwiftUI buttons beside it.
            host.safeAreaRegions = []
            host.owner = self
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            host.setAccessibilityElement(false)
            addSubview(host)
            for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                setContentHuggingPriority(host.contentHuggingPriority(for: orientation), for: orientation)
                setContentCompressionResistancePriority(host.contentCompressionResistancePriority(for: orientation), for: orientation)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: NSSize { host.intrinsicContentSize }
        override var firstBaselineOffsetFromTop: CGFloat { host.firstBaselineOffsetFromTop }
        override var lastBaselineOffsetFromBottom: CGFloat { host.lastBaselineOffsetFromBottom }
        override var acceptsFirstResponder: Bool { enabled }
        override func accessibilityChildren() -> [Any]? { [] }
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            tracking = area; addTrackingArea(area)
        }
        private var interaction: AssignedMenuButtonInteraction {
            AssignedMenuButtonInteraction(hovered: hovered, pressed: pressed, focused: hasFocus)
        }
        /// Called with each new `graphic` from the parent's update.
        func renderGraphic() {
            guard let graphic else { return }
            let state = interaction
            renderedState = state
            host.rootView = graphic(state)
        }
        /// Interaction changes re-render only when the state actually moved.
        private func reportInteraction() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                if self.renderedState != self.interaction { self.renderGraphic() }
                if self.reportedFocus != self.hasFocus {
                    self.reportedFocus = self.hasFocus
                    self.onFocusChange?(self.hasFocus)
                }
            }
        }
        override func becomeFirstResponder() -> Bool { hasFocus = true; reportInteraction(); return true }
        override func resignFirstResponder() -> Bool { hasFocus = false; reportInteraction(); return true }
        override func mouseEntered(with event: NSEvent) {
            // Hover changes the trigger appearance; only press/key activation opens it.
            hovered = true; reportInteraction()
        }
        override func mouseExited(with event: NSEvent) { hovered = false; reportInteraction() }
        override func mouseDown(with event: NSEvent) { open(usingKeyboard: false) }
        override func keyDown(with event: NSEvent) {
            if [36, 49, 125, 126].contains(event.keyCode) { open() }
            else { super.keyDown(with: event) }
        }
        override func accessibilityPerformPress() -> Bool { guard enabled else { return false }; open(); return true }
        private func open(usingKeyboard: Bool = true) {
            guard enabled else { return }
            openedUsingKeyboard = usingKeyboard
            // A pointer click should not leave a keyboard-focus ring on the
            // trigger. Keep the app's existing responder for pointer opening.
            if usingKeyboard { window?.makeFirstResponder(self) }
            pressed = true; reportInteraction(); showMenu()
        }
        func activateFromKeyboard() { open() }
        func showMenu() {
            guard enabled, let menu = nativeMenu ?? menuRoot.map({ NSHostingMenu.fresh($0()) }) else { return }
            openMenu = menu
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            guard let content = makeMenuContent?(menu) else { return }
            presenter.show(content, from: self, constrainToWindow: menuAppearance == .chatContext, besideAnchor: parentDismiss != nil, restoresAnchorFocus: openedUsingKeyboard) { [weak self] in
                guard let self else { return }
                self.pressed = false
                // A separate popup can consume the trigger's mouse-exit event.
                // Recompute actual hover when it closes instead of latching it.
                if let window = self.window {
                    let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                    self.hovered = self.bounds.contains(point)
                } else { self.hovered = false }
                self.reportInteraction()
            }
        }
        func dismissAll() { presenter.close(restoreFocus: true); parentDismiss?() }
        func cancelPresentation() {
            presenter.close(notify: false)
            pressed = false
            renderGraphic()
        }
    }
}

extension NSHostingMenu where Content == AnyView {
    /// A menu built for one opening. Never assign `rootView` on a menu that
    /// already exists: that aborts in AttributeGraph (`value_set_internal`)
    /// on the click that opens it (seen on macOS 27).
    static func fresh(_ content: AnyView) -> NSHostingMenu<AnyView> { NSHostingMenu(rootView: content) }
}

struct AssignedNativeMenuItems: View {
    @Environment(\.assignedMenuAppearance) private var appearance
    let menu: NSMenu
    let dismiss: @MainActor @Sendable () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.assignedMenuScrollTo) private var scrollTo
    @FocusState private var focused: Int?
    @State private var typeahead = ""
    @State private var lastTyped = Date.distantPast
    @State private var submenuRequest: (Int, UUID)?
    @State private var keyboardNavigating = false
    @ViewBuilder private var menuBody: some View {
        if appearance == .chatContext {
            ChatContextMenu { menuRows }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Menu actions")
        } else {
            VStack(alignment: .leading, spacing: theme.space.s0) { menuRows }
        }
    }
    @ViewBuilder private var menuRows: some View {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                if item.isHidden { EmptyView() }
                else if item.isSeparatorItem {
                    if appearance == .chatContext { ChatContextMenuDivider() }
                    else { Divider().overlay(theme.assignedColor("component.library.5.border", fallback: theme.border.default)) }
                } else if item.isSectionHeader {
                    Text(verbatim: item.title)
                        .assignedTypography(appearance == .chatContext ? "component.contextMenu.row.label" : "component.library.5.label", fallback: SettingsFont.rowTitle)
                        .foregroundStyle(appearance == .chatContext
                            ? theme.inspectionColor("component.contextMenu.row.disabledForeground", fallback: theme.text.secondary)
                            : theme.assignedColor("component.library.5.secondary", fallback: theme.text.secondary))
                } else if let submenu = item.submenu {
                    AssignedActionMenuInput(graphic: { state in
                        AnyView(Button(action: {}) {
                            HStack {
                                label(item)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(appearance == .chatContext
                                        ? theme.inspectionColor("component.contextMenu.row.foreground", fallback: theme.text.primary)
                                        : theme.assignedColor("component.library.5.secondary", fallback: theme.text.secondary))
                                    .accessibilityHidden(true)
                            }
                        }.buttonStyle(AssignedMenuRowStyle())
                            .environment(\.assignedMenuRowSelected, focused == index && (appearance != .chatContext || keyboardNavigating))
                            .assignedActionMenuVisualState(state)
                            .allowsHitTesting(false).accessibilityHidden(true))
                    }, content: nil, nativeMenu: submenu, enabled: item.isEnabled,
                        accessibilityLabel: item.title, parentDismiss: dismiss, onFocusChange: { _ in },
                        activationRequest: submenuRequest?.0 == index ? submenuRequest?.1 : nil)
                        .focusable(item.isEnabled).focusEffectDisabled().focused($focused, equals: index).id(index)
                        .onHover { if $0 { keyboardNavigating = false } }
                } else {
                    // Dismiss inside the actual Button action, so both its
                    // synthesized accessibility action and pointer input agree.
                    Button { activate(item) } label: { label(item) }
                    .disabled(!item.isEnabled)
                    .environment(\.assignedMenuRowSelected, appearance == .chatContext ? keyboardNavigating && focused == index : item.state != .off || focused == index)
                    .buttonStyle(AssignedMenuRowStyle())
                    .focusable(item.isEnabled)
                    .focusEffectDisabled()
                    .focused($focused, equals: index)
                    .id(index)
                    .onHover { if $0 { keyboardNavigating = false } }
                    .accessibilityAction { activate(item) }
                    .accessibilityAddTraits(item.state == .on ? [.isSelected] : [])
                }
            }
        
    }
    var body: some View {
        menuBody
        .onMoveCommand { direction in
            keyboardNavigating = true
            let options = menu.items.indices.filter { !menu.items[$0].isHidden && !menu.items[$0].isSeparatorItem && !menu.items[$0].isSectionHeader && menu.items[$0].isEnabled }
            guard !options.isEmpty else { return }
            let current = options.firstIndex(of: focused ?? -1) ?? (direction == .up ? 0 : -1)
            if direction == .up { focused = options[(current - 1 + options.count) % options.count] }
            else if direction == .down { focused = options[(current + 1) % options.count] }
        }
        .onChange(of: focused) { _, index in if let index { scrollTo?(index) } }
        // One handler on the menu, rather than one on both the primitive
        // style and its Button, prevents a single key from running twice.
        .onKeyPress(.space) { activateFocused() }
        .onKeyPress(.return) { activateFocused() }
        .onKeyPress(.rightArrow) {
            guard let focused, menu.items.indices.contains(focused), menu.items[focused].submenu != nil else { return .ignored }
            return activateFocused()
        }
        .onKeyPress(.leftArrow) {
            guard menu.supermenu != nil else { return .ignored }
            NSApp.keyWindow?.cancelOperation(nil)
            return .handled
        }
        .onKeyPress(characters: .alphanumerics) { key in
            if !key.modifiers.intersection([.command, .control, .option]).isEmpty {
                var flags: NSEvent.ModifierFlags = []
                if key.modifiers.contains(.command) { flags.insert(.command) }
                if key.modifiers.contains(.control) { flags.insert(.control) }
                if key.modifiers.contains(.option) { flags.insert(.option) }
                if key.modifiers.contains(.shift) { flags.insert(.shift) }
                let characters = NSApp.currentEvent?.charactersIgnoringModifiers ?? key.characters
                guard let item = menu.items.first(where: {
                    $0.isEnabled && !$0.isHidden && !$0.isSectionHeader && !$0.keyEquivalent.isEmpty && $0.submenu == nil &&
                    $0.keyEquivalent.caseInsensitiveCompare(characters) == .orderedSame &&
                    $0.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == flags
                }) else { return .ignored }
                activate(item)
                return .handled
            }
            guard key.modifiers.isEmpty || key.modifiers == .shift else { return .ignored }
            let now = Date()
            typeahead = now.timeIntervalSince(lastTyped) < 1 ? typeahead + key.characters : key.characters
            lastTyped = now
            guard let index = menu.items.firstIndex(where: { $0.isEnabled && !$0.isHidden && !$0.isSeparatorItem && !$0.isSectionHeader && $0.title.localizedStandardContains(typeahead) }) else { return .ignored }
            keyboardNavigating = true
            focused = index
            return .handled
        }
        .onAppear { DispatchQueue.main.async { focused = menu.items.firstIndex { $0.state == .on && $0.isEnabled && !$0.isSectionHeader } ?? menu.items.firstIndex { $0.isEnabled && !$0.isSeparatorItem && !$0.isSectionHeader && !$0.isHidden } } }
    }
    private func activateFocused() -> KeyPress.Result {
        guard let focused, menu.items.indices.contains(focused), menu.items[focused].isEnabled,
              !menu.items[focused].isSectionHeader, !menu.items[focused].isSeparatorItem, !menu.items[focused].isHidden else { return .ignored }
        if menu.items[focused].submenu != nil { submenuRequest = (focused, UUID()) }
        else { activate(menu.items[focused]) }
        return .handled
    }
    private func activate(_ item: NSMenuItem) {
        guard item.isEnabled, let index = menu.items.firstIndex(where: { $0 === item }) else { return }
        dismiss()
        menu.performActionForItem(at: index)
    }
    @ViewBuilder private func label(_ item: NSMenuItem) -> some View {
        if appearance == .chatContext {
            ChatContextMenuLabel(title: Text(verbatim: item.title), icon: Group {
                if item.state != .off { Image(systemName: "checkmark") }
                else if let image = item.image { Image(nsImage: image) }
                else { Color.clear }
            })
            if !item.keyEquivalent.isEmpty {
                Text(verbatim: shortcutLabel(item)).textStyle(.caption).foregroundStyle(theme.text.secondary)
            }
        } else {
        HStack(spacing: theme.assignedMetric("component.library.5.gap", fallback: theme.space.s6)) {
            Image(systemName: "checkmark").opacity(item.state == .off ? 0 : 1).accessibilityHidden(true)
                .foregroundStyle(theme.assignedColor("component.library.5.accent", fallback: theme.border.focus))
            if let image = item.image { Image(nsImage: image) }
            Text(verbatim: item.title).lineLimit(1).fixedSize(horizontal: appearance == .chatContext, vertical: true)
            if !item.keyEquivalent.isEmpty {
                Text(verbatim: shortcutLabel(item))
                    .assignedTypography("component.library.5.caption", fallback: SettingsFont.caption)
                    .foregroundStyle(theme.assignedColor("component.library.5.secondary", fallback: theme.text.secondary))
            }
        }
        }
    }
    private func shortcutLabel(_ item: NSMenuItem) -> String {
        let flags = item.keyEquivalentModifierMask
        let names = [(NSEvent.ModifierFlags.command, "cmd"), (.shift, "shift"), (.option, "option"), (.control, "ctrl")]
            .filter { flags.contains($0.0) }.map(\.1)
        let keyNames = [" ": "space", "\r": "return", "\t": "tab", "\u{7f}": "delete",
                        "\u{f700}": "up", "\u{f701}": "down", "\u{f702}": "left", "\u{f703}": "right"]
        let key = keyNames[item.keyEquivalent] ?? item.keyEquivalent.lowercased()
        if case .success(let hotkey) = HotkeyText.parse((names + [key]).joined(separator: "+")) { return hotkey.displayString }
        let glyphs = [(NSEvent.ModifierFlags.command, "⌘"), (.shift, "⇧"), (.option, "⌥"), (.control, "⌃")]
            .filter { flags.contains($0.0) }.map(\.1).joined()
        return glyphs + item.keyEquivalent.uppercased()
    }
}

import SwiftUI

private struct ExistingContextMenuInspection<MenuContent: View>: ViewModifier {
    let menuContent: MenuContent
    var chatMenu = true
    @State private var presented = false
    @ViewBuilder func body(content: Content) -> some View {
        content.overlay {
            ExistingContextMenuInspectionAnchor(presented: $presented, menuContent: menuContent, appearance: chatMenu ? .chatContext : nil)
        }.accessibilityAction(named: Text(localized: "Show menu")) { presented = true }
    }
}

extension View {
    /// Keep the existing actions; all app context menus share one recipe.
    func assignedContextMenu<MenuContent: View>(chatMenu: Bool = true, @ViewBuilder menuItems: () -> MenuContent) -> some View {
        modifier(ExistingContextMenuInspection(menuContent: menuItems(), chatMenu: chatMenu))
    }
}

private struct ExistingContextMenuInspectionAnchor<MenuContent: View>: NSViewRepresentable {
    @Binding var presented: Bool
    let menuContent: MenuContent
    var appearance: AssignedMenuAppearance? = nil
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        let binding = $presented
        view.enabled = environment.isEnabled
        view.theme = environment.theme
        view.menuAppearance = appearance ?? environment.assignedMenuAppearance
        // Every row with a context menu updates whenever its parent renders;
        // build the menu only when it opens.
        let menuContent = menuContent, environment = environment
        view.makeMenu = { AnyView(menuContent.environment(\.self, environment)) }
        view.onRequest = { binding.wrappedValue = true }
        view.onClose = { binding.wrappedValue = false }
        let show = presented && environment.isEnabled
        guard show != view.presenter.isPresented else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, show != view.presenter.isPresented else { return }
            if show { view.showMenu() }
            else { view.presenter.close(notify: false) }
        }
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.presenter.close(notify: false) }

    final class InputView: NSView {
        let presenter = AssignedMenuPanelPresenter()
        private let pointAnchor = NSView()
        var enabled = true
        var theme: (any ThemeProtocol)?
        var menuAppearance = AssignedMenuAppearance.chatContext
        var onRequest: (() -> Void)?
        var onClose: (() -> Void)?
        var makeMenu: (() -> AnyView)?
        private var hasPointerAnchor = false
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            pointAnchor.setAccessibilityElement(false)
            addSubview(pointAnchor)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled, bounds.contains(point), let event = NSApp.currentEvent else { return nil }
            let contextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return contextClick ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) { requestMenu(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { requestMenu(event) }
            else { super.mouseDown(with: event) }
        }
        private func requestMenu(_ event: NSEvent) {
            guard enabled else { return }
            let point = convert(event.locationInWindow, from: nil)
            pointAnchor.frame = NSRect(origin: point, size: .zero)
            hasPointerAnchor = true
            onRequest?()
        }
        func showMenu() {
            guard enabled, let theme, let makeMenu else { return }
            if !hasPointerAnchor { pointAnchor.frame = NSRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0) }
            let menu = NSHostingMenu.fresh(makeMenu())
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            let content = AssignedMenuSurface(content: AssignedNativeMenuItems(menu: menu, dismiss: { [weak self] in self?.presenter.close(restoreFocus: true) }))
                .environment(\.theme, theme)
                .environment(\.assignedMenuAppearance, menuAppearance)
            presenter.show(AnyView(content), from: pointAnchor, constrainToWindow: menuAppearance == .chatContext) { [weak self] in
                self?.hasPointerAnchor = false
                self?.onClose?()
            }
        }
    }
}

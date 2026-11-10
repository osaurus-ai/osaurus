#if OSAURUS_DESIGN_SYSTEM
import AppKit
import SwiftUI

/// Keep the app's original Picker content, tags, selection binding and native
/// menu behavior. Apply the inspector recipe to its AppKit title and items;
/// SwiftUI's foreground/font modifiers do not reach these native cells.
struct AssignedNativePicker<Content: View>: NSViewRepresentable {
    let content: Content
    let theme: any ThemeProtocol
    let enabled: Bool
    var family = 5
    var disabledMenuIndices: Set<Int> = []
    var onFocusChange: ((Bool) -> Void)? = nil
    var stylesClosedControl = true
    var inlineMenu: AnyView? = nil
    private func hostedContent(_ environment: EnvironmentValues) -> AnyView {
        if inlineMenu != nil {
            // The shared select container already supplies the fill and border.
            return AnyView(content.menuStyle(.button).buttonStyle(.borderless).environment(\.self, environment).disabled(!enabled))
        }
        return AnyView(content.environment(\.self, environment).disabled(!enabled))
    }

    func makeNSView(context: Context) -> AssignedPickerHostingView {
        let view = AssignedPickerHostingView(rootView: hostedContent(context.environment))
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: AssignedPickerHostingView, context: Context) {
        view.host.rootView = hostedContent(context.environment)
        view.recipe = TextRecipe(theme: theme, enabled: enabled, family: family, disabledMenuIndices: disabledMenuIndices, stylesClosedControl: stylesClosedControl)
        view.onFocusChange = onFocusChange
        view.inlineMenu = inlineMenu.map { AnyView($0.environment(\.self, context.environment)) }
        if stylesClosedControl {
            view.catalogAssignmentTarget(["text", "foreground", "disabledForeground"].map { "component.library.\(family)." + $0 }, name: "Picker value", theme: theme)
        }
        view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection)
        view.host.needsLayout = true
        DispatchQueue.main.async { [weak view] in view?.applyRecipe() }
    }
    static func dismantleNSView(_ view: AssignedPickerHostingView, coordinator: ()) {
        view.stopObservingWindow()
    }
    struct TextRecipe {
        let theme: any ThemeProtocol
        let enabled: Bool
        let family: Int
        let disabledMenuIndices: Set<Int>
        let stylesClosedControl: Bool
        let font: NSFont
        let foreground: NSColor
        let tracking: CGFloat
        let lineHeight: CGFloat
        let gap: CGFloat
        init(theme: any ThemeProtocol, enabled: Bool, family: Int, disabledMenuIndices: Set<Int>, stylesClosedControl: Bool = true) {
            self.theme = theme; self.enabled = enabled; self.family = family
            self.disabledMenuIndices = disabledMenuIndices
            self.stylesClosedControl = stylesClosedControl
            let prefix = "component.library.\(family)."
            font = theme.assignedNativeFont(prefix + "text", fallback: .systemFont(ofSize: 13))
            foreground = NSColor(theme.assignedColor(prefix + (enabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary))
            tracking = theme.assignedTracking(prefix + "text") ?? 0
            lineHeight = theme.assignedLineHeight(prefix + "text", fallback: 18)
            gap = theme.catalogMetric("gap", fallback: theme.space.s8)
        }
        func title(_ text: String) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: foreground, .kern: tracking, .paragraphStyle: paragraph])
        }
        /// The closed control's value, drawn on one line. A minimum line
        /// height would sit the glyphs at the bottom of a taller line box.
        func closedTitle(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: foreground, .kern: tracking])
        }
    }
    /// Intercepts only presentation. Selection runs the original NSMenuItem
    /// target/action, retaining the SwiftUI Picker's tags and binding.
    final class AssignedPickerMenuTrigger: NSView {
        weak var popup: NSPopUpButton?
        var recipe: TextRecipe?
        var inlineMenu: AnyView?
        let presenter = AssignedMenuPanelPresenter()
        private var closedTitle: NSAttributedString?
        private var closedFont: NSFont?
        private var chevron: NSImage?
        private var gap: CGFloat = 0

        var closedContentWidth: CGFloat {
            guard let closedTitle, let chevron else { return 0 }
            return ceil(closedTitle.size().width) + gap + ceil(chevron.size.width)
        }

        func setClosedTitle(_ title: String, recipe: TextRecipe) {
            let styledTitle = recipe.closedTitle(title)
            guard closedTitle != styledTitle || gap != recipe.gap else { return }
            closedTitle = styledTitle
            closedFont = recipe.font
            gap = recipe.gap
            chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: recipe.font.pointSize * 0.72, weight: .semibold)
                    .applying(.init(paletteColors: [recipe.foreground])))
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let closedTitle, let closedFont, let chevron else { return }
            let iconWidth = ceil(chevron.size.width)
            let rightToLeft = userInterfaceLayoutDirection == .rightToLeft
            let iconX = rightToLeft ? bounds.minX : bounds.maxX - iconWidth
            let textWidth = max(0, bounds.width - iconWidth - gap)
            let textX = rightToLeft ? bounds.minX + iconWidth + gap : bounds.minX
            // Center the glyphs (ascender to descender) on the chevron's line.
            let baseline = bounds.midY - (closedFont.ascender + closedFont.descender) / 2
            closedTitle.draw(with: NSRect(x: textX, y: baseline + closedFont.descender, width: textWidth,
                                          height: ceil(closedFont.ascender - closedFont.descender + closedFont.leading)),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            chevron.draw(in: NSRect(x: iconX, y: bounds.midY - chevron.size.height / 2,
                                    width: iconWidth, height: chevron.size.height))
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true); setAccessibilityRole(.popUpButton)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { recipe?.enabled == true && popup?.isEnabled == true }
        override func mouseDown(with event: NSEvent) { open() }
        override func keyDown(with event: NSEvent) {
            if [36, 49, 125, 126].contains(event.keyCode) { open() }
            else { super.keyDown(with: event) }
        }
        override func accessibilityPerformPress() -> Bool {
            guard acceptsFirstResponder else { return false }; open(); return true
        }
        private func open() {
            guard acceptsFirstResponder, let popup, let recipe else { return }
            guard let menu = inlineMenu.map({ NSHostingMenu.fresh($0) }) ?? popup.menu else { return }
            window?.makeFirstResponder(self)
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            guard menu.items.contains(where: { !$0.isHidden && !$0.isSeparatorItem }) else { return }
            // AppKit validation can re-enable Picker's Text options. Apply the
            // explicit value policy after validation, before exposing actions.
            for index in recipe.disabledMenuIndices where menu.items.indices.contains(index) {
                menu.items[index].isEnabled = false
            }
            let content = AssignedMenuSurface(content: AssignedNativeMenuItems(menu: menu, dismiss: { [weak self] in self?.presenter.close(restoreFocus: true) }))
                .environment(\.theme, recipe.theme)
                .environment(\.assignedMenuAppearance, .chatContext)
            presenter.show(AnyView(content), from: self, constrainToWindow: true, onClose: {})
        }
    }
    /// The Picker's hosting view, reporting its layout and size to the
    /// container so the trigger can track the popup.
    final class ContentHostingView: NSHostingView<AnyView> {
        weak var owner: AssignedPickerHostingView?
        override func layout() { super.layout(); owner?.applyRecipe() }
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            owner?.invalidateIntrinsicContentSize()
        }
    }
    /// A plain container: SwiftUI strips foreign subviews out of an
    /// NSHostingView on every update, so the trigger is the hosting view's
    /// sibling rather than its child. Re-adding it from `layout()` re-dirties
    /// layout each pass until AppKit aborts the window's update cycle.
    final class AssignedPickerHostingView: NSView {
        let host: ContentHostingView
        var recipe: TextRecipe?
        var onFocusChange: ((Bool) -> Void)?
        var inlineMenu: AnyView?
        private var windowObserver: NSObjectProtocol?
        private var lastFocus = false
        private var menuTrigger: AssignedPickerMenuTrigger?
        private var disabledItems: [NSMenuItem] = []
        private var reportedSize = NSSize(width: -1, height: -1)
        init(rootView: AnyView) {
            host = ContentHostingView(rootView: rootView)
            super.init(frame: .zero)
            host.sizingOptions = [.intrinsicContentSize]
            host.owner = self
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                setContentHuggingPriority(host.contentHuggingPriority(for: orientation), for: orientation)
                setContentCompressionResistancePriority(host.contentCompressionResistancePriority(for: orientation), for: orientation)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: NSSize {
            var size = host.intrinsicContentSize
            if inlineMenu != nil, let menuTrigger {
                size.width = max(size.width, menuTrigger.closedContentWidth)
            }
            return size
        }
        override var firstBaselineOffsetFromTop: CGFloat { host.firstBaselineOffsetFromTop }
        override var lastBaselineOffsetFromBottom: CGFloat { host.lastBaselineOffsetFromBottom }
        override func accessibilityChildren() -> [Any]? {
            if recipe?.family == 5, let menuTrigger { return [menuTrigger] }
            return super.accessibilityChildren()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            windowObserver = nil
            if let window {
                windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.reportFocus() }
                }
            }
            reportFocus()
        }
        private func reportFocus() {
            let responder = window?.firstResponder
            var focused = (responder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
            func ownsEditor(_ view: NSView) -> Bool {
                if let control = view as? NSControl, let editor = control.currentEditor(), editor === responder { return true }
                return view.subviews.contains(where: ownsEditor)
            }
            focused = focused || subviews.contains(where: ownsEditor)
            guard focused != lastFocus else { return }
            lastFocus = focused
            onFocusChange?(focused)
        }
        func stopObservingWindow() {
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            windowObserver = nil
            menuTrigger?.presenter.close()
        }
        /// Runs on every hosting layout pass, so it only writes what differs:
        /// each AppKit write re-dirties the popup and schedules another pass.
        func applyRecipe() {
            guard let recipe else { return }
            var disabled: [NSMenuItem] = []
            func visit(_ view: NSView) {
                if let popup = view as? NSPopUpButton {
                    if recipe.stylesClosedControl {
                        if popup.isBordered { popup.isBordered = false }
                        if popup.font != recipe.font { popup.font = recipe.font }
                        if popup.contentTintColor != recipe.foreground { popup.contentTintColor = recipe.foreground }
                        if let menu = popup.menu, menu.font != recipe.font { menu.font = recipe.font }
                        for item in popup.itemArray where !item.isSeparatorItem {
                            let title = recipe.title(item.title)
                            if item.attributedTitle != title { item.attributedTitle = title }
                        }
                        for index in recipe.disabledMenuIndices where popup.itemArray.indices.contains(index) {
                            disabled.append(popup.itemArray[index])
                        }
                        let title = recipe.title(popup.title)
                        if popup.attributedTitle != title { popup.attributedTitle = title }
                    }
                    if recipe.family == 5 {
                        let trigger = menuTrigger ?? AssignedPickerMenuTrigger()
                        menuTrigger = trigger
                        trigger.popup = popup; trigger.recipe = recipe
                        trigger.inlineMenu = inlineMenu
                        if inlineMenu != nil {
                            trigger.setClosedTitle(popup.title, recipe: recipe)
                            if popup.alphaValue != 0 { popup.alphaValue = 0 }
                        }
                        let frame = inlineMenu == nil ? convert(popup.bounds, from: popup) : bounds
                        if trigger.frame != frame { trigger.frame = frame }
                        trigger.setAccessibilityLabel(popup.accessibilityLabel() ?? "")
                        trigger.setAccessibilityValue(popup.title)
                        trigger.setAccessibilityEnabled(recipe.enabled && popup.isEnabled)
                        if !popup.refusesFirstResponder { popup.refusesFirstResponder = true }
                        popup.setAccessibilityElement(false)
                        popup.setAccessibilityHidden(true)
                        if trigger.superview !== self { addSubview(trigger, positioned: .above, relativeTo: host) }
                    }
                }
                if let picker = view as? NSDatePicker {
                    if picker.focusRingType != .none { picker.focusRingType = .none }
                    if picker.isBordered { picker.isBordered = false }
                    if picker.isBezeled { picker.isBezeled = false }
                    if picker.drawsBackground { picker.drawsBackground = false }
                    if picker.font != recipe.font { picker.font = recipe.font }
                    if picker.textColor != recipe.foreground { picker.textColor = recipe.foreground }
                }
                for child in view.subviews { visit(child) }
            }
            visit(host)
            for item in disabledItems where !disabled.contains(where: { $0 === item }) { item.isEnabled = true }
            for item in disabled where item.isEnabled { item.isEnabled = false }
            disabledItems = disabled
            // Un-bordering the popup narrows it without the hosting view
            // always passing the change up.
            let size = intrinsicContentSize
            if size != reportedSize { reportedSize = size; invalidateIntrinsicContentSize() }
        }
    }
}
#endif

import SwiftUI

private struct ExistingPickerInspectionPresentation: ViewModifier {
    var popupOnly = false
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var enabled
    @State private var focused = false
    @ViewBuilder func body(content: Content) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        if popupOnly {
            AssignedNativePicker(content: content, theme: inheritedTheme, enabled: enabled, stylesClosedControl: false)
        } else {
            let theme = inheritedTheme.catalogFamily(5, enabled: enabled)
            AssignedNativePicker(content: content, theme: theme, enabled: enabled, onFocusChange: { focused = $0 })
                .assignedTypography("component.library.5.text", fallback: SettingsFont.compactLabel)
                .foregroundStyle(theme.text.primary).tint(theme.border.focus)
                .padding(.horizontal, theme.catalogMetric("padding", fallback: 0))
                .padding(.vertical, theme.catalogMetric("paddingY", fallback: 6))
                .nativeCatalogTarget(["padding", "paddingY", "height"].map { "component.library.5.elements.container." + $0 }, "Select / picker")
                .frame(minHeight: theme.catalogMetric("height", fallback: 0))
                .assignedBaseChrome(5)
                .assignedBaseFocusRing(5, visible: focused && enabled, radius: theme.radius.medium)
        }
        #else
        content
        #endif
    }
}
extension View {
    /// Preserve the original Picker labels, options, tags and selection binding.
    func assignedNativePickerPresentation() -> some View { modifier(ExistingPickerInspectionPresentation()) }
    /// Connect only the popup; retain an existing control's layout and appearance.
    func assignedPickerPopupPresentation() -> some View { modifier(ExistingPickerInspectionPresentation(popupOnly: true)) }
}

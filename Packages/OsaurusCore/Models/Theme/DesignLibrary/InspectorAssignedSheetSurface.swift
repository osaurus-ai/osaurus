import AppKit
import SwiftUI

/// Keeps the existing attached sheet and bindings; the assigned opaque
/// surface owns its corners instead of AppKit's title frame.
struct InspectorAssignedSheetSurface: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> SheetSurfaceMarker { SheetSurfaceMarker() }
    func updateNSView(_ view: SheetSurfaceMarker, context: Context) {
        view.radius = max(0, radius)
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: SheetSurfaceMarker, coordinator: ()) {
        view.stopObserving()
        view.restoreSurface()
    }

    final class SheetSurfaceMarker: NSView {
        var radius: CGFloat = 0
        private var observer: NSObjectProtocol?
        private weak var styledWindow: NSWindow?
        private var originalStyle: NSWindow.StyleMask?
        private var originalBackground: NSColor?
        private var originalOpaque = true
        private var originalShadow = true
        private var originalRole: NSAccessibility.Role?
        private var originalCorner: CGFloat = 0
        private var originalMasks = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            if styledWindow !== window { restoreSurface() }
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applySurface() }
                }
            }
            scheduleUpdate()
        }

        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in self?.applySurface() }
        }

        private func applySurface() {
            guard let window else { return }
            guard window.isSheet || window.sheetParent != nil else { return }
            // Preserve native modality, dismissal, focus and parent attachment.
            // The guard prevents changing an ordinary window or inline example.
            if styledWindow !== window {
                originalStyle = window.styleMask
                originalBackground = window.backgroundColor
                originalOpaque = window.isOpaque
                originalShadow = window.hasShadow
                originalRole = window.accessibilityRole()
                originalCorner = window.contentView?.layer?.cornerRadius ?? 0
                originalMasks = window.contentView?.layer?.masksToBounds ?? false
                // SwiftUI continues to own the existing content size constraints.
                window.styleMask = [.borderless, .resizable]
                SheetKeyEligibility.keep(window, true)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                styledWindow = window
                window.setAccessibilityRole(.sheet)
                DispatchQueue.main.async { [weak window] in
                    guard let window, window.isVisible, window.isSheet || window.sheetParent != nil, NSApp.isActive else { return }
                    window.makeKey()
                }
            }
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = radius
            window.contentView?.layer?.masksToBounds = true
            window.invalidateShadow()
        }

        func restoreSurface() {
            guard let window = styledWindow, let originalStyle else { return }
            SheetKeyEligibility.keep(window, false)
            window.styleMask = originalStyle
            if let originalBackground { window.backgroundColor = originalBackground }
            window.isOpaque = originalOpaque
            window.hasShadow = originalShadow
            window.setAccessibilityRole(originalRole)
            window.contentView?.layer?.cornerRadius = originalCorner
            window.contentView?.layer?.masksToBounds = originalMasks
            window.invalidateShadow()
            styledWindow = nil
            self.originalStyle = nil
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

/// AppKit refuses key status to a borderless window, even a resizable one.
/// A restyled sheet that can't be key leaves typing and ⌘V with the window
/// under it while its fields still look focused. Kept windows answer
/// `canBecomeKey` with true; every other window keeps its class's answer.
@MainActor
enum SheetKeyEligibility {
    nonisolated(unsafe) private static var marker: UInt8 = 0
    private static var patched: Set<ObjectIdentifier> = []

    static func keep(_ window: NSWindow, _ keyable: Bool) {
        if keyable {
            // Both the class the window reports and its runtime class, which
            // differ while something observes the window with KVO.
            if let cls = NSClassFromString(window.className) { patch(cls) }
            if let cls = object_getClass(window) { patch(cls) }
        }
        objc_setAssociatedObject(window, &marker, keyable ? true : nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func isKept(_ window: NSWindow) -> Bool {
        objc_getAssociatedObject(window, &marker) != nil
    }

    private static func patch(_ cls: AnyClass) {
        guard patched.insert(ObjectIdentifier(cls)).inserted else { return }
        let selector = #selector(getter: NSWindow.canBecomeKey)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let inherited = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let override: @convention(block) (AnyObject) -> Bool = { window in
            objc_getAssociatedObject(window, &marker) != nil || inherited(window, selector)
        }
        let imp = imp_implementationWithBlock(override)
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }
}

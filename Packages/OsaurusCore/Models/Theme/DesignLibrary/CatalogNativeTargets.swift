import SwiftUI
import AppKit
import ObjectiveC

private struct NativeInspectionKey: EnvironmentKey { static let defaultValue: CatalogPreviewInspection? = nil }
private struct NativeSelectionKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var nativeCatalogInspection: CatalogPreviewInspection? {
        get { self[NativeInspectionKey.self] }
        set { self[NativeInspectionKey.self] = newValue }
    }
    var nativeCatalogSelection: String? {
        get { self[NativeSelectionKey.self] }
        set { self[NativeSelectionKey.self] = newValue }
    }
}
@MainActor private var nativeTargetStorage: UInt8 = 0
@MainActor private var nativeOverlayStorage: UInt8 = 0
private final class NativeTargetRecord: NSObject {
    let keys: [String]
    let name: String
    init(keys: [String], name: String) { self.keys = keys; self.name = name }
}
extension NSView {
    /// Called at the existing style application site, on the actual subview.
    func catalogAssignmentTarget(_ keys: [String], name: String, theme: (any ThemeProtocol)? = nil) {
        let resolved = keys.map { original in
            if let theme { return NativeCatalogAssignment.key(original, theme: theme) }
            return CatalogElementAssignments.routed(original, mappings: DesignThemeOverlay.shared.current()?.document.mappings ?? [:])
        }
        objc_setAssociatedObject(self, &nativeTargetStorage, NativeTargetRecord(keys: resolved, name: name), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    func updateCatalogInspection(_ inspection: CatalogPreviewInspection?, selection: String?) {
        guard let inspection else { return }
        let overlay: NativeAssignmentOverlay
        if let existing = objc_getAssociatedObject(self, &nativeOverlayStorage) as? NativeAssignmentOverlay { overlay = existing }
        else {
            overlay = NativeAssignmentOverlay(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.root = self
            addSubview(overlay, positioned: .above, relativeTo: nil)
            objc_setAssociatedObject(self, &nativeOverlayStorage, overlay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        overlay.inspection = inspection; overlay.selection = selection; overlay.needsDisplay = true
        DispatchQueue.main.async { [weak overlay] in overlay?.publishTargets() }

    }
}
private final class NativeAssignmentOverlay: NSView {
    let id = UUID()
    weak var root: NSView?
    weak var inspection: CatalogPreviewInspection?
    var selection: String?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func publishTargets() {
        guard window != nil, let inspection else { return }
        let targets = records().reduce(into: [String: Set<String>]()) { result, item in
            for key in item.1.keys { result[key, default: []].insert(item.1.name) }
        }
        if inspection.nativeTargets[id] != targets { inspection.nativeTargets[id] = targets }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.publishTargets() } }
        if window == nil {
            let id = id
            DispatchQueue.main.async { [weak inspection] in inspection?.nativeTargets.removeValue(forKey: id) }
        }
    }
    func records() -> [(NSView, NativeTargetRecord)] {
        guard let root else { return [] }
        var result: [(NSView, NativeTargetRecord)] = []
        func visit(_ view: NSView) {
            guard view !== self, !view.isHidden else { return }
            if let record = objc_getAssociatedObject(view, &nativeTargetStorage) as? NativeTargetRecord { result.append((view, record)) }
            if let field = view as? NSTextField, field.attributedStringValue.length > 0,
               let key = field.attributedStringValue.attribute(NSAttributedString.Key("OsaurusCatalogAssignment"), at: 0, effectiveRange: nil) as? String {
                result.append((field, NativeTargetRecord(keys: [key], name: "Text “" + field.stringValue + "”")))
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return result
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let selection else { return }
        for (view, record) in records() where record.keys.contains(selection) {
            let visible = view.visibleRect
            guard !visible.isEmpty else { continue }
            let rect = convert(visible, from: view).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            NSColor.systemOrange.withAlphaComponent(0.1).setFill(); path.fill()
            NSColor.systemOrange.setStroke(); path.lineWidth = 2
            path.setLineDash([5, 3], count: 2, phase: 0); path.stroke()
        }
    }
}

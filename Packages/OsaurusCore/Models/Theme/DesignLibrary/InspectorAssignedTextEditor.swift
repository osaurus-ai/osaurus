#if OSAURUS_DESIGN_SYSTEM
import AppKit
import SwiftUI

/// The app's multiline editor with the catalog's complete text recipe. Keeps
/// AppKit selection, undo, paste, scrolling and marked-text composition intact.
struct InspectorAssignedTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isComposing: Bool
    let font: NSFont
    let lineHeight: CGFloat
    let tracking: CGFloat
    let paragraphSpacing: CGFloat
    let textColor: NSColor
    let selectionColor: NSColor
    let editable: Bool
    var onFocusChange: (Bool) -> Void
    var accessibleName: String? = nil
    var accessibleHelp: String? = nil

    func makeNSView(context: Context) -> InspectorEditorScrollView {
        let scroll = InspectorEditorScrollView()
        let view = InspectorMultilineTextView()
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.focusRingType = .none
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        let coordinator = context.coordinator
        view.focusChanged = { [weak coordinator] in coordinator?.parent.onFocusChange($0) }
        view.compositionChanged = { [weak coordinator] in coordinator?.parent.isComposing = $0 }
        scroll.didLayout = { [weak coordinator, weak view] in
            if let view { coordinator?.measure(view) }
        }
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: InspectorEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? InspectorMultilineTextView else { return }
        view.isEditable = editable
        view.isSelectable = true
        view.setAccessibilityLabel(accessibleName ?? L("Multiline editor"))
        view.setAccessibilityHelp(accessibleHelp)
        view.insertionPointColor = textColor
        view.selectedTextAttributes = [.backgroundColor: selectionColor, .foregroundColor: textColor]
        guard !view.hasMarkedText() else { return }
        let selected = view.selectedRanges
        if view.string != text { view.string = text }
        let paragraph = NSMutableParagraphStyle()
        // A target minimum preserves larger glyphs instead of clipping them.
        paragraph.minimumLineHeight = lineHeight
        paragraph.paragraphSpacing = paragraphSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .kern: tracking,
            .paragraphStyle: paragraph
        ]
        view.typingAttributes = attributes
        view.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
        view.selectedRanges = selected.filter { NSMaxRange($0.rangeValue) <= (view.string as NSString).length }
        context.coordinator.measure(view)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InspectorAssignedTextEditor
        init(_ parent: InspectorAssignedTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            if parent.text != view.string { parent.text = view.string }
            measure(view)
        }
        func measure(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = ceil(max(parent.lineHeight, manager.usedRect(for: container).height))
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.measuredHeight - height) > 0.5 else { return }
                self.parent.measuredHeight = height
            }
        }
    }
}
final class InspectorMultilineTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    var compositionChanged: ((Bool) -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionChanged?(hasMarkedText())
    }
    override func unmarkText() {
        super.unmarkText()
        compositionChanged?(false)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
}
final class InspectorEditorScrollView: NSScrollView {
    var didLayout: (() -> Void)?
    override func layout() {
        super.layout()
        if let view = documentView as? NSTextView {
            view.setFrameSize(NSSize(width: contentSize.width, height: max(view.frame.height, contentSize.height)))
            view.textContainer?.containerSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        }
        didLayout?()
    }
}
#endif

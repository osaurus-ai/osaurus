import AppKit
import SwiftUI

/// A native single-line field with the inspector's full text recipe. NSTextField
/// supplies normal Tab traversal; the shared search view keeps its IME text view.
struct InspectorAssignedTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    var font: NSFont
    var textColor: NSColor
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var tracking: CGFloat?
    var editable: Bool
    var requestedFocus: Bool
    var alignment: NSTextAlignment = .left
    var onCommand: ((Selector) -> Bool)? = nil
    var accessibleName: String? = nil
    var accessibleHelp: String? = nil
    /// Drawn by the cell in the same text rect as the caret and value.
    var placeholder: String? = nil
    var placeholderColor: NSColor? = nil

    func makeNSView(context: Context) -> InspectorNativeTextField {
        let field = InspectorNativeTextField()
        field.delegate = context.coordinator
        let coordinator = context.coordinator
        field.onFocus = { [weak coordinator] in coordinator?.parent.onFocusChange?(true) }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = editable
        field.isSelectable = true
        field.isEnabled = editable
        field.alignment = alignment
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(accessibleName)
        field.setAccessibilityHelp(accessibleHelp)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.attributedStringValue = attributedText
        field.placeholderAttributedString = attributedPlaceholder
        return field
    }

    private var attributedPlaceholder: NSAttributedString? {
        guard let placeholder, !placeholder.isEmpty else { return nil }
        var attributes = attributes
        attributes[.foregroundColor] = placeholderColor ?? NSColor.placeholderTextColor
        return NSAttributedString(string: placeholder, attributes: attributes)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return [.font: font, .foregroundColor: textColor, .kern: tracking ?? 0, .paragraphStyle: paragraph]
    }

    private var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: attributes)
    }

    func updateNSView(_ field: InspectorNativeTextField, context: Context) {
        context.coordinator.parent = self
        field.font = font
        field.textColor = textColor
        field.alignment = alignment
        field.isEditable = editable
        field.isEnabled = editable
        field.setAccessibilityLabel(accessibleName)
        field.setAccessibilityHelp(accessibleHelp)
        let placeholderValue = attributedPlaceholder
        if field.placeholderAttributedString != placeholderValue {
            field.placeholderAttributedString = placeholderValue
        }

        if let editor = field.currentEditor() as? NSTextView {
            if !editor.hasMarkedText() {
                editor.alignment = alignment
                if editor.string != text { editor.string = text }
                editor.textStorage?.addAttributes(attributes, range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
                editor.typingAttributes = attributes
                editor.insertionPointColor = textColor
            }
        } else {
            field.attributedStringValue = attributedText
        }

        if context.coordinator.lastFocusRequest != requestedFocus {
            let previousRequest = context.coordinator.lastFocusRequest
            context.coordinator.lastFocusRequest = requestedFocus
            // An initial false value is not a request to resign. Focus changes
            // reported by the native editor must not focus that editor again.
            guard requestedFocus || previousRequest == true else { return }
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let window = field.window, let coordinator,
                      coordinator.parent.requestedFocus == requestedFocus else { return }
                let ownsEditor = field.currentEditor().map { window.firstResponder === $0 } ?? false
                let ownsFocus = window.firstResponder === field || ownsEditor
                if requestedFocus && editable {
                    if !ownsFocus { window.makeFirstResponder(field) }
                } else if ownsFocus {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InspectorAssignedTextField
        var lastFocusRequest: Bool?
        init(_ parent: InspectorAssignedTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                editor.alignment = parent.alignment
                editor.typingAttributes = parent.attributes
                editor.insertionPointColor = parent.textColor
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
            }
            parent.onFocusChange?(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
            parent.isComposing = composing
            if !composing { parent.text = field.stringValue }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
            parent.isComposing = false
            parent.onFocusChange?(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if !textView.hasMarkedText(), parent.onCommand?(commandSelector) == true { return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }
    }
}

final class InspectorNativeTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

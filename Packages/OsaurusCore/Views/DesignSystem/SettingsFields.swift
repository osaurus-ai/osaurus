//
//  SettingsFields.swift
//  osaurus
//
//  Input controls and the rows that label them:
//
//  - `SettingsTextField`     the one text input (single-line, multiline,
//                            secure, monospaced, leading icon, invalid)
//  - `SettingsTitleField`    a page or document title edited in place
//  - `SettingsFieldRow`      label + any control + hint, stacked
//  - `SettingsTextFieldRow`  `SettingsFieldRow` + `SettingsTextField`
//  - `SettingsStepperRow`    integer override with − / +
//  - `SettingsSliderRow`     float override with a slider
//

import AppKit
import SwiftUI

private struct SettingsFieldAccessibility {
    let name: String
    let help: String?
}

private extension EnvironmentValues {
    @Entry var settingsFieldAccessibility: SettingsFieldAccessibility? = nil
}

extension View {
    func settingsFieldAccessibility(_ name: String, help: String? = nil) -> some View {
        environment(\.settingsFieldAccessibility, SettingsFieldAccessibility(name: name, help: help))
    }
}

// MARK: - Title Field

/// A title edited where it is shown: plain text at rest, a hairline under
/// it on hover, the focus color while editing. For names that head their
/// own page (a draft's name), not for fields inside a form.
struct SettingsTitleField: View {
    @Environment(\.theme) private var theme

    /// Already localized.
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    /// Called when editing ends: focus left, Return, or a click elsewhere.
    var onCommit: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        TextField(text: $text, prompt: Text(verbatim: placeholder)) { Text(verbatim: placeholder) }
            .textFieldStyle(.plain)
            .assignedTypography("type.subheading", fallback: SettingsFont.rowTitle)
            .foregroundStyle(theme.text.primary)
            .focused(focus)
            .onSubmit { focus.wrappedValue = false }
            .onChange(of: focus.wrappedValue) { _, focused in if !focused { onCommit() } }
            .padding(.vertical, theme.space.s4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focus.wrappedValue ? theme.border.focus : theme.border.default)
                    .frame(height: theme.stroke.default)
                    .opacity(focus.wrappedValue || isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .onHover { isHovered = $0 }
            .animation(theme.motion.quick, value: focus.wrappedValue || isHovered)
            .endsEditingOnOutsideClick(focus.wrappedValue) { focus.wrappedValue = false }
    }
}

// MARK: - Text Field

struct SettingsTextField: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsFieldAccessibility) private var fieldAccessibility

    /// Verbatim placeholder; wrap catalog text in `L()`.
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var axis: Axis
    var lineLimit: Int?
    /// Vertical fields with a `lineLimit`: start this many lines tall and
    /// grow to the limit, instead of reserving every line up front.
    var minLines: Int?
    var monospaced: Bool
    var isSecure: Bool
    /// Secure fields only: trailing eye button that shows the value.
    var revealable: Bool
    var isInvalid: Bool
    /// Focus the field when it first appears (single-line only).
    var autofocus: Bool
    var focus: FocusState<Bool>.Binding?
    var onEditingChanged: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?

    #if OSAURUS_DESIGN_SYSTEM
    @Environment(\.inspectorInputPreviewState) private var previewState
    #endif
    private var displaysFocus: Bool {
        #if OSAURUS_DESIGN_SYSTEM
        return isFocused || previewState == "focus"
        #else
        return isFocused
        #endif
    }
    private var displaysHover: Bool {
        #if OSAURUS_DESIGN_SYSTEM
        return isHovering || previewState == "hover"
        #else
        return isHovering
        #endif
    }
    @State private var isFocused = false
    @State private var reveals = false
    @State private var isComposing = false
    @State private var isHovering = false
    @FocusState private var ownFocus: Bool

    init(
        placeholder: String,
        text: Binding<String>,
        icon: String? = nil,
        axis: Axis = .horizontal,
        lineLimit: Int? = nil,
        minLines: Int? = nil,
        monospaced: Bool = false,
        isSecure: Bool = false,
        revealable: Bool = false,
        isInvalid: Bool = false,
        autofocus: Bool = false,
        focus: FocusState<Bool>.Binding? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.axis = axis
        self.lineLimit = lineLimit
        self.minLines = minLines
        self.monospaced = monospaced
        self.isSecure = isSecure
        self.revealable = revealable
        self.isInvalid = isInvalid
        self.autofocus = autofocus
        self.focus = focus
        self.onEditingChanged = onEditingChanged
        self.onSubmit = onSubmit
    }

    private var valueFont: SettingsFont {
        monospaced ? SettingsFont.mono : SettingsFont.body
    }

    private var fieldName: String {
        fieldAccessibility.flatMap { $0.name.isEmpty ? nil : $0.name } ?? placeholder
    }

    var body: some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: theme.space.s8) {
            if let icon {
                Image(systemName: icon)
                    .font(SettingsFont.glyph)
                    .foregroundColor(iconColor)
                    .frame(width: 16)
                    .padding(.top, axis == .vertical ? 1 : 0)
            }

            field
                .textFieldStyle(.plain)
                .foregroundColor(isEnabled ? theme.assignedColor("component.input.foreground", fallback: theme.text.primary) : theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled))
                .focused(focus ?? $ownFocus)
                .onSubmit { onSubmit?() }
                .onKeyPress(keys: [.return], phases: .down, action: multilineReturn)
                .nativeCatalogTarget(["component.input.placeholder", "component.input.text"], "Placeholder inside empty input")
                .assignedTypography(monospaced ? "type.code" : "component.input.text", fallback: valueFont)

            if isSecure && revealable {
                Button {
                    reveals.toggle()
                } label: {
                    Image(systemName: reveals ? "eye.slash" : "eye")
                        .font(SettingsFont.glyph)
                        .foregroundColor(isEnabled ? theme.text.tertiary : theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled))
                }
                .buttonStyle(.plain)
                .help(reveals ? L("Hide password") : L("Show password"))
                .accessibilityLabel(reveals ? L("Hide password") : L("Show password"))
            }
        }
        .padding(.horizontal, theme.assignedMetric("component.input.paddingX", fallback: theme.settingsFieldInset))
        .padding(.vertical, theme.assignedMetric("component.input.paddingY", fallback: axis == .vertical ? theme.space.s8 : 0))
        .frame(minHeight: axis == .horizontal ? theme.assignedMetric("component.control.heightDefault", fallback: theme.controlSize.defaultHeight) : nil)
        .background(
            RoundedRectangle(cornerRadius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium), style: .continuous)
                .fill(isEnabled ? theme.assignedColor("component.input.background", fallback: theme.surface.raised) : theme.assignedColor("component.input.disabled.background", fallback: theme.surface.disabled))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium), style: .continuous)
                .strokeBorder(borderColor, lineWidth: theme.assignedMetric("component.input.borderWidth", fallback: theme.stroke.default))
        )
        #if OSAURUS_DESIGN_SYSTEM
        .assignedDesignEffect("component.input.effect", theme: theme, radius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium))
        #endif
        #if OSAURUS_DESIGN_SYSTEM
        .nativeCatalogTarget(["component.input.background", "component.input.border", "component.input.borderHover", "component.input.borderError", "component.input.radius", "component.input.paddingX", "component.input.paddingY", "component.input.borderWidth", "component.input.effect", "component.control.heightDefault"], "Input field container")
        #endif
        .preference(key: SettingsInputInvalidPreference.self, value: isInvalid)
        .assignedFocusRing(displaysFocus && isEnabled, radius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium))
        .onHover { isHovering = $0 }
        .onChange(of: focus?.wrappedValue ?? ownFocus) { _, focused in
            guard isFocused != focused else { return }
            withAnimation(theme.motion.quick) { isFocused = focused }
            onEditingChanged?(focused)
        }
        .onAppear {
            guard autofocus, axis == .horizontal else { return }
            DispatchQueue.main.async {
                #if OSAURUS_DESIGN_SYSTEM
                if !isSecure {
                    isFocused = true
                    if let focus { focus.wrappedValue = true }
                    return
                }
                #endif
                if let focus { focus.wrappedValue = true } else { ownFocus = true }
            }
        }
    }

    private var placeholderColor: Color {
        isEnabled
            ? theme.assignedColor("component.input.placeholder", fallback: theme.text.placeholder)
            : theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled)
    }

    /// The field's own prompt, so it shares the caret's text rect.
    private var prompt: Text? {
        placeholder.isEmpty ? nil : Text(verbatim: placeholder).foregroundColor(placeholderColor)
    }

    @ViewBuilder
    private var field: some View {
        if isSecure && !reveals {
            SecureField("", text: $text, prompt: prompt)
                .accessibilityLabel(Text(verbatim: fieldName))
                .accessibilityHint(Text(verbatim: fieldAccessibility?.help ?? ""))
                .focused(focus ?? $ownFocus)
                .onSubmit { onSubmit?() }
        } else if axis == .vertical {
            if let lineLimit, let minLines {
                TextField("", text: $text, prompt: prompt, axis: .vertical)
                    .accessibilityLabel(Text(verbatim: fieldName))
                    .accessibilityHint(Text(verbatim: fieldAccessibility?.help ?? ""))
                    .lineLimit(min(minLines, lineLimit)...lineLimit)
                    .focused(focus ?? $ownFocus)
                    .onSubmit { onSubmit?() }
            } else if let lineLimit {
                TextField("", text: $text, prompt: prompt, axis: .vertical)
                    .accessibilityLabel(Text(verbatim: fieldName))
                    .accessibilityHint(Text(verbatim: fieldAccessibility?.help ?? ""))
                    .lineLimit(lineLimit, reservesSpace: true)
                    .focused(focus ?? $ownFocus)
                    .onSubmit { onSubmit?() }
            } else {
                TextField("", text: $text, prompt: prompt, axis: .vertical)
                    .accessibilityLabel(Text(verbatim: fieldName))
                    .accessibilityHint(Text(verbatim: fieldAccessibility?.help ?? ""))
                    .focused(focus ?? $ownFocus)
                    .onSubmit { onSubmit?() }
            }
        } else {
            #if OSAURUS_DESIGN_SYSTEM
            InspectorAssignedTextField(
                text: $text, isComposing: $isComposing,
                font: theme.assignedNativeFont(monospaced ? "type.code" : "component.input.text", fallback: theme.nsFont(.bodySmall)),
                textColor: NSColor(theme.assignedColor(isEnabled ? "component.input.foreground" : "component.input.disabled.foreground", fallback: theme.text.primary)),
                onSubmit: { onSubmit?() },
                onFocusChange: { focused in
                    if isFocused != focused {
                        withAnimation(theme.motion.quick) { isFocused = focused }
                        onEditingChanged?(focused)
                    }
                    if let focus { focus.wrappedValue = focused }
                },
                tracking: theme.assignedTracking(monospaced ? "type.code" : "component.input.text"),
                editable: isEnabled, requestedFocus: focus?.wrappedValue ?? isFocused,
                accessibleName: fieldName, accessibleHelp: fieldAccessibility?.help,
                placeholder: placeholder, placeholderColor: NSColor(placeholderColor)
            )
            .frame(height: theme.assignedLineHeight(monospaced ? "type.code" : "component.input.text", fallback: theme.lineHeight(.bodySmall)))
            #else
            TextField("", text: $text, prompt: prompt)
                .accessibilityLabel(Text(verbatim: fieldName))
                .accessibilityHint(Text(verbatim: fieldAccessibility?.help ?? ""))
                .focused(focus ?? $ownFocus)
                .onSubmit { onSubmit?() }
            #endif
        }
    }

    /// Multiline fields follow the chat composer: Return submits, Shift+Return
    /// starts a new line. The field editor treats both as "end editing", so
    /// the newline is inserted explicitly. IME composition keeps its Return.
    private func multilineReturn(_ press: KeyPress) -> KeyPress.Result {
        guard axis == .vertical, !(isSecure && !reveals) else { return .ignored }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return .ignored
        }
        if press.modifiers.contains(.shift) {
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
        guard let onSubmit else { return .ignored }
        onSubmit()
        return .handled
    }

    /// `input.border` at rest and while focused (the ring draws outside it),
    /// `input.borderError` when invalid.
    private var borderColor: Color {
        isInvalid ? theme.assignedColor("component.input.borderError", fallback: theme.border.error) : theme.assignedColor(displaysHover && isEnabled ? "component.input.borderHover" : "component.input.border", fallback: theme.border.strong)
    }

    private var iconColor: Color {
        if !isEnabled { return theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled) }
        return isFocused ? theme.assignedColor("component.input.foreground", fallback: theme.text.primary) : theme.text.tertiary
    }
}

extension View {
    /// `SettingsTextField`'s surface, for a control that stands in for a
    /// field (a file chooser). `isHighlighted` draws the focus border, for a
    /// drop target.
    func settingsInputChrome(isInvalid: Bool = false, isHovered: Bool = false, isHighlighted: Bool = false) -> some View {
        modifier(SettingsInputChrome(isInvalid: isInvalid, isHovered: isHovered, isHighlighted: isHighlighted))
    }
}

private struct SettingsInputChrome: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let isInvalid: Bool
    let isHovered: Bool
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium), style: .continuous)
        content
            .background(
                shape.fill(
                    isEnabled
                        ? theme.assignedColor("component.input.background", fallback: theme.surface.raised)
                        : theme.assignedColor("component.input.disabled.background", fallback: theme.surface.disabled)))
            .overlay(
                shape.strokeBorder(
                    border, lineWidth: theme.assignedMetric("component.input.borderWidth", fallback: theme.stroke.default)))
    }

    private var border: Color {
        if isInvalid { return theme.assignedColor("component.input.borderError", fallback: theme.border.error) }
        if isHighlighted { return theme.border.focus }
        return theme.assignedColor(
            isHovered && isEnabled ? "component.input.borderHover" : "component.input.border", fallback: theme.border.strong)
    }
}

// MARK: - Text Editor

/// The one multi-line editor (prompts, instructions, JSON, headers). Same
/// chrome and focus ring as `SettingsTextField`.
struct SettingsTextEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsFieldAccessibility) private var fieldAccessibility
    @Binding var text: String
    var placeholder: String?
    var minHeight: CGFloat
    var maxHeight: CGFloat?
    var monospaced: Bool
    var isInvalid: Bool
    @State private var isHovering = false
    @State private var nativeFocused = false
    @State private var nativeComposing = false
    @State private var contentHeight: CGFloat = 60
    @FocusState private var isFocused: Bool

    init(text: Binding<String>, placeholder: String? = nil, minHeight: CGFloat = 80,
         maxHeight: CGFloat? = nil, monospaced: Bool = false, isInvalid: Bool = false) {
        _text = text; self.placeholder = placeholder; self.minHeight = minHeight
        self.maxHeight = maxHeight; self.monospaced = monospaced; self.isInvalid = isInvalid
    }
    private var prefix: String { "component.library.3." }
    private var textKey: String { monospaced ? "type.code" : prefix + "text" }
    private var fieldName: String {
        fieldAccessibility.flatMap { $0.name.isEmpty ? nil : $0.name } ?? placeholder ?? L("Multiline editor")
    }
    var body: some View {
        #if OSAURUS_DESIGN_SYSTEM
        let paddingX = theme.catalogLayoutMetric(prefix + "elements.layout.editorPaddingX", inheriting: theme.assignedMetric(prefix + "padding", fallback: 5))
        let paddingY = theme.catalogLayoutMetric(prefix + "elements.layout.editorPaddingY", inheriting: theme.assignedMetric(prefix + "padding", fallback: 5))
        let radius = theme.assignedMetric(prefix + "radius", fallback: theme.radius.medium)
        let ink = theme.assignedColor(prefix + (isEnabled ? "foreground" : "disabledForeground"), fallback: theme.text.primary)
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !nativeComposing, let placeholder {
                Text(verbatim: placeholder)
                    .assignedTypography(textKey, fallback: monospaced ? SettingsFont.mono : SettingsFont.body)
                    .foregroundStyle(theme.assignedColor(prefix + (isEnabled ? "secondary" : "disabledForeground"), fallback: theme.text.placeholder))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            InspectorAssignedTextEditor(text: $text, measuredHeight: $contentHeight, isComposing: $nativeComposing,
                font: theme.assignedNativeFont(textKey, fallback: theme.nsFont(.bodySmall)),
                lineHeight: theme.assignedLineHeight(textKey, fallback: theme.lineHeight(.bodySmall)),
                tracking: theme.assignedTracking(textKey) ?? 0,
                paragraphSpacing: theme.catalogLayoutMetric(prefix + "elements.layout.paragraphGap", inheriting: theme.assignedMetric(prefix + "gap", fallback: 0)),
                textColor: NSColor(ink), selectionColor: NSColor(theme.assignedColor(prefix + "selected", fallback: theme.surface.selected)),
                editable: isEnabled, onFocusChange: { nativeFocused = $0 },
                accessibleName: fieldName, accessibleHelp: fieldAccessibility?.help)
                .frame(height: min(maxHeight ?? .greatestFiniteMagnitude, max(theme.assignedMetric(prefix + "height", fallback: minHeight), contentHeight)))
        }
        .padding(.horizontal, paddingX).padding(.vertical, paddingY)
        .catalogLayoutTarget(prefix + "elements.layout.editorPaddingX")
        .catalogLayoutTarget(prefix + "elements.layout.editorPaddingY")
        .catalogLayoutTarget(prefix + "elements.layout.paragraphGap")
        .background(theme.assignedColor(prefix + (!isEnabled ? "disabledBackground" : isHovering ? "hover" : "background"), fallback: theme.surface.raised), in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(theme.assignedColor(prefix + (isInvalid ? "error" : "border"), fallback: theme.border.strong), lineWidth: theme.assignedMetric(prefix + "borderWidth", fallback: theme.stroke.default)))
        .overlay {
            if nativeFocused && isEnabled {
                let offset = theme.assignedMetric("component.focus.offset", fallback: theme.focusOffset)
                let role = DesignButtonBindings.role(prefix + "accent")
                RoundedRectangle(cornerRadius: radius + offset)
                    .inset(by: -offset)
                    .stroke(theme.assignedColor(role == "color.border.focus" ? "component.focus.color" : prefix + "accent", fallback: theme.border.focus), lineWidth: theme.assignedMetric("component.focus.width", fallback: theme.stroke.focus))
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovering = $0 }
        #if OSAURUS_DESIGN_SYSTEM
        .assignedDesignEffect("component.input.effect", theme: theme, radius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium))
        #endif
        .preference(key: SettingsInputInvalidPreference.self, value: isInvalid)
        .preference(key: SettingsEditorPreference.self, value: true)
        .nativeCatalogTarget(["background", "foreground", "disabledForeground", "padding", "radius", "border", "borderWidth", "error", "text", "gap", "height", "selected", "hover", "disabledBackground", "secondary", "accent"].map {
            CatalogElementAssignments.routed(prefix + $0, mappings: DesignThemeOverlay.shared.current()?.document.mappings ?? [:])
        }, "Multiline editor")
        #else
        legacyBody
        #endif
    }
    private var legacyBody: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, let placeholder {
                Text(verbatim: placeholder)
                    .foregroundColor(isEnabled ? theme.assignedColor("component.input.placeholder", fallback: theme.text.placeholder) : theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled))
                    .padding(.horizontal, 5)
                    .padding(.vertical, theme.space.s8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .foregroundColor(isEnabled ? theme.assignedColor("component.input.foreground", fallback: theme.text.primary) : theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .accessibilityLabel(Text(verbatim: fieldName))
                .accessibilityHint(Text(verbatim: fieldAccessibility?.help ?? ""))
        }
        .assignedTypography(monospaced ? "type.code" : "component.input.text", fallback: monospaced ? SettingsFont.mono : SettingsFont.body)
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .padding(.horizontal, 5)
        .padding(.vertical, theme.space.s4)
        .background(
            RoundedRectangle(cornerRadius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium), style: .continuous)
                .fill(isEnabled ? theme.assignedColor("component.input.background", fallback: theme.surface.raised) : theme.assignedColor("component.input.disabled.background", fallback: theme.surface.disabled))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium), style: .continuous)
                .strokeBorder(isInvalid ? theme.assignedColor("component.input.borderError", fallback: theme.border.error) : theme.assignedColor("component.input.border", fallback: theme.border.strong), lineWidth: theme.assignedMetric("component.input.borderWidth", fallback: theme.stroke.default))
        )
        #if OSAURUS_DESIGN_SYSTEM
        .assignedDesignEffect("component.input.effect", theme: theme, radius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium))
        #endif
        .preference(key: SettingsInputInvalidPreference.self, value: isInvalid)
        .assignedFocusRing(isFocused && isEnabled, radius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium))
        .animation(theme.motion.quick, value: isFocused)
    }
}
private struct SettingsEditorPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct SettingsInputInvalidPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: - Field Row

/// Label above a control, hint below. The stacked counterpart of
/// `SettingsRow` for controls too wide to sit trailing (text fields, editors,
/// pickers with long options).
struct SettingsFieldRow<Content: View>: View {
    @State private var containsInvalidInput = false
    @State private var containsEditor = false
    @Environment(\.theme) private var theme

    let label: String
    var hint: String?
    /// Settings-search landing anchor; glows the control, not the label.
    var anchorId: String?
    var verbatimHint: Bool
    var verbatimLabel: Bool
    @ViewBuilder let content: () -> Content

    init(
        label: String,
        hint: String? = nil,
        anchorId: String? = nil,
        verbatimHint: Bool = false,
        verbatimLabel: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.hint = hint
        self.anchorId = anchorId
        self.verbatimHint = verbatimHint
        self.verbatimLabel = verbatimLabel
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !label.isEmpty {
                Group {
                    if verbatimLabel {
                        SettingsFieldLabel(verbatim: label, editor: containsEditor)
                    } else {
                        SettingsFieldLabel(LocalizedStringKey(label), editor: containsEditor)
                    }
                }
                .padding(.bottom, theme.catalogLayoutMetric(containsEditor ? "component.library.3.elements.layout.labelGap" : "component.input.labelGap", inheriting: theme.assignedMetric(containsEditor ? "component.library.3.gap" : "component.input.contentGap", fallback: theme.space.s6)))
                .catalogLayoutTarget(containsEditor ? "component.library.3.elements.layout.labelGap" : "component.input.labelGap")
            }
            content()
                .settingsFieldAccessibility(
                    verbatimLabel ? label : L(String.LocalizationValue(label)),
                    help: hint.map { verbatimHint ? $0 : L(String.LocalizationValue($0)) }
                )
                .settingsLandingAnchor(anchorId)
                .onPreferenceChange(SettingsInputInvalidPreference.self) { containsInvalidInput = $0 }
                .onPreferenceChange(SettingsEditorPreference.self) { containsEditor = $0 }
            if let hint, !hint.isEmpty {
                Group {
                    if verbatimHint {
                        Text(verbatim: hint)
                    } else {
                        Text(LocalizedStringKey(hint), bundle: .module)
                    }
                }
                .assignedTypography(containsEditor ? "component.library.3.caption" : "component.input.helper.text", fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.assignedColor(containsEditor ? "component.library.3." + (containsInvalidInput ? "error" : "secondary") : containsInvalidInput ? "component.input.error.foreground" : "component.input.helper.foreground", fallback: theme.text.tertiary))
                .fixedSize(horizontal: false, vertical: true)
                .nativeCatalogTarget([containsEditor ? "component.library.3.caption" : "component.input.helper.text", containsEditor ? "component.library.3." + (containsInvalidInput ? "error" : "secondary") : containsInvalidInput ? "component.input.error.foreground" : "component.input.helper.foreground"], containsInvalidInput ? "Validation error below input" : "Helper text below input")
                .padding(.top, theme.catalogLayoutMetric(containsEditor ? "component.library.3.elements.layout.helperGap" : "component.input.helperGap", inheriting: theme.assignedMetric(containsEditor ? "component.library.3.gap" : "component.input.contentGap", fallback: theme.space.s6)))
                .catalogLayoutTarget(containsEditor ? "component.library.3.elements.layout.helperGap" : "component.input.helperGap")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sentence-case label above a stacked control, for layouts that can't
/// use `SettingsFieldRow` (label beside a counter, two fields on one line).
struct SettingsFieldLabel: View {
    @Environment(\.theme) private var theme

    private let text: Text
    var editor = false

    init(_ text: LocalizedStringKey, editor: Bool = false) {
        self.text = Text(text, bundle: .module)
        self.editor = editor
    }

    init(verbatim text: String, editor: Bool = false) {
        self.text = Text(verbatim: text)
        self.editor = editor
    }

    var body: some View {
        text
            .assignedTypography(editor ? "component.library.3.label" : "component.input.label.text", fallback: SettingsFont.rowTitle)
            .foregroundColor(theme.assignedColor(editor ? "component.library.3.elements.label.foreground" : "component.input.label.foreground", fallback: theme.text.primary))
            .nativeCatalogTarget([editor ? "component.library.3.label" : "component.input.label.text", editor ? "component.library.3.elements.label.foreground" : "component.input.label.foreground"], "Field label above input")
    }
}

// MARK: - Text Field Row

struct SettingsTextFieldRow: View {
    let label: String
    @Binding var text: String
    /// Catalog key.
    let placeholder: String
    let help: String
    var anchorId: String?
    var monospaced: Bool
    var isSecure: Bool
    var onEditingChanged: ((Bool) -> Void)?

    init(
        label: String,
        text: Binding<String>,
        placeholder: String,
        help: String = "",
        anchorId: String? = nil,
        monospaced: Bool = false,
        isSecure: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.help = help
        self.anchorId = anchorId
        self.monospaced = monospaced
        self.isSecure = isSecure
        self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        SettingsFieldRow(label: label, hint: help, anchorId: anchorId) {
            SettingsTextField(
                placeholder: placeholder.isEmpty ? "" : String(localized: String.LocalizationValue(placeholder), bundle: .module),
                text: $text,
                monospaced: monospaced,
                isSecure: isSecure,
                onEditingChanged: onEditingChanged
            )
        }
    }
}

// MARK: - Slider Row

/// A float override: unchecked inherits the model/runtime default, checked
/// reveals a slider.
struct SettingsSliderRow: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(7, enabled: baseComponentEnabled) }
    /// The group already insets its rows.
    @Environment(\.settingsInGroup) private var inGroup

    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Float>
    let step: Float
    let defaultValue: Float
    let formatString: String
    var anchorId: String? = nil

    private var hasOverride: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Read-only rendering must not turn an inherited value into a saved override.
    // A numeric fallback is used only when the user explicitly enables Override.
    var overrideEnabled: Binding<Bool> {
        Binding(
            get: { hasOverride },
            set: { enabled in
                guard enabled != hasOverride else { return }
                text = enabled ? String(format: formatString, defaultValue) : ""
            }
        )
    }

    var sliderValue: Binding<Float> {
        Binding(
            get: { effectiveValue },
            set: { text = String(format: formatString, $0) }
        )
    }

    private var effectiveValue: Float {
        if let v = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(v, range.lowerBound), range.upperBound)
        }
        return defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSliderRow.body.verticalGap", inheriting: theme.space.s8)) {
            SettingsRow(title: label, description: help) {
                Toggle(isOn: overrideEnabled) {
                    Text("Override", bundle: .module)
                        .font(SettingsFont.compactLabel)
                }
                .settingsCheckbox(showsLabel: true)
                .accessibilityLabel(Text(LocalizedStringKey(label), bundle: .module))
            }

            if hasOverride {
                HStack(spacing: theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSliderRow.body.horizontalGap", inheriting: theme.space.s12)) {
                    Text(verbatim: String(format: formatString, range.lowerBound))
                        .assignedTypography("component.library.7.caption", fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 28, alignment: .trailing)
                    #if OSAURUS_DESIGN_SYSTEM
                    AssignedBaseSlider(value: Binding(get: { Double(effectiveValue) }, set: { text = String(format: formatString, Float($0)) }),
                        range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step), label: L(String.LocalizationValue(label)))
                    #else
                    Slider(value: sliderValue, in: range, step: step)
                        .tint(theme.action.primary.default.background)
                        .controlSize(.small)
                    #endif
                    Text(verbatim: String(format: formatString, range.upperBound))
                        .assignedTypography("component.library.7.caption", fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 28, alignment: .leading)
                    Text(verbatim: String(format: formatString, effectiveValue))
                        .assignedTypography("component.library.7.caption", fallback: SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 44)
                        .padding(.vertical, 3)
                        .settingsChrome(.control, radius: theme.radius.small)
                }.catalogLayoutTarget("component.library.7.elements.layout.settingsSliderRow.body.horizontalGap")
            }
        }.catalogLayoutTarget("component.library.7.elements.layout.settingsSliderRow.body.verticalGap")
        .padding(.horizontal, inGroup ? 0 : theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSliderRow.body.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: 0))).padding(.vertical, inGroup ? 0 : theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSliderRow.body.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: 0))).catalogLayoutTarget("component.library.7.elements.layout.settingsSliderRow.body.padding.horizontal").catalogLayoutTarget("component.library.7.elements.layout.settingsSliderRow.body.padding.vertical")
        .assignedBaseChrome(7, fallback: nil)
        .environment(\.baseAssignmentFamily, 7)
        .environment(\.baseDescriptionAssignment, "component.library.7.caption")
        .settingsLandingAnchor(anchorId)
    }
}

// MARK: - Slider

/// A value always in effect, dragged across a range: title and live readout
/// on one line, the slider below, an optional caption under it. For an
/// optional override of a model default use `SettingsSliderRow`.
struct SettingsSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(7, enabled: baseComponentEnabled) }
    @Environment(\.isEnabled) private var isEnabled
    /// The group already insets its rows.
    @Environment(\.settingsInGroup) private var inGroup

    let title: LocalizedStringKey
    /// Already formatted ("1.5s", "0.75x", "Disabled").
    let valueText: String
    var description: LocalizedStringKey? = nil
    @Binding var value: Value
    let range: ClosedRange<Value>
    var step: Value.Stride? = nil
    var anchorId: String? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSlider.body.verticalGap", inheriting: theme.space.s8)) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSlider.body.horizontalGap", inheriting: theme.space.s8)) {
                Text(title, bundle: .module)
                    .assignedTypography("component.library.7.label", fallback: SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)
                Spacer(minLength: theme.space.s8)
                Text(verbatim: valueText)
                    .assignedTypography("component.library.7.text", fallback: SettingsFont.mono)
                    .foregroundColor(isEnabled ? theme.text.primary : theme.text.disabled)
                    .monospacedDigit()
            }.catalogLayoutTarget("component.library.7.elements.layout.settingsSlider.body.horizontalGap")

            slider
                .tint(theme.action.primary.default.background)
                .accessibilityLabel(Text(title, bundle: .module))
                .accessibilityValue(Text(verbatim: valueText))

            if let description {
                Text(description, bundle: .module)
                    .assignedTypography("component.library.7.caption", fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.catalogLayoutTarget("component.library.7.elements.layout.settingsSlider.body.verticalGap")
        .padding(.horizontal, inGroup ? 0 : theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSlider.body.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: 0))).padding(.vertical, inGroup ? 0 : theme.catalogLayoutMetric("component.library.7.elements.layout.settingsSlider.body.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: 0))).catalogLayoutTarget("component.library.7.elements.layout.settingsSlider.body.padding.horizontal").catalogLayoutTarget("component.library.7.elements.layout.settingsSlider.body.padding.vertical")
        .assignedBaseChrome(7, fallback: nil)
        .environment(\.baseAssignmentFamily, 7)
        .settingsLandingAnchor(anchorId)
    }

    @ViewBuilder
    private var slider: some View {
        #if OSAURUS_DESIGN_SYSTEM
        AssignedBaseSlider(value: Binding(get: { Double(value) }, set: { value = Value($0) }),
            range: Double(range.lowerBound)...Double(range.upperBound), step: step.map { Double($0) },
            label: L("Slider"), onEditingChanged: onEditingChanged)
        #else
        if let step {
            Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
        } else {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
        #endif
    }
}

// MARK: - Date Picker

/// Compact date (and optionally time) field. The label is read by
/// VoiceOver; show it visually with `SettingsFieldRow` / `SettingsRow`.
struct SettingsDatePicker: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(8, enabled: baseComponentEnabled) }
    @State private var assignedFocus = false

    let label: LocalizedStringKey
    @Binding var selection: Date
    var minimum: Date? = nil
    var components: DatePickerComponents = [.date]

    private var nativePicker: some View {
        Group {
            if let minimum {
                DatePicker(selection: $selection, in: minimum..., displayedComponents: components) {
                    Text(label, bundle: .module)
                }
            } else {
                DatePicker(selection: $selection, displayedComponents: components) {
                    Text(label, bundle: .module)
                }
            }
        }
        .labelsHidden()
        .datePickerStyle(.compact)
    }
    var body: some View {
        Group {
            #if OSAURUS_DESIGN_SYSTEM
            AssignedNativePicker(content: nativePicker, theme: theme, enabled: baseComponentEnabled, family: 8, onFocusChange: { assignedFocus = $0 })
            #else
            nativePicker
            #endif
        }
        .tint(theme.border.focus)
        .assignedTypography("component.library.8.text", fallback: SettingsFont.body)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.8.elements.layout.settingsDatePicker.body.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: 0))).padding(.vertical, theme.catalogLayoutMetric("component.library.8.elements.layout.settingsDatePicker.body.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: 0))).catalogLayoutTarget("component.library.8.elements.layout.settingsDatePicker.body.padding.horizontal").catalogLayoutTarget("component.library.8.elements.layout.settingsDatePicker.body.padding.vertical")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(8)
        .nativeCatalogTarget(["padding", "height", "hover", "disabledBackground"].map { "component.library.8.elements.container." + $0 } + ["component.library.8.accent"], "Date/time field")
        #if OSAURUS_DESIGN_SYSTEM
        .assignedBaseFocusRing(8, visible: assignedFocus && baseComponentEnabled, radius: theme.catalogMetric("radius", fallback: 8), keyboardOnly: false)
        #endif
        .fixedSize()
    }
}

// MARK: - Stepper Row

/// An integer setting typed or nudged with − / +.
struct SettingsStepperRow: View {
    let label: String
    let help: String
    private let stepper: SettingsStepper
    var anchorId: String?

    /// Override form: empty `text` inherits `defaultValue` (the placeholder).
    init(
        label: String,
        help: String,
        text: Binding<String>,
        range: ClosedRange<Int>,
        step: Int,
        defaultValue: Int,
        anchorId: String? = nil
    ) {
        self.label = label
        self.help = help
        self.stepper = SettingsStepper(text: text, range: range, step: step, defaultValue: defaultValue)
        self.anchorId = anchorId
    }

    init(
        label: String,
        help: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        unit: String? = nil,
        anchorId: String? = nil
    ) {
        self.label = label
        self.help = help
        self.stepper = SettingsStepper(value: value, range: range, step: step, unit: unit)
        self.anchorId = anchorId
    }

    var body: some View {
        SettingsRow(title: label, description: help, anchorId: anchorId) {
            stepper
                .settingsFieldAccessibility(L(String.LocalizationValue(label)), help: L(String.LocalizationValue(help)))
        }
        .environment(\.baseAssignmentFamily, 7)
        .environment(\.baseDescriptionAssignment, "component.library.7.caption")
    }
}

/// The settings number control: a typed value with − / + on one control
/// surface. Use it instead of `Stepper` so every number looks and edits the
/// same. Typed values write through while in range and clamp on submit/blur.
struct SettingsStepper: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(7, enabled: baseComponentEnabled) }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.settingsFieldAccessibility) private var fieldAccessibility

    @Binding private var value: Int?
    private let range: ClosedRange<Int>
    private let step: Int
    private let placeholder: Int?
    private let unit: String?

    @State private var draft = ""
    #if OSAURUS_DESIGN_SYSTEM
    @State private var isFocused = false
    @State private var composing = false
    @FocusState private var focusedStepButton: String?
    #else
    @FocusState private var isFocused: Bool
    #endif

    /// Override form: empty `text` inherits `defaultValue` (the placeholder).
    init(text: Binding<String>, range: ClosedRange<Int>, step: Int = 1, defaultValue: Int) {
        self._value = Binding(
            get: { Int(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) },
            set: { text.wrappedValue = $0.map(String.init) ?? "" }
        )
        self.range = range
        self.step = step
        self.placeholder = defaultValue
        self.unit = nil
    }

    init(value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String? = nil) {
        self._value = Binding(
            get: { value.wrappedValue },
            set: { if let v = $0 { value.wrappedValue = v } }
        )
        self.range = range
        self.step = step
        self.placeholder = nil
        self.unit = unit
    }

    private var effectiveValue: Int {
        clamp(value ?? placeholder ?? range.lowerBound)
    }

    private var fieldName: String {
        fieldAccessibility.flatMap { $0.name.isEmpty ? nil : $0.name } ?? L("Value")
    }

    private var fieldHelp: String? {
        var parts = [String]()
        if let unit { parts.append(L(String.LocalizationValue(unit))) }
        if value == nil, let placeholder { parts.append(String(localized: "Inherited value: \(placeholder)", bundle: .module)) }
        if let help = fieldAccessibility?.help, !help.isEmpty { parts.append(help) }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private var verticalPadding: CGFloat {
        theme.catalogLayoutMetric(
            "component.library.7.elements.layout.settingsStepper.body.paddingY",
            inheriting: theme.catalogLayoutMetric("component.library.7.padding", inheriting: theme.space.s2)
        )
    }

    private var minimumHeight: CGFloat {
        theme.catalogMetric("height", fallback: theme.controlSize.defaultHeight)
    }

    private func clamp(_ v: Int) -> Int {
        min(max(v, range.lowerBound), range.upperBound)
    }

    private var contentWidth: CGFloat {
        let font = theme.assignedNativeFont("component.library.7.text", fallback: theme.nsFont(.code))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: theme.assignedTracking("component.library.7.text") ?? 0]
        let bounds = [range.lowerBound, range.upperBound, placeholder ?? range.lowerBound]
        let number = bounds.map { (String($0) as NSString).size(withAttributes: attributes).width }.max() ?? 0
        return max(theme.space.s24, ceil(number + theme.space.s8))
    }
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.7.elements.layout.settingsStepper.body.horizontalGap", inheriting: theme.space.s4)) {
                ZStack(alignment: .trailing) {
                    if draft.isEmpty, let placeholder {
                        Text(verbatim: String(placeholder))
                            .foregroundColor(isEnabled ? theme.text.placeholder : theme.text.disabled)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    #if OSAURUS_DESIGN_SYSTEM
                    InspectorAssignedTextField(text: $draft, isComposing: $composing,
                        font: theme.assignedNativeFont("component.library.7.text", fallback: theme.nsFont(.code)),
                        textColor: NSColor(isEnabled ? theme.text.primary : theme.text.disabled),
                        onSubmit: commit, onFocusChange: { isFocused = $0 },
                        tracking: theme.assignedTracking("component.library.7.text"), editable: isEnabled,
                        requestedFocus: isFocused, alignment: .right,
                        onCommand: handleNumericCommand, accessibleName: fieldName, accessibleHelp: fieldHelp)
                        .frame(height: theme.assignedLineHeight("component.library.7.text", fallback: theme.lineHeight(.code)))
                    #else
                    TextField("", text: $draft)
                        .accessibilityLabel(Text(verbatim: fieldName))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(isEnabled ? theme.text.primary : theme.text.disabled)
                        .focused($isFocused)
                        .onSubmit(commit)
                        .onKeyPress(.upArrow) { adjust(increasing: true); return .handled }
                        .onKeyPress(.downArrow) { adjust(increasing: false); return .handled }
                        .accessibilityHint(Text(verbatim: fieldHelp ?? ""))
                    #endif
                }
                .frame(width: contentWidth)
                if let unit {
                    Text(LocalizedStringKey(unit), bundle: .module)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }.catalogLayoutTarget("component.library.7.elements.layout.settingsStepper.body.horizontalGap")
            .assignedTypography("component.library.7.text", fallback: SettingsFont.mono)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.7.elements.layout.settingsStepper.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s8))).catalogLayoutTarget("component.library.7.elements.layout.settingsStepper.body.paddingX")

            Divider().frame(height: theme.space.s16).accessibilityHidden(true)
            stepButton(increasing: false)
            Divider().frame(height: theme.space.s16).accessibilityHidden(true)
            stepButton(increasing: true)
        }
        .padding(.vertical, verticalPadding)
        .catalogLayoutTarget("component.library.7.elements.layout.settingsStepper.body.paddingY")
        .frame(minHeight: minimumHeight)
        #if OSAURUS_DESIGN_SYSTEM
        .assignedBaseChrome(7, fallback: .control)
        #else
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(isEnabled ? theme.surface.raised : theme.surface.disabled)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .strokeBorder(theme.border.strong, lineWidth: theme.stroke.default)
        )
        #endif
        .assignedBaseFocusRing(7, visible: isFocused && isEnabled, radius: theme.radius.medium, keyboardOnly: false)
        .fixedSize()
        .onAppear { draft = value.map(String.init) ?? "" }
        .onChange(of: value) { _, newValue in
            if !isFocused { draft = newValue.map(String.init) ?? "" }
        }
        .onChange(of: draft) { _, newDraft in
            guard isFocused else { return }
            let trimmed = newDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if placeholder != nil { value = nil }
            } else if let v = Int(trimmed), range.contains(v) {
                value = v
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func set(_ v: Int) {
        let clamped = clamp(v)
        value = clamped
        draft = String(clamped)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, placeholder != nil {
            value = nil
        } else if let v = Int(trimmed) {
            set(v)
        } else {
            draft = value.map(String.init) ?? ""
        }
    }

    private func adjust(increasing: Bool) {
        guard isEnabled else { return }
        let current = effectiveValue
        guard increasing ? current < range.upperBound : current > range.lowerBound else { return }
        let (next, overflow) = increasing ? current.addingReportingOverflow(step) : current.subtractingReportingOverflow(step)
        set(overflow ? (increasing ? range.upperBound : range.lowerBound) : next)
    }

    private func handleNumericCommand(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveUp(_:)): adjust(increasing: true)
        case #selector(NSResponder.moveDown(_:)): adjust(increasing: false)
        default: return false
        }
        return true
    }

    private func stepButton(increasing: Bool) -> some View {
        let icon = increasing ? "plus" : "minus"
        let enabled = increasing ? effectiveValue < range.upperBound : effectiveValue > range.lowerBound
        let title = increasing
            ? String(localized: "Increase \(fieldName)", bundle: .module)
            : String(localized: "Decrease \(fieldName)", bundle: .module)
        return Button { adjust(increasing: increasing) } label: {
            Image(systemName: icon)
                .font(SettingsFont.glyphSmall)
                .foregroundColor(enabled && isEnabled ? theme.text.primary : theme.text.disabled)
                .frame(width: theme.controlSize.compactHeight, height: max(theme.space.s24, minimumHeight - verticalPadding * 2))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(verbatim: title))
        .assignedBasePlainButtonStyle()
        #if OSAURUS_DESIGN_SYSTEM
        .focusable(enabled && isEnabled).focused($focusedStepButton, equals: icon).focusEffectDisabled()
        .assignedBaseFocusRing(7, visible: focusedStepButton == icon && enabled && isEnabled, radius: theme.radius.small)
        .onKeyPress(.space) {
            guard enabled && isEnabled else { return .ignored }
            adjust(increasing: increasing)
            return .handled
        }
        #endif
        .disabled(!enabled)
    }
}

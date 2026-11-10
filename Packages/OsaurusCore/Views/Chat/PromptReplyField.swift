//
//  PromptReplyField.swift
//  osaurus
//
//  The short reply editor of in-chat prompts: an NSTextView-backed field
//  with the chat input conventions (Enter submits, Shift+Enter inserts a
//  newline, Esc cancels) and the composer's send button. The clarify card
//  uses the `field` chrome inside its card; the owner's line into a hosted
//  conversation stands where the composer would be and wears its bubble.
//

import SwiftUI

struct PromptReplyField: View {
    enum Chrome {
        /// A text field beside the send button, inside a prompt card.
        case field
        /// The chat composer's raised bubble around field and button.
        case bubble
    }

    @Binding var text: String
    /// Catalog key, shown while the field is empty.
    let placeholder: LocalizedStringKey
    var canSubmit: Bool
    @Binding var isFocused: Bool
    var chrome: Chrome = .field
    /// Bind Return to the submit button as the card's default action. Off
    /// where another default action (an approval) can share the window.
    var isDefaultAction = true
    var submitHelp: LocalizedStringKey = "Send"
    var fieldIdentifier = "prompt-reply-field"
    var submitIdentifier = "prompt-reply-send"
    let onSubmit: () -> Void
    var onEscape: (() -> Void)?

    @State private var isComposing = false
    @Environment(\.theme) private var theme
    /// Settings ▸ Chat ▸ Check Spelling While Typing, applied live.
    @AppStorage(ComposerSpellCheckSetting.defaultsKey)
    private var spellCheckEnabled: Bool = ComposerSpellCheckSetting.defaultValue

    /// About four lines; beyond that the editor scrolls.
    private var inputMaxHeight: CGFloat {
        // 4 lines + the text view's vertical container insets (2pt × 2).
        ceil(theme.lineHeight(textRole) * 4) + 4
    }

    private var textRole: ThemeTextStyleRole { chrome == .bubble ? .body : .bodySmall }

    var body: some View {
        switch chrome {
        case .field:
            HStack(spacing: 10) {
                editor
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                            .fill(theme.surface.raised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                            .strokeBorder(
                                isFocused ? theme.border.focus : theme.border.default,
                                lineWidth: theme.stroke.default
                            )
                    )
                submitButton
            }
        case .bubble:
            HStack(alignment: .bottom, spacing: theme.space.s8) {
                editor
                submitButton
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.bubble, style: .continuous)
                    .fill(theme.surface.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.bubble, style: .continuous)
                    .strokeBorder(
                        isFocused ? theme.border.focus : theme.border.strong,
                        lineWidth: isFocused ? theme.stroke.focus : theme.stroke.default
                    )
            )
            .themeElevation(theme.elevation.raised)
            .animation(theme.motion.quick, value: isFocused)
        }
    }

    private var editor: some View {
        EditableTextView(
            text: $text,
            theme: theme,
            textRole: textRole,
            textColor: theme.text.primary,
            cursorColor: theme.cursor,
            isFocused: $isFocused,
            isComposing: $isComposing,
            maxHeight: inputMaxHeight,
            spellCheckEnabled: spellCheckEnabled,
            onCommit: { if canSubmit { onSubmit() } },
            onShiftCommit: nil,  // Shift+Enter → newline
            onEscape: onEscape.map { escape in
                {
                    escape()
                    return true
                }
            }
        )
        // Pin to the intrinsic height (1 line empty → ~4 lines, then
        // scrolls via the text view's own cap). The representable is
        // height-flexible and overlays propose the full window, so
        // without this the field balloons to fill its container.
        .fixedSize(horizontal: false, vertical: true)
        // EditableTextView carries a 6pt/2pt internal container inset;
        // pad the remainder so the visual frame is 12/9.
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder, bundle: .module)
                    .textStyle(textRole)
                    .foregroundColor(theme.text.placeholder)
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.top, 9 + theme.lineSpacing(textRole) / 2)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier(fieldIdentifier)
    }

    @ViewBuilder
    private var submitButton: some View {
        let button = SendButton(canSend: canSubmit, action: onSubmit)
            .help(Text(submitHelp, bundle: .module))
            .accessibilityLabel(Text(submitHelp, bundle: .module))
            .accessibilityIdentifier(submitIdentifier)
        if isDefaultAction {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }
}

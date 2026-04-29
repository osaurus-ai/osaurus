//
//  AgentSheetChrome.swift
//  osaurus
//
//  Shared chrome for the Agents feature so the editor, share, incoming-pair,
//  and remote-detail surfaces all read as one product:
//
//    - `AgentSheetHeader`, `AgentSheetFooter`, `AgentSheetSectionLabel`
//      assemble every sheet from the same building blocks (header gradient,
//      under-header divider, padding rhythm, close button, section caps).
//    - `PrimaryButtonStyle` / `SecondaryButtonStyle` / `DestructiveButtonStyle`
//      replace the hand-rolled accent capsules that diverged across files.
//      Capsule pills are reserved for status badges (Active / Remote / Accepted),
//      not actions.
//    - `StyledTextField` is the focus-ring text field used throughout. The
//      multiline (`axis: .vertical`) overload covers note fields previously
//      built with raw `TextField`s.
//    - `AgentSectionEmptyState` is the in-card empty placeholder used inside
//      `AgentDetailSection` bodies so empty tabs guide rather than disappear.
//

import SwiftUI

// MARK: - Sheet Header

/// Shared sheet header used by AgentEditor, Share, Incoming, and any future
/// agent sheets. Flat 18pt icon, 15pt semibold title, 12pt secondary subtitle,
/// 24x24 close button. Always followed by a faint divider so the body has a
/// clean baseline regardless of what's beneath.
struct AgentSheetHeader: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title, bundle: .module)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if let subtitle {
                        Text(subtitle, bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(theme.secondaryBackground)

            Divider().opacity(0.5)
        }
    }
}

// MARK: - Sheet Footer

/// Shared sheet footer with a primary CTA, optional secondary, optional hint.
/// Renders the divider on top, a `⌘+Enter`-style hint on the leading edge,
/// and a Cancel/Confirm pair on the trailing edge using the shared button
/// styles. When `primary` is `nil`, only the hint + secondary render — useful
/// for sheets like Share that have no commit action.
struct AgentSheetFooter: View {
    @Environment(\.theme) private var theme

    struct Action {
        let label: LocalizedStringKey
        let isEnabled: Bool
        let isLoading: Bool
        let handler: () -> Void

        init(
            label: LocalizedStringKey,
            isEnabled: Bool = true,
            isLoading: Bool = false,
            handler: @escaping () -> Void
        ) {
            self.label = label
            self.isEnabled = isEnabled
            self.isLoading = isLoading
            self.handler = handler
        }
    }

    let primary: Action?
    let secondary: Action?
    let hint: LocalizedStringKey?

    init(
        primary: Action? = nil,
        secondary: Action? = nil,
        hint: LocalizedStringKey? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.hint = hint
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)

            HStack(spacing: 10) {
                if let hint {
                    HStack(spacing: 4) {
                        Text("\u{2318}", bundle: .module)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.tertiaryBackground)
                            )
                        Text(hint, bundle: .module)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                if let secondary {
                    Button(action: secondary.handler) {
                        Text(secondary.label, bundle: .module)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!secondary.isEnabled || secondary.isLoading)
                    .keyboardShortcut(.cancelAction)
                }

                if let primary {
                    Button(action: primary.handler) {
                        HStack(spacing: 6) {
                            if primary.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(primary.label, bundle: .module)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!primary.isEnabled || primary.isLoading)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(theme.secondaryBackground)
        }
    }
}

// MARK: - Section Label

/// 11pt bold tertiary-text label with 0.5 tracking — matches the section
/// title style baked into `AgentDetailSection`. Use everywhere a "FIELD NAME"
/// caption appears in a sheet or card.
struct AgentSheetSectionLabel: View {
    @Environment(\.theme) private var theme

    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text, bundle: .module)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .tracking(0.5)
    }
}

// MARK: - Section Empty State

/// In-card empty placeholder used inside `AgentDetailSection` bodies.
/// Sized for embedding in section content (vs `SettingsEmptyState` which is
/// full-screen). Optional CTA renders as a small primary button below the
/// hint copy.
struct AgentSectionEmptyState: View {
    @Environment(\.theme) private var theme

    let icon: String
    let title: LocalizedStringKey
    let hint: LocalizedStringKey?
    let actionLabel: LocalizedStringKey?
    let action: (() -> Void)?

    init(
        icon: String,
        title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        actionLabel: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.hint = hint
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(theme.inputBackground.opacity(0.6))
                )
                .padding(.bottom, 2)

            Text(title, bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)

            if let hint {
                Text(hint, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel, bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
    }
}

// MARK: - Button Styles

/// Accent-tinted commit button. Replaces hand-rolled `Capsule().fill(accent)`
/// patterns scattered across share / incoming / remote views.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.accentColor)
            )
            .opacity(opacity(for: configuration))
    }

    private func opacity(for configuration: Configuration) -> Double {
        if !isEnabled { return 0.45 }
        return configuration.isPressed ? 0.8 : 1.0
    }
}

/// Neutral secondary button with a subtle bordered chip background.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(opacity(for: configuration))
    }

    private func opacity(for configuration: Configuration) -> Double {
        if !isEnabled { return 0.45 }
        return configuration.isPressed ? 0.8 : 1.0
    }
}

/// Soft destructive button (errorColor text + tinted background). Used for
/// Remove / Revoke / Delete in agent surfaces — tinted rather than filled
/// because destructive actions in this product are recoverable (re-pair,
/// re-issue) and shouldn't shout.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.errorColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.errorColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.errorColor.opacity(0.25), lineWidth: 1)
                    )
            )
            .opacity(opacity(for: configuration))
    }

    private func opacity(for configuration: Configuration) -> Double {
        if !isEnabled { return 0.45 }
        return configuration.isPressed ? 0.8 : 1.0
    }
}

// MARK: - Styled Text Field

/// Focus-ring text field with optional leading SF Symbol. Shared between the
/// agent editor, capability picker search, and the note fields on the
/// incoming-pair / remote-detail screens. The `axis` parameter wraps the
/// underlying SwiftUI `TextField(text:axis:)` for multiline note inputs.
struct StyledTextField: View {
    @Environment(\.theme) private var theme

    let placeholder: String
    @Binding var text: String
    let icon: String?
    let axis: Axis
    let lineLimit: Int?

    @State private var isFocused = false

    init(
        placeholder: String,
        text: Binding<String>,
        icon: String? = nil,
        axis: Axis = .horizontal,
        lineLimit: Int? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.axis = axis
        self.lineLimit = lineLimit
    }

    var body: some View {
        HStack(alignment: axis == .vertical ? .top : .center, spacing: 10) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isFocused ? theme.accentColor : theme.tertiaryText)
                    .frame(width: 16)
                    .padding(.top, axis == .vertical ? 1 : 0)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }

                if axis == .vertical {
                    multilineField
                } else {
                    singlelineField
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )
        )
    }

    private var singlelineField: some View {
        TextField(
            "",
            text: $text,
            onEditingChanged: { editing in
                withAnimation(.easeOut(duration: 0.15)) {
                    isFocused = editing
                }
            }
        )
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundColor(theme.primaryText)
    }

    @ViewBuilder
    private var multilineField: some View {
        // SwiftUI's multiline TextField doesn't expose onEditingChanged, so
        // we use a FocusState-bound helper instead. Same focus-ring behaviour.
        MultilineFocusable(
            text: $text,
            isFocused: $isFocused,
            lineLimit: lineLimit,
            theme: theme
        )
    }
}

private struct MultilineFocusable: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let lineLimit: Int?
    let theme: ThemeProtocol

    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if let lineLimit {
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(lineLimit, reservesSpace: true)
            } else {
                TextField("", text: $text, axis: .vertical)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundColor(theme.primaryText)
        .focused($fieldFocused)
        .onChange(of: fieldFocused) { _, newValue in
            withAnimation(.easeOut(duration: 0.15)) {
                isFocused = newValue
            }
        }
    }
}

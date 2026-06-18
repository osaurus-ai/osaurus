//
//  ThemedAlertDialog.swift
//  osaurus
//
//  Custom themed alert dialog with glass effects, spring animations,
//  and styled buttons matching the app's futuristic design language.
//

import SwiftUI

// MARK: - Alert Button Configuration

public enum ThemedAlertPresentationStyle: Equatable, Sendable {
    /// Full-window modal (dims and centers within the window).
    case window
    /// Contained modal (dims and centers within the view it’s applied to).
    /// Useful for toasts/popovers rendered inside a full-screen overlay.
    case contained
}

// MARK: - Global Alert Center (per-window)

@MainActor
public final class ThemedAlertCenter: ObservableObject {
    /// Global singleton (MainActor/UI only).
    public static let shared = ThemedAlertCenter()

    @Published private var activeByScope: [ThemedAlertScope: ThemedAlertRequest] = [:]

    func present(_ request: ThemedAlertRequest, scope: ThemedAlertScope) {
        // A scope holds at most one alert. When a new alert replaces a
        // different one already showing (e.g. an async sandbox-cleanup
        // notice landing while a delete-confirmation is open), reset the
        // clobbered presenter so its `isPresented` binding doesn't wedge
        // at `true`. Without this, the source view's `@State` stays set
        // and its `onChange`-driven re-present never fires again, so that
        // control can never raise its alert a second time.
        if let existing = activeByScope[scope], existing.id != request.id {
            existing.onDismiss()
        }
        activeByScope[scope] = request
    }

    func dismiss(scope: ThemedAlertScope, id: UUID) {
        if activeByScope[scope]?.id == id {
            activeByScope[scope] = nil
        }
    }

    func active(for scope: ThemedAlertScope) -> ThemedAlertRequest? {
        activeByScope[scope]
    }

    /// Cancel the active alert for `scope` as if its cancel-role button
    /// was clicked. Returns true when an alert was active (the event is
    /// considered handled even when the alert has no cancel button, so
    /// callers don't fall through to more destructive actions like
    /// closing the window underneath the alert).
    ///
    /// Used by ChatView's window-level Esc monitor, which owns the key
    /// event before SwiftUI keyboard shortcuts can see it.
    @discardableResult
    public func cancelActive(scope: ThemedAlertScope) -> Bool {
        guard let request = activeByScope[scope] else { return false }
        if let cancel = request.buttons.first(where: { $0.role == .cancel }) {
            cancel.action()
            request.onDismiss()
            activeByScope[scope] = nil
        }
        return true
    }
}

/// Defines the scope/context for themed alerts to prevent overlapping dialogs.
/// Each scope can have at most one active alert at a time.
public enum ThemedAlertScope: Hashable, Sendable {
    /// Alert scoped to a specific chat window
    case chat(UUID)
    /// Alert scoped to the management/settings view
    case management
    /// Alert scoped to the main content area
    case content
    /// Alert scoped to toast overlay panels
    case toastOverlay
    /// Alert scoped to the notch overlay panel
    case notchOverlay
    /// Alert scoped to a specific tool permission dialog
    case toolPermission(UUID)
    /// Fallback scope for unspecified contexts
    case unspecified
}

/// Represents a request to display a themed alert dialog.
/// Contains all the information needed to render the alert including title, message, and buttons.
public struct ThemedAlertRequest: Identifiable {
    /// Unique identifier for this alert request
    public let id: UUID
    /// The alert title displayed prominently
    public let title: String
    /// Optional message displayed below the title
    public let message: String?
    /// Optional accessory view rendered between the message and the button row.
    /// Use for extras like a "Don't ask again" toggle.
    public let accessory: AnyView?
    /// Button configurations for the alert actions
    public let buttons: [AlertButtonConfig]
    /// When true, the cancel button is rendered as an X in the top-trailing
    /// corner instead of inline. Useful for chooser-style alerts where the
    /// inline row would just be padding.
    public let showsCloseButton: Bool
    /// When set, replaces the standard message + accessory + divider +
    /// button-row section with this view. The header (icon / title) and
    /// the close X (if `showsCloseButton`) still render. Use for multi-
    /// page chooser flows that need their own state and navigation.
    public let customContent: AnyView?
    /// Optional fixed width override for the dialog. Defaults to the
    /// standard alert width (340). Useful for `customContent` flows
    /// that need more breathing room than a text alert.
    public let width: CGFloat?

    /// Callback invoked when the alert is dismissed
    public let onDismiss: () -> Void

    public init(
        id: UUID = UUID(),
        title: String,
        message: String?,
        accessory: AnyView? = nil,
        buttons: [AlertButtonConfig],
        showsCloseButton: Bool = false,
        customContent: AnyView? = nil,
        width: CGFloat? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.accessory = accessory
        self.buttons = buttons
        self.showsCloseButton = showsCloseButton
        self.customContent = customContent
        self.width = width
        self.onDismiss = onDismiss
    }
}

private struct ThemedAlertScopeKey: EnvironmentKey {
    static var defaultValue: ThemedAlertScope { .unspecified }
}

extension EnvironmentValues {
    var themedAlertScope: ThemedAlertScope {
        get { self[ThemedAlertScopeKey.self] }
        set { self[ThemedAlertScopeKey.self] = newValue }
    }
}

extension View {
    func themedAlertScope(_ scope: ThemedAlertScope) -> some View {
        environment(\.themedAlertScope, scope)
    }
}

/// Configuration for alert dialog buttons
public struct AlertButtonConfig {
    let title: String
    let role: ButtonRole?
    let action: () -> Void

    public static func destructive(_ title: String, action: @escaping () -> Void) -> AlertButtonConfig {
        AlertButtonConfig(title: title, role: .destructive, action: action)
    }

    public static func cancel(_ title: String, action: @escaping () -> Void = {}) -> AlertButtonConfig {
        AlertButtonConfig(title: title, role: .cancel, action: action)
    }

    public static func primary(_ title: String, action: @escaping () -> Void) -> AlertButtonConfig {
        AlertButtonConfig(title: title, role: nil, action: action)
    }

    public enum ButtonRole {
        case destructive
        case cancel
    }
}

// MARK: - Themed Alert Dialog View

/// A custom alert dialog with glass background and themed styling
private struct ThemedAlertDialogContent: View {
    @Environment(\.theme) private var theme

    let title: String
    let message: String?
    let accessory: AnyView?
    let buttons: [AlertButtonConfig]
    let showsCloseButton: Bool
    let customContent: AnyView?
    let width: CGFloat?
    let presentationStyle: ThemedAlertPresentationStyle
    let onDismiss: () -> Void

    @State private var isAppearing = false
    @State private var hoveredButton: String?

    var body: some View {
        ZStack {
            // Dimmed overlay
            overlayColor
                .opacity(isAppearing ? overlayOpacity : 0)
                .applyIf(presentationStyle == .window) { $0.ignoresSafeArea() }
                .onTapGesture {
                    if let cancel = cancelButton {
                        dismissWithAnimation { cancel.action() }
                    }
                }

            // Dialog content
            dialogContent
                .overlay(alignment: .topTrailing) {
                    if showsCloseButton, let cancel = cancelButton {
                        closeButton(cancel)
                            .padding(10)
                    }
                }
                .scaleEffect(isAppearing ? 1 : 0.9)
                .opacity(isAppearing ? 1 : 0)
                .offset(y: isAppearing ? 0 : 20)
        }
        .onAppear {
            withAnimation(theme.springAnimation()) {
                isAppearing = true
            }
        }
    }

    // MARK: - Overlay Styling

    private var overlayColor: Color {
        theme.isDark ? .black : Color(white: 0.1)
    }

    private var overlayOpacity: Double {
        theme.isDark ? 0.5 : 0.35
    }

    // MARK: - Dialog Content

    private var dialogContent: some View {
        VStack(spacing: 0) {
            // Header with icon
            headerSection

            if let customContent {
                customContent
                    .padding(.top, 16)
            } else {
                // Message
                if let message = message {
                    messageSection(message)
                }

                // Optional accessory (e.g. "Don't ask again" toggle)
                if let accessory = accessory {
                    accessory
                        .padding(.top, 12)
                }

                if !inlineButtons.isEmpty {
                    // Divider
                    Rectangle()
                        .fill(theme.primaryBorder.opacity(0.3))
                        .frame(height: 1)
                        .padding(.top, 16)

                    // Buttons
                    buttonSection
                }
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(width: width ?? 340)
        .background(dialogBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity * 2.4),
            radius: 36,
            x: 0,
            y: 18
        )
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity * 1.2),
            radius: 8,
            x: 0,
            y: 2
        )
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(iconBackgroundColor.opacity(0.15))
                    .frame(width: 48, height: 48)

                // Pulsing ring for attention
                Circle()
                    .stroke(iconBackgroundColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 48, height: 48)
                    .scaleEffect(isAppearing ? 1.2 : 1)
                    .opacity(isAppearing ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.5).repeatForever(autoreverses: false),
                        value: isAppearing
                    )

                Image(systemName: iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(iconBackgroundColor)
            }

            // Title
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Message Section

    private func messageSection(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Button Section

    private var buttonSection: some View {
        let inline = inlineButtons
        return Group {
            if inline.count <= 2 {
                HStack(spacing: 12) {
                    ForEach(Array(inline.enumerated()), id: \.element.title) { idx, button in
                        alertButton(button, isPrimary: idx == inlinePrimaryIndex)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(inline.enumerated()), id: \.element.title) { idx, button in
                        alertButton(button, isPrimary: idx == inlinePrimaryIndex)
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    /// Buttons rendered inline. When the close icon is shown, the cancel
    /// button is promoted to the corner and removed from the row.
    private var inlineButtons: [AlertButtonConfig] {
        guard showsCloseButton else { return buttons }
        return buttons.filter { $0.role != .cancel }
    }

    private var inlinePrimaryIndex: Int {
        if showsCloseButton { return -1 }
        return inlineButtons.firstIndex { $0.role == nil }
            ?? inlineButtons.firstIndex { $0.role == .destructive }
            ?? 0
    }

    private func closeButton(_ cancel: AlertButtonConfig) -> some View {
        Button {
            dismissWithAnimation { cancel.action() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(theme.tertiaryBackground.opacity(0.6))
                )
                .overlay(
                    Circle().stroke(theme.cardBorder, lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
        // Cancel was promoted to the corner X, so it carries the Esc
        // shortcut here instead of in the inline row.
        .keyboardShortcut(.cancelAction)
        .help(Text(cancel.title))
    }

    private func alertButton(_ config: AlertButtonConfig, isPrimary: Bool) -> some View {
        let isHovered = hoveredButton == config.title
        let isDestructive = config.role == .destructive
        // Return activates the primary action; Esc activates cancel.
        // `keyboardShortcut(nil)` is a no-op for the remaining buttons.
        let shortcut: KeyboardShortcut? =
            isPrimary
            ? .defaultAction
            : (config.role == .cancel ? .cancelAction : nil)

        return Button {
            dismissWithAnimation { config.action() }
        } label: {
            Text(config.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(buttonTextColor(isPrimary: isPrimary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(buttonBackground(isPrimary: isPrimary, isDestructive: isDestructive, isHovered: isHovered))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(buttonBorderColor(isPrimary: isPrimary, isHovered: isHovered), lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(shortcut)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            hoveredButton = hovering ? config.title : nil
        }
    }

    // MARK: - Styling Helpers

    private var dialogBackground: some View {
        ZStack {
            ThemedGlassSurface(cornerRadius: 16)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardGradient)
        }
    }

    private var cardGradient: LinearGradient {
        let topOpacity = theme.isDark ? 0.85 : 0.9
        let bottomOpacity = theme.isDark ? 0.8 : 0.85
        return LinearGradient(
            colors: [theme.cardBackground.opacity(topOpacity), theme.cardBackground.opacity(bottomOpacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var iconName: String {
        hasDestructiveButton ? "exclamationmark.triangle.fill" : "questionmark.circle.fill"
    }

    private var iconBackgroundColor: Color {
        hasDestructiveButton ? theme.warningColor : theme.accentColor
    }

    private var cancelButton: AlertButtonConfig? {
        buttons.first { $0.role == .cancel }
    }

    private var primaryButtonIndex: Int {
        buttons.firstIndex { $0.role == nil }
            ?? buttons.firstIndex { $0.role == .destructive }
            ?? 0
    }

    private var hasDestructiveButton: Bool {
        buttons.contains { $0.role == .destructive }
    }

    private func buttonTextColor(isPrimary: Bool) -> Color {
        isPrimary ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText
    }

    private func buttonBackground(isPrimary: Bool, isDestructive: Bool, isHovered: Bool) -> some ShapeStyle {
        let hoverOpacity = isHovered ? 0.9 : 1.0
        if isPrimary {
            let color = isDestructive ? theme.errorColor : theme.accentColor
            return AnyShapeStyle(color.opacity(hoverOpacity))
        }
        return AnyShapeStyle(theme.tertiaryBackground.opacity(isHovered ? 0.8 : 0.5))
    }

    private func buttonBorderColor(isPrimary: Bool, isHovered: Bool) -> Color {
        isPrimary ? .clear : (isHovered ? theme.primaryBorder : theme.cardBorder)
    }

    // MARK: - Dismiss Animation

    private func dismissWithAnimation(completion: @escaping () -> Void) {
        withAnimation(theme.springAnimation(responseMultiplier: 0.8)) {
            isAppearing = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + theme.animationDurationMedium) {
            completion()
            onDismiss()
        }
    }
}

// MARK: - View Modifier

/// View modifier for presenting themed alert dialogs
private struct ThemedAlertModifier: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let message: String?
    let accessory: AnyView?
    let buttons: [AlertButtonConfig]
    let presentationStyle: ThemedAlertPresentationStyle

    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                if isPresented {
                    ThemedAlertDialogContent(
                        title: title,
                        message: message,
                        accessory: accessory,
                        buttons: buttons,
                        showsCloseButton: false,
                        customContent: nil,
                        width: nil,
                        presentationStyle: presentationStyle,
                        onDismiss: {
                            isPresented = false
                        }
                    )
                }
            }
        )
    }
}

/// Presenter that routes alerts to a global host layer (per-window center).
private struct ThemedAlertPresenterModifier: ViewModifier {
    @Environment(\.themedAlertScope) private var scope

    let title: String
    @Binding var isPresented: Bool
    let message: String?
    let accessory: AnyView?
    let buttons: [AlertButtonConfig]

    @State private var requestId = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    Task { @MainActor in
                        ThemedAlertCenter.shared.present(
                            ThemedAlertRequest(
                                id: requestId,
                                title: title,
                                message: message,
                                accessory: accessory,
                                buttons: buttons,
                                onDismiss: { isPresented = false }
                            ),
                            scope: scope
                        )
                    }
                } else {
                    Task { @MainActor in
                        ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                    }
                }
            }
            .onAppear {
                if isPresented {
                    Task { @MainActor in
                        ThemedAlertCenter.shared.present(
                            ThemedAlertRequest(
                                id: requestId,
                                title: title,
                                message: message,
                                accessory: accessory,
                                buttons: buttons,
                                onDismiss: { isPresented = false }
                            ),
                            scope: scope
                        )
                    }
                }
            }
            .onDisappear {
                Task { @MainActor in
                    ThemedAlertCenter.shared.dismiss(scope: scope, id: requestId)
                }
            }
    }
}

/// Host view that renders the active alert as a global overlay.
@MainActor
public struct ThemedAlertHost: View {
    @ObservedObject private var center = ThemedAlertCenter.shared
    let scope: ThemedAlertScope

    public init(scope: ThemedAlertScope) {
        self.scope = scope
    }

    public var body: some View {
        ZStack {
            if let request = center.active(for: scope) {
                ThemedAlertDialogContent(
                    title: request.title,
                    message: request.message,
                    accessory: request.accessory,
                    buttons: request.buttons,
                    showsCloseButton: request.showsCloseButton,
                    customContent: request.customContent,
                    width: request.width,
                    presentationStyle: .window,
                    onDismiss: { request.onDismiss() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(center.active(for: scope) != nil)
        .animation(
            .spring(response: 0.35, dampingFraction: 0.85),
            value: center.active(for: scope)?.id
        )
    }
}

// MARK: - View Extension

extension View {
    /// Present a themed alert dialog with glass effects and spring animations.
    /// Supports 1–3 (or more) buttons; when 3+, buttons stack vertically for better ergonomics.
    @ViewBuilder
    func themedAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        accessory: AnyView? = nil,
        buttons: [AlertButtonConfig],
        presentationStyle: ThemedAlertPresentationStyle = .window
    ) -> some View {
        if presentationStyle == .contained {
            self.modifier(
                ThemedAlertModifier(
                    title: title,
                    isPresented: isPresented,
                    message: message,
                    accessory: accessory,
                    buttons: buttons,
                    presentationStyle: .contained
                )
            )
        } else {
            // Global host presentation (attach `ThemedAlertHost()` at a root view).
            self.modifier(
                ThemedAlertPresenterModifier(
                    title: title,
                    isPresented: isPresented,
                    message: message,
                    accessory: accessory,
                    buttons: buttons
                )
            )
        }
    }

    /// Present a themed alert dialog with glass effects and spring animations
    /// - Parameters:
    ///   - title: The title of the alert
    ///   - isPresented: Binding to control presentation
    ///   - message: Optional message text
    ///   - primaryButton: The primary action button configuration
    ///   - secondaryButton: Optional secondary button (typically cancel)
    func themedAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        primaryButton: AlertButtonConfig,
        secondaryButton: AlertButtonConfig? = nil,
        presentationStyle: ThemedAlertPresentationStyle = .window
    ) -> some View {
        if let secondaryButton {
            // Standard ordering: cancel/secondary on the left, primary on the right.
            return themedAlert(
                title,
                isPresented: isPresented,
                message: message,
                buttons: [secondaryButton, primaryButton],
                presentationStyle: presentationStyle
            )
        } else {
            return themedAlert(
                title,
                isPresented: isPresented,
                message: message,
                buttons: [primaryButton],
                presentationStyle: presentationStyle
            )
        }
    }
}

// MARK: - Local conditional modifier helper

private extension View {
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct ThemedAlertDialog_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                Color.gray.opacity(0.3)
                    .ignoresSafeArea()

                ThemedAlertDialogContent(
                    title: L("Cancel Background Task?"),
                    message: L("The work task is still running. Dismissing will cancel the task."),
                    accessory: nil,
                    buttons: [
                        .destructive(L("Cancel Task")) {},
                        .cancel(L("Keep Running")),
                    ],
                    showsCloseButton: false,
                    customContent: nil,
                    width: nil,
                    presentationStyle: .window,
                    onDismiss: {}
                )
            }
            .frame(width: 500, height: 400)
        }
    }
#endif

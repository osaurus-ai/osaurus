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
    /// Button configurations for the alert actions
    public let buttons: [AlertButtonConfig]

    /// Callback invoked when the alert is dismissed
    public let onDismiss: () -> Void

    public init(
        id: UUID = UUID(),
        title: String,
        message: String?,
        buttons: [AlertButtonConfig],
        onDismiss: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.buttons = buttons
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
    let buttons: [AlertButtonConfig]
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

            // Message
            if let message = message {
                messageSection(message)
            }

            // Divider
            Rectangle()
                .fill(theme.primaryBorder.opacity(0.3))
                .frame(height: 1)
                .padding(.top, 16)

            // Buttons
            buttonSection
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(width: 340)
        .background(dialogBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(dialogBorder)
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity * 2),
            radius: 24,
            x: 0,
            y: 12
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
            Text(title)
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
        Group {
            if buttons.count <= 2 {
                HStack(spacing: 12) {
                    ForEach(Array(buttons.enumerated()), id: \.element.title) { idx, button in
                        alertButton(button, isPrimary: idx == primaryButtonIndex)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(buttons.enumerated()), id: \.element.title) { idx, button in
                        alertButton(button, isPrimary: idx == primaryButtonIndex)
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    private func alertButton(_ config: AlertButtonConfig, isPrimary: Bool) -> some View {
        let isHovered = hoveredButton == config.title
        let isDestructive = config.role == .destructive

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

    private var dialogBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [theme.glassEdgeLight, theme.glassEdgeLight.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
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
    let buttons: [AlertButtonConfig]
    let presentationStyle: ThemedAlertPresentationStyle

    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                if isPresented {
                    ThemedAlertDialogContent(
                        title: title,
                        message: message,
                        buttons: buttons,
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
                    buttons: request.buttons,
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
        buttons: [AlertButtonConfig],
        presentationStyle: ThemedAlertPresentationStyle = .window
    ) -> some View {
        if presentationStyle == .contained {
            self.modifier(
                ThemedAlertModifier(
                    title: title,
                    isPresented: isPresented,
                    message: message,
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
                    title: "Cancel Background Task?",
                    message: "The agent task is still running. Dismissing will cancel the task.",
                    buttons: [
                        .destructive("Cancel Task") {},
                        .cancel("Keep Running"),
                    ],
                    presentationStyle: .window,
                    onDismiss: {}
                )
            }
            .frame(width: 500, height: 400)
        }
    }
#endif

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

    /// Per-scope stack, bottom first. Normally one entry: a scope holds a
    /// single alert and a new one replaces it. A request flagged
    /// `hostsNestedAlerts` (the chat History dialog) is the exception —
    /// alerts presented while it is on top push above it and pop back to
    /// it, so its content raising a confirmation doesn't tear it down.
    @Published private var stacksByScope: [ThemedAlertScope: [ThemedAlertRequest]] = [:]

    func present(_ request: ThemedAlertRequest, scope: ThemedAlertScope) {
        if scope == .toastOverlay {
            // The overlay host panel is created lazily; make sure it exists.
            ToastWindowController.shared.showOverlayIfNeeded()
        }
        var stack = stacksByScope[scope] ?? []
        if let index = stack.firstIndex(where: { $0.id == request.id }) {
            // Re-presenting an id (e.g. a progress alert updating its
            // content) swaps it in place without touching its presenter.
            stack[index] = request
        } else if let top = stack.last, top.hostsNestedAlerts {
            stack.append(request)
        } else if let top = stack.last {
            // Single-slot rule: a new alert replaces the one on top. Reset
            // the clobbered presenter (e.g. an async sandbox-cleanup notice
            // landing while a delete-confirmation is open) so its
            // `isPresented` binding doesn't wedge at `true`. Without this,
            // the source view's `@State` stays set and its `onChange`-driven
            // re-present never fires again, so that control can never
            // raise its alert a second time.
            top.onDismiss()
            stack[stack.count - 1] = request
        } else {
            stack = [request]
        }
        stacksByScope[scope] = stack
    }

    /// Present a Cancel / destructive confirmation in `scope`. The common
    /// shape of every "Delete / Remove / Unshare / Leave?" dialog; keeps
    /// call sites to one line and guarantees the dismiss bookkeeping.
    func confirmDestructive(
        scope: ThemedAlertScope,
        title: String,
        message: String?,
        destructiveTitle: String,
        cancelTitle: String = L("Cancel"),
        onConfirm: @escaping () -> Void
    ) {
        let requestId = UUID()
        present(
            ThemedAlertRequest(
                id: requestId,
                title: title,
                message: message,
                buttons: [
                    .cancel(cancelTitle),
                    .destructive(destructiveTitle) { onConfirm() },
                ],
                onDismiss: { [weak self] in
                    self?.dismiss(scope: scope, id: requestId)
                }
            ),
            scope: scope
        )
    }

    func dismiss(scope: ThemedAlertScope, id: UUID) {
        guard var stack = stacksByScope[scope],
            let index = stack.firstIndex(where: { $0.id == id })
        else { return }
        stack.remove(at: index)
        stacksByScope[scope] = stack.isEmpty ? nil : stack
    }

    /// The topmost (interactive) alert for `scope`.
    func active(for scope: ThemedAlertScope) -> ThemedAlertRequest? {
        stacksByScope[scope]?.last
    }

    /// Every alert showing in `scope`, bottom first. Only the last entry
    /// is interactive; the host renders the rest underneath it.
    func stack(for scope: ThemedAlertScope) -> [ThemedAlertRequest] {
        stacksByScope[scope] ?? []
    }

    /// True when ANY scope currently owns an alert. Read-only occupancy
    /// signal for callers that must not stack a new dialog on top of an
    /// existing one anywhere in the app (e.g. router announcement dialogs
    /// defer to the next activation instead).
    public var hasAnyActiveAlert: Bool {
        stacksByScope.values.contains { !$0.isEmpty }
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
        guard let request = active(for: scope) else { return false }
        if let cancel = request.buttons.first(where: { $0.role == .cancel }) {
            cancel.action()
            request.onDismiss()
            dismiss(scope: scope, id: request.id)
        }
        return true
    }
}

/// Defines the scope/context for themed alerts to prevent overlapping dialogs.
/// Each scope can have at most one active alert at a time.
public enum ThemedAlertScope: Hashable, Sendable {
    /// Alert scoped to a specific chat window
    case chat(UUID)
    /// Alert scoped to the main content area
    case content
    /// Alert scoped to toast overlay panels
    case toastOverlay
    /// Alert scoped to a specific tool permission dialog
    case toolPermission(UUID)
    /// Alert scoped to one presented sheet (see `themedAlertSheetHost()`)
    case sheet(UUID)
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
    /// Optional asset-catalog images (module bundle) rendered side by side
    /// above the title in place of the standard SF Symbol circle. Use for
    /// announcement-style dialogs that ship their own bundled artwork. Empty
    /// keeps the existing icon header for every other alert.
    public let headerImageNames: [String]
    /// Accessibility description for the header artwork as a whole. Ignored
    /// when no header images are set.
    public let headerImageAccessibilityLabel: String?
    /// False hides the default symbol header (the "?" / "!" badge) when no
    /// header artwork is set — for content dialogs (e.g. chat history)
    /// where a question-mark badge over a list reads as noise.
    public let showsHeaderIcon: Bool
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
    /// True for container dialogs (e.g. chat History) whose content raises
    /// alerts of its own — a delete confirmation, an export chooser, a
    /// progress notice. While such a request is on top of its scope, a
    /// newly presented alert STACKS above it instead of replacing it, and
    /// the container comes back (state intact) once the nested alert is
    /// dismissed. Off by default: plain alerts keep the single-slot
    /// replacement contract that `ThemedAlertCenter.present` documents.
    public let hostsNestedAlerts: Bool

    /// Callback invoked when the alert is dismissed
    public let onDismiss: () -> Void
    /// Inspector presentation metadata; never persisted or used by execution.
    var inspectionFamily: Int? = nil

    public init(
        id: UUID = UUID(),
        title: String,
        message: String?,
        headerImageNames: [String] = [],
        headerImageAccessibilityLabel: String? = nil,
        showsHeaderIcon: Bool = true,
        accessory: AnyView? = nil,
        buttons: [AlertButtonConfig],
        showsCloseButton: Bool = false,
        customContent: AnyView? = nil,
        width: CGFloat? = nil,
        hostsNestedAlerts: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.headerImageNames = headerImageNames
        self.headerImageAccessibilityLabel = headerImageAccessibilityLabel
        self.showsHeaderIcon = showsHeaderIcon
        self.accessory = accessory
        self.buttons = buttons
        self.showsCloseButton = showsCloseButton
        self.customContent = customContent
        self.width = width
        self.hostsNestedAlerts = hostsNestedAlerts
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
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(inspectionFamily ?? 17, enabled: baseComponentEnabled) }
    private func inspectionMetric(_ property: String, _ fallback: CGFloat) -> CGFloat {
        guard let inspectionFamily else { return fallback }
        return theme.assignedMetric("component.library.\(inspectionFamily)." + property, fallback: fallback)
    }

    let title: String
    let message: String?
    var headerImageNames: [String] = []
    var headerImageAccessibilityLabel: String? = nil
    var showsHeaderIcon: Bool = true
    let accessory: AnyView?
    let buttons: [AlertButtonConfig]
    let showsCloseButton: Bool
    let customContent: AnyView?
    let width: CGFloat?
    let presentationStyle: ThemedAlertPresentationStyle
    var inspectionFamily: Int? = nil
    let onDismiss: () -> Void

    @State private var isAppearing = false

    var body: some View {
        ZStack {
            // Dimmed overlay
            // `color.scrim` carries its own alpha; only fade it in.
            theme.scrim
                .opacity(isAppearing ? 1 : 0)
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
                            .padding(.horizontal, theme.space.s10)
                            // With no artwork above the title, the X
                            // shares the title row: centre it on the
                            // heading line below the 24pt top inset.
                            .padding(.top, titleLeadsHeader ? theme.space.s24 : theme.space.s8)
                    }
                }
                .scaleEffect(isAppearing ? 1 : 0.9)
                .opacity(isAppearing ? 1 : 0)
                .offset(y: isAppearing ? 0 : 20)
        }
        .onAppear {
            withAnimation(theme.motion.springAnimation) {
                isAppearing = true
            }
        }
    }

    private func dialogLayout(_ boundary: String, inheriting value: CGFloat) -> CGFloat {
        theme.catalogLayoutMetric("component.library.\(inspectionFamily ?? 17).elements.layout.dialog." + boundary, inheriting: value)
    }
    private func dialogLayoutKey(_ boundary: String) -> String {
        "component.library.\(inspectionFamily ?? 17).elements.layout.dialog." + boundary
    }

    // MARK: - Dialog Content

    private var dialogContent: some View {
        VStack(spacing: theme.space.s0) {
            // Header with icon
            headerSection

            if let customContent {
                customContent
                    .padding(.top, dialogLayout("contentGap", inheriting: inspectionMetric("gap", 16))).catalogLayoutTarget(dialogLayoutKey("contentGap"))
            } else {
                // Message
                if let message = message {
                    messageSection(message)
                }

                // Optional accessory (e.g. "Don't ask again" toggle)
                if let accessory = accessory {
                    accessory
                        .padding(.top, theme.space.s12)
                }

                if !inlineButtons.isEmpty {
                    // Divider
                    ThemeHairlineDivider()
                        .padding(.top, theme.space.s16)

                    // Buttons
                    buttonSection
                }
            }
        }
        .padding(.top, dialogLayout("paddingTop", inheriting: inspectionMetric("padding", 24))).catalogLayoutTarget(dialogLayoutKey("paddingTop"))
        .padding(.horizontal, dialogLayout("paddingX", inheriting: inspectionMetric("padding", 24))).catalogLayoutTarget(dialogLayoutKey("paddingX"))
        .padding(.bottom, dialogLayout("paddingBottom", inheriting: inspectionMetric("padding", 16))).catalogLayoutTarget(dialogLayoutKey("paddingBottom"))
        .frame(width: width ?? 340)
        .frame(minHeight: inspectionMetric("height", 0))
        .applyIf(inspectionFamily != nil) { $0.environment(\.theme, theme) }
        .assignedBaseChrome(inspectionFamily ?? 17, fallback: .overlay)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: theme.space.s12) {
            if !headerImageNames.isEmpty {
                // Custom artwork header (announcement-style dialogs). Kept
                // small and static — no pulsing ring — so it reads as a
                // friendly mark, not an attention grab.
                HStack(alignment: .bottom, spacing: theme.space.s12) {
                    ForEach(headerImageNames, id: \.self) { name in
                        Image(name, bundle: .module)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 84)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headerImageAccessibilityLabel ?? "")
                .accessibilityHidden(headerImageAccessibilityLabel == nil)
            } else if showsHeaderIcon {
                iconHeader
            }

            // Title
            Text(LocalizedStringKey(title), bundle: .module)
                .textStyle(.heading)
                .foregroundColor(theme.text.primary)
                .multilineTextAlignment(.center)
        }
    }

    /// True when the header is just the title (no images, no icon).
    private var titleLeadsHeader: Bool {
        headerImageNames.isEmpty && !showsHeaderIcon
    }

    private var iconHeader: some View {
        ZStack {
            Circle()
                .fill(iconStatus.background)
                .frame(width: 48, height: 48)

            Circle()
                .stroke(iconStatus.border, lineWidth: theme.stroke.default)
                .frame(width: 48, height: 48)

            Image(systemName: iconName)
                .glyphSize(.xlarge, weight: .semibold)
                .foregroundColor(iconStatus.foreground)
        }
    }

    // MARK: - Message Section

    private func messageSection(_ message: String) -> some View {
        Text(message)
            .textStyle(.bodySmall)
            .foregroundColor(theme.text.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .padding(.top, theme.space.s8)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Button Section

    private var buttonSection: some View {
        let inline = inlineButtons
        return Group {
            if inline.count <= 2 {
                HStack(spacing: theme.space.s12) {
                    ForEach(Array(inline.enumerated()), id: \.element.title) { idx, button in
                        alertButton(button, isPrimary: idx == inlinePrimaryIndex)
                    }
                }
            } else {
                VStack(spacing: theme.space.s10) {
                    ForEach(Array(inline.enumerated()), id: \.element.title) { idx, button in
                        alertButton(button, isPrimary: idx == inlinePrimaryIndex)
                    }
                }
            }
        }
        .padding(.top, theme.space.s16)
    }

    /// Buttons rendered inline. When the close icon is shown, the cancel
    /// button is promoted to the corner and removed from the row.
    private var inlineButtons: [AlertButtonConfig] {
        guard showsCloseButton else { return buttons }
        return buttons.filter { $0.role != .cancel }
    }

    /// Index of the inline button that takes the accent style and Return.
    /// With the corner X shown, an explicit role-nil action (e.g. an
    /// announcement's single call-to-action) still reads as primary; only
    /// the "nothing but cancel" chooser case yields no primary (`-1`).
    private var inlinePrimaryIndex: Int {
        if let explicit = inlineButtons.firstIndex(where: { $0.role == nil }) {
            return explicit
        }
        if showsCloseButton { return -1 }
        return inlineButtons.firstIndex { $0.role == .destructive } ?? 0
    }

    private func closeButton(_ cancel: AlertButtonConfig) -> some View {
        SettingsIconButton("xmark", help: cancel.title, size: .compact) {
            dismissWithAnimation { cancel.action() }
        }
        // Cancel was promoted to the corner X, so it carries the Esc
        // shortcut here instead of in the inline row.
        .keyboardShortcut(.cancelAction)
    }

    private func alertButton(_ config: AlertButtonConfig, isPrimary: Bool) -> some View {
        let isDestructive = config.role == .destructive
        // Return activates the primary action; Esc activates cancel.
        // `keyboardShortcut(nil)` is a no-op for the remaining buttons.
        let shortcut: KeyboardShortcut? =
            isPrimary
            ? .defaultAction
            : (config.role == .cancel ? .cancelAction : nil)

        let role: SettingsButtonRole = isPrimary ? (isDestructive ? .destructive : .primary) : .secondary
        return Button {
            dismissWithAnimation { config.action() }
        } label: {
            Text(config.title)
                .frame(maxWidth: .infinity)
        }
        .assignedSettingsButtonStyle(role)
        .keyboardShortcut(shortcut)
    }

    // MARK: - Styling Helpers

    private var iconName: String {
        hasDestructiveButton ? "exclamationmark.triangle.fill" : "questionmark.circle.fill"
    }

    private var iconStatus: ThemeStatusSet<Color> {
        hasDestructiveButton ? theme.status.warning : theme.status.info
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

    // MARK: - Dismiss Animation

    private func dismissWithAnimation(completion: @escaping () -> Void) {
        withAnimation(theme.motion.springAnimation(responseMultiplier: 0.8)) {
            isAppearing = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + theme.motion.durationStandard) {
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
    let width: CGFloat?
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
                        width: width,
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
    @Environment(\.theme) private var theme
    @ObservedObject private var center = ThemedAlertCenter.shared
    let scope: ThemedAlertScope

    public init(scope: ThemedAlertScope) {
        self.scope = scope
    }

    public var body: some View {
        let stack = center.stack(for: scope)
        let topId = stack.last?.id
        ZStack {
            // Bottom first, so a nested alert (delete confirmation, export
            // chooser) draws over the container dialog that raised it —
            // each card brings its own dim, which reads as the container
            // receding behind the modal. Only the top card takes clicks.
            ForEach(stack) { request in
                ThemedAlertDialogContent(
                    title: request.title,
                    message: request.message,
                    headerImageNames: request.headerImageNames,
                    headerImageAccessibilityLabel: request.headerImageAccessibilityLabel,
                    showsHeaderIcon: request.showsHeaderIcon,
                    accessory: request.accessory,
                    buttons: request.buttons,
                    showsCloseButton: request.showsCloseButton,
                    customContent: request.customContent,
                    width: request.width,
                    presentationStyle: .window,
                    inspectionFamily: request.inspectionFamily,
                    onDismiss: { request.onDismiss() }
                )
                // Identity-key by request so a replacement alert gets a
                // FRESH view. Without this, a request presented into the
                // scope right after a button dismissal reuses the old
                // view whose `isAppearing` state already animated to
                // false — the new card renders fully transparent
                // (observed live: the PII-model download progress alert
                // was invisible after Install replaced the ask alert).
                .id(request.id)
                // The host is attached as an `.overlay` AFTER the root's
                // `.themedAlertScope(...)`, so nothing inside the card
                // inherits that scope. Custom content that reads
                // `@Environment(\.themedAlertScope)` (e.g. the History
                // dialog's session rows) would otherwise present its own
                // alerts into `.unspecified`, which no host renders — the
                // row's Delete confirmation and Export chooser silently
                // went nowhere. Stamp the host's scope so nested alerts
                // land in this window.
                .themedAlertScope(scope)
                .allowsHitTesting(request.id == topId)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(topId != nil)
        .animation(
            theme.motion.springAnimation,
            value: topId
        )
    }
}

/// Gives a sheet its own alert layer. A sheet inherits the window's scope,
/// whose host draws on the window behind the sheet, so its alerts would be
/// hidden.
private struct ThemedAlertSheetHostModifier: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .themedAlertScope(.sheet(id))
            .overlay(ThemedAlertHost(scope: .sheet(id)))
    }
}

// MARK: - View Extension

extension View {
    /// Attach at the root of a sheet so `.window` alerts raised inside it
    /// show over the sheet.
    func themedAlertSheetHost() -> some View {
        modifier(ThemedAlertSheetHostModifier())
    }

    /// Present a themed alert dialog with glass effects and spring animations.
    /// Supports 1–3 (or more) buttons; when 3+, buttons stack vertically for better ergonomics.
    /// `width` overrides the standard 340pt dialog width (honoured by the
    /// `.contained` style only) — use when button labels would otherwise wrap.
    @ViewBuilder
    func themedAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        accessory: AnyView? = nil,
        buttons: [AlertButtonConfig],
        width: CGFloat? = nil,
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
                    width: width,
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
                CustomizableTheme.dark().text.tertiary
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

//
//  SettingsSheet.swift
//  osaurus
//
//  The one sheet frame for Settings: `SettingsSheetHeader` (icon, title,
//  subtitle, close) on top, `SettingsSheetFooter` (hint or warning, Cancel,
//  commit) on the bottom, and `SettingsSheet` composing both around a
//  scrolling body. Bodies compose from the settings kit.
//

import SwiftUI

private struct InspectorSheetPreviewThemeKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var inspectorSheetPreviewTheme: Bool {
        get { self[InspectorSheetPreviewThemeKey.self] }
        set { self[InspectorSheetPreviewThemeKey.self] = newValue }
    }
}

// MARK: - Sheet Header

/// Icon tile, card title, secondary subtitle, compact close button. Always
/// followed by a faint divider so the body has a clean baseline.
struct SettingsSheetHeader: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(17, enabled: baseComponentEnabled) }

    let icon: String?
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    /// Verbatim (already-localized or user-provided) subtitle, for dynamic
    /// text like a workspace name that must not go through the catalog.
    var subtitleText: String?
    /// Clamps a long subtitle; the verbatim one shows in full on hover.
    var subtitleLineLimit: Int?
    /// A compact control beside the close button ("Change Source").
    var accessory: AnyView?
    /// Replaces the icon tile with a 28pt mark, such as a provider logo.
    var leading: AnyView?
    let onClose: () -> Void

    init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        onClose: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.subtitleText = nil
        self.onClose = onClose
    }

    init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitleText: String?,
        onClose: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = nil
        self.subtitleText = subtitleText
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetHeader.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s12))) {
                if let leading {
                    leading.frame(width: 28, height: 28)
                } else if let icon {
                    SettingsIconTile(icon: icon, size: 28)
                        .environment(\.theme, theme)
                }

                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetHeader.body.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.settingsTitleToDescription))) {
                    Text(title, bundle: .module)
                        .assignedTypography("component.library.17.heading", fallback: SettingsFont.cardTitle)
                        .foregroundColor(theme.text.primary)
                    if let subtitle {
                        Text(subtitle, bundle: .module)
                            .assignedTypography("component.library.17.caption", fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(subtitleLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let subtitleText, !subtitleText.isEmpty {
                        Text(verbatim: subtitleText)
                            .assignedTypography("component.library.17.caption", fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(subtitleLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(subtitleLineLimit == nil ? "" : subtitleText)
                    }
                }.catalogLayoutTarget("component.library.17.elements.layout.settingsSheetHeader.body.verticalGap")

                Spacer(minLength: theme.space.s8)

                if let accessory { accessory }

                SettingsIconButton("xmark", help: "Close", size: .compact, action: onClose)
                    .keyboardShortcut(.escape, modifiers: [])
            }.catalogLayoutTarget("component.library.17.elements.layout.settingsSheetHeader.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetHeader.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.settingsSheetInset))).catalogLayoutTarget("component.library.17.elements.layout.settingsSheetHeader.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetHeader.body.paddingY", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.17.elements.layout.settingsSheetHeader.body.paddingY")
            .background(theme.surface.subtle)

            ThemeHairlineDivider(color: theme.border.default)
        }
    }
}

// MARK: - Sheet Footer

/// Sheet footer with a primary CTA, optional secondary, optional hint.
/// Renders the divider on top, a `⌘+Enter`-style hint on the leading edge,
/// and a Cancel/Confirm pair on the trailing edge using the shared button
/// styles. When `primary` is `nil`, only the hint + secondary render — useful
/// for sheets like Share that have no commit action.
struct SettingsSheetFooter: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(17, enabled: baseComponentEnabled) }

    struct Action {
        let label: LocalizedStringKey
        let isEnabled: Bool
        let isLoading: Bool
        /// Render the primary slot with the destructive button role (tinted, not
        /// filled) for commit actions that remove or revert user data.
        let isDestructive: Bool
        let handler: () -> Void

        init(
            label: LocalizedStringKey,
            isEnabled: Bool = true,
            isLoading: Bool = false,
            isDestructive: Bool = false,
            handler: @escaping () -> Void
        ) {
            self.label = label
            self.isEnabled = isEnabled
            self.isLoading = isLoading
            self.isDestructive = isDestructive
            self.handler = handler
        }
    }

    let primary: Action?
    let secondary: Action?
    /// Leading-edge destructive action ("Restore Anyway", "Delete"), kept
    /// apart from the commit pair so it can't be hit by reflex.
    var destructive: Action? = nil
    let hint: LocalizedStringKey?
    /// Verbatim (already localized) warning shown in the hint slot instead
    /// of the shortcut hint, for "you still need to…" guidance that must
    /// stay next to the button that triggered it.
    var warning: String? = nil
    /// Inside a themed alert's card, which supplies the inset and surface;
    /// Return commits, as in every alert.
    var embedded = false

    init(
        primary: Action? = nil,
        secondary: Action? = nil,
        destructive: Action? = nil,
        hint: LocalizedStringKey? = nil,
        warning: String? = nil,
        embedded: Bool = false
    ) {
        self.primary = primary
        self.secondary = secondary
        self.destructive = destructive
        self.hint = hint
        self.warning = warning
        self.embedded = embedded
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            ThemeHairlineDivider(color: theme.border.default)

            HStack(spacing: theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s8))) {
                if let destructive {
                    Button(action: destructive.handler) {
                        Text(destructive.label, bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.destructive, isLoading: destructive.isLoading)
                    .disabled(!destructive.isEnabled || destructive.isLoading)
                }

                if let warning {
                    HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap2", inheriting: theme.catalogMetric("gap", fallback: theme.space.s6))) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(SettingsFont.glyphSmall)
                            .padding(.top, theme.space.s2)
                        Text(verbatim: warning)
                            .assignedTypography("component.library.17.caption", fallback: SettingsFont.smallLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }.catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap2")
                    .foregroundColor(theme.status.warning.foreground)
                    .frame(maxWidth: 420, alignment: .leading)
                    .transition(.opacity)
                } else if let hint {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap3", inheriting: theme.catalogMetric("gap", fallback: theme.space.s4))) {
                        Text("\u{2318}", bundle: .module)
                            .assignedTypography("component.library.17.caption", fallback: SettingsFont.chip)
                            .padding(.horizontal, theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s4))).catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.paddingX")
                            .padding(.vertical, theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.paddingY", inheriting: theme.catalogMetric("padding", fallback: theme.space.s2))).catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.paddingY")
                            .assignedBaseChrome(17, fallback: .inset)
                        Text(hint, bundle: .module)
                            .assignedTypography("component.library.17.caption", fallback: SettingsFont.rowDescription)
                    }.catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap3")
                    .foregroundColor(theme.text.tertiary)
                }

                Spacer()

                if let secondary {
                    Button(action: secondary.handler) {
                        Text(secondary.label, bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.secondary)
                    .disabled(!secondary.isEnabled || secondary.isLoading)
                    .keyboardShortcut(.cancelAction)
                }

                if let primary {
                    let button = Button(action: primary.handler) {
                        HStack(spacing: theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap4", inheriting: theme.catalogMetric("gap", fallback: theme.space.s6))) {
                            if primary.isLoading {
                                SettingsSpinner(tint: primary.isDestructive
                                            ? theme.action.destructive.default.foreground
                                            : theme.action.primary.default.foreground)
                            }
                            Text(primary.label, bundle: .module)
                        }.catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap4")
                    }
                    .disabled(!primary.isEnabled || primary.isLoading)
                    .keyboardShortcut(.return, modifiers: embedded ? [] : .command)
                    if primary.isDestructive {
                        button.assignedSettingsButtonStyle(.destructive)
                    } else {
                        button.assignedSettingsButtonStyle(.primary)
                    }
                }
            }.catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.horizontalGap")
            .padding(.horizontal, embedded ? theme.space.s0 : theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.paddingX2", inheriting: theme.catalogMetric("padding", fallback: theme.settingsSheetInset))).catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.paddingX2")
            .padding(.top, theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.paddingY2", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16))).catalogLayoutTarget("component.library.17.elements.layout.settingsSheetFooter.body.paddingY2")
            .padding(.bottom, embedded ? theme.space.s0 : theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheetFooter.body.paddingY2", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16)))
            .background(embedded ? Color.clear : theme.surface.subtle)
        }
        .background(InspectorAssignedSheetCommit(action: primary?.handler,
            isEnabled: baseComponentEnabled && primary?.isEnabled == true && primary?.isLoading == false))
    }
}


// MARK: - Sheet

/// Standard sheet widths. Pick by content, not by taste.
enum SettingsSheetWidth {
    /// One short form: a name, a key, a confirmation.
    static let compact: CGFloat = 420
    /// A form with sections, or a list to pick from.
    static let regular: CGFloat = 560
    /// Editors with a preview or two columns.
    static let wide: CGFloat = 720
}

/// Header, scrolling body, footer. Use this for any new sheet; it gives the
/// close button, Escape, Cancel and ⌘Return for free, and injects the current
/// theme because sheets are presented outside the page's environment.
struct SettingsSheet<Content: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(17, enabled: baseComponentEnabled) }
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.inspectorSheetPreviewTheme) private var usesPreviewTheme

    let icon: String?
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    var width: CGFloat
    var maxBodyHeight: CGFloat?
    let primary: SettingsSheetFooter.Action?
    let secondary: SettingsSheetFooter.Action?
    var hint: LocalizedStringKey?
    var warning: String?
    private var subtitleText: String?
    private var subtitleLineLimit: Int?
    let onClose: () -> Void
    @ViewBuilder let content: Content

    init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        width: CGFloat = SettingsSheetWidth.compact,
        maxBodyHeight: CGFloat? = nil,
        primary: SettingsSheetFooter.Action? = nil,
        secondary: SettingsSheetFooter.Action? = nil,
        hint: LocalizedStringKey? = nil,
        warning: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.maxBodyHeight = maxBodyHeight
        self.primary = primary
        self.secondary = secondary
        self.hint = hint
        self.warning = warning
        self.onClose = onClose
        self.content = content()
    }

    /// A verbatim subtitle (a workflow's summary), clamped to `lineLimit`
    /// lines with the whole of it on hover.
    func subtitle(verbatim text: String?, lineLimit: Int?) -> Self {
        var sheet = self
        sheet.subtitleText = text
        sheet.subtitleLineLimit = lineLimit
        return sheet
    }

    private var header: SettingsSheetHeader {
        var header =
            subtitle == nil && subtitleText != nil
            ? SettingsSheetHeader(icon: icon, title: title, subtitleText: subtitleText, onClose: onClose)
            : SettingsSheetHeader(icon: icon, title: title, subtitle: subtitle, onClose: onClose)
        header.subtitleLineLimit = subtitleLineLimit
        return header
    }

    @State private var presenter = SheetPresenter()
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// The body's cap: the one asked for, and never so tall that the sheet
    /// runs past the window presenting it (which cuts off its header and
    /// footer).
    private var fittedBodyHeight: CGFloat? {
        guard let sheet = presenter.maxSheetHeight else { return maxBodyHeight }
        let room = max(theme.space.s64 * 2, sheet - headerHeight - footerHeight)
        return min(maxBodyHeight ?? room, room)
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            ScrollView {
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheet.body.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.settingsSectionGap))) {
                    content
                }.catalogLayoutTarget("component.library.17.elements.layout.settingsSheet.body.verticalGap")
                .assignedTypography("component.library.17.text", fallback: SettingsFont.body)
                .foregroundColor(theme.text.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheet.body.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: theme.settingsSheetInset))).padding(.vertical, theme.catalogLayoutMetric("component.library.17.elements.layout.settingsSheet.body.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: theme.settingsSheetInset))).catalogLayoutTarget("component.library.17.elements.layout.settingsSheet.body.padding.horizontal").catalogLayoutTarget("component.library.17.elements.layout.settingsSheet.body.padding.vertical")
            }
            .frame(maxHeight: fittedBodyHeight)
            .fixedSize(horizontal: false, vertical: maxBodyHeight == nil)

            if primary != nil || secondary != nil {
                SettingsSheetFooter(primary: primary, secondary: secondary, hint: hint, warning: warning)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }
        .frame(width: width)
        .settingsSheetSurface()
        .environment(\.theme, usesPreviewTheme ? baseTheme : themeManager.currentTheme)
    }
}

extension View {
    /// The root surface of a sheet: `surface.overlay` clipped to
    /// `radius.xlarge`. The sheet window draws the overlay elevation.
    func settingsSheetSurface() -> some View {
        modifier(SettingsSheetSurfaceModifier())
    }
}

private struct SettingsSheetSurfaceModifier: ViewModifier {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(17, enabled: baseComponentEnabled) }

    func body(content: Content) -> some View {
        content
            .frame(minHeight: theme.catalogMetric("height", fallback: 0))
            .presentationCornerRadius(theme.radius.xlarge)
            .presentationBackground(.clear)
            .background(InspectorAssignedSheetSurface(radius: theme.radius.xlarge))
            .assignedBaseChrome(17, fallback: nil)
            .background(theme.surface.overlay)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
    }
}

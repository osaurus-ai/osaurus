//
//  OnboardingComponents.swift
//  osaurus
//
//  Reusable onboarding design-kit components built on `OnboardingPalette` /
//  `OnboardingTypography` / `OnboardingLayout` (see OnboardingDesign.swift):
//  pill buttons, glass circle buttons, glass panels, selectable cards,
//  chips, badge, checkbox row, the chapter indicator, and the shared dialog
//  scaffold. Colors follow the app theme.
//

import SwiftUI

// MARK: - Right panel

/// Rounded-16 right panel with a faint white fill and an optional vertical
/// gradient tint (screen 2 uses the green create tint fading out by ~75%).
struct OnboardingRightPanel<Content: View>: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }

    var gradientTint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {

        ZStack {
            OnboardingGlass(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.panelRadius, theme))

            if let tint = gradientTint {
                LinearGradient(
                    stops: [
                        .init(color: tint, location: 0),
                        .init(color: .clear, location: 0.75),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.panelRadius, theme),
                        style: .continuous
                    )
                )
            }

            content()
        }
    
        }.environment(\.theme, theme)
}
}

// MARK: - Pill buttons

/// Capsule button in the kit's three fills and two sizes.
struct OnboardingPillButton: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    enum Style {
        /// White `#f5f5f5` fill, near-black label — the screen's main CTA.
        case primary
        /// Faint white fill, light label — secondary actions ("Cancel").
        case secondary
        /// No fill — text-only actions ("Change model").
        case text
    }

    enum Size {
        /// 15pt semibold, 20×12 padding — footer CTAs.
        case large
        /// 13pt, 12×8 padding — in-card actions and dialog buttons.
        case compact
    }

    let title: LocalizedStringKey
    var style: Style = .primary
    var size: Size = .large
    /// Optional leading SF Symbol (e.g. Download's `arrow.down.circle`).
    var leadingSymbol: String? = nil
    /// Optional trailing SF Symbol (e.g. Get started's `arrow.right`).
    var trailingSymbol: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s6) {
                if let leadingSymbol { Image(systemName: leadingSymbol).glyphSize(points: symbolSize, weight: .semibold) }
                Text(title, bundle: .module).lineLimit(1)
                if let trailingSymbol { Image(systemName: trailingSymbol).glyphSize(points: symbolSize, weight: .semibold) }
            }
        }.assignedSettingsButtonStyle(style == .primary ? .primary : style == .secondary ? .secondary : .tertiary,
            size: size == .large ? .regular : .compact)
        .disabled(!isEnabled)
}

    private var labelFont: SettingsFont {
        size == .large ? OnboardingTypography.cta : OnboardingTypography.chip
    }

    private var symbolSize: CGFloat { size == .large ? 13 : 11 }

    private var labelColor: Color {
        switch style {
        case .primary: return theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.vibrantLabel)
        case .secondary, .text: return theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Capsule().fill(
                isHovered ? theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelWhite) : theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.vibrantFill)
            )
        case .secondary:
            Capsule().fill(isHovered ? theme.assignedColor("component.library.55.hover", fallback: OnboardingPalette.fill8) : theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
        case .text:
            Capsule().fill(isHovered ? theme.assignedColor("component.library.55.hover", fallback: OnboardingPalette.fill5) : Color.clear)
        }
    }
}

// MARK: - Glass circle button

/// 24pt circular Back/Close affordance floating over the window corners —
/// dark fill with a subtle light rim, per the Figma glass buttons.
struct OnboardingCircleIconButton: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    /// SF Symbol name (`xmark` / `arrow.left`).
    let systemName: String
    let action: () -> Void
    var accessibilityLabelKey: LocalizedStringKey = "Close"

    @State private var isHovered = false

    var body: some View {
        Group {

        Button(action: action) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(theme.assignedColor("component.library.55.background", fallback: isHovered ? OnboardingPalette.fill10 : OnboardingPalette.fill3))
                Circle().strokeBorder(
                    theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.glassRim(isHovered ? 0.5 : 0.3)),
                    lineWidth: theme.hairline
                )
                Image(systemName: systemName)
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
            }
            // The onboarding chrome's own height, not the catalog's control
            // height: Back, the chapter indicator, and Skip setup share one
            // row, and a taller Back shifted the row when it appeared.
            .frame(width: OnboardingLayout.glassButtonDiameter, height: OnboardingLayout.glassButtonDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(OnboardingPressableButtonStyle(pressedScale: 0.9))
        .accessibilityLabel(Text(accessibilityLabelKey, bundle: .module))
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
    
        }.environment(\.theme, theme)
}
}

/// "Skip setup" on the same glass as the circle buttons, at their height.
struct OnboardingGlassTextButton: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title, bundle: .module)
                .font(OnboardingTypography.chapter)
                .foregroundColor(OnboardingPalette.labelPrimary)
                .padding(.horizontal, theme.space.s12)
                .frame(height: OnboardingLayout.glassButtonDiameter)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(isHovered ? OnboardingPalette.fill10 : OnboardingPalette.fill3)
                        Capsule().strokeBorder(OnboardingPalette.glassRim(isHovered ? 0.5 : 0.3), lineWidth: theme.hairline)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(OnboardingPressableButtonStyle(pressedScale: 0.95))
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
    }
}

// MARK: - Switch row

/// An optional preference on glass: a title, a caption saying what it
/// means, and a trailing switch. A switch, not a checkbox, so it never
/// reads as a box to tick before continuing.
struct OnboardingSwitchRow: View {
    @Environment(\.theme) private var theme
    @Binding var isOn: Bool
    let title: LocalizedStringKey
    let caption: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(title, bundle: .module)
                    .font(OnboardingTypography.optionTitle)
                    .foregroundColor(OnboardingPalette.labelPrimary)
                Text(caption, bundle: .module)
                    .font(OnboardingTypography.cardCaption)
                    .foregroundColor(OnboardingPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(isOn: $isOn) { Text(title, bundle: .module) }
                .settingsSwitch()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Selectable card

/// Specialty card on screen 2: icon + 17pt regular title row, 12pt caption,
/// 8pt inner gap (Figma Config/Cards). The selected card gets a `dinoGreenText`
/// border, a bold accent icon, and a slightly stronger fill.
struct OnboardingSelectableCard: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    /// SF Symbol shown before the title.
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    let isSelected: Bool
    var accent: Color = OnboardingPalette.dinoGreenText
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {

        Button(action: action) {
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingSelectableCard.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", theme.space.s8, theme))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingSelectableCard.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", theme.space.s8, theme))) {
                    Image(systemName: symbol)
                        .glyphSize(.medium, weight: isSelected ? .bold : .regular)
                        .foregroundColor(
                            isSelected ? accent : theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary)
                        )
                        .symbolEffect(.bounce, value: isSelected)
                    Text(title, bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: OnboardingTypography.cardTitleRegular)
                        .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                }.catalogLayoutTarget("component.library.55.elements.layout.onboardingSelectableCard.body.horizontalGap")
                Text(caption, bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                    .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }.catalogLayoutTarget("component.library.55.elements.layout.onboardingSelectableCard.body.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingSelectableCard.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s16, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingSelectableCard.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingSelectableCard.body.padding.horizontal").catalogLayoutTarget("component.library.55.elements.layout.onboardingSelectableCard.body.padding.vertical")
            .background(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                    .strokeBorder(
                        isSelected ? accent : theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill8),
                        lineWidth: theme.stroke.default
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
            )
            // Selection pop: the chosen card springs slightly proud of its
            // neighbors (the caller drives this change with a bouncy spring).
            .scaleEffect(isSelected && !reduceMotion ? 1.015 : 1)
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
    
        }.environment(\.theme, theme)
}

    private var fillColor: Color {
        if isSelected { return theme.assignedColor("component.library.55.selected", fallback: OnboardingPalette.fill5) }
        return isHovered ? theme.assignedColor("component.library.55.hover", fallback: OnboardingPalette.fill3) : theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill2)
    }
}

// MARK: - Chips & badge

/// Cyan-on-blue-tint "Picked for your Mac" badge, or dino green on its own
/// wash for the recommended path (`isBrand`).
struct OnboardingPickedBadge: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    let text: LocalizedStringKey
    var isBrand = false

    var body: some View {
        Group {

        Text(text, bundle: .module)
            .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.badge)
            .foregroundColor(isBrand ? OnboardingPalette.dinoGreenText : theme.assignedColor("component.library.55.accent", fallback: OnboardingPalette.accentCyan))
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingPickedBadge.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingPickedBadge.body.paddingX")
            .padding(.vertical, theme.space.s2)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill((isBrand ? OnboardingPalette.dinoGreen : theme.assignedColor("component.library.55.accent", fallback: OnboardingPalette.accentBlue)).opacity(0.22))
            )
    
        }.environment(\.theme, theme)
}
}

/// White-10% capsule meta chip ("Download : 8.05 GB").
struct OnboardingMetaChip: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }

    /// Pre-localized text (composed with formatted sizes).
    let text: String

    var body: some View {
        Group {

        Text(text)
            .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
            .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingMetaChip.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingMetaChip.body.paddingX")
            .padding(.vertical, theme.space.s2)
            .background(Capsule().fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill10)))
    
        }.environment(\.theme, theme)
}
}

/// Provider chip: 16pt logo + 13pt label, radius-8 card fill.
struct OnboardingProviderChip<Logo: View>: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    @ViewBuilder let logo: () -> Logo
    /// Provider display name (proper noun — never localized).
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Group {

        Button(action: action) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingProviderChip.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", theme.space.s8, theme))) {
                logo()
                    .frame(width: 16, height: 16)
                Text(label)
                    .catalogTypography(.body, theme: theme, fallback: OnboardingTypography.chip)
                    .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
            }.catalogLayoutTarget("component.library.55.elements.layout.onboardingProviderChip.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingProviderChip.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingProviderChip.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingProviderChip.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingProviderChip.body.paddingY")
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(isHovered ? theme.assignedColor("component.library.55.hover", fallback: OnboardingPalette.fill8) : theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .strokeBorder(theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill10), lineWidth: theme.stroke.default)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
    
        }.environment(\.theme, theme)
}
}

// MARK: - Option row

/// Full-width connect-option row inside the provider drill-in: 13pt semibold
/// title + 12pt caption, with an optional green verified check trailing.
struct OnboardingOptionRow: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    var isVerified: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Group {

        Button(action: action) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingOptionRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", theme.space.s12, theme))) {
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingOptionRow.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", theme.space.s2, theme))) {
                    Text(title, bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: OnboardingTypography.optionTitle)
                        .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                    Text(caption, bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.cardCaption)
                        .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
                }.catalogLayoutTarget("component.library.55.elements.layout.onboardingOptionRow.body.verticalGap")
                Spacer(minLength: 0)
                if isVerified {
                    Image(systemName: "checkmark.circle")
                        .glyphSize(.body, weight: .semibold)
                        .foregroundColor(theme.assignedColor("component.library.55.accent", fallback: OnboardingPalette.dinoGreen))
                }
            }.catalogLayoutTarget("component.library.55.elements.layout.onboardingOptionRow.body.horizontalGap")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingOptionRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingOptionRow.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingOptionRow.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingOptionRow.body.paddingY")
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(isHovered ? theme.assignedColor("component.library.55.hover", fallback: OnboardingPalette.fill8) : theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
        }
        .buttonStyle(OnboardingPressableButtonStyle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovered = hovering }
        }
    
        }.environment(\.theme, theme)
}
}

// MARK: - Dialog scaffold

/// Centered dark dialog over a black scrim, used by the provider connect
/// dialog (and shaped after the Figma connect frames). Esc and the corner X
/// both call `onClose`; the scrim is deliberately not tappable while a
/// connection test is in flight (`isDismissable`).
struct OnboardingDialog<Content: View>: View {
    var width: CGFloat = 438
    var isDismissable: Bool = true
    /// Top and trailing inset of the close button, so it can line up with a
    /// leading title. Only `.top` and `.trailing` are read.
    var closeInsets: EdgeInsets? = nil
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }

    /// Spring-up entrance (scale + rise + fade); a plain fade under Reduce
    /// Motion.
    private var dialogTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .scale(scale: 0.96)
            .combined(with: .opacity)
            .combined(with: .offset(y: 8))
    }

    var body: some View {
        Group {

        ZStack {
            OnboardingPalette.scrim(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if isDismissable { onClose() }
                }

            content()
                .frame(width: width)
                .background(
                    RoundedRectangle(
                        cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.panelRadius, theme),
                        style: .continuous
                    )
                    .fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.dialogSurface))
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.panelRadius, theme),
                        style: .continuous
                    )
                    .strokeBorder(theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill8), lineWidth: theme.stroke.default)
                )
                .overlay(alignment: .topTrailing) {
                    if isDismissable {
                        OnboardingCircleIconButton(systemName: "xmark", action: onClose)
                            .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingDialog.body.padding.horizontal", inheriting: closeInsets?.trailing ?? NativeComponentInspectionStyle.metric(55, "padding", theme.space.s12, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingDialog.body.padding.vertical", inheriting: closeInsets?.top ?? NativeComponentInspectionStyle.metric(55, "padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingDialog.body.padding.horizontal").catalogLayoutTarget("component.library.55.elements.layout.onboardingDialog.body.padding.vertical")
                    }
                }
                .themeElevation(theme.elevation.overlay)
                // Springs up from slightly smaller and lower while the scrim
                // simply fades — the host drives this with a bouncy spring.
                .transition(dialogTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            if isDismissable { onClose() }
        }
    
        }.environment(\.theme, theme)
}
}

/// Square logo card (glyph over a small caption) used in the provider
/// drill-in and connect dialog headers.
struct OnboardingLogoCard<Logo: View>: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    @ViewBuilder let logo: () -> Logo
    /// Provider display name (proper noun — never localized).
    let caption: String
    var logoSize: CGFloat = 28

    var body: some View {
        Group {

        VStack(spacing: theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingLogoCard.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(55, "gap", theme.space.s8, theme))) {
            logo()
                .frame(width: logoSize, height: logoSize)
            Text(caption)
                .catalogTypography(.caption, theme: theme, fallback: OnboardingTypography.footnote)
                .foregroundColor(theme.assignedColor("component.library.55.secondary", fallback: OnboardingPalette.labelSecondary))
        }.catalogLayoutTarget("component.library.55.elements.layout.onboardingLogoCard.body.verticalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingLogoCard.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s20, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingLogoCard.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.55.elements.layout.onboardingLogoCard.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(55, "padding", theme.space.s14, theme))).catalogLayoutTarget("component.library.55.elements.layout.onboardingLogoCard.body.paddingY")
        .background(
            RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                .fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(55, "radius", OnboardingLayout.cardRadius, theme), style: .continuous)
                .strokeBorder(theme.assignedColor("component.library.55.border", fallback: OnboardingPalette.fill8), lineWidth: theme.stroke.default)
        )
    
        }.environment(\.theme, theme)
}
}

// MARK: - Progress bar

/// Slim cyan progress bar on a faint track (the downloading state's bar).
struct OnboardingProgressBar: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }
    /// 0...1
    let progress: Double

    var body: some View {
        Group {

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.assignedColor("component.library.55.background", fallback: OnboardingPalette.fill10))
                Capsule()
                    .fill(theme.assignedColor("component.library.55.accent", fallback: OnboardingPalette.accentCyan))
                    .frame(width: max(6, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(theme.motion.standard, value: progress)
    
        }.environment(\.theme, theme)
}
}

// MARK: - Glass

/// Frosted glass over the landscape: the system material (it follows the
/// window's light or dark appearance), a faint theme ink wash, and a thin
/// specular rim.
struct OnboardingGlass: View {
    @Environment(\.theme) private var theme
    var cornerRadius: CGFloat
    var material: Material = .regularMaterial

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(material)
            shape.fill(OnboardingPalette.fill2)
            shape.strokeBorder(OnboardingPalette.glassRim(theme.isDark ? 0.14 : 0.5), lineWidth: theme.hairline)
        }
        .themeElevation(theme.elevation.raised)
    }
}

// MARK: - Chapter indicator

/// The chapters of the first run. The onboarding window holds the first
/// two; the walkthrough in chat holds Team: picking a teammate and its
/// first task.
enum OnboardingChapter: Int, CaseIterable {
    case welcome, model, team

    var title: LocalizedStringKey {
        switch self {
        case .welcome: return "Welcome"
        case .model: return "Model"
        case .team: return "Team"
        }
    }

    /// The walkthrough step's chapter.
    static func of(_ step: OnboardingPanel.Step?) -> OnboardingChapter {
        switch step {
        case .brain: return .model
        case .team, .firstTask, nil: return .team
        }
    }
}

/// "Welcome — Model — Team" on the same glass as Skip setup and at its
/// height, so the top row reads as one set of chrome. Drawn like the setup
/// card's stepper in chat: finished chapters checked, the current one a
/// filled ring, the next ones open rings, joined by hairlines.
struct OnboardingChapterIndicator: View {
    @Environment(\.theme) private var theme
    let current: OnboardingChapter
    var chapters: [OnboardingChapter] = OnboardingChapter.allCases

    var body: some View {
        HStack(spacing: theme.space.s6) {
            ForEach(Array(chapters.enumerated()), id: \.element.rawValue) { index, chapter in
                if index > 0 {
                    Capsule()
                        .fill(
                            chapter.rawValue <= current.rawValue
                                ? OnboardingPalette.labelSecondary : OnboardingPalette.glassRim(0.3)
                        )
                        .frame(width: theme.space.s12, height: theme.hairline)
                }
                segment(chapter)
            }
        }
        .padding(.horizontal, theme.space.s12)
        .frame(height: OnboardingLayout.glassButtonDiameter)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(OnboardingPalette.fill3)
                Capsule().strokeBorder(OnboardingPalette.glassRim(0.3), lineWidth: theme.hairline)
            }
        }
        .animation(theme.motion.standard, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                "Setup chapter \((chapters.firstIndex(of: current) ?? current.rawValue) + 1) of \(chapters.count): \(Text(current.title, bundle: .module))",
                bundle: .module))
    }

    private func segment(_ chapter: OnboardingChapter) -> some View {
        let isCurrent = chapter == current
        let isDone = chapter.rawValue < current.rawValue
        let symbol = isDone ? "checkmark.circle.fill" : isCurrent ? "circle.inset.filled" : "circle"
        let label = isCurrent ? OnboardingPalette.labelPrimary : OnboardingPalette.labelSecondary
        // One text run, so the ring sits on the word's baseline and both
        // center in the capsule together; every state is the same width.
        return (Text(Image(systemName: symbol)).foregroundColor(isDone ? OnboardingPalette.dinoGreenText : label)
            + Text(verbatim: " ")
            + Text(chapter.title, bundle: .module).foregroundColor(label))
            .font(OnboardingTypography.chapter)
            .fixedSize()
    }
}

// MARK: - Provider logo

/// Committed asset-catalog logo image for a provider chip / card, falling
/// back to an SF Symbol when the preset has no committed logo asset.
struct OnboardingProviderLogo: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(55, enabled: inspectionEnabled) }

    let preset: ProviderPreset
    var size: CGFloat = 16

    var body: some View {
        Group {

        if let asset = Self.assetName(for: preset) {
            Image(asset, bundle: .module)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
                .frame(width: size, height: size)
        } else {
            ProviderIcon(preset: preset, size: size, color: theme.assignedColor("component.library.55.foreground", fallback: OnboardingPalette.labelPrimary))
        }
    
        }.environment(\.theme, theme)
}

    /// Imageset name for the five Figma-exported logos; `nil` falls back to
    /// the generic `ProviderIcon` symbol.
    static func assetName(for preset: ProviderPreset) -> String? {
        switch preset {
        case .openai: return "provider-logo-openai"
        case .anthropic: return "provider-logo-anthropic"
        case .xai: return "provider-logo-xai"
        case .openrouter: return "provider-logo-openrouter"
        case .google: return "provider-logo-gemini"
        default: return nil
        }
    }

}

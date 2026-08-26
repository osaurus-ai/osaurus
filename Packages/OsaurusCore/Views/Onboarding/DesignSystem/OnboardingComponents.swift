//
//  OnboardingComponents.swift
//  osaurus
//
//  Reusable onboarding design-kit components built on `OnboardingPalette` /
//  `OnboardingTypography` / `OnboardingLayout` (see OnboardingDesign.swift):
//  the window shell, pill buttons, glass circle buttons, panels, selectable
//  cards, chips, badge, checkbox row, and the shared dialog scaffold. All
//  dark-only, matching the Figma onboarding kit.
//

import SwiftUI

// MARK: - Window shell

/// Full-window layout for one onboarding step: 40pt padding, fixed 400pt
/// left column (bottom-aligned, 56pt trailing inset), 40pt gap, flexible
/// right panel slot. Back/Close overlay buttons are rendered by the parent
/// (`OnboardingView`) so they stay pixel-stable across step transitions.
struct OnboardingStepLayout<Left: View, Right: View>: View {
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right

    var body: some View {
        HStack(alignment: .top, spacing: OnboardingLayout.columnGap) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                left()
            }
            .padding(.trailing, OnboardingLayout.leftColumnTrailingInset)
            .frame(width: OnboardingLayout.leftColumnWidth)
            .frame(maxHeight: .infinity, alignment: .bottomLeading)

            right()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(OnboardingLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Right panel

/// Rounded-16 right panel with a faint white fill and an optional vertical
/// gradient tint (screen 2 uses the green create tint fading out by ~75%).
struct OnboardingRightPanel<Content: View>: View {
    var gradientTint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: OnboardingLayout.panelRadius, style: .continuous)
                .fill(OnboardingPalette.fill3)

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
                        cornerRadius: OnboardingLayout.panelRadius,
                        style: .continuous
                    )
                )
            }

            content()
        }
    }
}

// MARK: - Pill buttons

/// Capsule button in the kit's three fills and two sizes.
struct OnboardingPillButton: View {
    enum Style {
        /// White `#f5f5f5` fill, near-black label — the screen's main CTA.
        case primary
        /// Faint white fill, light label — secondary actions ("Set up later").
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
            HStack(spacing: 6) {
                if let symbol = leadingSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize, weight: .semibold))
                }
                Text(title, bundle: .module)
                    .font(labelFont)
                    .lineLimit(1)
                if let symbol = trailingSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize, weight: .semibold))
                }
            }
            .foregroundColor(labelColor)
            .padding(.horizontal, size == .large ? 20 : 12)
            .padding(.vertical, size == .large ? 12 : 8)
            .background(background)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var labelFont: Font {
        size == .large ? OnboardingTypography.cta : OnboardingTypography.chip
    }

    private var symbolSize: CGFloat { size == .large ? 13 : 11 }

    private var labelColor: Color {
        switch style {
        case .primary: return OnboardingPalette.vibrantLabel
        case .secondary, .text: return OnboardingPalette.labelPrimary
        }
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Capsule().fill(
                isHovered ? OnboardingPalette.labelWhite : OnboardingPalette.vibrantFill
            )
        case .secondary:
            Capsule().fill(isHovered ? OnboardingPalette.fill8 : OnboardingPalette.fill5)
        case .text:
            Capsule().fill(isHovered ? OnboardingPalette.fill5 : Color.clear)
        }
    }
}

// MARK: - Glass circle button

/// 24pt circular Back/Close affordance floating over the window corners —
/// dark fill with a subtle light rim, per the Figma glass buttons.
struct OnboardingCircleIconButton: View {
    /// SF Symbol name (`xmark` / `arrow.left`).
    let systemName: String
    let action: () -> Void
    var accessibilityLabelKey: LocalizedStringKey = "Close"

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(isHovered ? 0.55 : 0.35))
                Circle().strokeBorder(
                    Color.white.opacity(isHovered ? 0.5 : 0.3),
                    lineWidth: 0.5
                )
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OnboardingPalette.vibrantFill)
            }
            .frame(
                width: OnboardingLayout.glassButtonDiameter,
                height: OnboardingLayout.glassButtonDiameter
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabelKey, bundle: .module))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - Checkbox row

/// 12pt blue checkbox + 10pt label — the usage-data opt-in on screen 1.
struct OnboardingCheckboxRow: View {
    @Binding var isOn: Bool
    let label: LocalizedStringKey

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isOn ? OnboardingPalette.accentBlue : Color.clear)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            isOn ? OnboardingPalette.accentBlue : OnboardingPalette.fill10,
                            lineWidth: 1
                        )
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 12, height: 12)

                Text(label, bundle: .module)
                    .font(OnboardingTypography.footnote)
                    .foregroundColor(OnboardingPalette.labelSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Selectable card

/// Specialty card on screen 2: icon + 17pt regular title row, 12pt caption,
/// 8pt inner gap (Figma Config/Cards). The selected card gets a `dinoGreen`
/// border, a bold accent icon, and a slightly stronger fill.
struct OnboardingSelectableCard: View {
    /// SF Symbol shown before the title.
    let symbol: String
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    let isSelected: Bool
    var accent: Color = OnboardingPalette.dinoGreen
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                        .foregroundColor(
                            isSelected ? accent : OnboardingPalette.labelPrimary
                        )
                    Text(title, bundle: .module)
                        .font(OnboardingTypography.cardTitleRegular)
                        .foregroundColor(OnboardingPalette.labelPrimary)
                }
                Text(caption, bundle: .module)
                    .font(OnboardingTypography.cardCaption)
                    .foregroundColor(OnboardingPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent : OnboardingPalette.fill8,
                        lineWidth: 1
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var fillColor: Color {
        if isSelected { return OnboardingPalette.fill5 }
        return isHovered ? OnboardingPalette.fill3 : OnboardingPalette.fill2
    }
}

// MARK: - Chips & badge

/// Cyan-on-blue-tint "Picked for your Mac" badge.
struct OnboardingPickedBadge: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text, bundle: .module)
            .font(OnboardingTypography.badge)
            .foregroundColor(OnboardingPalette.accentCyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OnboardingPalette.accentBlue.opacity(0.22))
            )
    }
}

/// White-10% capsule meta chip ("Download : 8.05 GB").
struct OnboardingMetaChip: View {
    /// Pre-localized text (composed with formatted sizes).
    let text: String

    var body: some View {
        Text(text)
            .font(OnboardingTypography.cardCaption)
            .foregroundColor(OnboardingPalette.labelPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(OnboardingPalette.fill10))
    }
}

/// Provider chip: 16pt logo + 13pt label, radius-8 card fill.
struct OnboardingProviderChip<Logo: View>: View {
    @ViewBuilder let logo: () -> Logo
    /// Provider display name (proper noun — never localized).
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                logo()
                    .frame(width: 16, height: 16)
                Text(label)
                    .font(OnboardingTypography.chip)
                    .foregroundColor(OnboardingPalette.labelPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? OnboardingPalette.fill8 : OnboardingPalette.fill5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(OnboardingPalette.fill10, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

// MARK: - Option row

/// Full-width connect-option row inside the provider drill-in: 13pt semibold
/// title + 12pt caption, with an optional green verified check trailing.
struct OnboardingOptionRow: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    var isVerified: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title, bundle: .module)
                        .font(OnboardingTypography.optionTitle)
                        .foregroundColor(OnboardingPalette.labelPrimary)
                    Text(caption, bundle: .module)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelSecondary)
                }
                Spacer(minLength: 0)
                if isVerified {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(OnboardingPalette.dinoGreen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? OnboardingPalette.fill8 : OnboardingPalette.fill5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
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
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if isDismissable { onClose() }
                }

            content()
                .frame(width: width)
                .background(
                    RoundedRectangle(
                        cornerRadius: OnboardingLayout.panelRadius,
                        style: .continuous
                    )
                    .fill(OnboardingPalette.dialogSurface)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: OnboardingLayout.panelRadius,
                        style: .continuous
                    )
                    .strokeBorder(OnboardingPalette.fill8, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isDismissable {
                        OnboardingCircleIconButton(systemName: "xmark", action: onClose)
                            .padding(12)
                    }
                }
                .shadow(color: Color.black.opacity(0.4), radius: 30, y: 14)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            if isDismissable { onClose() }
        }
    }
}

/// Square logo card (glyph over a small caption) used in the provider
/// drill-in and connect dialog headers.
struct OnboardingLogoCard<Logo: View>: View {
    @ViewBuilder let logo: () -> Logo
    /// Provider display name (proper noun — never localized).
    let caption: String
    var logoSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 8) {
            logo()
                .frame(width: logoSize, height: logoSize)
            Text(caption)
                .font(OnboardingTypography.footnote)
                .foregroundColor(OnboardingPalette.labelSecondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                .fill(OnboardingPalette.fill5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingLayout.cardRadius, style: .continuous)
                .strokeBorder(OnboardingPalette.fill8, lineWidth: 1)
        )
    }
}

// MARK: - Progress bar

/// Slim cyan progress bar on a faint track (the downloading state's bar).
struct OnboardingProgressBar: View {
    /// 0...1
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OnboardingPalette.fill10)
                Capsule()
                    .fill(OnboardingPalette.accentCyan)
                    .frame(width: max(6, proxy.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.3), value: progress)
    }
}

// MARK: - Provider logo

/// Committed asset-catalog logo image for a provider chip / card, falling
/// back to an SF Symbol when the preset has no committed logo asset.
struct OnboardingProviderLogo: View {
    let preset: ProviderPreset
    var size: CGFloat = 16

    var body: some View {
        if let asset = Self.assetName(for: preset) {
            Image(asset, bundle: .module)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(OnboardingPalette.labelPrimary)
                .frame(width: size, height: size)
        } else {
            ProviderIcon(preset: preset, size: size, color: OnboardingPalette.labelPrimary)
        }
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

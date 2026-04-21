//
//  OnboardingScaffold.swift
//  osaurus
//
//  Shared layout grammar for every onboarding screen:
//      top bar (back button) -> header (title + subtitle) -> content
//          -> flexible spacer -> footer caption -> CTA -> bottom inset
//
//  Composing this scaffold keeps spacing, typography and horizontal insets
//  identical step-to-step.
//

import SwiftUI

struct OnboardingScaffold<Content: View, CTA: View>: View {
    let title: LocalizedStringKey?
    let subtitle: LocalizedStringKey?
    let footer: LocalizedStringKey?
    let onBack: (() -> Void)?
    let hasCTA: Bool
    let content: Content
    let cta: CTA

    @Environment(\.theme) private var theme

    init(
        title: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder cta: () -> CTA
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.onBack = onBack
        self.hasCTA = true
        self.content = content()
        self.cta = cta()
    }

    fileprivate init(
        title: LocalizedStringKey?,
        subtitle: LocalizedStringKey?,
        footer: LocalizedStringKey?,
        onBack: (() -> Void)?,
        hasCTA: Bool,
        content: Content,
        cta: CTA
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.onBack = onBack
        self.hasCTA = hasCTA
        self.content = content
        self.cta = cta
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: OnboardingMetrics.topBarHeight)

            if let title = title {
                header(title, isPrimary: true)
            }

            if let subtitle = subtitle {
                Spacer().frame(height: OnboardingMetrics.titleToSubtitle)
                header(subtitle, isPrimary: false)
            }

            if title != nil || subtitle != nil {
                Spacer().frame(height: OnboardingMetrics.headerToBody)
            }

            content
                .frame(maxWidth: .infinity)

            // Flexible spacer pushes footer + CTA to the bottom while content
            // remains anchored under the header.
            Spacer(minLength: OnboardingMetrics.bodyToFooter)

            if let footer = footer {
                Text(footer, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.captionSize))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, hasCTA ? OnboardingMetrics.footerToCTA : 0)
            }

            if hasCTA {
                cta
            }

            Spacer().frame(height: OnboardingMetrics.bottomInset)
        }
        .padding(.horizontal, OnboardingMetrics.contentHorizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func header(_ key: LocalizedStringKey, isPrimary: Bool) -> some View {
        Text(key, bundle: .module)
            .font(
                theme.font(
                    size: isPrimary ? OnboardingMetrics.titleSize : OnboardingMetrics.subtitleSize,
                    weight: isPrimary ? .semibold : .regular
                )
            )
            .foregroundColor(isPrimary ? theme.primaryText : theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(isPrimary ? 0 : 4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 0) {
            if let onBack = onBack {
                OnboardingBackButton(action: onBack)
            }
            Spacer(minLength: 0)
        }
    }
}

extension OnboardingScaffold where CTA == EmptyView {
    init(
        title: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            footer: footer,
            onBack: onBack,
            hasCTA: false,
            content: content(),
            cta: EmptyView()
        )
    }
}

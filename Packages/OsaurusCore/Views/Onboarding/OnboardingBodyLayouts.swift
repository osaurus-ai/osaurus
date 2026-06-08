//
//  OnboardingBodyLayouts.swift
//  osaurus
//
//  Body layout primitives that fill the body slot of `OnboardingChromeShell`:
//
//  - `OnboardingTwoColumnBody` — illustration + helper copy on the left,
//    scrollable form content on the right. Used by Create Agent, Configure
//    AI, and Identity (non-recovery phases).
//  - `OnboardingFullWidthBody` — single-column full-width content. Used
//    when the illustration rail would crowd out the primary content
//    (e.g. Identity's `.recovery` phase).
//  - `OnboardingHeroBody` — single-column centered illustration + headline
//    + subtitle. Used by Welcome and the Walkthrough's internal pages.
//
//  All layouts share a graceful illustration placeholder that draws when
//  the supplied imageset hasn't been filled in yet, so the screen never
//  visually collapses around an empty image.
//

import AppKit
import SwiftUI

// MARK: - Scroll Container

/// Single source of truth for any vertical scrolling inside an onboarding
/// body. Applies the shared `scrollContentBuffer` so glass-card hover
/// shadows clear the chrome's body clip on top/bottom edges. Step files
/// should always reach for this instead of building a `ScrollView` inline.
struct OnboardingScrollContainer<Content: View>: View {
    let alignment: Alignment
    let content: Content

    init(
        alignment: Alignment = .topLeading,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(maxWidth: .infinity, alignment: alignment)
                .padding(OnboardingMetrics.scrollContentBuffer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

// MARK: - Two-Column Body

/// Two-column body with a left visual column and a right form / content
/// column. The default initializer builds the standard
/// illustration + headline + supporting copy left column; a generalized
/// `leftColumn:` overload lets steps (e.g. Create Agent) substitute a
/// custom visual (preview card, etc.) while keeping the shared widths,
/// paddings, and right-column scroll policy.
struct OnboardingTwoColumnBody<LeftContent: View, RightContent: View>: View {
    let leftContent: LeftContent
    let subtitle: LocalizedStringKey?
    /// When `true` (default) the right column wraps `rightContent` in a
    /// single vertical `OnboardingScrollContainer`. Set `false` for steps
    /// that need to manage their own internal scroll regions (e.g. a sticky
    /// header above a scrollable substate body).
    let useScrollView: Bool
    let rightContent: RightContent

    @Environment(\.theme) private var theme

    /// Generalized initializer — caller supplies the left column.
    init(
        subtitle: LocalizedStringKey? = nil,
        useScrollView: Bool = true,
        @ViewBuilder leftColumn: () -> LeftContent,
        @ViewBuilder rightContent: () -> RightContent
    ) {
        self.leftContent = leftColumn()
        self.subtitle = subtitle
        self.useScrollView = useScrollView
        self.rightContent = rightContent()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumnContainer
                .frame(width: OnboardingMetrics.leftColumnWidth)

            rightColumn
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left Column

    /// Wraps the caller's left-column content with the shared paddings,
    /// vertical centring, and width constraint so every two-column step
    /// has a pixel-stable rhythm.
    private var leftColumnContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            leftContent
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.leftColumnPadding)
        .padding(.vertical, OnboardingMetrics.bodyVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Right Column

    /// Right column. When `useScrollView` is `true`, the optional subtitle +
    /// `rightContent` are wrapped in a single shared
    /// `OnboardingScrollContainer`. When `false`, the subtitle and content
    /// are laid out non-scrollably and the caller is expected to manage
    /// any inner scroll regions itself.
    @ViewBuilder
    private var rightColumn: some View {
        if useScrollView {
            OnboardingScrollContainer {
                rightInnerStack
                    .padding(.horizontal, OnboardingMetrics.rightColumnHorizontalPadding)
                    .padding(.vertical, OnboardingMetrics.bodyVerticalPadding)
            }
        } else {
            rightInnerStack
                .padding(.horizontal, OnboardingMetrics.rightColumnHorizontalPadding)
                .padding(.vertical, OnboardingMetrics.bodyVerticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var rightInnerStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let subtitle = subtitle {
                Text(subtitle, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.subtitleSize))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)
            }

            rightContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Two-Column Body — illustration convenience

extension OnboardingTwoColumnBody where LeftContent == OnboardingIllustrationLeftColumn {
    /// Convenience initializer producing the canonical illustration +
    /// headline + body left column. Used by Configure AI and Identity.
    init(
        illustrationAsset: String?,
        leftHeadline: LocalizedStringKey? = nil,
        leftBody: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        useScrollView: Bool = true,
        @ViewBuilder rightContent: () -> RightContent
    ) {
        self.init(
            subtitle: subtitle,
            useScrollView: useScrollView,
            leftColumn: {
                OnboardingIllustrationLeftColumn(
                    illustrationAsset: illustrationAsset,
                    headline: leftHeadline,
                    body: leftBody
                )
            },
            rightContent: rightContent
        )
    }
}

// MARK: - Full-Width Body

/// Single-column body for step phases where the illustration rail
/// would crowd out the primary content (e.g. the BIP39 recovery
/// grid). Mirrors `OnboardingTwoColumnBody`'s right-column padding so
/// content stays vertically aligned across phases that swap layouts.
struct OnboardingFullWidthBody<Content: View>: View {
    let subtitle: LocalizedStringKey?
    let content: Content

    @Environment(\.theme) private var theme

    init(
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        OnboardingScrollContainer {
            VStack(alignment: .leading, spacing: 0) {
                if let subtitle = subtitle {
                    Text(subtitle, bundle: .module)
                        .font(theme.font(size: OnboardingMetrics.subtitleSize))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 14)
                }

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, OnboardingMetrics.rightColumnHorizontalPadding)
            .padding(.vertical, OnboardingMetrics.bodyVerticalPadding)
        }
    }
}

// MARK: - Illustration Left Column

/// The canonical left column for `OnboardingTwoColumnBody`: glow-backed
/// illustration, optional headline, optional supporting body. Promoted to
/// a named view so other steps can reuse it directly when they need a
/// custom-laid-out left column that *also* renders the illustration.
struct OnboardingIllustrationLeftColumn: View {
    let illustrationAsset: String?
    let headline: LocalizedStringKey?
    let supportingBody: LocalizedStringKey?

    @Environment(\.theme) private var theme

    init(
        illustrationAsset: String?,
        headline: LocalizedStringKey? = nil,
        body: LocalizedStringKey? = nil
    ) {
        self.illustrationAsset = illustrationAsset
        self.headline = headline
        self.supportingBody = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            illustrationBlock

            if headline != nil || supportingBody != nil {
                Spacer().frame(height: OnboardingMetrics.illustrationToHeadline)
            }

            if let headline = headline {
                Text(headline, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.leftHeadlineSize, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let body = supportingBody {
                Spacer().frame(height: OnboardingMetrics.leftHeadlineToBody)
                Text(body, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.leftBodySize))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var illustrationBlock: some View {
        ZStack {
            Circle()
                .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 50)

            if let asset = illustrationAsset, OnboardingAssetCheck.exists(asset) {
                Image(asset, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: OnboardingMetrics.illustrationMaxHeight)
            } else {
                IllustrationPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: OnboardingMetrics.illustrationMaxHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingMetrics.illustrationMaxHeight)
    }
}

// MARK: - Hero Body

/// Single-column centered hero (illustration + headline + subtitle).
///
/// Layout notes:
///  - `ScrollView` is a backstop for long localized copy / large
///    Dynamic Type — content is centered in the viewport when it fits
///    and scrolls when it doesn't.
///  - The wrapping copy must NOT use `fixedSize(vertical: true)` next
///    to `.frame(maxWidth:)`: SwiftUI's ideal-size pass can lock the
///    height at single-line, clipping multi-line wrapped text.
///  - Centring uses `.frame(minHeight:, alignment:)` rather than
///    `Spacer().layoutPriority(...)`; layout-priority Spacers collapse
///    to their minimum length under a `ScrollView`'s unbounded
///    vertical proposal.
struct OnboardingHeroBody<Footer: View>: View {
    let illustrationAsset: String?
    let headline: LocalizedStringKey?
    let subtitle: LocalizedStringKey?
    /// Optional content rendered centered beneath the subtitle (e.g. the
    /// Welcome step's usage opt-in checkbox). Defaults to `EmptyView`, so
    /// existing hero callers (Walkthrough) render exactly as before.
    let footer: Footer

    @Environment(\.theme) private var theme

    init(
        illustrationAsset: String?,
        headline: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder footer: () -> Footer
    ) {
        self.illustrationAsset = illustrationAsset
        self.headline = headline
        self.subtitle = subtitle
        self.footer = footer()
    }

    var body: some View {
        // The hero (illustration + copy) stays vertically centered, while the
        // optional `footer` is pushed to the bottom of the body slot so it
        // sits close to the CTA. With the default `EmptyView` footer this
        // collapses to a plain centered hero (Walkthrough is unaffected).
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            heroStack
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, OnboardingMetrics.heroBodyHorizontalPadding)
        .padding(.vertical, OnboardingMetrics.heroBodyVerticalPadding)
    }

    private var heroStack: some View {
        VStack(spacing: 0) {
            heroIllustration

            if headline != nil || subtitle != nil {
                Spacer().frame(height: OnboardingMetrics.heroIllustrationToHeadline)
            }

            if let headline = headline {
                Text(headline, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.heroHeadlineSize, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: OnboardingMetrics.heroMaxTextWidth)
            }

            if let subtitle = subtitle {
                Spacer().frame(height: OnboardingMetrics.heroHeadlineToSubtitle)
                Text(subtitle, bundle: .module)
                    .font(theme.font(size: OnboardingMetrics.heroSubtitleSize))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: OnboardingMetrics.heroMaxTextWidth)
            }
        }
    }

    private var heroIllustration: some View {
        let glowDiameter = OnboardingMetrics.heroIllustrationMaxHeight + 40
        return ZStack {
            Circle()
                .fill(theme.accentColor.opacity(theme.isDark ? 0.16 : 0.10))
                .frame(width: glowDiameter, height: glowDiameter)
                .blur(radius: 60)

            if let asset = illustrationAsset, OnboardingAssetCheck.exists(asset) {
                Image(asset, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: OnboardingMetrics.heroIllustrationMaxHeight)
            } else {
                IllustrationPlaceholder()
                    .frame(width: glowDiameter, height: OnboardingMetrics.heroIllustrationMaxHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingMetrics.heroIllustrationMaxHeight)
    }
}

// MARK: - Hero Body — footerless convenience

extension OnboardingHeroBody where Footer == EmptyView {
    /// Convenience initializer for hero steps with no footer content
    /// (Walkthrough's internal pages). Keeps the call sites unchanged from
    /// before `footer` was introduced.
    init(
        illustrationAsset: String?,
        headline: LocalizedStringKey? = nil,
        subtitle: LocalizedStringKey? = nil
    ) {
        self.init(
            illustrationAsset: illustrationAsset,
            headline: headline,
            subtitle: subtitle,
            footer: { EmptyView() }
        )
    }
}

// MARK: - Illustration Placeholder

/// Friendly placeholder shown until the designer-supplied PNG drops into the
/// imageset. Adapts to light/dark mode via theme tokens.
struct IllustrationPlaceholder: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(theme.isDark ? 0.14 : 0.08),
                            theme.accentColor.opacity(theme.isDark ? 0.06 : 0.04),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            theme.accentColor.opacity(theme.isDark ? 0.2 : 0.18),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                        )
                )

            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(theme.accentColor.opacity(0.6))
                Text("illustration", bundle: .module)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundColor(theme.accentColor.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

// MARK: - Asset existence check

/// Lightweight cached check for whether an imageset has a real PNG behind
/// it. SwiftUI's `Image(_, bundle:)` silently renders nothing when the asset
/// is missing — we want to swap in a friendly placeholder instead.
@MainActor
enum OnboardingAssetCheck {
    private static var cache: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let cached = cache[name] { return cached }
        let exists =
            Bundle.module.image(forResource: NSImage.Name(name)) != nil
            || NSImage(named: name) != nil
        cache[name] = exists
        return exists
    }
}

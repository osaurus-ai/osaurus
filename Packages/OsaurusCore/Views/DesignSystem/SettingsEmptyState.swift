//
//  SettingsEmptyState.swift
//  osaurus
//
//  The one empty state, in two sizes:
//
//  - hero (default): a page with nothing in it yet — glowing icon, title,
//    pitch, example cards or custom content, and actions.
//  - `.inline`: a section with nothing in it — icon, one line, optional hint
//    and action, sized to sit inside a group. Also the loading placeholder.
//

import SwiftUI

// MARK: - Models

extension SettingsEmptyState {
    struct Example {
        let icon: String
        let title: String
        let description: String
        /// Starts the create flow from this example.
        var action: (() -> Void)? = nil
    }

    struct Action {
        let title: String
        let icon: String
        let handler: () -> Void
    }

    enum Style {
        case hero
        case inline
        case loading
    }
}

// MARK: - Settings Empty State

struct SettingsEmptyState: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(19, enabled: baseComponentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    #if OSAURUS_DESIGN_SYSTEM
    @Environment(\.inspectorForceReducedMotion) private var forceReducedMotion
    #endif
    private var reduceMotion: Bool {
        #if OSAURUS_DESIGN_SYSTEM
        systemReduceMotion || forceReducedMotion
        #else
        systemReduceMotion
        #endif
    }

    let icon: String
    /// Catalog key.
    let title: String
    /// Catalog key.
    let subtitle: String
    var examples: [Example] = []
    var primaryAction: Action? = nil
    var secondaryAction: Action? = nil
    var hasAppeared: Bool = true
    /// Optional richer body rendered between the subtitle and the buttons,
    /// in place of the example cards.
    var content: AnyView? = nil
    /// Tighter hero for pages whose `content` carries the visual weight:
    /// drops the glowing icon and closes up the vertical rhythm.
    var compact: Bool = false
    /// Already-localized fine print beneath the buttons (pricing, terms).
    var footnote: String? = nil
    var style: Style = .hero

    @State private var glowIntensity: CGFloat = 0.6

    var body: some View {
        Group {
            switch style {
            case .hero: hero
            case .inline, .loading: inline
            }
        }
        #if OSAURUS_DESIGN_SYSTEM
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(19, fallback: nil)
        #endif
    }

    // MARK: - Inline

    private var inline: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.inline.verticalGap", inheriting: theme.space.s8)) {
            Group {
                if style == .loading {
                    #if OSAURUS_DESIGN_SYSTEM
                    Group {
                        let color = theme.assignedColor("component.library.19." + (baseComponentEnabled ? "accent" : "disabledForeground"), fallback: theme.text.secondary)
                        ProgressView().controlSize(.regular).assignedProgressIndicator(tintOverride: color)
                    }.accessibilityRepresentation {
                        ProgressView().accessibilityLabel(Text(LocalizedStringKey(title), bundle: .module))
                    }
                    #else
                    ProgressView().controlSize(.small)
                    #endif
                } else {
                    Image(systemName: icon)
                        .glyphSize(18, weight: .light)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Circle().fill(theme.surface.subtle))

            Text(LocalizedStringKey(title), bundle: .module)
                .assignedTypography("component.library.19.text", fallback: SettingsFont.rowTitle)
                .foregroundColor(theme.text.secondary)
                .multilineTextAlignment(.center)

            if !subtitle.isEmpty {
                Text(LocalizedStringKey(subtitle), bundle: .module)
                    .assignedTypography("component.library.19.caption", fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            if primaryAction != nil || secondaryAction != nil {
                HStack(spacing: theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.inline.horizontalGap", inheriting: theme.space.s8)) {
                    if let secondaryAction { inlineButton(.secondary, secondaryAction) }
                    if let primaryAction { inlineButton(.primary, primaryAction) }
                }.catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.inline.horizontalGap")
                .padding(.top, 2)
            }
        }.catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.inline.verticalGap")
        .frame(maxWidth: .infinity)
        .padding(.vertical, theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.inline.paddingY", inheriting: theme.space.s16)).catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.inline.paddingY")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.inline.paddingX", inheriting: theme.space.s12)).catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.inline.paddingX")
    }

    private func inlineButton(_ role: SettingsButtonRole, _ action: Action) -> some View {
        SettingsButton(
            role,
            action.title,
            icon: action.icon.isEmpty ? nil : action.icon,
            size: .compact,
            verbatim: true,
            action: action.handler
        )
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.hero.verticalGap", inheriting: (compact ? 16 : 24))) {
            Spacer()

            if !compact {
                glowingIcon
                    #if OSAURUS_DESIGN_SYSTEM
                    .id(reduceMotion)
                    #endif
                    .opacity(hasAppeared ? 1 : 0)
                    .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.8)
                    #if OSAURUS_DESIGN_SYSTEM
                    .animation(reduceMotion ? nil : theme.motion.springAnimation.delay(0.1), value: hasAppeared)
                    #else
                    .animation(theme.motion.springAnimation.delay(0.1), value: hasAppeared)
                    #endif
            }

            VStack(spacing: theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.hero.verticalGap2", inheriting: theme.space.s8)) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .assignedTypography("component.library.19.heading", fallback: SettingsFont.pageTitle)
                    .foregroundColor(theme.text.primary)
                    .multilineTextAlignment(.center)

                Text(LocalizedStringKey(subtitle), bundle: .module)
                    .assignedTypography("component.library.19.text", fallback: SettingsFont.pageSubtitle)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    #if !OSAURUS_DESIGN_SYSTEM
                    .lineSpacing(2)
                    #endif
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
            }.catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.hero.verticalGap2")
            .entrance(hasAppeared, offset: 15, delay: 0.2, reduceMotion: reduceMotion)

            if let content {
                content
                    #if OSAURUS_DESIGN_SYSTEM
                    .assignedTypography("component.library.19.text", fallback: SettingsFont.body)
                    .foregroundColor(theme.text.primary)
                    #endif
                    .entrance(hasAppeared, offset: 20, delay: 0.3, reduceMotion: reduceMotion)
            } else if !examples.isEmpty {
                exampleCards
                    .entrance(hasAppeared, offset: 20, delay: 0.3, reduceMotion: reduceMotion)
            }

            VStack(spacing: theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.hero.verticalGap3", inheriting: theme.space.s8)) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.hero.horizontalGap", inheriting: theme.space.s12)) {
                    if let secondaryAction {
                        SettingsButton(
                            .secondary, secondaryAction.title, icon: secondaryAction.icon, verbatim: true,
                            action: secondaryAction.handler
                        )
                    }
                    if let primaryAction {
                        SettingsButton(
                            .primary, primaryAction.title, icon: primaryAction.icon, verbatim: true,
                            action: primaryAction.handler
                        )
                    }
                }.catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.hero.horizontalGap")

                if let footnote {
                    Text(verbatim: footnote)
                        .assignedTypography("component.library.19.caption", fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560)
                }
            }.catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.hero.verticalGap3")
            .entrance(hasAppeared, offset: 10, delay: 0.4, reduceMotion: reduceMotion)

            Spacer()
        }.catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.hero.verticalGap")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.19.elements.layout.settingsEmptyState.hero.paddingX", inheriting: theme.space.s24)).catalogLayoutTarget("component.library.19.elements.layout.settingsEmptyState.hero.paddingX")
        #if OSAURUS_DESIGN_SYSTEM
        .animation(reduceMotion ? nil : theme.motion.loop(.easeInOut, duration: 2, autoreverses: true), value: glowIntensity)
        .task(id: reduceMotion) { glowIntensity = reduceMotion ? 0.6 : 1 }
        #else
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(theme.motion.loop(.easeInOut, duration: 2, autoreverses: true)) {
                glowIntensity = 1.0
            }
        }
        #endif
    }

    /// Flat hero glyph on a `surface.selected` disc; `glowIntensity` only
    /// fades the disc in so Reduce Motion users see a static state.
    private var glowingIcon: some View {
        ZStack {
            Circle()
                .fill(theme.surface.selected)
                .frame(width: 88, height: 88)
                .overlay(Circle().strokeBorder(theme.border.default, lineWidth: theme.stroke.default))
                #if OSAURUS_DESIGN_SYSTEM
                .opacity(reduceMotion ? 1 : 0.5 + glowIntensity * 0.5)
                #else
                .opacity(0.5 + glowIntensity * 0.5)
                #endif

            Image(systemName: icon)
                .glyphSize(36, weight: .medium)
                .foregroundColor(theme.text.primary)
        }
    }

    private var exampleCards: some View {
        SettingsFeatureCards(
            features: examples.map {
                SettingsFeature(icon: $0.icon, title: $0.title, caption: $0.description, action: $0.action)
            },
            style: .centered
        )
        .frame(maxWidth: 540)
    }
}

// MARK: - Inline Initializers

extension SettingsEmptyState {
    /// A section, list, or filter with nothing in it. `title` and `hint` are
    /// catalog keys; action titles are already localized. `isLoading` swaps
    /// the icon for a spinner and keeps the copy.
    init(
        inline icon: String,
        title: String,
        hint: String = "",
        action: Action? = nil,
        secondaryAction: Action? = nil,
        isLoading: Bool = false
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: hint,
            primaryAction: action,
            secondaryAction: secondaryAction,
            style: isLoading ? .loading : .inline
        )
    }

    /// Same footprint as `init(inline:)` so a section doesn't jump when its
    /// data lands. `title` is a catalog key ("Loading members…").
    init(loading title: String) {
        self.init(icon: "", title: title, subtitle: "", style: .loading)
    }
}

private struct EntranceModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let shown: Bool
    let offset: CGFloat
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : offset)
            #if OSAURUS_DESIGN_SYSTEM
            .animation(reduceMotion ? nil : theme.motion.springAnimation.delay(delay), value: shown)
            #else
            .animation(theme.motion.springAnimation.delay(delay), value: shown)
            #endif
    }
}

private extension View {
    func entrance(_ shown: Bool, offset: CGFloat, delay: Double, reduceMotion: Bool) -> some View {
        modifier(EntranceModifier(shown: shown, offset: offset, delay: delay, reduceMotion: reduceMotion))
    }
}

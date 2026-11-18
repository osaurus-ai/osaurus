//
//  SettingsLibrary.swift
//  osaurus
//
//  The two shapes a library item takes:
//
//  - `LibraryCard`: a grid tile (agents, templates, workflows, plugins,
//    workspaces, themes, knowledge collections, provider directory).
//  - `LibraryRow`: a flat row inside a `SettingsSection` group (events,
//    channels, providers, skills, commands, models, memory items).
//
//  Both take user data verbatim (names, descriptions) and own hover,
//  selection, and the open-on-click affordance.
//

import SwiftUI

// MARK: - Library Card

struct LibraryCard<Hero: View, Leading: View, Badges: View, Accessory: View, Content: View, Footer: View, MenuItems: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var assignmentFamily: Int { baseTheme.inspectionProductFamily(for: "background", fallback: 13) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(assignmentFamily, enabled: baseComponentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Verbatim (user data).
    let title: String
    /// Verbatim, one line. Pass a placeholder ("No description") rather
    /// than nil to keep card heights even across a grid.
    var subtitle: String?
    /// Dims the subtitle (placeholder text).
    var subtitleIsPlaceholder: Bool
    var isSelected: Bool
    var minHeight: CGFloat
    /// Already-localized tooltip for the open action.
    var help: String?
    var animationDelay: Double
    var hasAppeared: Bool
    let action: (() -> Void)?
    /// Edge-to-edge media above the card body (theme previews).
    @ViewBuilder let hero: Hero
    @ViewBuilder let leading: Leading
    @ViewBuilder let badges: Badges
    /// Trailing header control beside the menu (install button, toggle).
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    @ViewBuilder let menu: MenuItems

    @State private var isHovered = false

    init(
        title: String,
        subtitle: String? = nil,
        subtitleIsPlaceholder: Bool = false,
        isSelected: Bool = false,
        minHeight: CGFloat = 140,
        help: String? = nil,
        animationDelay: Double = 0,
        hasAppeared: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder hero: () -> Hero = { EmptyView() },
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder badges: () -> Badges = { EmptyView() },
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content = { EmptyView() },
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        @ViewBuilder menu: () -> MenuItems = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsPlaceholder = subtitleIsPlaceholder
        self.isSelected = isSelected
        self.minHeight = minHeight
        self.help = help
        self.animationDelay = animationDelay
        self.hasAppeared = hasAppeared
        self.action = action
        self.hero = hero()
        self.leading = leading()
        self.badges = badges()
        self.accessory = accessory()
        self.content = content()
        self.footer = footer()
        self.menu = menu()
    }

    private var hasMenu: Bool { MenuItems.self != EmptyView.self }
    private var hasFooter: Bool { Footer.self != EmptyView.self }
    private var hasHero: Bool { Hero.self != EmptyView.self }

    var body: some View {
        card
            .libraryOpenAction(action, help: help)
            .onHover { hovering in
                withAnimation(theme.motion.quick) { isHovered = hovering }
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 16)
            .animation(
                theme.motion.springAnimation.delay(animationDelay),
                value: hasAppeared
            )
    }

    private var card: some View {
        VStack(spacing: theme.space.s0) {
            if hasHero {
                hero
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            cardBody
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
        .assignedBaseChrome(assignmentFamily, fallback: isHovered || isSelected ? .cardHover : .card, selected: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.libraryCard.cardBody.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s12))) {
            HStack(alignment: .center, spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.libraryCard.cardBody.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s12))) {
                leading

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.libraryCard.cardBody.horizontalGap2", inheriting: theme.catalogMetric("gap", fallback: theme.space.s6))) {
                        Text(verbatim: title)
                            .assignedTypography("component.library.\(assignmentFamily).heading", fallback: SettingsFont.cardTitle)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                        badges
                    }.catalogLayoutTarget("component.library.13.elements.layout.libraryCard.cardBody.horizontalGap2")
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .assignedTypography("component.library.\(assignmentFamily).caption", fallback: SettingsFont.rowDescription)
                            .foregroundColor(subtitleIsPlaceholder ? theme.text.tertiary : theme.text.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: theme.space.s8)

                accessory

                if hasMenu {
                    SettingsOverflowMenu(help: "More actions", size: .compact) { menu }
                }
            }.catalogLayoutTarget("component.library.13.elements.layout.libraryCard.cardBody.horizontalGap")

            content.environment(\.theme, theme)

            Spacer(minLength: 0)

            if hasFooter {
                footer
            }
        }.catalogLayoutTarget("component.library.13.elements.layout.libraryCard.cardBody.verticalGap")
        .frame(maxWidth: .infinity, minHeight: theme.catalogMetric("height", fallback: minHeight), alignment: .topLeading)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.13.elements.layout.libraryCard.cardBody.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16))).padding(.vertical, theme.catalogLayoutMetric("component.library.13.elements.layout.libraryCard.cardBody.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: theme.space.s16))).catalogLayoutTarget("component.library.13.elements.layout.libraryCard.cardBody.padding.horizontal").catalogLayoutTarget("component.library.13.elements.layout.libraryCard.cardBody.padding.vertical")
    }
}

/// The card's preview text: up to two lines, italic placeholder when empty.
struct LibraryCardPreview: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var assignmentFamily: Int { baseTheme.inspectionProductFamily(for: "background", fallback: 13) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(assignmentFamily, enabled: baseComponentEnabled) }

    /// Verbatim.
    let text: String
    /// Catalog key shown when `text` is empty.
    var placeholder: String = "No description"
    var lines: Int = 2

    var body: some View {
        Group {
            if text.isEmpty {
                Text(LocalizedStringKey(placeholder), bundle: .module)
                    .italic()
                    .foregroundColor(theme.text.tertiary)
            } else {
                Text(verbatim: text)
                    .foregroundColor(theme.text.secondary)
            }
        }
        .assignedTypography("component.library.\(assignmentFamily).text", fallback: SettingsFont.caption)
        .lineLimit(lines, reservesSpace: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card's bottom line: facts joined with " · " and trailing actions.
struct LibraryCardFooter<Actions: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var assignmentFamily: Int { baseTheme.inspectionProductFamily(for: "background", fallback: 13) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(assignmentFamily, enabled: baseComponentEnabled) }

    /// Already-localized facts ("3 steps", "On 2 agents").
    let facts: [String]
    @ViewBuilder let actions: Actions

    init(facts: [String], @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.facts = facts
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.13.elements.layout.libraryCardFooter.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s8))) {
            Text(verbatim: facts.joined(separator: " · "))
                .assignedTypography("component.library.\(assignmentFamily).caption", fallback: SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            actions
        }.catalogLayoutTarget("component.library.13.elements.layout.libraryCardFooter.body.horizontalGap")
    }
}

/// One fact in a card's stat row: icon, optional short text, tooltip.
struct LibraryStat {
    let icon: String
    /// Already-localized; nil for icon-only markers.
    var text: String?
    var help: String?
    /// Higher wins when the row is tight.
    var priority: Double = 1
    var isWarning: Bool = false
}

/// Dot-separated icon + text facts along a card's bottom edge.
struct LibraryStatRow: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var assignmentFamily: Int { baseTheme.inspectionProductFamily(for: "background", fallback: 13) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(assignmentFamily, enabled: baseComponentEnabled) }

    let stats: [LibraryStat]

    var body: some View {
        HStack(spacing: theme.space.s0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    Circle()
                        .fill(theme.border.strong)
                        .frame(width: 3, height: 3)
                        .padding(.horizontal, theme.catalogLayoutMetric("component.library.13.elements.layout.libraryStatRow.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s8))).catalogLayoutTarget("component.library.13.elements.layout.libraryStatRow.body.paddingX")
                }
                HStack(spacing: theme.space.s2) {
                    Image(systemName: stat.icon)
                        .assignedTypography("component.library.\(assignmentFamily).caption", fallback: SettingsFont.footnote)
                    if let text = stat.text {
                        Text(verbatim: text)
                            .assignedTypography("component.library.\(assignmentFamily).caption", fallback: SettingsFont.chip)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .layoutPriority(stat.priority)
                .foregroundColor(stat.isWarning ? theme.status.warning.foreground : theme.text.tertiary)
                .help(stat.help ?? "")
            }
            Spacer(minLength: 0)
        }
    }
}

/// Round tinted SF Symbol tile for cards whose item has no avatar.
struct LibraryIcon: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(11, enabled: baseComponentEnabled) }
    let symbol: String
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .glyphSize(points: size * 0.39, weight: .semibold)
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(theme.wash(behind: tint)))
            .overlay(Circle().strokeBorder(theme.rule(around: tint), lineWidth: theme.stroke.default))
    }
}

// MARK: - Library Row

/// Title and subtitle share `SettingsRow`'s type assignments so a library
/// list and a settings group read as one hierarchy.
struct LibraryRow<Leading: View, Badges: View, Trailing: View, MenuItems: View, Footer: View>: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var assignmentFamily: Int { baseTheme.inspectionProductFamily(for: "background", fallback: 20) }
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(assignmentFamily, enabled: baseComponentEnabled) }
    @Environment(\.settingsInGroup) private var inGroup

    /// Verbatim (user data).
    let title: String
    /// Verbatim, up to two lines.
    var subtitle: String?
    var monospacedSubtitle: Bool
    var isSelected: Bool
    var showsChevron: Bool
    var anchorId: String?
    let action: (() -> Void)?
    let footer: Footer?
    @ViewBuilder let leading: Leading
    @ViewBuilder let badges: Badges
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let menu: MenuItems

    @State private var isHovered = false

    init(
        title: String,
        subtitle: String? = nil,
        monospacedSubtitle: Bool = false,
        isSelected: Bool = false,
        showsChevron: Bool = false,
        anchorId: String? = nil,
        action: (() -> Void)? = nil,
        footer: Footer? = Optional<EmptyView>.none,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder badges: () -> Badges = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder menu: () -> MenuItems = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.monospacedSubtitle = monospacedSubtitle
        self.isSelected = isSelected
        self.showsChevron = showsChevron
        self.anchorId = anchorId
        self.action = action
        self.footer = footer
        self.leading = leading()
        self.badges = badges()
        self.trailing = trailing()
        self.menu = menu()
    }

    private var hasMenu: Bool { MenuItems.self != EmptyView.self }

    var body: some View {
        row
            .libraryOpenAction(action, help: nil, family: 20)
            .onHover { hovering in
                withAnimation(theme.motion.quick) { isHovered = hovering }
            }
            .settingsLandingAnchor(anchorId)
    }

    private var row: some View {
        let fallbackInset = footer == nil ? 0 : theme.space.s12
        // A group already insets each child, like `SettingsRow`'s grouped
        // case; a footer row draws its own raised band and keeps its inset.
        let insetByGroup = inGroup && footer == nil
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            rowHeader
            if let footer { footer }
        }
        .padding(.horizontal, insetByGroup ? 0 : theme.catalogLayoutMetric("component.library.20.elements.layout.libraryRow.row.padding.horizontal", inheriting: theme.catalogMetric("padding", fallback: fallbackInset)))
        .padding(.vertical, insetByGroup ? 0 : theme.catalogLayoutMetric("component.library.20.elements.layout.libraryRow.row.padding.vertical", inheriting: theme.catalogMetric("padding", fallback: fallbackInset)))
        .catalogLayoutTarget("component.library.20.elements.layout.libraryRow.row.padding.horizontal")
        .catalogLayoutTarget("component.library.20.elements.layout.libraryRow.row.padding.vertical")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBaseChrome(assignmentFamily, fallback: nil, selected: isSelected, element: "row")
        .contentShape(Rectangle())
        .background(wash)
    }

    private var rowHeader: some View {
        HStack(alignment: .center, spacing: theme.catalogLayoutMetric("component.library.20.elements.layout.libraryRow.row.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s12))) {
            leading

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.20.elements.layout.libraryRow.row.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.settingsTitleToDescription))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.20.elements.layout.libraryRow.row.horizontalGap2", inheriting: theme.catalogMetric("gap", fallback: theme.space.s6))) {
                    Text(verbatim: title)
                        .assignedTypography("component.library.14.label", fallback: SettingsFont.rowTitle)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    badges
                }.catalogLayoutTarget("component.library.20.elements.layout.libraryRow.row.horizontalGap2")
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .assignedTypography("component.library.14.text", fallback: monospacedSubtitle ? SettingsFont.monoSmall : SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }.catalogLayoutTarget("component.library.20.elements.layout.libraryRow.row.verticalGap")
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing

            if hasMenu {
                SettingsOverflowMenu(help: "More actions", size: .compact) { menu }
            }

            if showsChevron {
                SettingsChevron()
            }
        }.catalogLayoutTarget("component.library.20.elements.layout.libraryRow.row.horizontalGap")

    }

    /// Hover / selection wash, bled into the group's row inset so it
    /// covers the whole row band.
    @ViewBuilder
    private var wash: some View {
        let hasFooter = footer != nil
        let isHovering = isHovered && (action != nil || hasFooter)
        let fill = isSelected ? theme.surface.selected
            : isHovering ? theme.surface.hover
            : hasFooter ? theme.surface.raised : .clear
        let bleedsIntoGroup = inGroup && !hasFooter
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        shape
            .fill(fill)
            .overlay(shape.strokeBorder(isSelected ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke))
            .padding(.horizontal, bleedsIntoGroup ? -theme.space.s8 : 0)
            .padding(.vertical, bleedsIntoGroup ? -theme.space.s4 : 0)
    }
}

// MARK: - Open Action

extension View {
    /// Click-to-open for cards and rows. A tap gesture rather than a wrapping
    /// `Button` so inner toggles, menus, and buttons keep their own clicks.
    @ViewBuilder
    fileprivate func libraryOpenAction(_ action: (() -> Void)?, help: String?, family: Int = 13) -> some View {
        if let action {
            self
                .modifier(LibraryOpenAction(action: action, help: help, family: family))
        } else {
            self
        }
    }
}

private struct LibraryOpenAction: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    let action: () -> Void
    let help: String?
    let family: Int
    func body(content: Content) -> some View {
        content.onTapGesture { if enabled { action() } }
            .assignedBaseKeyboardButton(family, action: action)
            .pointingHandCursor()
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { if enabled { action() } }
            .help(help ?? "")
    }
}

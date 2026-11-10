//
//  SettingsChips.swift
//  osaurus
//
//  `StatusChip` is the only tinted capsule (state, role, kind) and
//  `CountBadge` the only count pill. Sentence case, one size each.
//

import SwiftUI

// MARK: - Status Chip

struct StatusChip: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(10, enabled: baseComponentEnabled) }

    enum Tone: Equatable {
        /// `surface.subtle` wash, `border.default` edge, `text.secondary`.
        case neutral
        /// The "selected / highlighted" tone: `surface.selected` wash with `text.primary`.
        case accent
        case success
        case warning
        case urgentWarning
        case error
        case info
        /// Data-driven colour (agent or category colour). Theme tones must use
        /// the named cases.
        case custom(Color)
    }

    /// Already-localized text (rendered verbatim).
    let text: String
    let tone: Tone
    var icon: String?
    /// Status dot instead of an icon, for live states (Running, Connected).
    var showsDot: Bool
    /// Already-localized tooltip.
    var help: String?
    var typographyKey: String?
    private var sharedTypographyKey: String {
        #if OSAURUS_DESIGN_SYSTEM
        return "component.library.10.text"
        #else
        return typographyKey ?? "component.library.10.text"
        #endif
    }

    init(_ text: String, tone: Tone = .neutral, icon: String? = nil, showsDot: Bool = false, help: String? = nil, typographyKey: String? = nil) {
        self.text = text
        self.tone = tone
        self.icon = icon
        self.showsDot = showsDot
        self.help = help
        self.typographyKey = typographyKey
    }

    init(_ text: String, tint: Color, icon: String? = nil, showsDot: Bool = false, help: String? = nil) {
        self.init(text, tone: .custom(tint), icon: icon, showsDot: showsDot, help: help)
    }

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.10.elements.layout.statusChip.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: 4))) {
            if showsDot {
                Circle().fill(tint).frame(width: 5, height: 5)
            } else if let icon {
                Image(systemName: icon)
                    .glyphSize(8, weight: .bold)
            }
            Text(verbatim: text)
                .assignedTypography(sharedTypographyKey, fallback: SettingsFont.chip)
                .lineLimit(1)
        }.catalogLayoutTarget("component.library.10.elements.layout.statusChip.body.horizontalGap")
        .foregroundColor(tint)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.10.elements.layout.statusChip.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: 6))).catalogLayoutTarget("component.library.10.elements.layout.statusChip.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.10.elements.layout.statusChip.body.paddingY", inheriting: theme.catalogMetric("gap", fallback: 2))).catalogLayoutTarget("component.library.10.elements.layout.statusChip.body.paddingY")
        .frame(minHeight: theme.catalogMetric("height", fallback: 0))
        .assignedBadgeSurface(fill: fill, stroke: stroke)
        .fixedSize()
        .help(help ?? "")
    }

    private var statusKind: ThemeStatusKind? {
        switch tone {
        case .success: return .success
        case .warning: return .warning
        case .urgentWarning: return .urgentWarning
        case .error: return .error
        case .info: return .info
        case .neutral, .accent, .custom: return nil
        }
    }

    private var tint: Color {
        #if OSAURUS_DESIGN_SYSTEM
        if !baseComponentEnabled { return theme.text.disabled }
        #endif
        if let statusKind { return theme.status[statusKind].foreground }
        switch tone {
        case .neutral: return theme.text.secondary
        case .accent: return theme.text.primary
        case .custom(let color): return color
        default: return theme.text.secondary
        }
    }

    private var fill: Color {
        #if OSAURUS_DESIGN_SYSTEM
        if !baseComponentEnabled { return theme.surface.disabled }
        #endif
        if let statusKind { return theme.status[statusKind].background }
        switch tone {
        case .neutral: return theme.surface.subtle
        case .accent: return theme.surface.selected
        case .custom(let color): return color.opacity(0.12)
        default: return theme.surface.subtle
        }
    }

    private var stroke: Color {
        if let statusKind { return theme.status[statusKind].border }
        switch tone {
        // `surface.subtle` is within a few percent of the raised card it sits
        // on, so the neutral pill needs an edge to read as a chip.
        case .neutral: return theme.border.default
        case .accent: return .clear
        case .custom(let color): return color
        default: return .clear
        }
    }
}

// MARK: - Count Badge

/// Neutral count pill next to page titles, section titles, tabs, and
/// navigation rows. `.attention` is the accent variant for unread/pending.
struct CountBadge: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(10, enabled: baseComponentEnabled) }

    enum Prominence {
        case neutral
        case attention
    }

    let count: Int
    var prominence: Prominence
    var typographyKey: String?
    private var sharedTypographyKey: String {
        #if OSAURUS_DESIGN_SYSTEM
        return "component.library.10.caption"
        #else
        return typographyKey ?? "component.library.10.caption"
        #endif
    }

    init(_ count: Int, prominence: Prominence = .neutral, typographyKey: String? = nil) {
        self.count = count
        self.prominence = prominence
        self.typographyKey = typographyKey
    }

    var body: some View {
        Text(verbatim: "\(count)")
            .assignedTypography(sharedTypographyKey, fallback: SettingsFont.count)
            .monospacedDigit()
            .foregroundColor(
                !baseComponentEnabled ? theme.text.disabled : prominence == .attention ? theme.action.primary.default.foreground : theme.text.secondary
            )
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.10.elements.layout.countBadge.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: 7))).catalogLayoutTarget("component.library.10.elements.layout.countBadge.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.10.elements.layout.countBadge.body.paddingY", inheriting: theme.catalogMetric("gap", fallback: 2))).catalogLayoutTarget("component.library.10.elements.layout.countBadge.body.paddingY")
            .frame(minHeight: theme.catalogMetric("height", fallback: 0))
            .assignedBadgeSurface(fill: !baseComponentEnabled ? theme.surface.disabled : prominence == .attention ? theme.action.primary.default.background : theme.surface.subtle, stroke: .clear)
            .fixedSize()
    }
}

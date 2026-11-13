import SwiftUI
import AppKit

/// A scope reads the preserved component assignments while retaining the actual
/// app's implementation. Base families use all saved assignments. No global
/// semantic role is rewritten to implement a component-specific reassignment.
struct CatalogResolvedTheme: ThemeProtocol {
    let base: any ThemeProtocol
    let family: Int
    var enabled = true
    private var snapshot: DesignThemeSnapshot? { DesignThemeOverlay.shared.current() }
    private var mode: String { isDark ? "dark" : "light" }
    /// Everything besides the snapshot, family and property that a scoped
    /// read depends on.
    private func memoKey(_ property: String, kind: Int) -> DesignThemeOverlay.MemoKey {
        let flags = (isDark ? 2 : 0) | (base is CatalogResolvedTheme ? 4 : 0)
        return .init(property: property, family: family, flags: flags, kind: kind)
    }
    func value(_ property: String) -> JSONValue? {
        DesignThemeOverlay.shared.memoized(memoKey(property, kind: 0)) { resolve(property, in: $0) }
    }
    private func resolve(_ property: String, in snapshot: DesignThemeSnapshot?) -> JSONValue? {
        guard let snapshot else { return nil }
        let key = CatalogElementAssignments.routed("component.library.\(family).\(property)", mappings: snapshot.document.mappings)
        guard let role = snapshot.document.mappings[key] else { return nil }
        return snapshot.document.tokens[role]?[mode]
    }
    private func color(_ property: String, _ original: Color) -> Color {
        let assigned: Color? = DesignThemeOverlay.shared.memoized(memoKey(property, kind: 1)) { _ in
            value(property)?.designString.map { Color(themeHex: $0) }
        }
        return assigned ?? original
    }
    func metric(_ property: String, fallback: CGFloat) -> CGFloat {
        value(property)?.designNumber.map { CGFloat($0) } ?? fallback
    }
    private func recipe(_ property: String) -> ThemeTextStyle? {
        DesignThemeOverlay.shared.memoized(memoKey(property, kind: 2)) { _ in
            guard case .object(var object)? = value(property) else { return nil }
            let name = object["family"]?.designString ?? "system"
            object["family"] = .string(name == "systemMonospaced" ? "code" : "ui")
            object["familyName"] = ["system", "systemMonospaced"].contains(name) ? .null : .string(name)
            return try? JSONDecoder().decode(ThemeTextStyle.self, from: JSONEncoder().encode(JSONValue.object(object)))
        }
    }
    /// The family lists mirror which roles each component's design reaches;
    /// a role outside its family's reach keeps the surrounding theme value.
    var colors: ThemeColorRoles<Color> {
        var c = base.colors
        c.surface.raised = color("background", c.surface.raised)
        if family <= 20 || family >= 43 { c.surface.subtle = color("background", c.surface.subtle) }
        c.surface.overlay = color("background", c.surface.overlay)
        if [31,32,38,39].contains(family) { c.surface.code = color("background", c.surface.code) }
        if [41,42].contains(family) { c.surface.sidebar = color("background", c.surface.sidebar) }
        if family == 28 { c.chat.userBackground = color("background", c.chat.userBackground) }
        if family == 29 { c.chat.assistantBackground = color("background", c.chat.assistantBackground) }
        c.surface.hover = color("hover", c.surface.hover)
        c.surface.selected = color("selected", c.surface.selected)
        c.surface.disabled = color("disabledBackground", c.surface.disabled)
        c.text.primary = color("foreground", c.text.primary)
        c.text.secondary = color("secondary", c.text.secondary)
        c.text.tertiary = color("secondary", c.text.tertiary)
        c.text.disabled = color("disabledForeground", c.text.disabled)
        c.text.placeholder = color("placeholder", c.text.placeholder)
        c.border.default = color("border", c.border.default)
        c.border.strong = color("border", c.border.strong)
        c.border.focus = color("accent", c.border.focus)
        if family >= 43 || [31,32,36,37,38,39,40,42].contains(family) { c.selection.background = color("selected", c.selection.background); c.border.subtle = color("border", c.border.subtle) }
        if family >= 43 || [28,29,30,31,32,33,34,36,37,38,39].contains(family) { c.text.link = color("accent", c.text.link); c.cursor = color("accent", c.cursor) }
        c.action.primary.default.background = color("onBackground", color("accent", c.action.primary.default.background))
        c.action.primary.default.foreground = color("onForeground", c.action.primary.default.foreground)
        c.surface.selected = color("offBackground", c.surface.selected)
        c.border.error = color("error", c.border.error)
        c.status.error.foreground = color("error", c.status.error.foreground)
        c.status.success.foreground = color("success", c.status.success.foreground)
        c.status.warning.foreground = color("warning", c.status.warning.foreground)
        if family >= 43 || [18,34,35,36,37,38,39,40,41,42].contains(family) { c.status.info.foreground = color("accent", c.status.info.foreground) }
        if !enabled {
            let ink = color("disabledForeground", c.text.disabled)
            let fill = color("disabledBackground", c.surface.disabled)
            c.text.primary = ink; c.text.secondary = ink; c.text.tertiary = ink
            c.status.error.foreground = ink; c.status.success.foreground = ink
            c.status.warning.foreground = ink; c.status.info.foreground = ink
            c.surface.raised = fill; c.surface.subtle = fill; c.surface.overlay = fill
            c.surface.selected = fill; c.surface.hover = fill
        }
        return c
    }
    /// The component property that scopes a text style.
    private static func typographyProperty(_ role: ThemeTextStyleRole) -> String {
        switch role {
        case .heading, .title, .display, .hero, .lead, .subheading: return "heading"
        case .body, .bodySmall, .chatBody, .bodyEmphasis: return "text"
        case .label, .labelEmphasis: return "label"
        case .caption, .footnote, .micro: return "caption"
        case .code: return "code"
        }
    }
    func hasTypographyOverride(_ role: ThemeTextStyleRole) -> Bool {
        let property = Self.typographyProperty(role)
        return value(property) != nil
            || DesignThemeOverlay.shared.memoized(memoKey("type." + role.rawValue, kind: 4)) {
                $0?.changedTokens.contains("type." + role.rawValue) == true
            }
    }
    /// Each property is resolved once and applied to every style it scopes.
    var typography: ThemeTypography {
        var t = base.typography
        if let s = recipe("heading") {
            t.styles.heading = s; t.styles.title = s; t.styles.display = s; t.styles.subheading = s
            t.styles.hero = s; t.styles.lead = s
        }
        if let s = recipe("text") {
            t.styles.body = s; t.styles.bodySmall = s; t.styles.chatBody = s; t.styles.bodyEmphasis = s
        }
        if let s = recipe("label") { t.styles.label = s; t.styles.labelEmphasis = s }
        if let s = recipe("caption") { t.styles.caption = s; t.styles.footnote = s; t.styles.micro = s }
        if let s = recipe("code") { t.styles.code = s }
        return t
    }
    var radius: ThemeRadii {
        var r = base.radius
        if let n = value("radius")?.designNumber { r.medium = n; r.large = n; r.xlarge = n; r.bubble = n }
        let row: Double? = DesignThemeOverlay.shared.memoized(memoKey("row.radius", kind: 3)) { snapshot in
            guard let snapshot, let role = snapshot.document.mappings["component.library.\(family).elements.row.radius"] else { return nil }
            return snapshot.document.tokens[role]?[mode].designNumber
        }
        if let row { r.small = row }
        return r
    }
    var stroke: ThemeStrokes { var s = base.stroke; if let n = value("borderWidth")?.designNumber { s.default = n }; return s }
    var controlSize: ThemeControlSizes {
        var c = base.controlSize
        if let n = value("height")?.designNumber { c.defaultHeight = n; c.rowMinimumHeight = n }
        if let n = value("avatarSize")?.designNumber { c.chatAvatar = n }
        return c
    }
    var inspectionRevision: String { base.inspectionRevision }
    // Native text caches are shared across message roles. A scoped user-body
    // recipe must never be reused for an assistant body with the same revision.
    var renderFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(base.renderFingerprint)
        // Assignment-only edits can leave the resolved global theme unchanged.
        // Include the inspector generation so native font/layout caches refresh.
        hasher.combine(base.inspectionRevision)
        hasher.combine(family)
        hasher.combine(enabled)
        return hasher.finalize()
    }
    func nativeAssignedFont(_ role: ThemeTextStyleRole) -> NSFont? {
        let property = Self.typographyProperty(role)
        guard case .object? = value(property) else { return nil }
        return assignedNativeFont("component.library.\(family).\(property)", fallback: base.nsFont(role))
    }
    var space: ThemeSpaceScale { base.space }
    var focusOffset: Double { base.focusOffset }
    var motion: ThemeMotion { base.motion }
    var elevation: ThemeElevation { base.elevation }
    var effects: ThemeEffects { base.effects }
    var windowMaterial: ThemeWindowMaterial { base.windowMaterial }
    var fontScale: Double { base.fontScale }
    var isDark: Bool { base.isDark }
    var showInlineAvatar: Bool { base.showInlineAvatar }
    var showAgentName: Bool { base.showAgentName }
    var codeHighlightTheme: String? { base.codeHighlightTheme }
    var customThemeConfig: CustomTheme? { base.customThemeConfig }
}

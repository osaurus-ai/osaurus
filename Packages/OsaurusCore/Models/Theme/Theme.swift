//
//  Theme.swift
//  osaurus
//
//  Runtime theme: semantic roles resolved to SwiftUI values. See
//  ThemeRoles.swift for the dotted-name map.
//

import AppKit
import SwiftUI

extension NSFont {
    /// The same face with tabular digits, so live counters don't jitter.
    func withMonospacedDigits() -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

/// Decides whether a theme font-family name means "use the system font".
///
/// Fonts are resolved many times per render across every view, so the
/// classification is memoized for the life of the process.
enum ThemeFontNameClassifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memo: [String: Bool] = [:]

    /// True when `name` is empty, the shared `system` sentinel, or names the
    /// given system family.
    static func isSystemFamily(_ name: String, matching needle: String) -> Bool {
        if name.isEmpty { return true }
        let key = "\(needle)\u{0}\(name)"
        lock.lock()
        let cached = memo[key]
        lock.unlock()
        if let cached { return cached }

        let lower = name.lowercased()
        let result = lower == "system" || lower == "systemmonospaced" || lower.contains(needle)
        lock.lock()
        memo[key] = result
        lock.unlock()
        return result
    }
}

// MARK: - Theme Protocol

protocol ThemeProtocol: Sendable {
    // Semantic color roles (resolved)
    var colors: ThemeColorRoles<Color> { get }
    var inspectionRevision: String { get }

    // Typography and geometry
    var typography: ThemeTypography { get }
    var radius: ThemeRadii { get }
    var stroke: ThemeStrokes { get }
    var focusOffset: Double { get }
    var space: ThemeSpaceScale { get }
    var controlSize: ThemeControlSizes { get }
    var motion: ThemeMotion { get }
    var elevation: ThemeElevation { get }
    var effects: ThemeEffects { get }
    var windowMaterial: ThemeWindowMaterial { get }

    /// Global font zoom applied exactly once by `textStyle(_:)` and the size bridges.
    var fontScale: Double { get }

    // Appearance
    var isDark: Bool { get }

    // Product preferences carried by the theme document
    var showInlineAvatar: Bool { get }
    var showAgentName: Bool { get }

    // Code syntax highlighting theme (Highlightr name). nil = auto.
    var codeHighlightTheme: String? { get }

    // Custom theme reference (for editing)
    var customThemeConfig: CustomTheme? { get }

    /// Changes whenever any token that affects rendering changes (colors,
    /// typography, geometry, materials, font zoom, appearance). Native views
    /// compare it to decide when cached layout and attributed text are stale.
    var renderFingerprint: Int { get }
}

// MARK: - Role group accessors

extension ThemeProtocol {
    var inspectionRevision: String { "" }
    var surface: ThemeSurfaceRoles<Color> { colors.surface }
    var text: ThemeTextRoles<Color> { colors.text }
    var chat: ThemeChatRoles<Color> { colors.chat }
    var action: ThemeActionRoles<Color> { colors.action }
    var border: ThemeBorderRoles<Color> { colors.border }
    var selection: ThemeSelectionRoles<Color> { colors.selection }
    var cursor: Color { colors.cursor }
    var status: ThemeStatusRoles<Color> { colors.status }
    var danger: ThemeDangerRoles<Color> { colors.danger }
    var scrim: Color { colors.scrim }
    /// A light wash for pauses that keep the content behind them readable.
    /// Derived from `scrim` because surface roles are opaque.
    var scrimSubtle: Color { colors.scrim.opacity(0.2) }
    var shadow: Color { colors.shadow }

    var showInlineAvatar: Bool { true }
    var showAgentName: Bool { true }
    var codeHighlightTheme: String? { nil }
    var customThemeConfig: CustomTheme? { nil }
}

// MARK: - Typography helpers

extension ThemeProtocol {
    /// The complete named text recipe, scaled once by the user's font zoom.
    func scaledTextStyle(_ role: ThemeTextStyleRole) -> ThemeTextStyle {
        var style = typography.styles[role]
        style.size *= fontScale
        style.lineHeight *= fontScale
        return style
    }

    /// SwiftUI font for a named text style (family + size + weight).
    func textStyle(_ role: ThemeTextStyleRole) -> Font {
        let style = scaledTextStyle(role)
        return font(for: style)
    }

    /// Minimum line height for a named text style, in points.
    func lineHeight(_ role: ThemeTextStyleRole) -> CGFloat {
        CGFloat(scaledTextStyle(role).lineHeight)
    }

    /// Tracking for a named text style, in points.
    func tracking(_ role: ThemeTextStyleRole) -> CGFloat {
        CGFloat(scaledTextStyle(role).tracking)
    }

    /// AppKit font for a named text style (for NSTextView / table cells),
    /// optionally at another weight or set in the other shared family.
    func nsFont(
        _ role: ThemeTextStyleRole, weight: NSFont.Weight? = nil, family: ThemeFontFamilyRole? = nil
    ) -> NSFont {
        #if OSAURUS_DESIGN_SYSTEM
        if family == nil, let scoped = self as? CatalogResolvedTheme,
            let assigned = scoped.nativeAssignedFont(role) { return assigned }
        #endif
        var style = scaledTextStyle(role)
        if let family { style.family = family }
        guard let weight else { return nsFont(for: style) }
        let base = nsFont(for: style)
        let isSystem =
            style.family == .ui
            ? ThemeFontNameClassifier.isSystemFamily(typography.families.ui, matching: "sf pro")
            : ThemeFontNameClassifier.isSystemFamily(typography.families.code, matching: "sf mono")
        guard isSystem else {
            return weight >= .semibold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
        }
        return style.family == .code
            ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight)
            : NSFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    /// AppKit font for a role with tabular digits, for live counters.
    func nsFont(_ role: ThemeTextStyleRole, weight: NSFont.Weight? = nil, monospacedDigit: Bool) -> NSFont {
        let base = nsFont(role, weight: weight)
        guard monospacedDigit else { return base }
        let style = scaledTextStyle(role)
        if style.family == .ui, ThemeFontNameClassifier.isSystemFamily(typography.families.ui, matching: "sf pro") {
            return NSFont.monospacedDigitSystemFont(ofSize: CGFloat(style.size), weight: weight ?? style.nsFontWeight)
        }
        return base.withMonospacedDigits()
    }

    /// The role's scaled point size, for sizing SF Symbols next to its text.
    func pointSize(_ role: ThemeTextStyleRole) -> CGFloat {
        CGFloat(scaledTextStyle(role).size)
    }

    /// SF Symbol configuration matching a role's size and weight.
    func symbolConfiguration(_ role: ThemeTextStyleRole, weight: NSFont.Weight? = nil) -> NSImage.SymbolConfiguration {
        let style = scaledTextStyle(role)
        return NSImage.SymbolConfiguration(pointSize: CGFloat(style.size), weight: weight ?? style.nsFontWeight)
    }

    func font(for style: ThemeTextStyle) -> Font {
        switch style.family {
        case .ui: return font(size: style.size, weight: style.fontWeight)
        case .code: return monoFont(size: style.size, weight: style.fontWeight)
        }
    }

    func nsFont(for style: ThemeTextStyle) -> NSFont {
        let size = CGFloat(style.size)
        switch style.family {
        case .ui:
            if ThemeFontNameClassifier.isSystemFamily(typography.families.ui, matching: "sf pro") {
                return NSFont.systemFont(ofSize: size, weight: style.nsFontWeight)
            }
            return NSFont(name: typography.families.ui, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: style.nsFontWeight)
        case .code:
            if ThemeFontNameClassifier.isSystemFamily(typography.families.code, matching: "sf mono") {
                return NSFont.monospacedSystemFont(ofSize: size, weight: style.nsFontWeight)
            }
            return NSFont(name: typography.families.code, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: style.nsFontWeight)
        }
    }

    /// Creates a font using the theme's UI font family at an explicit size.
    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if ThemeFontNameClassifier.isSystemFamily(typography.families.ui, matching: "sf pro") {
            return .system(size: size, weight: weight)
        }
        return .custom(typography.families.ui, size: size).weight(weight)
    }

    /// Creates a monospace font using the theme's code font family.
    func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if ThemeFontNameClassifier.isSystemFamily(typography.families.code, matching: "sf mono") {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(typography.families.code, size: size).weight(weight)
    }

    /// Leading added between wrapped lines so each line lands on the
    /// style's target line height. Zero when the font is already taller.
    func lineSpacing(_ role: ThemeTextStyleRole) -> CGFloat {
        let style = scaledTextStyle(role)
        return ThemeTextMetrics.extraLeading(for: nsFont(for: style), lineHeight: CGFloat(style.lineHeight))
    }

    /// Paragraph style carrying the role's minimum line height, for AppKit text.
    func paragraphStyle(
        _ role: ThemeTextStyleRole,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight(role)
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        return paragraph
    }

    /// The complete AppKit attribute set for a role: font, tracking (kern)
    /// and paragraph style with the role's minimum line height.
    func textAttributes(
        _ role: ThemeTextStyleRole,
        color: NSColor? = nil,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> [NSAttributedString.Key: Any] {
        let style = scaledTextStyle(role)
        let font = nsFont(role)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle(role, alignment: alignment, lineBreakMode: lineBreakMode),
        ]
        if style.tracking != 0 { attributes[.kern] = CGFloat(style.tracking) }
        if let color { attributes[.foregroundColor] = color }
        return attributes
    }
}

// MARK: - Text metrics

/// Natural font metrics used to turn a target line height into the extra
/// leading SwiftUI / AppKit need. Memoized per font name and size.
enum ThemeTextMetrics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memo: [String: CGFloat] = [:]

    /// Height of one unadorned line set in `font`.
    static func naturalLineHeight(for font: NSFont) -> CGFloat {
        let key = "\(font.fontName)\u{0}\(font.pointSize)"
        lock.lock()
        let cached = memo[key]
        lock.unlock()
        if let cached { return cached }
        let height = ceil(font.ascender - font.descender + font.leading)
        lock.lock()
        memo[key] = height
        lock.unlock()
        return height
    }

    static func extraLeading(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        max(0, lineHeight - naturalLineHeight(for: font))
    }
}

// MARK: - Geometry helpers

extension ThemeProtocol {
    /// One physical pixel for the given display scale (`stroke.hairline`).
    func hairline(forBackingScale scale: CGFloat) -> CGFloat {
        stroke.hairlineRule.width(forBackingScale: scale)
    }

    /// One physical pixel on the main display; prefer the display-specific
    /// overload inside views that know their window.
    var hairline: CGFloat {
        hairline(forBackingScale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// One physical pixel for the display `view` is on.
    @MainActor
    func hairline(for view: NSView) -> CGFloat {
        hairline(forBackingScale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }
}

// MARK: - Motion helpers

extension ThemeMotion {
    /// True when the user asked macOS to reduce motion. Nonessential
    /// animation resolves to an instant state change in that case.
    static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func timing(_ duration: Double) -> Animation {
        if Self.reduceMotionEnabled { return .linear(duration: 0) }
        switch easing {
        case .easeInOut: return .easeInOut(duration: duration)
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        case .linear: return .linear(duration: duration)
        }
    }

    var quick: Animation { timing(durationQuick) }
    var standard: Animation { timing(durationStandard) }
    var slow: Animation { timing(durationSlow) }

    /// `NSAnimationContext` / Core Animation durations; 0 under Reduce Motion.
    var quickInterval: TimeInterval { Self.reduceMotionEnabled ? 0 : durationQuick }
    var standardInterval: TimeInterval { Self.reduceMotionEnabled ? 0 : durationStandard }
    var slowInterval: TimeInterval { Self.reduceMotionEnabled ? 0 : durationSlow }

    /// The theme easing as a Core Animation timing function.
    var timingFunction: CAMediaTimingFunction {
        switch easing {
        case .easeInOut: return CAMediaTimingFunction(name: .easeInEaseOut)
        case .easeIn: return CAMediaTimingFunction(name: .easeIn)
        case .easeOut: return CAMediaTimingFunction(name: .easeOut)
        case .linear: return CAMediaTimingFunction(name: .linear)
        }
    }

    /// The shared spring recipe; instant under Reduce Motion.
    var springAnimation: Animation {
        if Self.reduceMotionEnabled { return .linear(duration: 0) }
        return .spring(response: spring.response, dampingFraction: spring.dampingFraction)
    }

    /// A repeating animation for spinners, pulses and shimmer. `duration` is
    /// the loop's own period, not a theme duration. Nil under Reduce Motion,
    /// so the state change lands without looping.
    func loop(
        _ curve: ThemeEasing = .linear,
        duration: Double,
        autoreverses: Bool = false,
        delay: Double = 0
    ) -> Animation? {
        if Self.reduceMotionEnabled { return nil }
        let base: Animation
        switch curve {
        case .easeInOut: base = .easeInOut(duration: duration)
        case .easeIn: base = .easeIn(duration: duration)
        case .easeOut: base = .easeOut(duration: duration)
        case .linear: base = .linear(duration: duration)
        }
        return base.repeatForever(autoreverses: autoreverses).delay(delay)
    }

    /// A one-shot animation whose length is part of the effect (a countdown
    /// bar, an attention pulse), not a theme duration. Nil under Reduce Motion.
    func timed(_ curve: ThemeEasing = .linear, duration: Double) -> Animation? {
        if Self.reduceMotionEnabled { return nil }
        switch curve {
        case .easeInOut: return .easeInOut(duration: duration)
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        case .linear: return .linear(duration: duration)
        }
    }

    func springAnimation(responseMultiplier: Double = 1.0, dampingMultiplier: Double = 1.0) -> Animation {
        if Self.reduceMotionEnabled { return .linear(duration: 0) }
        return .spring(
            response: spring.response * responseMultiplier,
            dampingFraction: min(1.0, spring.dampingFraction * dampingMultiplier)
        )
    }
}

// MARK: - Elevation helpers

extension ThemeElevationRecipe {
    var swiftUIColor: Color { Color(themeHex: color) }
}

struct ThemeElevationModifier: ViewModifier {
    let recipe: ThemeElevationRecipe

    func body(content: Content) -> some View {
        if recipe.opacity <= 0 || recipe.blur <= 0 {
            content
        } else {
            content.shadow(
                color: recipe.swiftUIColor.opacity(recipe.opacity),
                radius: recipe.blur / 2,
                x: recipe.x,
                y: recipe.y
            )
        }
    }
}

extension View {
    /// Applies a shadow recipe. `blur` is treated as the CSS-style blur
    /// diameter and halved for SwiftUI's radius.
    func themeElevation(_ recipe: ThemeElevationRecipe) -> some View {
        modifier(ThemeElevationModifier(recipe: recipe))
    }
}

extension CALayer {
    /// The AppKit twin of `themeElevation(_:)`. Recipe `y` points down the
    /// screen, so it is negated for an unflipped layer.
    func applyThemeElevation(_ recipe: ThemeElevationRecipe) {
        guard recipe.opacity > 0, recipe.blur > 0 else {
            shadowOpacity = 0
            return
        }
        shadowColor = NSColor(recipe.swiftUIColor).cgColor
        shadowOpacity = Float(recipe.opacity)
        shadowRadius = recipe.blur / 2
        shadowOffset = CGSize(width: recipe.x, height: isGeometryFlipped ? recipe.y : -recipe.y)
    }
}

// MARK: - Customizable Theme (Wraps CustomTheme)

/// A theme implementation that wraps a CustomTheme configuration
struct CustomizableTheme: ThemeProtocol {
    let config: CustomTheme

    /// Global zoom applied on top of the theme's own typography. Captured at
    /// construction; ThemeManager rebuilds live theme instances when it changes.
    let fontScale: Double

    /// Resolved once per theme instance so view bodies don't re-parse hex.
    let colors: ThemeColorRoles<Color>

    let renderFingerprint: Int
    let inspectionRevision: String

    init(config: CustomTheme, fontScale: Double = ThemeManager.fontScale) {
        #if OSAURUS_DESIGN_SYSTEM
        self.init(
            resolved: DesignThemeOverlay.shared.resolve(config), fontScale: fontScale,
            inspectionRevision: DesignThemeOverlay.shared.current()?.generation ?? "")
        #else
        self.init(resolved: config, fontScale: fontScale)
        #endif
    }

    /// A theme over `config` exactly as given, without the design overlay
    /// replacing its tokens.
    init(resolved config: CustomTheme, fontScale: Double, inspectionRevision: String = "") {
        self.config = config
        self.fontScale = fontScale
        self.inspectionRevision = inspectionRevision
        self.colors = config.colors.map { Color(themeHex: $0) }
        self.renderFingerprint = Self.fingerprint(config: config, fontScale: fontScale)
    }

    private static func fingerprint(config: CustomTheme, fontScale: Double) -> Int {
        var hasher = Hasher()
        hasher.combine(config.colors)
        hasher.combine(config.typography)
        hasher.combine(config.radius)
        hasher.combine(config.stroke)
        hasher.combine(config.focusOffset)
        hasher.combine(config.space)
        hasher.combine(config.controlSize)
        hasher.combine(config.motion)
        hasher.combine(config.elevation)
        hasher.combine(config.effects)
        hasher.combine(config.windowMaterial)
        hasher.combine(config.messages)
        hasher.combine(config.codeHighlightTheme)
        hasher.combine(config.isDark)
        hasher.combine(fontScale)
        return hasher.finalize()
    }

    var typography: ThemeTypography { config.typography }
    var radius: ThemeRadii { config.radius }
    var stroke: ThemeStrokes { config.stroke }
    var focusOffset: Double { config.focusOffset }
    var space: ThemeSpaceScale { config.space }
    var controlSize: ThemeControlSizes { config.controlSize }
    var motion: ThemeMotion { config.motion }
    var elevation: ThemeElevation { config.elevation }
    var effects: ThemeEffects { config.effects }
    var windowMaterial: ThemeWindowMaterial { config.windowMaterial }

    var isDark: Bool { config.isDark }

    var showInlineAvatar: Bool { config.messages.showInlineAvatar }
    var showAgentName: Bool { config.messages.showAgentName }

    var codeHighlightTheme: String? { config.codeHighlightTheme }
    var customThemeConfig: CustomTheme? { config }

    /// Canonical Light preset resolved as a theme (previews, tests, fallbacks).
    static func light(fontScale: Double = 1.0) -> CustomizableTheme {
        CustomizableTheme(config: .lightDefault, fontScale: fontScale)
    }

    /// Canonical Dark preset resolved as a theme (previews, tests, fallbacks).
    static func dark(fontScale: Double = 1.0) -> CustomizableTheme {
        CustomizableTheme(config: .darkDefault, fontScale: fontScale)
    }
}

// MARK: - Theme Manager

extension Notification.Name {
    static let globalThemeChanged = Notification.Name("globalThemeChanged")
}

@MainActor
public class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    /// UserDefaults key the retired theme library stored its active theme in.
    static let retiredActiveThemeKey = "activeThemeId"

    @Published var currentTheme: ThemeProtocol
    @Published var chatTheme: ThemeProtocol
    @Published public private(set) var appearanceMode: AppearanceMode = .system

    /// Global font zoom applied on top of every theme's typography. Static so
    /// `CustomizableTheme` instances can capture it at construction wherever
    /// they are built. `nonisolated(unsafe)` so it can serve as a default
    /// argument in the nonisolated `CustomizableTheme.init`; all writes stay
    /// on the main actor (this class), and themes are built on it too.
    nonisolated(unsafe) public private(set) static var fontScale: Double = 1.0
    static let fontScaleStep: Double = 0.1

    public var canZoomFontIn: Bool {
        Self.fontScale < ServerConfiguration.fontSizeMultiplierRange.upperBound
    }
    public var canZoomFontOut: Bool {
        Self.fontScale > ServerConfiguration.fontSizeMultiplierRange.lowerBound
    }
    public var isDefaultFontScale: Bool { Self.fontScale == 1.0 }

    public func zoomFontIn() { setFontScale(Self.fontScale + Self.fontScaleStep) }
    public func zoomFontOut() { setFontScale(Self.fontScale - Self.fontScaleStep) }
    public func resetFontScale() { setFontScale(1.0) }

    public func setFontScale(_ scale: Double, persist: Bool = true) {
        // Snap to the step grid so repeated zooms don't accumulate float drift.
        let snapped = (scale / Self.fontScaleStep).rounded() * Self.fontScaleStep
        let clamped = ServerConfiguration.clampedFontSizeMultiplier(snapped)
        guard clamped != Self.fontScale else { return }
        Self.fontScale = clamped

        if persist {
            ServerConfigurationStore.updateFontSizeMultiplier(clamped)
        }

        // Rebuild the live theme instances so every observer re-renders with
        // the new scale.
        applyResolvedTheme(for: appearanceMode, animated: false)
        NotificationCenter.default.post(name: .globalThemeChanged, object: nil)
    }

    #if OSAURUS_DESIGN_SYSTEM
    /// Rebuild published app themes from the immutable working snapshot, without
    /// changing the persisted appearance or the sent engineering handoff.
    /// Development preview range is independent of the saved product zoom limit.
    func setDesignInspectionScale(_ scale: Double) {
        Self.fontScale = min(max(scale, 0.7), 2.0)
        refreshDesignInspection()
    }
    func refreshDesignInspection() {
        let refreshed = CustomizableTheme(config: Self.seed(isDark: currentTheme.isDark))
        currentTheme = refreshed
        chatTheme = refreshed
        NotificationCenter.default.post(name: .globalThemeChanged, object: nil)
    }
    #endif

    private init() {
        let config = ServerConfigurationStore.load() ?? ServerConfiguration.default
        // Restore the persisted font zoom before any theme instance is built
        // so the initial themes capture the correct scale.
        Self.fontScale = ServerConfiguration.clampedFontSizeMultiplier(config.fontSizeMultiplier)

        let mode = Self.migrateRetiredActiveTheme(configured: config.appearanceMode)
        let themeInstance = CustomizableTheme(config: Self.seed(isDark: Self.isDarkMode(for: mode)))
        self.currentTheme = themeInstance
        self.chatTheme = themeInstance
        self.appearanceMode = mode

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    /// Custom themes were retired. A user who still has one active keeps its
    /// light or dark look as their appearance; the theme file stays on disk.
    private static func migrateRetiredActiveTheme(configured: AppearanceMode) -> AppearanceMode {
        let defaults = UserDefaults.standard
        guard let rawId = defaults.string(forKey: retiredActiveThemeKey) else { return configured }
        defaults.removeObject(forKey: retiredActiveThemeKey)
        let themesDirectory = OsaurusPaths.resolvePath(new: OsaurusPaths.themes(), legacy: "Themes")
        let mode = retiredThemeAppearance(
            activeThemeId: rawId,
            readThemeFile: { id in
                try? Data(contentsOf: themesDirectory.appendingPathComponent("\(id.uuidString).json"))
            },
            configured: configured
        )
        if mode != configured {
            ServerConfigurationStore.updateAppearanceMode(mode)
        }
        return mode
    }

    /// The appearance a retired active theme maps to: the built-in Dark and
    /// Light ids map directly, any other theme by its stored `isDark` flag.
    /// Unreadable or unknown themes keep the configured mode.
    static func retiredThemeAppearance(
        activeThemeId: String,
        readThemeFile: (UUID) -> Data?,
        configured: AppearanceMode
    ) -> AppearanceMode {
        guard let id = UUID(uuidString: activeThemeId) else { return configured }
        if id == CustomTheme.builtInDarkID { return .dark }
        if id == CustomTheme.builtInLightID { return .light }
        guard let data = readThemeFile(id),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let isDark = object["isDark"] as? Bool
        else { return configured }
        return isDark ? .dark : .light
    }

    /// Update the appearance mode and apply the theme
    public func setAppearanceMode(_ mode: AppearanceMode, persist: Bool = true) {
        appearanceMode = mode
        if persist {
            ServerConfigurationStore.updateAppearanceMode(mode)
        }
        applyResolvedTheme(for: mode, animated: true)
        NotificationCenter.default.post(name: .globalThemeChanged, object: nil)
    }

    private static func seed(isDark: Bool) -> CustomTheme {
        isDark ? CustomTheme.darkDefault : CustomTheme.lightDefault
    }

    /// Determine if dark mode should be used based on appearance mode
    private static func isDarkMode(for mode: AppearanceMode) -> Bool {
        switch mode {
        case .system:
            // Always read the system appearance from UserDefaults rather than
            // NSApp.effectiveAppearance. The latter can block the main thread
            // during AppKit appearance transitions (even after app launch),
            // causing app hangs. UserDefaults "AppleInterfaceStyle" is set by
            // the OS before DistributedNotificationCenter fires the appearance-
            // changed notification, so it is always current at this call site.
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        case .light:
            return false
        case .dark:
            return true
        }
    }

    @objc private func systemAppearanceChanged() {
        // Delivered on an arbitrary thread; hop to the main actor before
        // touching any @Published theme state.
        Task { @MainActor [weak self] in
            self?.applySystemAppearanceChange()
        }
    }

    private func applySystemAppearanceChange() {
        guard appearanceMode == .system else { return }

        applyResolvedTheme(for: .system, animated: true)
        NotificationCenter.default.post(name: .globalThemeChanged, object: nil)
    }

    private func applyResolvedTheme(for mode: AppearanceMode, animated: Bool) {
        let themeInstance = CustomizableTheme(config: Self.seed(isDark: Self.isDarkMode(for: mode)))

        if animated {
            withAnimation(themeInstance.motion.standard) {
                currentTheme = themeInstance
                chatTheme = themeInstance
            }
        } else {
            currentTheme = themeInstance
            chatTheme = themeInstance
        }
    }
}

// MARK: - Theme Environment Key

struct ThemeEnvironmentKey: EnvironmentKey {
    // Computed so a non-Sendable value is not stored as a global.
    static var defaultValue: ThemeProtocol { CustomizableTheme(config: .lightDefault, fontScale: 1.0) }
}

extension EnvironmentValues {
    var theme: ThemeProtocol {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {
    /// Paints the canvas role and injects the current theme.
    func themedBackground() -> some View {
        self.modifier(ThemedBackgroundModifier())
    }
}

struct ThemedBackgroundModifier: ViewModifier {
    @ObservedObject private var themeManager = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .background(themeManager.currentTheme.surface.canvas)
            .environment(\.theme, themeManager.currentTheme)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // RGBA (32-bit), trailing alpha (issue #2129)
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

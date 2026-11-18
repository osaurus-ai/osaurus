//
//  ThemeTokenHelperTests.swift
//  OsaurusCoreTests
//
//  Contracts for the helpers that turn theme tokens into rendering values:
//  text metrics, the render fingerprint, hairlines, the focus ring, motion
//  and layer elevation.
//

import AppKit
import Foundation
import QuartzCore
import Testing

@testable import OsaurusCore

@Suite("Theme token helpers")
struct ThemeTokenHelperTests {
    // MARK: - Text metrics

    @Test("line spacing lands each role on its target line height", arguments: ThemeTextStyleRole.allCases)
    func lineSpacingMatchesTargetLineHeight(_ role: ThemeTextStyleRole) {
        for theme in [CustomizableTheme.light(), CustomizableTheme.light(fontScale: 1.5)] {
            let natural = ThemeTextMetrics.naturalLineHeight(for: theme.nsFont(role))
            let spacing = theme.lineSpacing(role)
            #expect(spacing >= 0)
            #expect(spacing == max(0, theme.lineHeight(role) - natural))
        }
    }

    @Test("AppKit attributes carry the role's font, line height and tracking", arguments: ThemeTextStyleRole.allCases)
    func textAttributesCarryTheWholeRecipe(_ role: ThemeTextStyleRole) throws {
        var config = CustomTheme.lightDefault
        config.typography.styles[role].tracking = 0.4
        let theme = CustomizableTheme(resolved: config, fontScale: 1.25)

        let attributes = theme.textAttributes(role, color: .red)
        let font = try #require(attributes[.font] as? NSFont)
        let paragraph = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)

        #expect(font == theme.nsFont(role))
        #expect(font.pointSize == CGFloat(config.typography.styles[role].size * 1.25))
        #expect(paragraph.minimumLineHeight == CGFloat(config.typography.styles[role].lineHeight * 1.25))
        #expect(attributes[.kern] as? CGFloat == 0.4)
        #expect(attributes[.foregroundColor] as? NSColor == .red)
    }

    @Test("zero tracking adds no kern attribute")
    func zeroTrackingOmitsKern() {
        var config = CustomTheme.lightDefault
        config.typography.styles.body.tracking = 0
        let attributes = CustomizableTheme(resolved: config, fontScale: 1).textAttributes(.body)
        #expect(attributes[.kern] == nil)
    }

    // MARK: - Render fingerprint

    @Test("render fingerprint is stable for identical configs")
    func fingerprintIsStable() {
        let a = CustomizableTheme(config: CustomTheme.darkDefault, fontScale: 1)
        let b = CustomizableTheme(config: CustomTheme.darkDefault, fontScale: 1)
        #expect(a.renderFingerprint == b.renderFingerprint)
    }

    @Test("render fingerprint ignores metadata that never reaches pixels")
    func fingerprintIgnoresMetadata() {
        var renamed = CustomTheme.darkDefault
        renamed.metadata.name = "Renamed"
        renamed.metadata.updatedAt = Date(timeIntervalSince1970: 42)
        #expect(
            CustomizableTheme(config: renamed, fontScale: 1).renderFingerprint
                == CustomizableTheme(config: CustomTheme.darkDefault, fontScale: 1).renderFingerprint
        )
    }

    @Test(
        "render fingerprint changes with every rendering token",
        arguments: [
            "radius", "stroke", "space", "controlSize", "motion", "elevation", "typography", "focusOffset", "colors",
        ]
    )
    func fingerprintTracksTokens(_ field: String) {
        let base = CustomTheme.darkDefault
        var changed = base
        switch field {
        case "radius": changed.radius.medium += 1
        case "stroke": changed.stroke.focus += 1
        case "space": changed.space.s8 += 1
        case "controlSize": changed.controlSize.defaultHeight += 1
        case "motion": changed.motion.durationQuick += 0.05
        case "elevation": changed.elevation.raised.blur += 2
        case "typography": changed.typography.styles.caption.lineHeight += 1
        case "focusOffset": changed.focusOffset += 1
        default: changed.colors.text.primary = "#123456"
        }
        #expect(
            CustomizableTheme(resolved: changed, fontScale: 1).renderFingerprint
                != CustomizableTheme(resolved: base, fontScale: 1).renderFingerprint
        )
    }

    @Test("render fingerprint changes with the global font scale")
    func fingerprintTracksFontScale() {
        #expect(
            CustomizableTheme(config: CustomTheme.darkDefault, fontScale: 1).renderFingerprint
                != CustomizableTheme(config: CustomTheme.darkDefault, fontScale: 1.25).renderFingerprint
        )
    }

    // MARK: - Hairline

    @Test(
        "hairline is one physical pixel at each backing scale",
        arguments: [(1, 1), (2, 0.5), (3, 1.0 / 3.0), (0, 1)] as [(CGFloat, CGFloat)]
    )
    func hairlineIsOnePhysicalPixel(_ scale: CGFloat, _ expected: CGFloat) {
        let theme = CustomizableTheme.light()
        let fromStrokes: CGFloat = ThemeStrokes.hairline(forBackingScale: scale)
        let fromTheme: CGFloat = theme.hairline(forBackingScale: scale)
        #expect(fromStrokes == expected)
        #expect(fromTheme == expected)
    }

    // MARK: - Focus ring

    @Test("focus ring starts focus.offset outside the control and stays concentric", arguments: [CGFloat(0), 4, 8, 12])
    func focusRingGeometry(_ controlRadius: CGFloat) {
        var config = CustomTheme.lightDefault
        config.focusOffset = 2
        config.stroke.focus = 3
        let theme = CustomizableTheme(resolved: config, fontScale: 1)

        let ring = SettingsFocusRingGeometry(theme: theme, controlRadius: controlRadius)

        #expect(ring.lineWidth == 3)
        #expect(ring.outset - ring.lineWidth == 2)
        #expect(ring.cornerRadius - ring.outset == controlRadius)
    }

    // MARK: - Motion

    @Test("AppKit intervals follow the theme durations, or zero under Reduce Motion")
    func motionIntervals() {
        var motion = ThemeMotion.default
        motion.durationQuick = 0.11
        motion.durationStandard = 0.22
        motion.durationSlow = 0.33
        if ThemeMotion.reduceMotionEnabled {
            #expect(motion.quickInterval == 0 && motion.standardInterval == 0 && motion.slowInterval == 0)
            #expect(motion.loop(duration: 1) == nil)
            #expect(motion.timed(duration: 1) == nil)
        } else {
            #expect(motion.quickInterval == 0.11)
            #expect(motion.standardInterval == 0.22)
            #expect(motion.slowInterval == 0.33)
            #expect(motion.loop(duration: 1) != nil)
            #expect(motion.timed(duration: 1) != nil)
        }
    }

    @Test(
        "Core Animation timing follows the theme easing",
        arguments: [
            (ThemeEasing.easeInOut, CAMediaTimingFunctionName.easeInEaseOut),
            (.easeIn, .easeIn),
            (.easeOut, .easeOut),
            (.linear, .linear),
        ]
    )
    func timingFunctionFollowsEasing(_ easing: ThemeEasing, _ name: CAMediaTimingFunctionName) {
        var motion = ThemeMotion.default
        motion.easing = easing
        #expect(controlPoints(motion.timingFunction) == controlPoints(CAMediaTimingFunction(name: name)))
    }

    // MARK: - Layer elevation

    @Test("layer elevation applies the recipe with y pointing down the screen", arguments: [false, true])
    func layerElevation(_ flipped: Bool) {
        let layer = CALayer()
        layer.isGeometryFlipped = flipped
        let recipe = ThemeElevationRecipe(x: 1, y: 3, blur: 10, opacity: 0.3)

        layer.applyThemeElevation(recipe)

        #expect(abs(Double(layer.shadowOpacity) - 0.3) < 0.0001)
        #expect(layer.shadowRadius == 5)
        #expect(layer.shadowOffset == CGSize(width: 1, height: flipped ? 3 : -3))

        layer.applyThemeElevation(.none)
        #expect(layer.shadowOpacity == 0)
    }

    private func controlPoints(_ function: CAMediaTimingFunction) -> [Float] {
        (0 ..< 4).flatMap { index -> [Float] in
            var point = [Float](repeating: 0, count: 2)
            function.getControlPoint(at: index, values: &point)
            return point
        }
    }
}

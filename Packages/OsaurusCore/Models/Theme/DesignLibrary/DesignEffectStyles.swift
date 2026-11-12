typealias DesignEffectLayer = ThemeEffectLayer
typealias DesignEffectRecipe = ThemeEffectRecipe

import SwiftUI
import AppKit

struct DesignEffectSurface: NSViewRepresentable {
    let recipe: DesignEffectRecipe
    let radius: CGFloat
    func makeNSView(context: Context) -> DesignEffectNSView { DesignEffectNSView() }
    func updateNSView(_ view: DesignEffectNSView, context: Context) {
        view.recipe = recipe; view.radius = radius; view.needsDisplay = true
    }
}
final class DesignEffectNSView: NSView {
    var recipe = DesignEffectRecipe(layers: [], available: false)
    var radius: CGFloat = 8
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard recipe.available, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 64, dy: 64)
        guard rect.width > 0, rect.height > 0 else { return }
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // Figma's first effect is the top layer.
        for effect in recipe.layers.reversed() where effect.visible {
            ctx.saveGState()
            let color = NSColor(Color(themeHex: effect.color)).cgColor
            let inset = effect.type == "INNER_SHADOW"
            if inset {
                ctx.addPath(shape); ctx.clip()
            } else {
                ctx.addRect(bounds); ctx.addPath(shape); ctx.clip(using: .evenOdd)
            }
            ctx.setShadow(offset: CGSize(width: effect.x, height: effect.y), blur: effect.blur / 2, color: color)
            ctx.setFillColor(NSColor.black.cgColor)
            if inset {
                ctx.addRect(bounds.insetBy(dx: -256, dy: -256))
                let hole = rect.insetBy(dx: effect.spread, dy: effect.spread)
                ctx.addPath(CGPath(roundedRect: hole, cornerWidth: max(0, radius - effect.spread), cornerHeight: max(0, radius - effect.spread), transform: nil))
                ctx.drawPath(using: .eoFill)
            } else {
                let cast = rect.insetBy(dx: -effect.spread, dy: -effect.spread)
                ctx.addPath(CGPath(roundedRect: cast, cornerWidth: radius + effect.spread, cornerHeight: radius + effect.spread, transform: nil))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
    }
}
extension View {
    func designEffect(_ value: JSONValue?, radius: CGFloat) -> some View {
        overlay {
            if let value, let data = try? JSONEncoder().encode(value),
               let recipe = try? JSONDecoder().decode(DesignEffectRecipe.self, from: data), recipe.available {
                DesignEffectSurface(recipe: recipe, radius: radius).padding(-64).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
    func assignedDesignEffect(_ key: String, theme: any ThemeProtocol, radius: CGFloat) -> some View {
        designEffect(DesignButtonBindings.value(key, theme: theme), radius: radius)
    }

    /// Draws a library effect recipe (`theme.effects`) around a rounded rect
    /// of `radius`. Draws nothing while the recipe is unavailable.
    func themeEffect(_ role: ThemeEffectRole, radius: CGFloat) -> some View {
        modifier(ThemeEffectModifier(role: role, radius: radius))
    }
}

private struct ThemeEffectModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let role: ThemeEffectRole
    let radius: CGFloat

    func body(content: Content) -> some View {
        let recipe = theme.effects[role]
        content.overlay {
            if recipe.available {
                DesignEffectSurface(recipe: recipe, radius: radius).padding(-64).allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

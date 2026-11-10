#if OSAURUS_DESIGN_SYSTEM
import SwiftUI

/// The existing action bar's assignments are independent of its shared Buttons.
/// Hover state stays in this small subtree, never on FloatingInputCard itself.
struct InspectorComposerActionSurface: ViewModifier {
    @Environment(\.theme) private var base
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func body(content: Content) -> some View {
        let theme = base.catalogFamily(22, enabled: enabled, authoritative: true)
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        content
            .padding(theme.catalogMetric("padding", fallback: 0))
            .frame(minHeight: theme.catalogMetric("height", fallback: 32))
            .background(shape.fill(!enabled ? theme.surface.disabled : hovered ? theme.surface.hover : theme.surface.raised))
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.border.default, lineWidth: theme.stroke.default))
            .onHover { hovered = $0 }
    }
}
#endif

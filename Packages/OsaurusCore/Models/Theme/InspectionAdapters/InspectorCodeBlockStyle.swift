import SwiftUI
import AppKit

enum CodeBlockInspectionStyle {
    static let key = "component.library.32."
    static func scope(_ theme: any ThemeProtocol) -> any ThemeProtocol {
        if (theme as? CatalogResolvedTheme)?.family == 32 { return theme }
        return theme.catalogFamily(32)
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func headerHeight(_ theme: any ThemeProtocol, fallback: CGFloat = 28) -> CGFloat {
        let font = theme.assignedNativeFont(key + "caption", fallback: theme.nsFont(.caption))
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(metric("height", fallback, theme), max(natural, theme.assignedLineHeight(key + "caption", fallback: 16)) + 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.headerPaddingY", inheriting: metric("gap", theme.space.s4, theme)))
    }
}
extension View {
    @ViewBuilder func codeBlockCaption() -> some View {
        assignedTypography(CodeBlockInspectionStyle.key + "caption", fallback: SettingsFont.caption)
    }
    @ViewBuilder func codeBlockSurface(_ theme: any ThemeProtocol) -> some View {
        background(theme.surface.code)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: CodeBlockInspectionStyle.metric("borderWidth", 1, theme)))
    }
    @ViewBuilder func codeCopyStyle(_ theme: any ThemeProtocol) -> some View {
        buttonStyle(InspectorCodeCopyStyle(theme: theme))
    }
}
private struct InspectorCodeCopyStyle: ButtonStyle {
    let theme: any ThemeProtocol
    func makeBody(configuration: Configuration) -> some View {
        Body(content: configuration.label, theme: theme)
    }
    private struct Body<Content: View>: View {
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        let content: Content
        let theme: any ThemeProtocol
        var body: some View {
            content.padding(CodeBlockInspectionStyle.metric("gap", theme.space.s4, theme))
                .foregroundColor(enabled ? theme.text.secondary : theme.text.disabled)
                .background(enabled ? (hovered ? theme.surface.hover : theme.surface.code) : theme.surface.disabled)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.small))
                .onHover { hovered = $0 }
        }
    }
}

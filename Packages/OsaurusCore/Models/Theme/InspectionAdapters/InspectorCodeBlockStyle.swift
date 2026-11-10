import SwiftUI
import AppKit

enum CodeBlockInspectionStyle {
    static let key = "component.library.32."
    static func scope(_ theme: any ThemeProtocol) -> any ThemeProtocol {
        #if OSAURUS_DESIGN_SYSTEM
        if (theme as? CatalogResolvedTheme)?.family == 32 { return theme }
        #endif
        return theme.catalogFamily(32, authoritative: true)
    }
    static func metric(_ property: String, _ fallback: CGFloat, _ theme: any ThemeProtocol) -> CGFloat {
        theme.assignedMetric(key + property, fallback: fallback)
    }
    static func headerHeight(_ theme: any ThemeProtocol, fallback: CGFloat = 28) -> CGFloat {
        #if OSAURUS_DESIGN_SYSTEM
        let font = theme.assignedNativeFont(key + "caption", fallback: theme.nsFont(.caption))
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(metric("height", fallback, theme), max(natural, theme.assignedLineHeight(key + "caption", fallback: 16)) + 2 * theme.catalogLayoutMetric("component.library.32.elements.layout.headerPaddingY", inheriting: metric("gap", 4, theme)))
        #else
        return fallback
        #endif
    }
}
extension View {
    @ViewBuilder func codeBlockCaption() -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        assignedTypography(CodeBlockInspectionStyle.key + "caption", fallback: SettingsFont.caption)
        #else
        textStyle(.footnote, weight: 500, family: .code)
        #endif
    }
    @ViewBuilder func codeBlockSurface(_ theme: any ThemeProtocol) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        background(theme.surface.code)
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
            .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: CodeBlockInspectionStyle.metric("borderWidth", 1, theme)))
        #else
        settingsChrome(.code)
        #endif
    }
    @ViewBuilder func codeCopyStyle(_ theme: any ThemeProtocol) -> some View {
        #if OSAURUS_DESIGN_SYSTEM
        buttonStyle(InspectorCodeCopyStyle(theme: theme))
        #else
        buttonStyle(.plain)
        #endif
    }
}
#if OSAURUS_DESIGN_SYSTEM
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
            content.padding(CodeBlockInspectionStyle.metric("gap", 4, theme))
                .foregroundColor(enabled ? theme.text.secondary : theme.text.disabled)
                .background(enabled ? (hovered ? theme.surface.hover : theme.surface.code) : theme.surface.disabled)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.small))
                .onHover { hovered = $0 }
        }
    }
}
#endif

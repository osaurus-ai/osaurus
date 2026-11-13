import SwiftUI

/// Ephemeral preview selection. Never stored in the design document.
@MainActor final class CatalogPreviewInspection: ObservableObject {
    @Published var selected: String?
    @Published var targets: [String: Set<String>] = [:] { didSet { refreshTargets() } }
    @Published var nativeTargets: [UUID: [String: Set<String>]] = [:] { didSet { refreshTargets() } }
    @Published private(set) var allTargets: [String: Set<String>] = [:]
    private func refreshTargets() {
        var result = targets
        for source in nativeTargets.values { for (key, names) in source { result[key, default: []].formUnion(names) } }
        if allTargets != result { allTargets = result }
    }

    func label(for key: String, fallback: String) -> String {
        if let surface = AgentContentSurfaceAssignments.byKey[key] { return surface.label + (allTargets[key] == nil ? " (not shown)" : "") }
        if let layout = CatalogLayoutAssignments.byKey[key] { return layout.label.components(separatedBy: " — ").last ?? layout.label }
        let property = key.split(separator: ".").last.map(String.init) ?? fallback
        if key.hasPrefix("component.library.6.elements.layout.") {
            let variant = key.contains(".compact.") ? "Compact segments" : "Standard segments"
            let labels = [
                "outerPadding": "Track padding",
                "optionGap": "Gap between segments",
                "activityGap": "Gap beside activity indicator",
                "optionPaddingX": "Horizontal segment padding",
                "optionPaddingY": "Vertical segment padding"
            ]
            if let label = labels[property] { return variant + " — " + label }
        }
        let menuLabels = ["component.contextMenu.container.padding":"Menu container — Space inside border",
            "component.contextMenu.container.gap":"Menu container — Gap between actions / dividers",
            "component.contextMenu.row.paddingX":"Menu action row — Leading padding",
            "component.contextMenu.row.paddingTrailing":"Menu action row — Trailing padding",
            "component.contextMenu.row.gap":"Menu action row — Icon-to-label gap"]
        if let label = menuLabels[key] { return label }
        if key == "component.library.5.elements.container.padding" { return "Select / picker — Horizontal padding" }
        if key == "component.library.5.elements.container.paddingY" { return "Select / picker — Vertical padding" }
        let attachmentLabels = [
            "component.library.24.elements.image.height": "Attachment row — Minimum image height",
            "component.library.24.elements.image.padding": "Image thumbnail — Padding around image",
            "component.library.24.elements.image.radius": "Image thumbnail — Corner radius",
            "component.library.24.elements.container.gap": "Attachment row — Gap between items"
        ]
        if let label = attachmentLabels[key] { return label }
        if ["component.library.28.accent", "component.library.29.accent"].contains(key) { return "Links in message text — Color" }
        let messageLayout = [
            "component.library.28.elements.layout.topGap": "Space above user message",
            "component.library.28.elements.layout.attachmentTextGap": "Gap between attachments and message text",
            "component.library.28.elements.layout.editorActionsGap": "Gap between editor and action row",
            "component.library.28.elements.layout.actionButtonsGap": "Gap between editor actions",
            "component.library.29.elements.layout.actionsGap": "Gap between agent reply and action row"
        ]
        if let label = messageLayout[key] { return label }
        let attributes = ["background":"Fill", "foreground":"Text / icon color", "secondary":"Secondary text color", "border":"Border color", "borderWidth":"Border thickness", "radius":"Corner radius", "padding":"Inner padding", "paddingX":"Horizontal padding", "paddingY":"Vertical padding", "gap":"Spacing", "height":"Minimum height", "minimumHeight":"Minimum height", "minimumLabelWidth":"Minimum label width", "hover":"Hover fill", "selected":"Selected fill", "selectedBorder":"Selected outline", "disabledBackground":"Disabled fill", "disabledForeground":"Disabled text / icon color", "error":"Error color", "success":"Success color", "warning":"Warning color", "accent":"Accent color", "effect":"Surface effect", "avatarSize":"Avatar size", "contentGap":"Vertical spacing", "offset":"Focus ring offset", "width":"Focus ring thickness", "color":"Focus ring color", "borderHover":"Hovered border", "borderError":"Error border", "placeholder":"Placeholder color", "heightDefault":"Minimum field height", "onBackground":"Enabled fill", "offBackground":"Disabled / off fill", "onForeground":"On-state indicator color", "offForeground":"Off-state indicator color", "switchWidth":"Switch width", "switchHeight":"Switch height", "indicatorSize":"Checkbox size", "thumbSize":"Thumb size", "trackHeight":"Track thickness"]
        let attribute = attributes[property] ?? (property.hasSuffix("Gap") ? "Spacing" : "Typography")
        if let names = allTargets[key], !names.isEmpty {
            let sorted = names.sorted()
            let visible = sorted.prefix(2).map { name in
                let line = name.replacingOccurrences(of:"\n",with:" ")
                return line.count > 75 ? String(line.prefix(72)) + "…" : line
            }.joined(separator:"; ")
            return visible + (sorted.count > 2 ? " (+\(sorted.count - 2) more)" : "") + " — " + attribute
        }
        // Keep assignments for conditional/app-only elements accessible, without
        // falsely claiming that an unrelated preview element demonstrates them.
        let component: String
        if key.hasPrefix("component.library."), let id = Int(key.split(separator:".")[2]), let spec = CatalogcomponentCatalog.first(where:{$0.id == id}) { component = spec.name }
        else if key.hasPrefix("component.input.") { component = "Input" }
        else if key.hasPrefix("component.button.") { component = "Button" }
        else if key.hasPrefix("component.focus.") { component = "Keyboard focus ring" }
        else { component = "Component" }
        let absent = ["heading":"Title text", "label":"Control / row label", "text":"Body text", "caption":"Supporting text", "code":"Code text", "emphasis":"Emphasized text"]
        return component + " · " + (absent[property] ?? attribute) + " (not shown)"
    }
}
struct CatalogPreviewTargets: PreferenceKey {
    static let defaultValue: [String: Set<String>] = [:]
    static func reduce(value: inout [String: Set<String>], nextValue: () -> [String: Set<String>]) {
        for (key, names) in nextValue() { value[key, default: []].formUnion(names) }
    }
}
struct CatalogPreviewTarget: ViewModifier {
    @Environment(\.nativeCatalogSelection) private var selection
    let keys: [String]
    let name: String
    func body(content: Content) -> some View {
        content
            .transformPreference(CatalogPreviewTargets.self) { value in
                for key in keys { value[key, default: []].insert(name) }
            }
            .overlay {
                if let selection, keys.contains(selection) {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [5,3]))
                        .background(Color.orange.opacity(0.10))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
extension View {
    func catalogPreviewTarget(_ keys: [String], _ name: String) -> some View {
        modifier(CatalogPreviewTarget(keys: keys, name: name))
    }
}
/// Filters choices only. Never changes or normalizes a saved assignment.
enum CatalogAssignmentMenu {
    static let groups = ["Text", "Surfaces", "Borders", "Status", "Selection", "Chat", "Focus and cursor", "Button · Brand", "Button · Primary", "Button · Secondary", "Button · Tertiary", "Button · Destructive", "Button · Shared", "Spacing", "Sizes", "Corner radii", "Stroke widths", "Focus geometry", "Typography", "Elevation", "Bevel", "Other"]
    static func group(_ token:String, kind:String) -> String {
        if token.hasPrefix("color.action.") {
            for variant in ["brand","primary","secondary","tertiary","destructive"] where token.hasPrefix("color.action." + variant + ".") { return "Button · " + variant.capitalized }
            return "Button · Shared"
        }
        if token == "color.cursor" || token == "color.border.focus" { return "Focus and cursor" }
        for (prefix, title) in [("color.text.","Text"),("color.surface.","Surfaces"),("color.border.","Borders"),("color.status.","Status"),("color.danger.","Status"),("color.selection.","Selection"),("color.chat.","Chat"),("space.","Spacing"),("size.","Sizes"),("radius.","Corner radii"),("stroke.","Stroke widths"),("focus.","Focus geometry"),("effect.elevation.","Elevation"),("effect.bevel.","Bevel")] where token.hasPrefix(prefix) { return title }
        return kind == "typography" ? "Typography" : "Other"
    }
    static func allows(_ token:String, for key:String, kind:String) -> Bool {
        let property = key.split(separator:".").last.map(String.init) ?? ""
        let lower = property.lowercased()
        if kind == "dimension" {
            if CatalogLayoutAssignments.byKey[key] != nil { return token.hasPrefix("space.") }
            if lower.contains("radius") { return token.hasPrefix("radius.") }
            if lower.contains("borderwidth") || (key.contains(".focus.") && property == "width") { return token.hasPrefix("stroke.") }
            if key.contains(".focus.") && property == "offset" { return token.hasPrefix("focus.") || token.hasPrefix("space.") }
            if lower.contains("padding") || lower.contains("gap") || lower.contains("inset") { return token.hasPrefix("space.") }
            return token.hasPrefix("size.") || token.hasPrefix("space.")
        }
        guard kind == "color" else { return true }
        let button = key.hasPrefix("component.button.") || key.contains(".elements.button.")
        let fill = lower.contains("background") || ["hover","selected"].contains(property)
        let border = lower.contains("border") || key.contains(".border.")
        if token.hasPrefix("color.action.") {
            guard button else { return false }
            return fill ? token.hasSuffix(".background") : border ? token.hasSuffix(".border") : token.hasSuffix(".foreground")
        }
        if fill {
            return token.hasPrefix("color.surface.") || token.hasSuffix(".background") || token.hasPrefix("color.danger.") || token == "color.scrim"
        }
        if border {
            return token.hasPrefix("color.border.") || (token.hasPrefix("color.status.") && token.hasSuffix(".border"))
        }
        // Accents and error assignments can also drive strokes; normal text cannot.
        if ["accent","error"].contains(property) || key.hasPrefix("component.focus.") {
            return token.hasPrefix("color.text.") || token.hasPrefix("color.border.") || token.hasPrefix("color.danger.") || token == "color.cursor" || token.hasSuffix(".foreground")
        }
        return token.hasPrefix("color.text.") || token.hasPrefix("color.danger.") || token.hasSuffix(".foreground")
    }
}

/// Use exactly the same assignment routing as the renderer.
enum NativeCatalogAssignment {
    static func key(_ original: String, theme: any ThemeProtocol) -> String {
        let scoped = CatalogElementAssignments.childKey(original, family: (theme as? CatalogResolvedTheme).map { "component.library.\($0.family)" })
        return CatalogElementAssignments.routed(scoped, mappings: DesignThemeOverlay.shared.current()?.document.mappings ?? [:])
    }
    static func name(_ key: String) -> String {
        if key.hasPrefix("component.input.label.") { return "Field label above input" }
        if key.hasPrefix("component.input.helper.") { return "Helper text below input" }
        if key == "component.input.error.foreground" { return "Validation error below input" }
        if key == "component.input.text" { return "Input value and placeholder text" }
        if key == "component.input.placeholder" { return "Placeholder inside empty input" }
        let parts = key.split(separator: ".").map(String.init)
        let element = parts.count > 4 && parts[3] == "elements" ? parts[4] : "text"
        if parts.count > 2, parts[2] == "8" {
            if element == "chip" { return "AM/PM button" }
            if element == "container" { return "Date/time field" }
        }
        return ["heading": "Heading text", "label": "Control label", "body": "Body text", "supportingText": "Supporting text", "editor": "Editor text", "row": "Row content", "badge": "Badge", "chip": "Chip", "container": "Container", "codeBlock": "Code block", "input": "Input field"][element] ?? element.capitalized
    }
}
private struct NativeCatalogPreviewKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var nativeCatalogPreview: Bool {
        get { self[NativeCatalogPreviewKey.self] }
        set { self[NativeCatalogPreviewKey.self] = newValue }
    }
}
private struct NativeCatalogTarget: ViewModifier {
    @Environment(\.nativeCatalogPreview) private var active
    let keys: [String]
    let name: String
    @ViewBuilder func body(content: Content) -> some View {
        if active { content.catalogPreviewTarget(keys, name) } else { content }
    }
}
extension View {
    @ViewBuilder func nativeCatalogTarget(_ keys: [String], _ name: String) -> some View {
        modifier(NativeCatalogTarget(keys: keys, name: name))
    }
}

extension View {
    @ViewBuilder func nativeCatalogTextTarget(role: ThemeTextStyleRole, theme: any ThemeProtocol) -> some View {
        if let scoped = theme as? CatalogResolvedTheme {
            let property: String = switch role {
            case .heading, .title, .display: "heading"
            case .label: "label"
            case .caption, .footnote, .micro: "caption"
            case .code: "code"
            default: "text"
            }
            let key = NativeCatalogAssignment.key("component.library.\(scoped.family)." + property, theme: theme)
            nativeCatalogTarget([key], NativeCatalogAssignment.name(key))
        } else { self }
    }
}

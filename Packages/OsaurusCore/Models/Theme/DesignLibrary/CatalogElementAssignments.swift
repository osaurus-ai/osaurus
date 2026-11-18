import Foundation

/// Independent element assignments, initialized from the user's existing choices.
/// Legacy family keys remain readable for old snapshots and unmigrated app sites.
enum CatalogElementAssignments {
    static let properties: [String: [String]] = [
        "container": ["background","border","borderWidth","radius","padding","paddingY","gap","height","hover","selected","disabledBackground","error"],
        "row": ["background","border","borderWidth","radius","padding","gap","height","hover","selected","disabledBackground","disabledForeground","foreground","secondary","accent","label","text","caption"],
        "badge": ["background","selected","border","borderWidth","radius","gap","padding","caption","foreground","accent","success","warning","error","secondary"],
        "avatar": ["avatarSize","radius","selected","label","foreground","accent","gap","disabledForeground"],
        "editor": ["background","border","borderWidth","radius","padding","gap","text","label","foreground","accent","error","disabledForeground"],
        "chip": ["error","background","border","borderWidth","radius","padding","gap","height","hover","selected","label","text","caption","secondary","foreground","accent","disabledForeground"],
        "progress": ["selected","accent","error","caption","secondary","gap","trackHeight","thumbSize","foreground","radius","border","borderWidth","height","disabledForeground","disabledBackground","label"],
        "divider": ["border","borderWidth"],
        "image": ["radius","height","selected","background","border","borderWidth","padding","gap","accent","hover","disabledBackground"],
        "codeBlock": ["radius","padding","gap","background","selected","border","borderWidth","code","foreground","caption","secondary"],
        "switch": ["onBackground","offBackground","onForeground","offForeground","switchWidth","switchHeight","thumbSize","gap","radius","accent","label","foreground","border","borderWidth","disabledBackground","disabledForeground"],
        "checkbox": ["onBackground","offBackground","onForeground","indicatorSize","radius","border","borderWidth","gap","accent","label","foreground","disabledBackground","disabledForeground"],
        "heading": ["heading","foreground","disabledForeground"],
        "body": ["text","foreground","disabledForeground"],
        "supportingText": ["caption","secondary","foreground","disabledForeground"],
        "label": ["label","foreground","disabledForeground"],
        "emphasis": ["emphasis","foreground","disabledForeground"],
        "code": ["code","foreground","disabledForeground"]
    ]
    /// Compatibility routing for existing single-property app adapters. Dedicated
    /// row/badge/editor adapters pass explicit element keys instead.
    static func defaultElement(_ property: String) -> String {
        switch property {
        case "heading": return "heading"
        case "label": return "label"
        case "text", "foreground", "disabledForeground": return "body"
        case "caption", "secondary": return "supportingText"
        case "code": return "code"
        case "emphasis": return "emphasis"
        case "avatarSize": return "avatar"
        default: return "container"
        }
    }
    static func routed(_ original: String, mappings: [String:String]) -> String {
        // Old snapshots keep local overrides, but shared controls have one owner.
        if let range = original.range(of: ".elements.") {
            let child = String(original[range.upperBound...])
            if ["input.", "button.", "control.", "focus."].contains(where: { child.hasPrefix($0) }) {
                return "component." + child
            }
        }
        let parts = original.split(separator: ".")
        guard parts.count == 4, parts[0] == "component", parts[1] == "library" else { return original }
        let property = String(parts[3])
        let family = Int(parts[2])
        let element: String
        if [3, 21].contains(family ?? 0), properties["editor"]?.contains(property) == true { element = "editor" }
        else if family == 24, properties["chip"]?.contains(property) == true { element = "chip" }
        else if family == 32, property == "code" { element = "codeBlock" }
        else { element = defaultElement(property) }
        let candidate = key(parts.prefix(3).joined(separator: "."), element, property)
        return mappings[candidate] == nil ? original : candidate
    }
    static func key(_ family: String, _ element: String, _ property: String) -> String { family + ".elements." + element + "." + property }
    static func childKey(_ original: String, family: String?) -> String {
        // Product placement must never create another copy of a base style.
        original
    }
    static func extendMappings(_ mappings: [String:String]) -> [String:String] {
        var result = mappings
        for family in 3...55 {
            let prefix = "component.library.\(family)"
            // Retain legacy keys in the schema so old snapshots and experiments
            // round-trip unchanged. Rendering no longer reads these copies.
            for (old, role) in mappings where CatalogLayoutAssignments.byKey[old] == nil && ["component.input.", "component.button.", "component.control.", "component.focus."].contains(where: { old.hasPrefix($0) }) {
                let archived = prefix + ".elements." + old.dropFirst("component.".count)
                if result[archived] == nil { result[archived] = role }
            }
            for (element, names) in properties {
                for property in names where !(element == "chip" && property == "error") {
                    let new = key(prefix, element, property)
                    if result[new] == nil, let saved = mappings[prefix + "." + property] { result[new] = saved }
                }
            }
        }
        for (key, _, role) in modelPickerRowDefaults where mappings[key] == nil {
            result[key] = role
        }
        // New layout assignments inherit the previous gap without overwriting experiments.
        for name in ["columnGap", "rowGap", "sectionGap", "headingGap", "searchResultsGap"] {
            let key = "component.library.26.elements.layout." + name
            if result[key] == nil { result[key] = mappings["component.library.26.elements.container.gap"] ?? mappings["component.library.26.gap"] ?? "space.8" }
        }
        // Message layout boundaries are independent; seed from saved spacing.
        for (family, fields) in [(28, ["topGap", "attachmentTextGap", "editorActionsGap", "actionButtonsGap"]), (29, ["actionsGap"])] {
            for field in fields {
                let target = "component.library.\(family).elements.layout." + field
                if result[target] == nil {
                    result[target] = mappings["component.library.\(family).elements.container.gap"] ?? mappings["component.library.\(family).gap"] ?? "space.8"
                }
            }
        }
        // Move the existing settings section recipe into its base page without
        // modifying the old product assignments or resetting their saved values.
        for (old, role) in Array(result) where old.hasPrefix("component.library.46.") {
            let target = old.replacingOccurrences(of: "component.library.46.", with: "component.library.57.")
            if result[target] == nil { result[target] = role }
        }
        // Chips own shared variants; seed from existing saved styles once.
        // Legacy product assignments remain intact for snapshots and recovery.
        for variant in ["selector", "filter", "removable"] {
            for property in properties["chip"]! {
                let target = "component.library.56.elements.\(variant).\(property)"
                let legacy = variant == "selector" ? "component.library.23.elements.chip." : "component.library.10.elements.badge."
                let fallback = variant == "selector" ? "component.library.23." : "component.library.10."
                if result[target] == nil {
                    result[target] = mappings[legacy + property] ?? mappings[fallback + property]
                    if result[target] == nil, property == "label" { result[target] = mappings[fallback + "caption"] }
                }
            }
        }
        for size in ["regular", "small"] {
            for property in ["height", "padding", "gap", "label"] {
                let target = "component.library.56.elements.\(size).\(property)"
                if result[target] == nil {
                    let legacy = mappings["component.library.23.elements.chip." + property] ?? mappings["component.library.23." + property]
                    result[target] = target == regularChipHeight && legacy == "space.24" ? "size.control.compactHeight" : legacy
                }
            }
        }
        // Older snapshots inherit their existing thumb color, not a new design.
        for (key, role) in Array(result) where key.hasSuffix(".elements.switch.onForeground") {
            let off = String(key.dropLast("onForeground".count)) + "offForeground"
            if result[off] == nil { result[off] = role }
        }
        let quoteFill = key("component.library.18", "quote", "background")
        if result[quoteFill] == nil { result[quoteFill] = "color.surface.subtle" }
        return AgentContentSurfaceAssignments.extend(result)
    }
    static func migrate(_ document: DesignWorkingDocument) -> DesignWorkingDocument {
        var result = document
        result.mappings = extendMappings(document.mappings)
        // Earlier versions generated the same height for both sizes.
        if result.explicitAssignments?.contains(regularChipHeight) != true,
           result.mappings[regularChipHeight] == "space.24" {
            result.mappings[regularChipHeight] = "size.control.compactHeight"
        }
        // Only replace the previous stock roles. Explicit or custom choices stay in place.
        for (key, previous, role) in modelPickerRowDefaults
        where result.explicitAssignments?.contains(key) != true && result.mappings[key] == previous {
            result.mappings[key] = role
        }
        return result
    }

    private static let modelPickerRowDefaults = [
        ("component.library.26.elements.row.foreground", "color.text.secondary", "color.text.primary"),
        ("component.library.26.elements.row.text", "type.bodySmall", "type.caption")
    ]

    private static let regularChipHeight = "component.library.56.elements.regular.height"
}

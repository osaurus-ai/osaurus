import Foundation

/// The shipped library holds only assignments that paint: a mapping present means
/// the component reads it, an absent mapping means the component keeps its own recipe.
enum DesignLibraryPruning {
    /// Composite families keep the app's recipe for every property the designer
    /// did not edit, so their unedited gallery defaults never ship.
    static let recipeFamilies: Set<Int> = [10, 13, 14, 15, 16, 17, 57]
    /// Properties another owner sets: bubble text belongs to the rich-text body
    /// (family 31), and onboarding (55) sets each type role in its own ramp, so a
    /// family-wide recipe would flatten its greeting, titles and footnotes.
    static let delegatedProperties: [Int: Set<String>] = [
        28: ["heading", "label", "code"],
        29: ["label", "caption", "avatarSize", "secondary"],
        55: ["heading", "text", "caption"],
    ]
    /// Read directly by `CatalogResolvedTheme.radius` for every family.
    static let rowRadiusSuffix = ".elements.row.radius"

    static func pruned(_ document: DesignWorkingDocument, edited assignments: Set<String>, editedTokens: Set<String>) -> DesignWorkingDocument {
        let mappings = document.mappings
        let explicit = document.explicitAssignments ?? []
        var edited = assignments
        var delegated: Set<String> = []
        for (family, properties) in delegatedProperties {
            for property in properties {
                let legacy = "component.library.\(family).\(property)"
                delegated.insert(legacy)
                delegated.insert(CatalogElementAssignments.routed(legacy, mappings: mappings))
            }
        }
        // A legacy edit reaches the app through the element key it routes to.
        for key in assignments where key.split(separator: ".").count == 4 {
            let routed = CatalogElementAssignments.routed(key, mappings: mappings)
            if routed != key { edited.insert(routed) }
        }
        var kept: [String: String] = [:]
        for (key, role) in mappings {
            // Layout slots inherit the surrounding component until the designer sets one.
            if CatalogLayoutAssignments.byKey[key] != nil || key.contains(".elements.layout.") {
                if explicit.contains(key) { kept[key] = role }
                continue
            }
            let parts = key.split(separator: ".")
            guard parts.count > 3, parts[0] == "component", parts[1] == "library", let family = Int(parts[2]) else {
                kept[key] = role; continue
            }
            if CatalogElementAssignments.routed(key, mappings: mappings) != key || delegated.contains(key) { continue }
            if recipeFamilies.contains(family), !edited.contains(key), !key.hasSuffix(rowRadiusSuffix) { continue }
            kept[key] = role
        }
        var result = document
        result.mappings = kept
        result.explicitAssignments = explicit.filter { kept[$0] != nil }
        result.editedAssignments = edited.filter { kept[$0] != nil }
        result.editedTokens = editedTokens
        return result
    }
}

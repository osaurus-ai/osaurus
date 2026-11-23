import SwiftUI

/// Component assignment resolver for the real SettingsButtonStyle. Values come
/// from the working semantic document that also builds the app's typed themes.
enum DesignButtonBindings {
    /// Additive Figma size assignments. Legacy button assignments remain untouched.
    static var libraryDefaults: [String: String] {
        var result: [String: String] = [:]
        for (size, height, padding, label) in [
            ("default", "size.control.defaultHeight", "space.8", "type.label"),
            ("small", "size.control.compactHeight", "space.8", "type.label"),
            ("extraSmall", "space.24", "space.6", "type.caption"),
            ("extraExtraSmall", "space.16", "space.4", "type.caption")
        ] {
            let prefix = "component.button.size.\(size)."
            for (property, token) in ["height":height, "paddingX":padding, "paddingY":"space.0",
                "label":label, "gap":"space.8", "minimumLabelWidth":"space.40",
                "radius":"radius.medium", "borderWidth":"stroke.none"] {
                result[prefix + property] = token
            }
        }
        for state in ["default", "hover", "pressed", "disabled"] {
            for property in ["background", "foreground", "border"] {
                result["component.button.brand.\(state).\(property)"] = "color.action.brand.\(state).\(property)"
            }
            result["component.button.brand.\(state).effect"] = "effect.elevation.none"
        }
        result["component.button.brand.focus.color"] = "color.border.focus"
        return result
    }

    static func role(_ key:String)->String {
        guard let mappings = DesignThemeOverlay.shared.current()?.document.mappings else { return key }
        return mappings[CatalogElementAssignments.routed(key, mappings: mappings)] ?? key
    }
    static func value(_ key:String,theme:any ThemeProtocol)->JSONValue? {
        let isDark = theme.isDark
        let familyID = (theme as? CatalogResolvedTheme)?.family
        let family = familyID.map { "component.library.\($0)" }
        let compute: (DesignThemeSnapshot?) -> JSONValue? = { snapshot in
            resolve(key, family: family, isDark: isDark, snapshot: snapshot)
        }
        let memoKey = DesignThemeOverlay.MemoKey(property: key, family: familyID ?? -1, flags: isDark ? 2 : 0, kind: 10)
        return DesignThemeOverlay.shared.memoized(memoKey, compute)
    }
    private static func resolve(_ key:String,family:String?,isDark:Bool,snapshot:DesignThemeSnapshot?)->JSONValue? {
        let scopedKey = CatalogElementAssignments.childKey(key, family: family)
        let resolvedKey = snapshot?.document.mappings[scopedKey] == nil ? key : scopedKey
        let token=snapshot?.document.tokens[role(resolvedKey)]
        return isDark ? token?.dark : token?.light
    }
    static func color(_ key:String,theme:any ThemeProtocol,fallback:Color)->Color {
        guard case .string(let hex)?=value(key,theme:theme) else {return fallback}
        return Color(themeHex:hex)
    }
    // A role-specific assignment overrides the shared ring only when explicitly
    // changed from the catalog default. The preview uses the same resolution.
    static func focusColor(_ kind: ThemeActionKind, theme: any ThemeProtocol) -> Color {
        let key = "component.button.\(kind.rawValue).focus.color"
        let assigned = role(key)
        return color(assigned == "color.border.focus" || assigned == key ? "component.focus.color" : key,
                     theme: theme, fallback: theme.border.focus)
    }
    static func dimension(_ key:String,theme:any ThemeProtocol,fallback:Double)->Double {
        value(key,theme:theme)?.designNumber ?? fallback
    }
    static func textRole(compact:Bool)->ThemeTextStyleRole {
        let name=role(compact ? "component.button.compactLabel" : "component.button.label")
        return ThemeTextStyleRole(rawValue:String(name.dropFirst("type.".count))) ?? (compact ? .caption : .label)
    }
    static func state(_ theme:any ThemeProtocol,kind:ThemeActionKind,interaction:ThemeActionInteraction,fallback:ThemeActionState<Color>)->ThemeActionState<Color> {
        let prefix="component.button.\(kind.rawValue).\(interaction.rawValue)."
        return ThemeActionState(background:color(prefix+"background",theme:theme,fallback:fallback.background),foreground:color(prefix+"foreground",theme:theme,fallback:fallback.foreground))
    }
}

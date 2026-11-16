import AppKit
import Foundation
import CryptoKit

struct DesignToken: Codable, Equatable, Sendable {
    var type: String
    var light: JSONValue
    var dark: JSONValue
    var use: String
    subscript(_ mode: String) -> JSONValue {
        get { mode == "dark" ? dark : light }
        set { if mode == "dark" { dark = newValue } else { light = newValue } }
    }
}
struct DesignTokenSpecification: Codable { var semanticTokens: [String: DesignToken] }
struct DesignMappingSpecification: Codable { var mappings: [String: String] }
struct DesignWorkingDocument: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var sourceRevision: String
    var baselineSHA256: String
    var tokens: [String: DesignToken]
    var mappings: [String: String]
    var primitives: [String: DesignPrimitiveColor]? = nil
    var colorAliases: [String: DesignColorAlias]? = nil
    var primitiveSource: String? = nil
    var scalarPrimitives: [String: DesignScalarPrimitive]? = nil
    var valueAliases: [String: DesignColorAlias]? = nil
    var figmaSource: JSONValue? = nil
    // Records deliberate selections even when the chosen token equals an old default.
    var explicitAssignments: Set<String>? = nil
    /// Assignments and tokens that differ from the handoff baseline. Stored so the
    /// shipped app never needs the baseline to know what the designer changed.
    var editedAssignments: Set<String>? = nil
    var editedTokens: Set<String>? = nil
}
struct DesignThemeSnapshot: Sendable {
    let generation = UUID().uuidString
    let light: CustomTheme
    let dark: CustomTheme
    let document: DesignWorkingDocument
    let changedTokens: Set<String>
}
/// Immutable value snapshots are read by nonisolated theme construction; mutation
/// stays on the main actor. No view or production persistence lives in this bridge.
final class DesignThemeOverlay: @unchecked Sendable {
    struct MemoKey: Hashable {
        let property: String
        let family: Int
        let flags: Int
        let kind: Int
    }
    static let shared = DesignThemeOverlay()
    private let lock = NSLock()
    private var snapshot: DesignThemeSnapshot? = DesignLibraryRuntime.bundledSnapshot()
    private var revision = 0
    private var memo: [MemoKey: Any] = [:]
    func install(_ value: DesignThemeSnapshot) {
        lock.lock(); snapshot = value; revision += 1; memo.removeAll(); lock.unlock()
    }
    func current() -> DesignThemeSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
    /// A value derived only from the installed snapshot, computed once per
    /// snapshot. Scoped theme reads run in every view body, so resolving
    /// them afresh each time costs whole frames.
    func memoized<Value>(_ key: MemoKey, _ compute: (DesignThemeSnapshot?) -> Value) -> Value {
        lock.lock()
        // Unwrap before casting: a missing `Any?` entry casts to any optional
        // `Value` as a nil hit.
        if let entry = memo[key], let hit = entry as? Value { lock.unlock(); return hit }
        let current = snapshot, seen = revision
        lock.unlock()
        let value = compute(current)
        lock.lock()
        if revision == seen { memo[key] = value }
        lock.unlock()
        return value
    }
    func resolve(_ original: CustomTheme) -> CustomTheme {
        guard let value = current() else { return original }
        var result = original.isDark ? value.dark : value.light
        // Keep product preferences and attribution from the actual app theme.
        result.metadata = original.metadata
        result.messages = original.messages
        return result
    }
}

enum DesignWorkingError: LocalizedError {
    case incompatible, invalid(String)
    var errorDescription: String? {
        switch self { case .incompatible: return "Snapshot schema, source or baseline does not match this development build."
        case .invalid(let field): return "Invalid design value: \(field)" }
    }
}
extension JSONValue {
    var designString: String? { if case .string(let s) = self { return s }; return nil }
    var designNumber: Double? { if case .number(let n) = self { return n }; return nil }
    var designObject: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    mutating func designSet(_ path: [String], _ value: JSONValue) {
        guard let head = path.first else { self = value; return }
        var object = designObject ?? [:]; var child = object[head] ?? .object([:])
        child.designSet(Array(path.dropFirst()), value); object[head] = child; self = .object(object)
    }
}

enum DesignLibraryDefinition {
    static let revision = "00ba05e7f77bc120bb90fc164cb2a0705599ea00"
    static func baseline(tokenData: Data, mappingData: Data, primitiveData: Data?) throws -> (legacy: DesignWorkingDocument, current: DesignWorkingDocument) {
        let spec = try JSONDecoder().decode(DesignTokenSpecification.self, from: tokenData)
        var maps = try JSONDecoder().decode(DesignMappingSpecification.self, from: mappingData).mappings
        // These layout references extend the handoff; they introduce no colors or primitive palette.
        maps.merge([
            "component.button.paddingX":"space.16", "component.button.paddingY":"space.6",
            "component.button.minimumHeight":"size.control.defaultHeight",
            "component.button.compactLabel":"type.caption", "component.button.compactPaddingX":"space.12",
            "component.button.compactPaddingY":"space.4", "component.button.compactHeight":"size.control.compactHeight",
            "component.button.focus.width":"stroke.focus", "component.button.focus.offset":"focus.offset"
        ]) { original, _ in original }
        for kind in ["primary", "secondary", "tertiary", "destructive"] {
            for state in ["default", "hover", "pressed", "disabled"] { maps["component.button.\(kind).\(state).effect"] = "effect.elevation.none" }
        }
        maps["component.input.effect"] = "effect.elevation.none"
        maps.merge(DesignButtonBindings.libraryDefaults) { original, _ in original }
        maps.merge(DesignLibraryDefaults.inputDefaults) { original, _ in original }
        for spec in CatalogcomponentCatalog where spec.id > 2 {
            maps.merge(spec.defaults) { original, _ in original }
        }
        maps = CatalogElementAssignments.extendMappings(maps)
        let fingerprint = SHA256.hash(data: tokenData + mappingData).map { String(format: "%02x", $0) }.joined()
        var baseline = DesignWorkingDocument(sourceRevision: revision, baselineSHA256: fingerprint, tokens: spec.semanticTokens, mappings: maps)
        let legacyBaseline = baseline
        baseline = DesignTypographyTokens.extend(baseline)
        if let primitiveData {
            let seed = try JSONDecoder().decode(DesignPrimitiveSeed.self, from: primitiveData)
            baseline.schemaVersion = 2
            baseline.primitives = seed.primitives; baseline.colorAliases = seed.aliases
            baseline.primitiveSource = seed.source
            baseline = try baseline.resolvingColors()
        }
        baseline = try DesignFigmaSync.baseline(baseline)
        // User-approved library extension, separate from the historical Figma import.
        // The same tuned neutral primitive resolves to a light surface in Dark
        // and a dark surface in Light. Existing saved aliases win on upgrade.
        baseline.tokens["color.surface.inverse"] = DesignToken(type: "color",
            light: .string("#181816FF"), dark: .string("#FBFAF9FF"),
            use: "Opaque inverse surface: dark in Light mode, light in Dark mode. Pair with color.text.inverse. Backed by neutral/900 independently in each appearance.")
        if baseline.colorAliases == nil { baseline.colorAliases = [:] }
        baseline.colorAliases?["color.surface.inverse"] = DesignColorAlias(light: "neutral/900", dark: "neutral/900")
        baseline = try baseline.resolvingColors()
        for name in ["color.surface.none", "color.border.none"] {
            baseline.tokens[name] = DesignToken(type:"color", light:.string("#00000000"), dark:.string("#00000000"), use:name == "color.surface.none" ? "No background fill. Explicitly removes the assigned surface in both appearances; does not add glass or material." : "No visible border. Explicitly removes the assigned stroke in both appearances.")
        }
        // Approved control-only boundaries: decorative outlines retain their recipes.
        for (name, light, dark, use) in [
            ("color.border.control", "neutral/500", "neutral/200", "Input, select, editor and switch boundaries; independent of decorative dividers."),
            ("color.status.urgentWarning.background", "amber/300", "amber/100", "Stronger warning surface for an immediate risk or irreversible action."),
            ("color.status.urgentWarning.foreground", "amber/600", "amber/500", "Readable text and icon color on the urgent warning surface."),
            ("color.status.urgentWarning.border", "amber/200", "amber/200", "Border of the urgent warning surface."),
            ("color.border.controlHover", "neutral/500", "neutral/600", "Hovered input boundary, distinct from its resting stroke and keyboard focus."),
            ("color.border.controlCheck", "neutral/500", "neutral/300", "Checkbox boundary; preserves its independent Dark-mode outline."),
            ("color.control.offIndicator", "neutral/700", "neutral/50", "Off-state switch thumb; independent of the on-state indicator.")
        ] {
            baseline.tokens[name] = DesignToken(type: "color", light: .string("#000000FF"), dark: .string("#000000FF"), use: use)
            baseline.colorAliases?[name] = DesignColorAlias(light: light, dark: dark)
        }
        baseline.colorAliases?["color.status.warning.background"]?.light = "amber/50"
        baseline = try baseline.resolvingColors()
        return (legacyBaseline, baseline)
    }
    /// The editor's full working document, pruned to what paints against its baseline.
    static func pruned(_ candidate: DesignWorkingDocument, baseline: DesignWorkingDocument) -> DesignWorkingDocument {
        DesignLibraryPruning.pruned(candidate,
            edited: Set(candidate.mappings.compactMap { baseline.mappings[$0.key] != $0.value ? $0.key : nil }).union(candidate.explicitAssignments ?? []),
            editedTokens: Set(candidate.tokens.compactMap { key, value in baseline.tokens[key] != value ? key : nil }))
    }
    static func makeSnapshot(_ candidate: DesignWorkingDocument, baseline: DesignWorkingDocument) throws -> DesignThemeSnapshot {
        try makeSnapshot(pruned(candidate, baseline: baseline))
    }
    /// A pruned document carries its own edit record; no baseline is needed to paint it.
    static func makeSnapshot(_ document: DesignWorkingDocument) throws -> DesignThemeSnapshot {
        DesignThemeSnapshot(light: try resolve(document, mode: "light"), dark: try resolve(document, mode: "dark"), document: document,
            changedTokens: document.editedTokens ?? [])
    }
    private static func resolve(_ doc: DesignWorkingDocument, mode: String) throws -> CustomTheme {
        let base = mode == "dark" ? CustomTheme.darkDefault : CustomTheme.lightDefault
        var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(base))
        for (name, token) in doc.tokens {
            let value = token[mode]
            if name.hasPrefix("type."), case .object(var recipe) = value {
                let family = recipe["family"]?.designString ?? "system"
                recipe["family"] = .string(family == "systemMonospaced" ? "code" : "ui")
                recipe["familyName"] = ["system", "systemMonospaced"].contains(family) ? .null : .string(family)
                json.designSet(["typography","styles",String(name.dropFirst(5))], .object(recipe))
            } else if let path = Self.path(for:name) { json.designSet(path, value) }
        }
        return try JSONDecoder().decode(CustomTheme.self, from: JSONEncoder().encode(json))
    }
    static func path(for role: String) -> [String]? {
        let parts = role.split(separator:".").map(String.init)
        if role.hasPrefix("color.") {
            if role == "color.chat.user.background" { return ["colors","chat","userBackground"] }
            if role == "color.chat.assistant.background" { return ["colors","chat","assistantBackground"] }
            return ["colors"] + parts.dropFirst()
        }
        if role.hasPrefix("font.family.") { return ["typography","families",parts.last!] }
        if role.hasPrefix("material.window.") { return ["windowMaterial"] + parts.dropFirst(2) }
        if role == "focus.offset" { return ["focusOffset"] }
        if role.hasPrefix("space.") { return ["space","s" + parts.last!] }
        if role.hasPrefix("size.control.") { return ["controlSize",parts.last!] }
        if role == "size.row.minimumHeight" { return ["controlSize","rowMinimumHeight"] }
        if role == "size.chat.avatar" { return ["controlSize","chatAvatar"] }
        if role.hasPrefix("motion.duration.") { return ["motion","duration" + parts.last!.capitalized] }
        if let effect = ThemeEffectRole(token: role) { return ["effects", effect.rawValue] }
        if ["radius","stroke","motion","elevation"].contains(parts.first ?? "") { return parts }
        return nil
    }
}

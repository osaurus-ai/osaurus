#if OSAURUS_DESIGN_SYSTEM
import Foundation

struct DesignScalarPrimitive: Codable, Equatable, Sendable {
    var light: JSONValue
    var dark: JSONValue
    subscript(_ mode: String) -> JSONValue {
        get { mode == "dark" ? dark : light }
        set { if mode == "dark" { dark = newValue } else { light = newValue } }
    }
}
struct DesignFigmaSeed: Codable {
    var source: JSONValue
    var tokens: [String: DesignToken]
    var primitives: [String: DesignPrimitiveColor]
    var colorAliases: [String: DesignColorAlias]
    var scalarPrimitives: [String: DesignScalarPrimitive]
    var valueAliases: [String: DesignColorAlias]
}
enum DesignFigmaSync {
    static func baseline(_ original: DesignWorkingDocument) throws -> DesignWorkingDocument {
        guard let url = Bundle.module.url(forResource: "figma-sync", withExtension: "json", subdirectory: "LibraryResources") else { return original }
        let seed = try JSONDecoder().decode(DesignFigmaSeed.self, from: Data(contentsOf: url))
        var doc = original
        doc.tokens.merge(seed.tokens) { _, new in new }
        doc.primitives = (doc.primitives ?? [:]).merging(seed.primitives) { _, new in new }
        doc.colorAliases = (doc.colorAliases ?? [:]).merging(seed.colorAliases) { _, new in new }
        doc.scalarPrimitives = seed.scalarPrimitives
        doc.valueAliases = seed.valueAliases
        doc.figmaSource = seed.source
        doc.primitiveSource = seed.source.designObject?["url"]?.designString
        return try doc.resolvingColors()
    }
    /// One-time authorized Figma sync. Old snapshots retain their stored recipes;
    /// missing definitions are added so they remain loadable in the extended editor.
    static func upgrade(_ original: DesignWorkingDocument, baseline: DesignWorkingDocument, importValues: Bool = true) throws -> DesignWorkingDocument {
        guard baseline.figmaSource != nil else { return original }
        var doc = original
        let applying = importValues && doc.figmaSource == nil
        doc.tokens.merge(baseline.tokens) { old, new in applying ? new : old }
        doc.primitives = (doc.primitives ?? [:]).merging(baseline.primitives ?? [:]) { old, new in applying ? new : old }
        doc.colorAliases = (doc.colorAliases ?? [:]).merging(baseline.colorAliases ?? [:]) { old, new in applying ? new : old }
        if applying {
            doc.scalarPrimitives = baseline.scalarPrimitives
            doc.valueAliases = baseline.valueAliases
        } else if doc.scalarPrimitives == nil {
            // Preserve snapshot experiments by creating local scalar values for their bindings.
            doc.scalarPrimitives = baseline.scalarPrimitives
            doc.valueAliases = baseline.valueAliases
            for (path, alias) in doc.valueAliases ?? [:] {
                for mode in ["light", "dark"] {
                    if let value = original.valueAtPath(path, mode: mode) {
                        let ref = "saved/" + path + "/" + mode
                        doc.scalarPrimitives?[ref] = DesignScalarPrimitive(light: value, dark: value)
                        doc.valueAliases?[path]?[mode] = ref
                    }
                }
            }
        }
        // Add bindings only for newly introduced tokens. Existing recipes and
        // primitive experiments must not be overwritten by a library expansion.
        doc.scalarPrimitives = (doc.scalarPrimitives ?? [:]).merging(baseline.scalarPrimitives ?? [:]) { old, _ in old }
        for (path, alias) in baseline.valueAliases ?? [:] where doc.valueAliases?[path] == nil {
            if let (token, _) = baseline.pathParts(path), original.tokens[token] == nil {
                if doc.valueAliases == nil { doc.valueAliases = [:] }
                doc.valueAliases?[path] = alias
            }
        }
        doc.figmaSource = baseline.figmaSource
        doc.primitiveSource = baseline.primitiveSource
        return try doc.resolvingColors()
    }
}
extension DesignWorkingDocument {
    func pathParts(_ path: String) -> (String, [String])? {
        guard let token = tokens.keys.filter({ path == $0 || path.hasPrefix($0 + ".") }).max(by: { $0.count < $1.count }) else { return nil }
        return (token, path == token ? [] : String(path.dropFirst(token.count + 1)).split(separator: ".").map(String.init))
    }
    func valueAtPath(_ path: String, mode: String) -> JSONValue? {
        guard let (key, parts) = pathParts(path), let value = tokens[key]?[mode] else { return nil }
        return value.figmaValue(parts)
    }
    mutating func setValueAtPath(_ path: String, mode: String, value: JSONValue) throws {
        guard let (key, parts) = pathParts(path), var token = tokens[key] else { throw DesignWorkingError.invalid(path) }
        var recipe = token[mode]
        try recipe.figmaSet(parts, value)
        token[mode] = recipe; tokens[key] = token
    }
    mutating func updateBoundValue(_ path: String, mode: String, value: JSONValue) {
        guard let ref = valueAliases?[path]?[mode], !ref.isEmpty else { return }
        scalarPrimitives?[ref]?[mode] = value
    }
}
extension JSONValue {
    func figmaValue(_ path: [String]) -> JSONValue? {
        guard let head = path.first else { return self }
        if case .array(let values) = self, let i = Int(head), values.indices.contains(i) { return values[i].figmaValue(Array(path.dropFirst())) }
        return designObject?[head]?.figmaValue(Array(path.dropFirst()))
    }
    mutating func figmaSet(_ path: [String], _ value: JSONValue) throws {
        guard let head = path.first else { self = value; return }
        if case .array(var values) = self, let i = Int(head), values.indices.contains(i) {
            try values[i].figmaSet(Array(path.dropFirst()), value); self = .array(values)
        } else if case .object(var values) = self, var child = values[head] {
            try child.figmaSet(Array(path.dropFirst()), value); values[head] = child; self = .object(values)
        } else { throw DesignWorkingError.invalid(path.joined(separator: ".")) }
    }
}
#endif

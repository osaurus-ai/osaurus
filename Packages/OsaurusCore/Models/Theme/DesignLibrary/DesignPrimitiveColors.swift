import Foundation

struct DesignPrimitiveColor: Codable, Equatable, Sendable {
    var light: String
    var dark: String
    subscript(_ mode: String) -> String {
        get { mode == "dark" ? dark : light }
        set { if mode == "dark" { dark = newValue } else { light = newValue } }
    }
}
struct DesignColorAlias: Codable, Equatable, Sendable {
    var light: String? = nil
    var dark: String? = nil
    subscript(_ mode: String) -> String {
        get { (mode == "dark" ? dark : light) ?? "" }
        set { if mode == "dark" { dark = newValue } else { light = newValue } }
    }
}
struct DesignPrimitiveSeed: Codable {
    let source: String
    let retrievedAt: String
    let primitives: [String: DesignPrimitiveColor]
    let aliases: [String: DesignColorAlias]
}
extension DesignWorkingDocument {
    static func canonicalHex(_ hex: String) -> String {
        let value = hex.uppercased()
        return value.count == 7 ? value + "FF" : value
    }
    func colorValue(_ path: String, mode: String) -> JSONValue? { valueAtPath(path, mode: mode) }
    mutating func setColorValue(_ path: String, mode: String, hex: String) throws {
        try setValueAtPath(path, mode: mode, value: .string(hex))
    }
    func resolvingColors() throws -> Self {
        var resolved = self
        for (name, value) in primitives ?? [:] {
            for mode in ["light", "dark"] {
                guard value[mode].range(of: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$", options: .regularExpression) != nil else { throw DesignWorkingError.invalid("Primitive " + name) }
            }
        }
        func color(_ path: String, _ mode: String, _ visited: Set<String> = []) throws -> String {
            guard !visited.contains(path) else { throw DesignWorkingError.invalid("Alias cycle: " + path) }
            let ref = colorAliases?[path]?[mode] ?? ""
            if ref.hasPrefix("@") { return try color(String(ref.dropFirst()), mode, visited.union([path])) }
            if !ref.isEmpty, let value = primitives?[ref] { return value[mode] }
            if ref.isEmpty, let value = valueAtPath(path, mode: mode)?.designString { return value }
            throw DesignWorkingError.invalid("Missing primitive: " + ref)
        }
        for (path, alias) in colorAliases ?? [:] {
            for mode in ["light", "dark"] where !alias[mode].isEmpty {
                try resolved.setColorValue(path, mode: mode, hex: color(path, mode))
            }
        }
        for (path, alias) in valueAliases ?? [:] {
            for mode in ["light", "dark"] where !alias[mode].isEmpty {
                guard let value = scalarPrimitives?[alias[mode]]?[mode] else { throw DesignWorkingError.invalid("Missing value primitive: " + alias[mode]) }
                try resolved.setValueAtPath(path, mode: mode, value: value)
            }
        }
        return resolved
    }
}

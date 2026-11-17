//
//  ThemeTokenPolicy.swift
//  osaurus
//
//  The single validator for theme overrides, used by the editor, import and
//  the JSON editor. Unknown keys and wrong types are errors that name their
//  line; out-of-range values are clamped with a warning.
//

import Foundation

public struct ThemePolicyFinding: Equatable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    public var message: String
    /// The token or JSON key the finding is about.
    public var key: String?
    /// 1-based line in the JSON source, when known.
    public var line: Int?

    public var id: String { "\(severity.rawValue)|\(key ?? "")|\(line ?? 0)|\(message)" }

    public init(severity: Severity, message: String, key: String? = nil, line: Int? = nil) {
        self.severity = severity
        self.message = message
        self.key = key
        self.line = line
    }
}

/// The outcome of validating a theme's JSON text.
public struct ThemeJSONValidation: Sendable {
    /// The decoded document with overrides clamped; nil when an error blocks it.
    public var document: ThemeDocument?
    public var findings: [ThemePolicyFinding]

    public var hasErrors: Bool { findings.contains { $0.severity == .error } }
}

enum ThemeTokenPolicy {
    /// How a token's override value is checked.
    enum Rule: Equatable {
        case color
        case number(ClosedRange<Double>)
        case fontFamily
        case typography
        case choice([String])
        case spring
        case radiusShape
    }

    static let typeSizeRange: ClosedRange<Double> = 11 ... 32
    static let bodyMinimumSize: Double = 12
    static let lineHeightFactor: ClosedRange<Double> = 1.1 ... 1.8
    static let weightRange: ClosedRange<Double> = 100 ... 900
    static let typographyFields: Set<String> = ["size", "lineHeight", "weight"]

    /// The policy for a token, or nil when it may never be overridden.
    static func rule(for key: String) -> Rule? {
        if key.hasPrefix("color.") {
            if key.hasPrefix("color.status.") || key.hasPrefix("color.data.") { return nil }
            return .color
        }
        switch key {
        case "material.window.tint", "material.window.fallback": return .color
        case "material.window.tintOpacity": return .number(0 ... 1)
        case "material.window.nativeMaterial": return .choice(ThemeNativeMaterial.allCases.map(\.rawValue))
        case "material.window.blending": return .choice(ThemeWindowBlending.allCases.map(\.rawValue))
        case "font.family.ui", "font.family.code": return .fontFamily
        case "stroke.default", "stroke.focus": return .number(0.5 ... 4)
        case "radius.pill": return .radiusShape
        case "size.control.defaultHeight", "size.control.compactHeight": return .number(24 ... 48)
        case "size.row.minimumHeight": return .number(24 ... 56)
        case "size.chat.avatar": return .number(16 ... 40)
        case "motion.spring": return .spring
        case "motion.easing": return .choice(["linear", "easeIn", "easeOut", "easeInOut"])
        default: break
        }
        if key.hasPrefix("type.") { return .typography }
        if key.hasPrefix("radius.") { return .number(0 ... 20) }
        if key.hasPrefix("motion.duration.") { return .number(0 ... 0.6) }
        return nil
    }

    /// Every token a theme may override, in the bundled library.
    static func overridableKeys(in base: DesignWorkingDocument) -> [String] {
        base.tokens.keys.filter { rule(for: $0) != nil }.sorted()
    }

    // MARK: - Overrides

    /// Validates and clamps overrides. Errors drop the offending token;
    /// `source` is the JSON text, used to name lines.
    static func sanitize(
        _ overrides: ThemeOverrides?, base: DesignWorkingDocument, source: String? = nil
    ) -> (overrides: ThemeOverrides, findings: [ThemePolicyFinding]) {
        guard let overrides else { return (ThemeOverrides(), []) }
        var clean = ThemeOverrides()
        var findings: [ThemePolicyFinding] = []
        for key in overrides.tokens.keys.sorted() {
            let line = source.flatMap { lineNumber(of: "\"\(key)\"", in: $0) }
            func report(_ severity: ThemePolicyFinding.Severity, _ message: String) {
                findings.append(ThemePolicyFinding(severity: severity, message: message, key: key, line: line))
            }
            guard let token = base.tokens[key] else {
                report(.error, L("Unknown token \"\(key)\"."))
                continue
            }
            guard let rule = rule(for: key) else {
                report(.error, L("\"\(key)\" can't be changed by a theme."))
                continue
            }
            let entry = overrides.tokens[key]!
            var cleanEntry = ThemeTokenOverride()
            var failed = false
            for mode in ThemeGenerator.modes {
                guard let value = entry[mode] else { continue }
                switch check(value, rule: rule, key: key, base: token[mode]) {
                case .ok(let v):
                    cleanEntry[mode] = v
                case .clamped(let v, let message):
                    cleanEntry[mode] = v
                    report(.warning, message)
                case .invalid(let message):
                    report(.error, message)
                    failed = true
                }
            }
            if !failed, cleanEntry.light != nil || cleanEntry.dark != nil { clean.tokens[key] = cleanEntry }
        }
        // A clamp applied to both modes is reported once.
        var seen = Set<String>()
        findings = findings.filter { seen.insert($0.id).inserted }
        return (clean, findings)
    }

    private enum Check {
        case ok(JSONValue)
        case clamped(JSONValue, String)
        case invalid(String)
    }

    private static func check(_ value: JSONValue, rule: Rule, key: String, base: JSONValue) -> Check {
        switch rule {
        case .color:
            guard let hex = value.designString, ThemeColorMath.rgb(hex: hex) != nil else {
                return .invalid(L("\"\(key)\" needs a color like \"#1A2B3C\"."))
            }
            return .ok(.string(hex))
        case .number(let range):
            guard let n = value.designNumber, n.isFinite else {
                return .invalid(L("\"\(key)\" needs a number."))
            }
            return clamp(n, to: range, key: key).map { .clamped(.number($0.0), $0.1) } ?? .ok(.number(n))
        case .fontFamily:
            guard let name = value.designString?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return .invalid(L("\"\(key)\" needs a font family name."))
            }
            return .ok(.string(name))
        case .choice(let options):
            guard let s = value.designString, options.contains(s) else {
                return .invalid(L("\"\(key)\" must be one of: \(options.joined(separator: ", "))."))
            }
            return .ok(.string(s))
        case .radiusShape:
            if value.designString == "capsule" { return .ok(value) }
            return check(value, rule: .number(0 ... 20), key: key, base: base)
        case .spring:
            guard case .object(let object) = value else {
                return .invalid(L("\"\(key)\" needs { \"response\": …, \"dampingFraction\": … }."))
            }
            var result = base.designObject ?? [:]
            var warnings: [String] = []
            for (field, n) in object {
                let range: ClosedRange<Double>
                switch field {
                case "response": range = 0 ... 0.6
                case "dampingFraction": range = 0.1 ... 1
                default: return .invalid(L("\"\(key)\" has an unknown field \"\(field)\"."))
                }
                guard let number = n.designNumber, number.isFinite else {
                    return .invalid(L("\"\(key).\(field)\" needs a number."))
                }
                if let (c, message) = clamp(number, to: range, key: "\(key).\(field)") {
                    result[field] = .number(c)
                    warnings.append(message)
                } else {
                    result[field] = .number(number)
                }
            }
            return warnings.isEmpty ? .ok(.object(result)) : .clamped(.object(result), warnings.joined(separator: " "))
        case .typography:
            guard case .object(let object) = value else {
                return .invalid(L("\"\(key)\" needs { \"size\": …, \"lineHeight\": …, \"weight\": … }."))
            }
            for field in object.keys where !typographyFields.contains(field) {
                return .invalid(L("\"\(key)\" can only change size, lineHeight and weight, not \"\(field)\"."))
            }
            var numbers: [String: Double] = [:]
            for (field, n) in object {
                guard let number = n.designNumber, number.isFinite else {
                    return .invalid(L("\"\(key).\(field)\" needs a number."))
                }
                numbers[field] = number
            }
            let style = String(key.dropFirst(5))
            var warnings: [String] = []
            var result: [String: JSONValue] = [:]
            let baseSize = base.designObject?["size"]?.designNumber ?? 13
            let baseLine = base.designObject?["lineHeight"]?.designNumber ?? baseSize
            var size = numbers["size"] ?? baseSize
            if numbers["size"] != nil {
                let lower = ThemeGenerator.bodyStyles.contains(style) || style == "caption" ? bodyMinimumSize : typeSizeRange.lowerBound
                if let (c, message) = clamp(size, to: lower ... typeSizeRange.upperBound, key: "\(key).size") {
                    size = c
                    warnings.append(message)
                }
                result["size"] = .number(size)
            }
            if var line = numbers["lineHeight"] {
                let range = (size * lineHeightFactor.lowerBound).rounded(.up) ... (size * lineHeightFactor.upperBound).rounded(.down)
                if let (c, message) = clamp(line, to: range, key: "\(key).lineHeight") {
                    line = c
                    warnings.append(message)
                }
                result["lineHeight"] = .number(line)
            } else if numbers["size"] != nil, baseSize > 0 {
                result["lineHeight"] = .number((baseLine * size / baseSize).rounded())
            }
            if var weight = numbers["weight"] {
                if let (c, message) = clamp(weight, to: weightRange, key: "\(key).weight") {
                    weight = c
                    warnings.append(message)
                }
                result["weight"] = .number((weight / 100).rounded() * 100)
            }
            return warnings.isEmpty ? .ok(.object(result)) : .clamped(.object(result), warnings.joined(separator: " "))
        }
    }

    private static func clamp(_ n: Double, to range: ClosedRange<Double>, key: String) -> (Double, String)? {
        guard !range.contains(n) else { return nil }
        let c = min(max(n, range.lowerBound), range.upperBound)
        return (c, L("\"\(key)\" was \(format(n)); clamped to \(format(c)) (allowed \(format(range.lowerBound))–\(format(range.upperBound)))."))
    }

    private static func format(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%g", n)
    }

    // MARK: - JSON

    private static let documentKeys: Set<String> = [
        "schemaVersion", "id", "name", "author", "createdAt", "updatedAt", "appearance", "preferences", "overrides",
        "codeHighlightTheme", "messages",
    ]
    private static let preferenceKeys: Set<String> = ["accent", "tone", "contrast", "corners", "readability"]
    private static let readabilityKeys: Set<String> = [
        "uiFont", "codeFont", "readingSize", "lineSpacing", "strongerOutlines", "largerControls",
    ]
    private static let tokenModeKeys: Set<String> = ["light", "dark"]

    /// Parses, checks keys and types, then clamps overrides.
    static func validateJSON(_ text: String, base: DesignWorkingDocument) -> ThemeJSONValidation {
        let data = Data(text.utf8)
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return ThemeJSONValidation(
                document: nil,
                findings: [ThemePolicyFinding(severity: .error, message: syntaxMessage(error), line: syntaxLine(error))]
            )
        }
        guard let root = raw as? [String: Any] else {
            return ThemeJSONValidation(
                document: nil, findings: [ThemePolicyFinding(severity: .error, message: L("A theme must be a JSON object."), line: 1)]
            )
        }
        var findings: [ThemePolicyFinding] = []
        func unknown(_ keys: some Sequence<String>, allowed: Set<String>, scope: String) {
            for key in keys where !allowed.contains(key) {
                findings.append(
                    ThemePolicyFinding(
                        severity: .error, message: L("Unknown key \"\(key)\" in \(scope)."), key: key,
                        line: lineNumber(of: "\"\(key)\"", in: text)
                    )
                )
            }
        }
        unknown(root.keys, allowed: documentKeys, scope: L("the theme"))
        if let preferences = root["preferences"] as? [String: Any] {
            unknown(preferences.keys, allowed: preferenceKeys, scope: "preferences")
            if let readability = preferences["readability"] as? [String: Any] {
                unknown(readability.keys, allowed: readabilityKeys, scope: "readability")
            }
        }
        if let overrides = root["overrides"] as? [String: Any] {
            unknown(overrides.keys, allowed: ["tokens"], scope: "overrides")
            if let tokens = overrides["tokens"] as? [String: Any] {
                for (key, value) in tokens {
                    guard let entry = value as? [String: Any] else {
                        findings.append(
                            ThemePolicyFinding(
                                severity: .error, message: L("\"\(key)\" needs { \"light\": …, \"dark\": … }."), key: key,
                                line: lineNumber(of: "\"\(key)\"", in: text)
                            )
                        )
                        continue
                    }
                    unknown(entry.keys, allowed: tokenModeKeys, scope: key)
                }
            }
        }
        var document: ThemeDocument?
        do {
            document = try ThemeDocumentCodec.decoder().decode(ThemeDocument.self, from: data)
        } catch {
            findings.append(decodingFinding(error, text: text))
        }
        if var decoded = document {
            let (clean, policyFindings) = sanitize(decoded.overrides, base: base, source: text)
            findings += policyFindings
            decoded.overrides = clean.isEmpty ? nil : clean
            document = decoded
        }
        let blocked = findings.contains { $0.severity == .error }
        return ThemeJSONValidation(document: blocked ? nil : document, findings: findings)
    }

    /// 1-based line of the first occurrence of `needle`.
    static func lineNumber(of needle: String, in text: String) -> Int? {
        guard let range = text.range(of: needle) else { return nil }
        return text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static func syntaxMessage(_ error: Error) -> String {
        let description = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
        return L("The JSON can't be read: \(description ?? error.localizedDescription)")
    }

    private static func syntaxLine(_ error: Error) -> Int? {
        let description = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? ""
        guard let range = description.range(of: #"line (\d+)"#, options: .regularExpression) else { return nil }
        return Int(description[range].dropFirst(5))
    }

    private static func decodingFinding(_ error: Error, text: String) -> ThemePolicyFinding {
        let path: [CodingKey]
        let message: String
        switch error {
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            path = context.codingPath
            message = L("Wrong type at \(pathString(path)): \(context.debugDescription)")
        case DecodingError.dataCorrupted(let context):
            path = context.codingPath
            message = L("Invalid value at \(pathString(path)): \(context.debugDescription)")
        case DecodingError.keyNotFound(let key, let context):
            path = context.codingPath + [key]
            message = L("Missing \"\(key.stringValue)\" at \(pathString(context.codingPath)).")
        default:
            path = []
            message = error.localizedDescription
        }
        let key = path.last?.stringValue
        return ThemePolicyFinding(
            severity: .error, message: message, key: key, line: key.flatMap { lineNumber(of: "\"\($0)\"", in: text) }
        )
    }

    private static func pathString(_ path: [CodingKey]) -> String {
        path.isEmpty ? L("the top level") : path.map(\.stringValue).joined(separator: ".")
    }
}

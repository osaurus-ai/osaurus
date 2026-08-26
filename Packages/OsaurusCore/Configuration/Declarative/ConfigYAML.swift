//
//  ConfigYAML.swift
//  osaurus
//
//  YAML round-trip + strict validation for `OsaurusConfigDocument`.
//
//  Codable silently ignores unknown keys, which is exactly wrong for an
//  agent-facing config surface: a misspelled `default_temprature` must
//  come back as an actionable error, not a silent no-op. So decoding is
//  two-phase: (1) parse the raw YAML tree and walk it against the known
//  key sets, collecting every unknown/typo'd key with the valid
//  alternatives; (2) only if the walk is clean, decode via Codable.
//

import Foundation
import Yams

public enum ConfigYAMLError: Error, Sendable, Equatable {
    /// Malformed YAML (parse failure). Carries the parser's message.
    case malformed(String)
    /// Structurally valid YAML that violates the schema. Each element is a
    /// self-contained, model-actionable message.
    case invalid([String])

    public var messages: [String] {
        switch self {
        case .malformed(let m): return ["YAML parse error: \(m)"]
        case .invalid(let list): return list
        }
    }
}

/// JSON rendering of the same document — the alternate I/O format for
/// scripting. YAML stays canonical (templates, exports default to it);
/// JSON input needs no separate decode path because JSON is a YAML 1.2
/// subset and `ConfigYAML.decode` strict-validates the parsed tree the
/// same way regardless of the surface syntax.
public enum ConfigJSON {

    public static func encode(_ document: OsaurusConfigDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var doc = document
        if doc.version == nil { doc.version = 1 }
        return String(decoding: try encoder.encode(doc), as: UTF8.self)
    }
}

/// Document format selector for export surfaces (tool / HTTP / CLI).
public enum ConfigDocumentFormat: String, Sendable {
    case yaml
    case json

    /// Lenient parse for user-supplied format strings; nil input = yaml.
    public static func parse(_ raw: String?) -> ConfigDocumentFormat? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .yaml
        }
        return ConfigDocumentFormat(rawValue: raw.lowercased())
    }
}

public enum ConfigYAML {

    // MARK: - Encode

    public static func encode(_ document: OsaurusConfigDocument) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options = YAMLEncoder.Options(
            sortKeys: false,
            newLineScalarStyle: .literal
        )
        var doc = document
        if doc.version == nil { doc.version = 1 }
        return try encoder.encode(doc)
    }

    // MARK: - Decode

    /// Strict decode: schema-validates the raw tree first, then decodes.
    public static func decode(_ yaml: String) throws -> OsaurusConfigDocument {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConfigYAMLError.invalid(["The YAML document is empty."])
        }
        let tree: Any?
        do {
            tree = try Yams.load(yaml: yaml)
        } catch {
            throw ConfigYAMLError.malformed(String(describing: error))
        }
        guard let root = tree as? [AnyHashable: Any] else {
            throw ConfigYAMLError.invalid([
                "The document root must be a YAML mapping (top-level sections like `agents:`, "
                    + "`agents:`, ...). Got \(typeName(of: tree))."
            ])
        }
        let issues = validate(root: root)
        guard issues.isEmpty else { throw ConfigYAMLError.invalid(issues) }

        do {
            return try YAMLDecoder().decode(OsaurusConfigDocument.self, from: yaml)
        } catch let error as DecodingError {
            throw ConfigYAMLError.invalid([describe(error)])
        } catch {
            throw ConfigYAMLError.malformed(error.localizedDescription)
        }
    }

    // MARK: - Known keys (derived from the manifest)

    /// Keys allowed in each mapping of the document, addressed by a
    /// dotted path. `[]` entries describe list items. Derived from
    /// `ConfigManifest` — the single source of truth for the schema.
    static var knownKeys: [String: Set<String>] { ConfigManifest.knownKeys }

    /// List sections whose items must each carry the given required key.
    private static var listItemRequiredKey: [String: String] {
        ConfigManifest.listItemRequiredKey
    }

    // MARK: - Validation walk

    /// Generic manifest-driven walk: every mapping is checked against the
    /// manifest's known keys, entity lists against their item shape and
    /// required key, and freeform maps against their value constraints.
    /// Adding a section or key to `ConfigManifest` extends this walk with
    /// no code change here.
    static func validate(root: [AnyHashable: Any]) -> [String] {
        var issues: [String] = []
        checkMapping(root, path: "", issues: &issues)

        for section in ConfigManifest.sections {
            let name = section.id.rawValue
            guard let raw = root[name] else { continue }
            walk(raw, spec: section.value, path: name, displayPath: name, issues: &issues)
        }

        if let version = root["version"], let n = version as? Int, n != 1 {
            issues.append("Unsupported `version: \(n)`. This build supports version 1.")
        }
        return issues
    }

    private static func walk(
        _ raw: Any,
        spec: ConfigValueSpec,
        path: String,
        displayPath: String,
        issues: inout [String]
    ) {
        switch spec {
        case .scalar, .scalarList:
            return

        case .freeformMap(_, let allowedValues, _, _):
            guard let allowedValues, let mapping = raw as? [AnyHashable: Any] else { return }
            for (_, value) in mapping {
                if let text = value as? String, !allowedValues.contains(text.lowercased()) {
                    issues.append(
                        "\(displayPath) values must be one of: "
                            + allowedValues.joined(separator: ", ") + ". Got `\(text)`.")
                }
            }

        case .mapping(let keys):
            guard let mapping = raw as? [AnyHashable: Any] else {
                issues.append("`\(displayPath)` must be a YAML mapping. Got \(typeName(of: raw)).")
                return
            }
            checkMapping(mapping, path: path, displayPath: displayPath, issues: &issues)
            for key in keys {
                guard let child = mapping[key.key] else { continue }
                walk(
                    child, spec: key.value, path: "\(path).\(key.key)",
                    displayPath: "\(displayPath).\(key.key)", issues: &issues)
            }

        case .entityList(let keys, let requiredKey):
            guard let list = raw as? [Any] else {
                issues.append("`\(displayPath)` must be a YAML list. Got \(typeName(of: raw)).")
                return
            }
            let itemSpecPath = "\(path)[]"
            for (index, element) in list.enumerated() {
                let itemPath = "\(displayPath)[\(index)]"
                guard let item = element as? [AnyHashable: Any] else {
                    issues.append("\(itemPath) must be a mapping. Got \(typeName(of: element)).")
                    continue
                }
                checkMapping(item, path: itemSpecPath, displayPath: itemPath, issues: &issues)
                let value = (item[requiredKey] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value == nil || value?.isEmpty == true {
                    issues.append("\(itemPath) is missing required key `\(requiredKey)`.")
                }
                for key in keys {
                    guard let child = item[key.key] else { continue }
                    walk(
                        child, spec: key.value, path: "\(itemSpecPath).\(key.key)",
                        displayPath: "\(itemPath).\(key.key)", issues: &issues)
                }
            }
        }
    }

    private static func checkMapping(
        _ mapping: [AnyHashable: Any],
        path: String,
        displayPath: String? = nil,
        issues: inout [String]
    ) {
        guard let known = knownKeys[path] else { return }
        let display = displayPath ?? (path.isEmpty ? "top level" : path)
        for key in mapping.keys {
            guard let keyString = key as? String else {
                issues.append("Non-string key at \(display).")
                continue
            }
            if !known.contains(keyString) {
                var message = "Unknown key `\(keyString)` at \(display)."
                if path.isEmpty, ["server", "chat", "app"].contains(keyString) {
                    // Scope reduction 2: these sections are Settings-UI-only.
                    // Without this teach, models loop on the removed path.
                    message +=
                        " Server runtime, chat behavior, and app settings are managed in "
                        + "the Settings UI, not declaratively — remove this section and "
                        + "point the user to Settings."
                } else if keyString == "prune", path.isEmpty {
                    // Small models put `prune: true` inside the document —
                    // the delete flow then dead-ends on this decode error
                    // with an otherwise-correct keep-list in hand.
                    message +=
                        " `prune` is a TOOL ARGUMENT, not a document key — call "
                        + "osaurus_config {action: 'apply', yaml: <this document without "
                        + "the prune line>, prune: true}."
                } else if keyString == "id", known.contains("name") {
                    // Models keep writing `id:` because inspect payloads carry
                    // one; the document deliberately matches by name.
                    message += " Entities match by `name` (case-insensitive) — use `name`."
                } else if keyString == "cron", known.contains("frequency_value") {
                    // Models nest cron expressions under invented keys; the
                    // schedule shape is flat and splits kind from value.
                    message +=
                        " Cron schedules are flat keys: `frequency: cron` with the "
                        + "expression in `frequency_value`."
                } else if let alias = keyAliases[keyString], known.contains(alias) {
                    message += " Use `\(alias)`."
                } else if let suggestion = closest(keyString, in: known) {
                    message += " Did you mean `\(suggestion)`?"
                } else {
                    message += " Valid keys: \(known.sorted().joined(separator: ", "))."
                }
                issues.append(message)
            }
        }
    }

    // MARK: - Helpers

    private static func typeName(of value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case is String: return "a string"
        case is Bool: return "a boolean"
        case is Int, is Double: return "a number"
        case is [Any]: return "a list"
        case is [AnyHashable: Any]: return "a mapping"
        default: return String(describing: type(of: value!))
        }
    }

    /// Wrong-but-predictable keys mapped to the document's real key. These
    /// are the field names `osaurus_inspect` payloads use (or common API
    /// spellings), which models naturally copy into YAML; the edit-distance
    /// fallback can't bridge them, so the error names the fix directly.
    private static let keyAliases: [String: String] = [
        "default_model": "model",
        "provider_type": "provider",
        "api_key": "set_api_key",
        // Top-level section misses local models actually emit. Too far for
        // the edit-distance fallback (`mcp` → `mcp_servers` is distance 8).
        "mcp": "mcp_servers",
        "mcps": "mcp_servers",
        "knowledge": "knowledge_collections",
        // Schedule vocabulary models pick up from prose ("run on a daily
        // cadence at 08:00"); the real keys are too far for edit distance.
        "cadence": "frequency",
        "time": "frequency_time_of_day",
        "time_of_day": "frequency_time_of_day",
    ]

    /// Cheap did-you-mean: smallest edit distance within a small budget.
    static func closest(_ key: String, in candidates: Set<String>) -> String? {
        var best: (String, Int)?
        for candidate in candidates {
            let d = editDistance(key.lowercased(), candidate.lowercased())
            if d <= 3, d < (best?.1 ?? Int.max) {
                best = (candidate, d)
            }
        }
        return best?.0
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func describe(_ error: DecodingError) -> String {
        func pathString(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { key -> String in
                if let index = key.intValue { return "[\(index)]" }
                return key.stringValue
            }
            return path.isEmpty ? "top level" : path.joined(separator: ".")
        }
        switch error {
        case .typeMismatch(let type, let context):
            return "Wrong type at \(pathString(context)): expected \(type)."
        case .valueNotFound(let type, let context):
            return "Missing value at \(pathString(context)): expected \(type)."
        case .keyNotFound(let key, let context):
            return "Missing required key `\(key.stringValue)` at \(pathString(context))."
        case .dataCorrupted(let context):
            return "Invalid value at \(pathString(context)): \(context.debugDescription)"
        @unknown default:
            return "Could not decode the document: \(error)"
        }
    }
}

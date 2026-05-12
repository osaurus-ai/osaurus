//
//  ManifestValidate.swift
//  osaurus
//
//  Validates a plugin manifest JSON file against the structural rules
//  Osaurus enforces at install time. Produces either an "OK" summary or a
//  diagnostic listing of missing or malformed fields.
//
//  This validator is intentionally structural rather than a full
//  PluginManifest decode: the CLI doesn't depend on OsaurusCore, and a
//  hand-rolled validator gives nicer field-level diagnostics than a single
//  Codable error.
//

import Foundation

public struct ManifestValidate {

    public static func execute(args: [String]) {
        guard let path = args.first, !path.isEmpty else {
            fputs("Usage: osaurus manifest validate <manifest.json>\n", stderr)
            exit(EXIT_FAILURE)
        }

        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            fputs("Error: File not found: \(url.path)\n", stderr)
            exit(EXIT_FAILURE)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fputs("Error: Failed to read file: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        let report = validate(data: data)
        printReport(report, source: url.lastPathComponent)
        exit(report.errors.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    // MARK: - Public API (testable)

    public struct Report {
        public var errors: [String] = []
        public var warnings: [String] = []
        public var summary: Summary?

        public init() {}

        public struct Summary {
            public let pluginId: String
            public let version: String?
            public let toolsCount: Int
            public let routesCount: Int
            public let hasWeb: Bool
            public let hasConfig: Bool
        }
    }

    /// Validates the bytes of a manifest JSON file. Pure (no I/O), so unit
    /// tests can construct minimal payloads.
    public static func validate(data: Data) -> Report {
        var report = Report()

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            report.errors.append("Not valid JSON: \(error.localizedDescription)")
            return report
        }

        guard let obj = root as? [String: Any] else {
            report.errors.append("Top-level JSON must be an object.")
            return report
        }

        // plugin_id: required, non-empty string
        let pluginId: String
        if let raw = obj["plugin_id"] {
            if let s = raw as? String {
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report.errors.append("`plugin_id` is empty.")
                    pluginId = ""
                } else {
                    pluginId = s
                }
            } else {
                report.errors.append("`plugin_id` must be a string (got \(typeName(of: raw))).")
                pluginId = ""
            }
        } else {
            report.errors.append("`plugin_id` is required.")
            pluginId = ""
        }

        // capabilities: required, object
        guard let caps = obj["capabilities"] else {
            report.errors.append("`capabilities` is required.")
            return report
        }
        guard let capsObj = caps as? [String: Any] else {
            report.errors.append("`capabilities` must be an object (got \(typeName(of: caps))).")
            return report
        }

        let toolsCount = validateTools(capsObj["tools"], into: &report)
        let routesCount = validateRoutes(capsObj["routes"], into: &report)
        let hasWeb = validateWeb(capsObj["web"], into: &report)
        let hasConfig = validateConfig(capsObj["config"], into: &report)
        if let h = capsObj["artifact_handler"], !(h is Bool) {
            report.errors.append("`capabilities.artifact_handler` must be a boolean.")
        }

        validateSecrets(obj["secrets"], into: &report)
        validateDocs(obj["docs"], into: &report)
        validateCompatFields(obj, into: &report)

        // Optional well-formed-but-loose fields surface as warnings rather
        // than errors so a typo doesn't fail validation outright.
        if let v = obj["version"], !(v is String) {
            report.warnings.append("`version` should be a string (got \(typeName(of: v))).")
        }
        if let n = obj["name"], !(n is String) {
            report.warnings.append("`name` should be a string (got \(typeName(of: n))).")
        }
        if let i = obj["instructions"], !(i is String) {
            report.errors.append("`instructions` must be a string (got \(typeName(of: i))).")
        }
        if let lic = obj["license"], !(lic is String) {
            report.warnings.append("`license` should be a string (got \(typeName(of: lic))).")
        }
        if let authors = obj["authors"] {
            if let arr = authors as? [Any] {
                for (i, a) in arr.enumerated() where !(a is String) {
                    report.errors.append("`authors[\(i)]` must be a string.")
                }
            } else {
                report.errors.append("`authors` must be an array of strings.")
            }
        }

        report.summary = Report.Summary(
            pluginId: pluginId,
            version: obj["version"] as? String,
            toolsCount: toolsCount,
            routesCount: routesCount,
            hasWeb: hasWeb,
            hasConfig: hasConfig
        )
        return report
    }

    // MARK: - Top-level field validators (added for plugin authoring v1)

    /// Validates the optional top-level `secrets` array. Each entry is
    /// a `SecretSpec`: required `id` + `label`, optional `description`
    /// / `required` (bool) / `url`. Surfaced for authors so a typo in
    /// `secrets` doesn't silently get the user a plugin that asks for
    /// nothing on install.
    private static func validateSecrets(_ raw: Any?, into report: inout Report) {
        guard let raw else { return }
        guard let arr = raw as? [Any] else {
            report.errors.append("`secrets` must be an array (got \(typeName(of: raw))).")
            return
        }
        for (i, entry) in arr.enumerated() {
            guard let secret = entry as? [String: Any] else {
                report.errors.append("`secrets[\(i)]` must be an object.")
                continue
            }
            requireNonEmptyString(secret["id"], at: "secrets[\(i)].id", report: &report)
            requireNonEmptyString(secret["label"], at: "secrets[\(i)].label", report: &report)
            if let req = secret["required"], !(req is Bool) {
                report.errors.append("`secrets[\(i)].required` must be a boolean.")
            }
            if let url = secret["url"], !(url is String) {
                report.errors.append("`secrets[\(i)].url` must be a string.")
            }
            if let desc = secret["description"], !(desc is String) {
                report.errors.append("`secrets[\(i)].description` must be a string.")
            }
        }
    }

    /// Validates `docs` shape (readme path, changelog path, optional
    /// links array of `{label, url}`). All sub-fields are optional but
    /// must be the right type if present.
    private static func validateDocs(_ raw: Any?, into report: inout Report) {
        guard let raw else { return }
        guard let docs = raw as? [String: Any] else {
            report.errors.append("`docs` must be an object.")
            return
        }
        if let r = docs["readme"], !(r is String) {
            report.errors.append("`docs.readme` must be a string.")
        }
        if let c = docs["changelog"], !(c is String) {
            report.errors.append("`docs.changelog` must be a string.")
        }
        if let links = docs["links"] {
            guard let arr = links as? [Any] else {
                report.errors.append("`docs.links` must be an array.")
                return
            }
            for (i, entry) in arr.enumerated() {
                guard let link = entry as? [String: Any] else {
                    report.errors.append("`docs.links[\(i)]` must be an object.")
                    continue
                }
                requireNonEmptyString(link["label"], at: "docs.links[\(i)].label", report: &report)
                requireNonEmptyString(link["url"], at: "docs.links[\(i)].url", report: &report)
            }
        }
    }

    /// Validates `min_osaurus` / `min_macos` shape. Host enforces
    /// these at load time (see `PluginManager.compatibilityFailure`);
    /// catching unparseable strings at validate time saves the
    /// author a debug cycle.
    private static func validateCompatFields(_ obj: [String: Any], into report: inout Report) {
        validateVersionField(
            obj["min_osaurus"],
            field: "min_osaurus",
            example: "semver like '0.18.0'",
            isValid: looksLikeSemver,
            into: &report
        )
        validateVersionField(
            obj["min_macos"],
            field: "min_macos",
            example: "major[.minor[.patch]] like '14.5'",
            isValid: looksLikeOSVersion,
            into: &report
        )
    }

    /// Shared shape check for the two version fields: type-error if
    /// not a string; warning if non-empty but unparseable. Empty string
    /// is treated as "no constraint" and passes silently — the host
    /// would also ignore it.
    private static func validateVersionField(
        _ raw: Any?,
        field: String,
        example: String,
        isValid: (String) -> Bool,
        into report: inout Report
    ) {
        guard let raw else { return }
        guard let s = raw as? String else {
            report.errors.append("`\(field)` must be a string.")
            return
        }
        if !s.isEmpty, !isValid(s) {
            report.warnings.append(
                "`\(field)` is '\(s)'; expected \(example) — host will ignore unparseable constraints."
            )
        }
    }

    /// Loose semver shape check: at least three dot-separated integer
    /// components. Mirrors what `SemanticVersion.parse` accepts without
    /// re-implementing it (the CLI module deliberately doesn't depend
    /// on `OsaurusRepository`'s parser).
    private static func looksLikeSemver(_ s: String) -> Bool {
        let core = s.split(separator: "-", maxSplits: 1).first ?? Substring(s)
        let nums = core.split(separator: ".", omittingEmptySubsequences: false)
        guard nums.count == 3 else { return false }
        return nums.allSatisfy { Int($0) != nil }
    }

    /// `min_macos` accepts "14", "14.5", or "14.5.1" — at least one
    /// integer component, all-integer.
    private static func looksLikeOSVersion(_ s: String) -> Bool {
        let nums = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !nums.isEmpty else { return false }
        return nums.allSatisfy { Int($0) != nil }
    }

    // MARK: - Capability validators

    private static func validateTools(_ raw: Any?, into report: inout Report) -> Int {
        guard let raw else { return 0 }
        guard let arr = raw as? [Any] else {
            report.errors.append("`capabilities.tools` must be an array (got \(typeName(of: raw))).")
            return 0
        }
        for (i, entry) in arr.enumerated() {
            guard let tool = entry as? [String: Any] else {
                report.errors.append("`capabilities.tools[\(i)]` must be an object.")
                continue
            }
            requireNonEmptyString(tool["id"], at: "capabilities.tools[\(i)].id", report: &report)
            requireNonEmptyString(
                tool["description"],
                at: "capabilities.tools[\(i)].description",
                report: &report
            )
            // `parameters` is optional and may be any JSON value the model can interpret.
            // `requirements` should be an array of strings if present.
            if let req = tool["requirements"] {
                if let arr = req as? [Any] {
                    for (j, item) in arr.enumerated()
                    where !(item is String) {
                        report.errors.append(
                            "`capabilities.tools[\(i)].requirements[\(j)]` must be a string."
                        )
                    }
                } else {
                    report.errors.append(
                        "`capabilities.tools[\(i)].requirements` must be an array of strings."
                    )
                }
            }
            if let policy = tool["permission_policy"] {
                if let s = policy as? String {
                    if !["auto", "ask", "deny"].contains(s) {
                        report.warnings.append(
                            "`capabilities.tools[\(i)].permission_policy` is '\(s)'; expected one of auto / ask / deny."
                        )
                    }
                } else {
                    report.errors.append(
                        "`capabilities.tools[\(i)].permission_policy` must be a string."
                    )
                }
            }
        }
        return arr.count
    }

    private static func validateRoutes(_ raw: Any?, into report: inout Report) -> Int {
        guard let raw else { return 0 }
        guard let arr = raw as? [Any] else {
            report.errors.append("`capabilities.routes` must be an array (got \(typeName(of: raw))).")
            return 0
        }
        for (i, entry) in arr.enumerated() {
            guard let route = entry as? [String: Any] else {
                report.errors.append("`capabilities.routes[\(i)]` must be an object.")
                continue
            }
            requireNonEmptyString(route["id"], at: "capabilities.routes[\(i)].id", report: &report)
            requireNonEmptyString(route["path"], at: "capabilities.routes[\(i)].path", report: &report)
            // methods: non-empty array of strings
            if let m = route["methods"] {
                if let methods = m as? [Any] {
                    if methods.isEmpty {
                        report.errors.append(
                            "`capabilities.routes[\(i)].methods` must be a non-empty array."
                        )
                    }
                    for (j, item) in methods.enumerated() where !(item is String) {
                        report.errors.append(
                            "`capabilities.routes[\(i)].methods[\(j)]` must be a string."
                        )
                    }
                } else {
                    report.errors.append(
                        "`capabilities.routes[\(i)].methods` must be an array of strings."
                    )
                }
            } else {
                report.errors.append("`capabilities.routes[\(i)].methods` is required.")
            }
            if let auth = route["auth"] {
                if let s = auth as? String {
                    if !["none", "verify", "owner"].contains(s) {
                        report.warnings.append(
                            "`capabilities.routes[\(i)].auth` is '\(s)'; expected one of none / verify / owner."
                        )
                    }
                } else {
                    report.errors.append(
                        "`capabilities.routes[\(i)].auth` must be a string."
                    )
                }
            }
            if let exposed = route["tunnel_exposed"], !(exposed is Bool) {
                report.errors.append(
                    "`capabilities.routes[\(i)].tunnel_exposed` must be a boolean."
                )
            }
        }
        return arr.count
    }

    private static func validateWeb(_ raw: Any?, into report: inout Report) -> Bool {
        guard let raw else { return false }
        guard let web = raw as? [String: Any] else {
            report.errors.append("`capabilities.web` must be an object.")
            return false
        }
        requireNonEmptyString(web["static_dir"], at: "capabilities.web.static_dir", report: &report)
        requireNonEmptyString(web["entry"], at: "capabilities.web.entry", report: &report)
        requireNonEmptyString(web["mount"], at: "capabilities.web.mount", report: &report)
        if let auth = web["auth"] {
            if let s = auth as? String {
                if !["none", "verify", "owner"].contains(s) {
                    report.warnings.append(
                        "`capabilities.web.auth` is '\(s)'; expected one of none / verify / owner."
                    )
                }
            } else {
                report.errors.append("`capabilities.web.auth` must be a string.")
            }
        } else {
            report.errors.append("`capabilities.web.auth` is required.")
        }
        if let exposed = web["tunnel_exposed"], !(exposed is Bool) {
            report.errors.append("`capabilities.web.tunnel_exposed` must be a boolean.")
        }
        if let apiMount = web["api_mount"] {
            if !(apiMount is String) {
                report.errors.append("`capabilities.web.api_mount` must be a string.")
            }
        }
        return true
    }

    private static func validateConfig(_ raw: Any?, into report: inout Report) -> Bool {
        guard let raw else { return false }
        guard let config = raw as? [String: Any] else {
            report.errors.append("`capabilities.config` must be an object.")
            return false
        }
        if let sections = config["sections"] {
            guard let arr = sections as? [Any] else {
                report.errors.append("`capabilities.config.sections` must be an array.")
                return true
            }
            for (i, entry) in arr.enumerated() {
                guard let section = entry as? [String: Any] else {
                    report.errors.append("`capabilities.config.sections[\(i)]` must be an object.")
                    continue
                }
                requireNonEmptyString(
                    section["title"],
                    at: "capabilities.config.sections[\(i)].title",
                    report: &report
                )
                validateConfigFields(
                    section["fields"],
                    sectionPath: "capabilities.config.sections[\(i)]",
                    into: &report
                )
            }
        } else {
            report.errors.append("`capabilities.config.sections` is required when `config` is set.")
        }
        return true
    }

    /// Validates each field inside a config section. Required: `key`,
    /// `type`, `label`. `type` must be one of the documented enum
    /// values — this catches typos like `"checkbox"` (should be
    /// `toggle`) early instead of silently rendering nothing.
    private static func validateConfigFields(
        _ raw: Any?,
        sectionPath: String,
        into report: inout Report
    ) {
        guard let raw else {
            report.errors.append("`\(sectionPath).fields` is required.")
            return
        }
        guard let arr = raw as? [Any] else {
            report.errors.append("`\(sectionPath).fields` must be an array.")
            return
        }
        // Mirrors `PluginManifest.ConfigFieldType` exactly. Adding a
        // new field type means updating both this list and the Swift
        // enum — the validator failing loudly here is the "did you
        // forget to update the validator?" trap.
        let validTypes: Set<String> = [
            "text", "secret", "toggle", "select", "multiselect",
            "number", "readonly", "status",
        ]
        for (j, entry) in arr.enumerated() {
            let path = "\(sectionPath).fields[\(j)]"
            guard let field = entry as? [String: Any] else {
                report.errors.append("`\(path)` must be an object.")
                continue
            }
            requireNonEmptyString(field["key"], at: "\(path).key", report: &report)
            requireNonEmptyString(field["label"], at: "\(path).label", report: &report)
            if let t = field["type"] {
                if let s = t as? String {
                    if !validTypes.contains(s) {
                        report.errors.append(
                            "`\(path).type` is '\(s)'; expected one of: "
                                + validTypes.sorted().joined(separator: ", ")
                        )
                    }
                } else {
                    report.errors.append("`\(path).type` must be a string.")
                }
            } else {
                report.errors.append("`\(path).type` is required.")
            }
        }
    }

    // MARK: - Helpers

    private static func requireNonEmptyString(
        _ value: Any?,
        at field: String,
        report: inout Report
    ) {
        guard let value else {
            report.errors.append("`\(field)` is required.")
            return
        }
        guard let s = value as? String else {
            report.errors.append("`\(field)` must be a string (got \(typeName(of: value))).")
            return
        }
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.errors.append("`\(field)` is empty.")
        }
    }

    private static func typeName(of value: Any) -> String {
        switch value {
        case is String: return "string"
        case is NSNumber: return "number/bool"
        case is [Any]: return "array"
        case is [String: Any]: return "object"
        case is NSNull: return "null"
        default: return "\(type(of: value))"
        }
    }

    private static func printReport(_ report: Report, source: String) {
        if !report.errors.isEmpty {
            fputs("\(source): FAIL (\(report.errors.count) error\(report.errors.count == 1 ? "" : "s"))\n", stderr)
            for e in report.errors {
                fputs("  - \(e)\n", stderr)
            }
            for w in report.warnings {
                fputs("  ! \(w)\n", stderr)
            }
            return
        }

        var summaryLine = "\(source): OK"
        if let s = report.summary {
            var bits: [String] = ["plugin_id=\(s.pluginId)"]
            if let v = s.version { bits.append("version=\(v)") }
            bits.append("tools=\(s.toolsCount)")
            bits.append("routes=\(s.routesCount)")
            if s.hasWeb { bits.append("web=yes") }
            if s.hasConfig { bits.append("config=yes") }
            summaryLine += " (" + bits.joined(separator: ", ") + ")"
        }
        print(summaryLine)
        for w in report.warnings {
            print("  ! \(w)")
        }
    }
}

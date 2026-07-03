//
//  AppleScriptDictionaryService.swift
//  OsaurusCore — AppleScript Computer Use
//
//  Loads an app's scripting definition (sdef), distills it to the vocabulary
//  the AppleScript model actually needs (app-specific classes, properties, and
//  commands), and caches the distilled summary per app bundle. The summary is
//  injected into the AppleScript loop's system prompt (bounded, harness-gated)
//  so the model writes against the app's REAL dictionary instead of guessing
//  vocabulary — the single biggest reducer of compile/runtime errors.
//
//  The sdef is resolved via `OSACopyScriptingDefinitionFromURL`, which returns
//  the COMPLETE definition with XIncludes (e.g. the shared CocoaStandard suite)
//  already expanded. Distillation then SKIPS the "Standard Suite" — the generic
//  verbs (open/close/delete/make/…) are vocabulary every AppleScript model
//  already knows — keeping the injected text dense with app-specific signal.
//
//  Read-only: this reads bundle metadata off disk. It never sends Apple Events,
//  so it needs no Automation permission and can run before any consent gate.
//

import Carbon
import Foundation

enum AppleScriptDictionaryService {

    /// Hard cap for one app's distilled dictionary summary. Keeps the prompt
    /// bounded even for huge dictionaries (Adobe apps ship thousands of terms).
    static let maxSummaryChars = 1_600

    // MARK: - Cache

    /// Distilled summaries keyed by app bundle path, invalidated when the
    /// bundle's modification date changes (app updated in place).
    private struct CacheEntry {
        let modified: Date?
        /// `nil` is cached too: "no usable dictionary" is a stable answer and
        /// re-parsing a non-scriptable app on every call would waste the win.
        let summary: String?
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CacheEntry] = [:]

    // MARK: - Public entry

    /// The distilled scripting-dictionary summary for the app at `bundleURL`,
    /// or `nil` when the app has no usable dictionary. Cached per bundle.
    static func dictionarySummary(appName: String, bundleURL: URL) -> String? {
        let path = bundleURL.path
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date

        cacheLock.lock()
        if let entry = cache[path], entry.modified == modified {
            let cached = entry.summary
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let summary = loadAndDistill(appName: appName, bundleURL: bundleURL)

        cacheLock.lock()
        cache[path] = CacheEntry(modified: modified, summary: summary)
        cacheLock.unlock()
        return summary
    }

    /// Resolve an app NAME to its bundle URL: a running app with that name
    /// first (exact localized-name match), then the standard install locations.
    /// `runningApps` comes from the caller's already-captured desktop snapshot
    /// so this stays main-actor-free.
    static func bundleURL(appName: String, runningApps: [(name: String, bundleURL: URL?)] = [])
        -> URL?
    {
        if let running = runningApps.first(where: {
            $0.name.caseInsensitiveCompare(appName) == .orderedSame
        }), let url = running.bundleURL {
            return url
        }
        let fm = FileManager.default
        let candidates = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            "/System/Applications/Utilities/\(appName).app",
            "/System/Library/CoreServices/\(appName).app",
            NSHomeDirectory() + "/Applications/\(appName).app",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Load + distill

    private static func loadAndDistill(appName: String, bundleURL: URL) -> String? {
        guard let data = copyScriptingDefinition(bundleURL) else { return nil }
        return distill(sdefData: data, appName: appName)
    }

    /// The complete sdef (XIncludes resolved) for the bundle, or `nil` when the
    /// app isn't scriptable.
    static func copyScriptingDefinition(_ bundleURL: URL) -> Data? {
        var unmanaged: Unmanaged<CFData>?
        let status = OSACopyScriptingDefinitionFromURL(bundleURL as CFURL, 0, &unmanaged)
        guard status == 0, let cfData = unmanaged?.takeRetainedValue() else { return nil }
        let data = cfData as Data
        return data.isEmpty ? nil : data
    }

    /// Distill raw sdef XML into a bounded, model-readable vocabulary summary.
    /// Deterministic + pure over its input, so it unit-tests with inline XML.
    static func distill(sdefData: Data, appName: String, maxChars: Int = maxSummaryChars) -> String? {
        guard let document = try? XMLDocument(data: sdefData, options: []) else { return nil }
        guard let root = document.rootElement() else { return nil }

        var lines: [String] = []
        for suite in root.elements(forName: "suite") {
            let suiteName = suite.attribute(forName: "name")?.stringValue ?? ""
            // Generic verbs the model already knows; keep the summary dense
            // with app-specific vocabulary.
            if suiteName.caseInsensitiveCompare("Standard Suite") == .orderedSame { continue }

            for cls in suite.elements(forName: "class") {
                if let line = classLine(cls) { lines.append(line) }
            }
            // `class-extension` adds properties to a class defined elsewhere
            // (commonly `application`) — the extension properties ARE the app's
            // top-level readable state, so include them.
            for ext in suite.elements(forName: "class-extension") {
                if let line = classExtensionLine(ext) { lines.append(line) }
            }
            for command in suite.elements(forName: "command") {
                if let line = commandLine(command) { lines.append(line) }
            }
        }
        guard !lines.isEmpty else { return nil }

        var summary = "\(appName) scripting dictionary (app-specific):"
        for line in lines {
            let candidate = summary + "\n" + line
            if candidate.count > maxChars { break }
            summary = candidate
        }
        // Only the header fit → nothing useful.
        guard summary.contains("\n") else { return nil }
        return summary
    }

    // MARK: - Element rendering

    private static func classLine(_ cls: XMLElement) -> String? {
        guard let name = cls.attribute(forName: "name")?.stringValue, !name.isEmpty else {
            return nil
        }
        var parts: [String] = []
        let properties = cls.elements(forName: "property").prefix(10).compactMap(propertyBrief)
        if !properties.isEmpty {
            parts.append("properties: " + properties.joined(separator: ", "))
        }
        let elements = cls.elements(forName: "element")
            .prefix(6)
            .compactMap { $0.attribute(forName: "type")?.stringValue }
        if !elements.isEmpty {
            parts.append("elements: " + elements.joined(separator: ", "))
        }
        let detail = parts.isEmpty ? "" : " — " + parts.joined(separator: "; ")
        return "class \(name)\(detail)"
    }

    private static func classExtensionLine(_ ext: XMLElement) -> String? {
        guard let extends = ext.attribute(forName: "extends")?.stringValue, !extends.isEmpty
        else { return nil }
        let properties = ext.elements(forName: "property").prefix(10).compactMap(propertyBrief)
        let elements = ext.elements(forName: "element")
            .prefix(6)
            .compactMap { $0.attribute(forName: "type")?.stringValue }
        var parts: [String] = []
        if !properties.isEmpty { parts.append("properties: " + properties.joined(separator: ", ")) }
        if !elements.isEmpty { parts.append("elements: " + elements.joined(separator: ", ")) }
        guard !parts.isEmpty else { return nil }
        return "class \(extends) (extended) — " + parts.joined(separator: "; ")
    }

    private static func propertyBrief(_ property: XMLElement) -> String? {
        guard let name = property.attribute(forName: "name")?.stringValue, !name.isEmpty else {
            return nil
        }
        let type = typeString(property)
        let access = property.attribute(forName: "access")?.stringValue
        let readOnly = access == "r" ? ", r/o" : ""
        return type.isEmpty ? name : "\(name) (\(type)\(readOnly))"
    }

    private static func commandLine(_ command: XMLElement) -> String? {
        guard let name = command.attribute(forName: "name")?.stringValue, !name.isEmpty else {
            return nil
        }
        var parts: [String] = []
        if let direct = command.elements(forName: "direct-parameter").first {
            let type = typeString(direct)
            parts.append("direct: \(type.isEmpty ? "any" : type)")
        }
        let parameters = command.elements(forName: "parameter")
            .prefix(8)
            .compactMap { parameter -> String? in
                guard let pname = parameter.attribute(forName: "name")?.stringValue else {
                    return nil
                }
                let type = typeString(parameter)
                let optional = parameter.attribute(forName: "optional")?.stringValue == "yes"
                return "\(pname)\(type.isEmpty ? "" : " (\(type))")\(optional ? "?" : "")"
            }
        if !parameters.isEmpty { parts.append("params: " + parameters.joined(separator: ", ")) }
        if let result = command.elements(forName: "result").first {
            let type = typeString(result)
            if !type.isEmpty { parts.append("returns \(type)") }
        }
        let detail = parts.isEmpty ? "" : " — " + parts.joined(separator: "; ")
        return "command \(name)\(detail)"
    }

    /// A node's type: the `type` attribute, else its nested `<type type=…/>`
    /// children joined (the sdef list/union form).
    private static func typeString(_ element: XMLElement) -> String {
        if let direct = element.attribute(forName: "type")?.stringValue, !direct.isEmpty {
            return direct
        }
        let nested = element.elements(forName: "type")
            .compactMap { child -> String? in
                guard let t = child.attribute(forName: "type")?.stringValue, !t.isEmpty else {
                    return nil
                }
                let isList = child.attribute(forName: "list")?.stringValue == "yes"
                return isList ? "list of \(t)" : t
            }
        return nested.joined(separator: " | ")
    }
}

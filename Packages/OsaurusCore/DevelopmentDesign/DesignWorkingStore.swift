#if OSAURUS_DESIGN_INSPECTOR
import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI

@MainActor final class DesignWorkingStore: ObservableObject {
    static let revision = "00ba05e7f77bc120bb90fc164cb2a0705599ea00"
    static let shared: DesignWorkingStore = {
        do {
            guard let tokens = Bundle.module.url(forResource: "semantic-tokens", withExtension: "json", subdirectory: "DesignInspectorResources"),
                let mappings = Bundle.module.url(forResource: "component-mappings", withExtension: "json", subdirectory: "DesignInspectorResources") else {
                preconditionFailure("Development inspector resources are absent")
            }
            let store = try DesignWorkingStore(root: OsaurusPaths.root().appendingPathComponent("design-inspector"),
                tokenData: Data(contentsOf: tokens), mappingData: Data(contentsOf: mappings), primitiveData: Data(contentsOf: Bundle.module.url(forResource: "primitive-colors", withExtension: "json", subdirectory: "DesignInspectorResources")!))
            if ProcessInfo.processInfo.environment["OSAURUS_AGENT_SURFACE_CHECKS"] == "1" {
                exit(DesignAgentSurfaceChecks.run(store))
            }
            if ProcessInfo.processInfo.environment["OSAURUS_CATALOG_LAYOUT_CHECKS"] == "1" {
                DesignCatalogLayoutChecks.run(store)
            }
            if ProcessInfo.processInfo.environment["OSAURUS_APP_DEFAULT_CHECKS"] == "1" {
                DesignFigmaChecks.runAppDefaults(store)
                exit(0)
            }
            if ProcessInfo.processInfo.environment["OSAURUS_FIGMA_SYNC_CHECKS"] == "1" {
                DesignFigmaChecks.run(store)
            }
            return store
        } catch { preconditionFailure("Development inspector cannot initialize: \(error)") }
    }()
    @Published private(set) var document: DesignWorkingDocument
    @Published private(set) var status = "Working values autosave separately from the engineering handoff."
    @Published private(set) var snapshots: [URL] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    let legacyBaseline: DesignWorkingDocument
    let baseline: DesignWorkingDocument
    let root: URL
    private let notifiesApp: Bool
    private var preservedModeDifferences: [String: DesignToken] = [:]
    private var undoHistory: [DesignWorkingDocument] = []
    private var redoHistory: [DesignWorkingDocument] = []
    var workingFile: URL { root.appendingPathComponent("working.json") }

    init(root: URL, tokenData: Data, mappingData: Data, primitiveData: Data? = nil, notifiesApp: Bool = true) throws {
        self.root = root; self.notifiesApp = notifiesApp
        let definition = try DesignLibraryDefinition.baseline(tokenData: tokenData, mappingData: mappingData, primitiveData: primitiveData)
        self.legacyBaseline = definition.legacy
        var baseline = definition.current
        // The shipped library retains assignments for app configurations that
        // no longer appear in the generated preview catalog. Keep that contract
        // editable and loadable without discarding saved component assignments.
        let shipped = try JSONDecoder().decode(DesignWorkingDocument.self,
            from: DesignLibraryRuntime.resource("design-library"))
        for (key, role) in shipped.mappings where baseline.mappings[key] == nil {
            baseline.mappings[key] = role
        }
        baseline = CatalogElementAssignments.migrate(baseline)
        self.baseline = baseline; self.document = baseline
        let legacyFile = root.appendingPathComponent("catalog-import.json")
        if let data = try? Data(contentsOf: legacyFile),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = (object["tokens"] as? [String: Any])?["semanticTokens"],
           let encoded = try? JSONSerialization.data(withJSONObject: raw),
           let old = try? JSONDecoder().decode([String: DesignToken].self, from: encoded) {
            preservedModeDifferences = old.filter { $0.value.light != $0.value.dark && $0.value.type == "typography" }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Snapshots"), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: workingFile.path) {
            do {
                var loaded = try JSONDecoder().decode(DesignWorkingDocument.self, from: Data(contentsOf: workingFile))
                for name in ["color.surface.none","color.border.none"] where loaded.tokens[name] == nil { loaded.tokens[name] = baseline.tokens[name] }
                loaded = CatalogElementAssignments.migrate(loaded)
                // Add the preserved catalog contract to earlier button-only snapshots.
                for (key, value) in baseline.mappings where loaded.mappings[key] == nil { loaded.mappings[key] = value }
                if loaded.schemaVersion == 1 && baseline.schemaVersion == 2 {
                    let backup = root.appendingPathComponent("Before-primitives-" + UUID().uuidString + ".json")
                    try FileManager.default.copyItem(at: workingFile, to: backup)
                    loaded = try migrateColors(loaded)
                    try validate(loaded)
                    try JSONEncoder().encode(loaded).write(to: workingFile, options: .atomic)
                    status = "Primitives added; saved experiments preserved. Backup: " + backup.lastPathComponent
                }
                let extended = DesignTypographyTokens.extend(loaded)
                if extended != loaded {
                    let backup = root.appendingPathComponent("Before-typography-" + UUID().uuidString + ".json")
                    try FileManager.default.copyItem(at: workingFile, to: backup)
                    try validate(extended)
                    try JSONEncoder().encode(extended).write(to: workingFile, options: .atomic)
                    loaded = extended
                    status = "Typography styles added; saved design preserved."
                }
                loaded = try DesignFigmaSync.upgrade(loaded, baseline: baseline)
                try validate(loaded); document = loaded
                if loaded.figmaSource != nil { try JSONEncoder().encode(loaded).write(to: workingFile, options: .atomic) }
            } catch {
                let recovery = root.appendingPathComponent("Recovery-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: workingFile, to: recovery)
                status = "Working file preserved at \(recovery.lastPathComponent). Could not load: \(error.localizedDescription)."
            }
        }
        let imported = root.appendingPathComponent("catalog-import.json")
        let marker = root.appendingPathComponent("catalog-imported.json")
        if FileManager.default.fileExists(atPath: imported.path), !FileManager.default.fileExists(atPath: marker.path) {
            let data = try Data(contentsOf: imported)
            guard let legacy = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: imported])
            }
            let candidate = try decodeCatalog(legacy)
            try validate(candidate)
            if FileManager.default.fileExists(atPath: workingFile.path) {
                try FileManager.default.copyItem(at: workingFile, to: root.appendingPathComponent("Before-catalog-import-" + UUID().uuidString + ".json"))
            }
            document = candidate
            try JSONEncoder().encode(document).write(to: workingFile, options: .atomic)
            try data.write(to: marker, options: .atomic)
            status = "Existing catalog and saved edits connected to Osaurus"
        }
        try publish(document)
        reloadSnapshots()
    }
    func catalogDocument(baseline useBaseline: Bool = false) -> [String: Any] {
        let doc = useBaseline ? baseline : document
        let tokens = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(doc.tokens))) ?? [:]
        var result: [String: Any] = ["tokens": ["semanticTokens": tokens], "components": ["mappings": doc.mappings]]
        if let primitives = doc.primitives, let aliases = doc.colorAliases {
            result["primitives"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(primitives))
            result["colorAliases"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(aliases))
            result["primitiveSource"] = doc.primitiveSource
        }
        result["scalarPrimitives"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(doc.scalarPrimitives))
        result["valueAliases"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(doc.valueAliases))
        result["figmaSource"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(doc.figmaSource))
        result["explicitAssignments"] = Array(doc.explicitAssignments ?? []).sorted()
        return result
    }
    private func decodeCatalog(_ legacy: [String: Any]) throws -> DesignWorkingDocument {
        guard let tokens = (legacy["tokens"] as? [String: Any])?["semanticTokens"],
              let maps = (legacy["components"] as? [String: Any])?["mappings"] as? [String: String] else { throw DesignWorkingError.incompatible }
        var candidate = document
        candidate.tokens = try JSONDecoder().decode([String: DesignToken].self, from: JSONSerialization.data(withJSONObject: tokens))
        candidate.mappings.merge(CatalogElementAssignments.extendMappings(maps)) { _, new in new }
        candidate.explicitAssignments = Set(legacy["explicitAssignments"] as? [String] ?? [])
        for name in ["color.surface.none","color.border.none"] where candidate.tokens[name] == nil { candidate.tokens[name] = baseline.tokens[name] }
        if let primitives = legacy["primitives"], let aliases = legacy["colorAliases"] {
            candidate.primitives = try JSONDecoder().decode([String: DesignPrimitiveColor].self, from: JSONSerialization.data(withJSONObject: primitives))
            candidate.colorAliases = try JSONDecoder().decode([String: DesignColorAlias].self, from: JSONSerialization.data(withJSONObject: aliases))
            candidate.schemaVersion = 2
        } else if baseline.schemaVersion == 2 {
            candidate.schemaVersion = 1
            candidate = try migrateColors(candidate)
        }
        if let raw = legacy["scalarPrimitives"], !(raw is NSNull) { candidate.scalarPrimitives = try JSONDecoder().decode([String: DesignScalarPrimitive].self, from: JSONSerialization.data(withJSONObject: raw)) }
        if let raw = legacy["valueAliases"], !(raw is NSNull) { candidate.valueAliases = try JSONDecoder().decode([String: DesignColorAlias].self, from: JSONSerialization.data(withJSONObject: raw)) }
        return try DesignTypographyTokens.extend(CatalogElementAssignments.migrate(candidate)).resolvingColors()
    }
    private func migrateColors(_ legacy: DesignWorkingDocument) throws -> DesignWorkingDocument {
        var legacy = try DesignFigmaSync.upgrade(DesignTypographyTokens.extend(CatalogElementAssignments.migrate(legacy)), baseline: baseline, importValues: false)
        // Catalog assignments can grow without changing the document schema.
        // Apply the same additive migration to snapshots as to working.json;
        // keep every saved assignment and leave strict validation in place.
        for (key, role) in baseline.mappings where legacy.mappings[key] == nil { legacy.mappings[key] = role }
        guard legacy.schemaVersion == 1, baseline.schemaVersion == 2 else { return try legacy.resolvingColors() }
        var result = legacy
        for (key, role) in baseline.mappings where result.mappings[key] == nil { result.mappings[key] = role }
        result.schemaVersion = 2; result.primitives = baseline.primitives
        result.colorAliases = baseline.colorAliases; result.primitiveSource = baseline.primitiveSource
        for path in (baseline.colorAliases ?? [:]).keys {
            for mode in ["light", "dark"] {
                guard let saved = legacy.colorValue(path, mode: mode)?.designString,
                      let original = legacyBaseline.colorValue(path, mode: mode)?.designString else { continue }
                if DesignWorkingDocument.canonicalHex(saved) != DesignWorkingDocument.canonicalHex(original) {
                    let name = "saved/" + path + "/" + mode
                    result.primitives?[name] = DesignPrimitiveColor(light: saved, dark: saved)
                    result.colorAliases?[path]?[mode] = name
                }
            }
        }
        return try result.resolvingColors()
    }
    func editPrimitive(_ name: String, mode: String, hex: String) {
        var candidate = document
        guard candidate.primitives?[name] != nil else { return }
        candidate.primitives?[name]?[mode] = hex
        commit(candidate)
    }
    func assignPrimitive(_ path: String, mode: String, primitive: String) {
        var candidate = document
        guard candidate.colorAliases?[path] != nil else { return }
        candidate.colorAliases?[path]?[mode] = primitive
        commit(candidate)
    }
    func replaceFromCatalog(_ legacy: [String: Any]) {
        do { commit(try decodeCatalog(legacy)) }
        catch { status = "Change not applied: \(error.localizedDescription)" }
    }
    func role(_ key: String) -> String { document.mappings[key] ?? key }
    func value(_ role: String, mode: String) -> JSONValue { document.tokens[role]?[mode] ?? .null }
    func choices(kind: String) -> [String] {
        document.tokens.keys.filter {
            guard let token = document.tokens[$0], token.type == kind else { return false }
            // Formula tokens stay visible in the browser but cannot feed scalar controls.
            return kind != "dimension" || (token.light.designNumber != nil && token.dark.designNumber != nil)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func assign(_ key: String, to role: String) {
        var candidate = document; candidate.mappings[key] = role
        candidate.explicitAssignments = (candidate.explicitAssignments ?? []).union([key]); commit(candidate)
    }
    func edit(_ role: String, mode: String, value: JSONValue, field: String? = nil) {
        var candidate = document
        let colorPath = field == "color" ? role + ".color" : role
        if candidate.colorAliases?[colorPath] != nil {
            status = "Choose a primitive for semantic colors; edit hex values in Primitives."
            return
        }
        guard var token = candidate.tokens[role] else { return }
        let modes = token.type == "dimension" ? ["light", "dark"] : [mode]
        for target in modes {
            if let field {
                guard case .object(var recipe) = token[target] else { return }
                recipe[field] = value; token[target] = .object(recipe)
            } else { token[target] = value }
        }
        candidate.tokens[role] = token
        for target in modes { candidate.updateBoundValue(role + (field.map { "." + $0 } ?? ""), mode: target, value: field.flatMap { token[target].designObject?[$0] } ?? token[target]) }
        commit(candidate)
    }
    private func commit(_ candidate: DesignWorkingDocument) {
        guard candidate != document else { return }
        do {
            let candidate = try candidate.resolvingColors()
            try validate(candidate)
            let snapshot = try makeSnapshot(candidate)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(candidate).write(to: workingFile, options: .atomic)
            undoHistory.append(document); if undoHistory.count > 100 { undoHistory.removeFirst() }
            redoHistory.removeAll(); document = candidate
            apply(snapshot); status = "All working changes saved"; updateHistory()
        } catch { status = "Change not applied: \(error.localizedDescription)" }
    }
    private func restore(_ candidate: DesignWorkingDocument) throws {
        try validate(candidate)
        let snapshot = try makeSnapshot(candidate)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(candidate).write(to: workingFile, options: .atomic)
        document = candidate; apply(snapshot); status = "All working changes saved"; updateHistory()
    }
    func undo() {
        guard let value = undoHistory.last else { return }
        let prior = document
        do { try restore(value); undoHistory.removeLast(); redoHistory.append(prior); updateHistory() }
        catch { status = "Undo failed: \(error.localizedDescription)" }
    }
    func redo() {
        guard let value = redoHistory.last else { return }
        let prior = document
        do { try restore(value); redoHistory.removeLast(); undoHistory.append(prior); updateHistory() }
        catch { status = "Redo failed: \(error.localizedDescription)" }
    }
    func reset() { commit(baseline) }
    private func updateHistory() { canUndo = !undoHistory.isEmpty; canRedo = !redoHistory.isEmpty }
    func snapshot(_ name: String) {
        do {
            let safe = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
            let file = root.appendingPathComponent("Snapshots").appendingPathComponent("\(safe.isEmpty ? "Snapshot" : String(safe.prefix(50)))-\(UUID().uuidString.prefix(8)).json")
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
            reloadSnapshots(); status = "Snapshot saved: \(file.lastPathComponent)"
        } catch { status = "Snapshot failed: \(error.localizedDescription)" }
    }
    func loadSnapshot(_ url: URL) {
        do { let value = try migrateColors(JSONDecoder().decode(DesignWorkingDocument.self, from: Data(contentsOf: url))); try validate(value); commit(value) }
        catch { status = "Snapshot not applied: \(error.localizedDescription)" }
    }
    private func reloadSnapshots() {
        snapshots = ((try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Snapshots"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func changesForReview() -> JSONValue {
        var changed: [String: JSONValue] = [:]
        for (name, token) in document.tokens where token != legacyBaseline.tokens[name] {
            let old = legacyBaseline.tokens[name]
            changed[name] = .object(["light":.object(["old":old?.light ?? .null,"new":token.light]), "dark":.object(["old":old?.dark ?? .null,"new":token.dark])])
        }
        let mappings = Dictionary(uniqueKeysWithValues: document.mappings.filter { legacyBaseline.mappings[$0.key] != $0.value || document.explicitAssignments?.contains($0.key) == true || DesignTypographyTokens.roles.contains($0.value) }.map { key, value in
            (key, JSONValue.object(["old":.string(legacyBaseline.tokens[legacyBaseline.mappings[key] ?? ""] == nil ? "" : legacyBaseline.mappings[key] ?? ""), "new":.string(value)]))
        })
        return JSONValue.object(["sourceRevision":.string(Self.revision), "baselineSHA256":.string(baseline.baselineSHA256),
            "status":.string("Reviewed experimental changes; provisional visual values. Does not apply itself to the app or handoff."),
            "tokens":.object(changed), "componentAssignments":.object(mappings),
            "adaptationNotes":.array([
                .string("The preserved 55-family catalog assignments remain intact. Semantic colors resolve from the live Figma primitive palette; saved experiments remain as explicit saved primitives. Original catalog values are preserved, including its pre-existing mode-specific label tracking; typography edits are independent by appearance."),
                .string("Numeric font weights resolve to nearest native weight; line height is a minimum and tracking scales once."),
                .string("One classic native window material; CSS blur radius is a visual reference, not an AppKit numeric parameter.")
            ])])
    }
    @discardableResult func exportChanges() throws -> URL {
        let export = changesForReview()
        let folder = root.appendingPathComponent("Exports"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Reviewed-changes-\(UUID().uuidString.prefix(8)).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(export).write(to: file, options: .atomic)
        let editable = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-editable.json")
        try encoder.encode(DesignLibraryDefinition.pruned(document, baseline: baseline)).write(to: editable, options: .atomic)
        status = "Exported resolved changes and editable primitives: \(file.path)"; return file
    }
    private func validate(_ candidate: DesignWorkingDocument) throws {
        guard candidate.schemaVersion == baseline.schemaVersion, candidate.sourceRevision == baseline.sourceRevision,
            candidate.baselineSHA256 == baseline.baselineSHA256, Set(baseline.tokens.keys).isSubset(of: Set(candidate.tokens.keys)),
            Set(candidate.mappings.keys) == Set(baseline.mappings.keys) else {
            let extra = Set(candidate.mappings.keys).subtracting(baseline.mappings.keys).sorted()
            let missing = Set(baseline.mappings.keys).subtracting(candidate.mappings.keys).sorted()
            throw DesignWorkingError.invalid("Compatibility: extra assignments \(extra), missing assignments \(missing)")
        }
        guard (candidate.explicitAssignments ?? []).isSubset(of: Set(candidate.mappings.keys)) else { throw DesignWorkingError.invalid("Explicit assignments") }
        if baseline.schemaVersion == 2 {
            guard let aliases = candidate.colorAliases, let primitives = candidate.primitives,
                  Set((baseline.colorAliases ?? [:]).keys).isSubset(of: Set(aliases.keys)),
                  Set((baseline.primitives ?? [:]).keys).isSubset(of: Set(primitives.keys)),
                  try candidate.resolvingColors() == candidate else { throw DesignWorkingError.invalid("Primitive aliases") }
        }
        for (key, role) in candidate.mappings {
            guard let type = candidate.tokens[role]?.type,
                type == baseline.tokens[baseline.mappings[key] ?? ""]?.type else { throw DesignWorkingError.invalid("Assignment \(key)") }
            if key.hasPrefix("component.button."), type == "dimension",
                candidate.tokens[role]?.light.designNumber == nil {
                throw DesignWorkingError.invalid("Scalar button assignment: \(key)")
            }
        }
        for (name, token) in candidate.tokens {
            if ["color.surface.none", "color.border.none"].contains(name) {
                guard token.light == .string("#00000000"), token.dark == .string("#00000000"), candidate.colorAliases?[name] == nil else { throw DesignWorkingError.invalid("None must remain transparent") }
            }
            guard token.type == baseline.tokens[name]?.type else { throw DesignWorkingError.invalid(name) }
            for mode in ["light", "dark"] {
                let v = token[mode]
                if token.type == "color" {
                    guard case .string(let hex) = v, hex.range(of:"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$",options:.regularExpression) != nil else { throw DesignWorkingError.invalid(name) }
                } else if token.type == "typography" {
                    guard case .object(let recipe) = v, case .string(let family)? = recipe["family"], !family.isEmpty else { throw DesignWorkingError.invalid(name) }
                    for field in ["size", "weight", "lineHeight", "tracking"] {
                        guard case .number(let n)? = recipe[field], n.isFinite,
                            (field == "tracking" || n >= 0), (field != "weight" || n <= 1000), (field != "size" || n > 0) else { throw DesignWorkingError.invalid(name + "." + field) }
                    }
                } else if token.type == "effect" {
                    let recipe = try JSONDecoder().decode(DesignEffectRecipe.self, from: JSONEncoder().encode(v))
                    for layer in recipe.layers {
                        guard ["INNER_SHADOW", "DROP_SHADOW"].contains(layer.type), layer.blendMode == "NORMAL",
                              [layer.x, layer.y, layer.blur, layer.spread].allSatisfy({ $0.isFinite }), layer.blur >= 0,
                              layer.color.range(of: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$", options: .regularExpression) != nil else { throw DesignWorkingError.invalid(name) }
                    }
                } else if case .number(let number) = v {
                    guard number.isFinite, number >= 0, (name != "material.window.tintOpacity" || number <= 1) else { throw DesignWorkingError.invalid(name) }
                }
            }

        }
        _ = try makeSnapshot(candidate)
    }
    private func publish(_ candidate: DesignWorkingDocument) throws { apply(try makeSnapshot(candidate)) }
    private func apply(_ snapshot: DesignThemeSnapshot) {
        guard notifiesApp else { return }
        DesignThemeOverlay.shared.install(snapshot)
        ThemeManager.shared.refreshDesignInspection()
    }
    func makeSnapshot(_ candidate: DesignWorkingDocument) throws -> DesignThemeSnapshot {
        try DesignLibraryDefinition.makeSnapshot(candidate, baseline: baseline)
    }
    static func path(for role: String) -> [String]? { DesignLibraryDefinition.path(for: role) }

}

#endif

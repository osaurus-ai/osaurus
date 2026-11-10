#if OSAURUS_DESIGN_INSPECTOR
import Foundation

/// Opt-in deterministic checks in an isolated temporary store. Never edits the
/// user's working design, workflows, model configuration or credentials.
@MainActor enum DesignCatalogLayoutChecks {
    static func run(_ live: DesignWorkingStore) {
        var results: [String: Any] = [:]
        do {
            func check(_ passed: Bool, _ name: String) throws {
                results[name] = passed
                if !passed { throw DesignWorkingError.invalid(name) }
            }
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Inspector-Layout-Checks-" + UUID().uuidString)
            let tokens = Bundle.module.url(forResource: "semantic-tokens", withExtension: "json", subdirectory: "DesignInspectorResources")!
            let maps = Bundle.module.url(forResource: "component-mappings", withExtension: "json", subdirectory: "DesignInspectorResources")!
            let primitives = Bundle.module.url(forResource: "primitive-colors", withExtension: "json", subdirectory: "DesignInspectorResources")!
            func make() throws -> DesignWorkingStore {
                try DesignWorkingStore(root: root, tokenData: Data(contentsOf: tokens), mappingData: Data(contentsOf: maps), primitiveData: Data(contentsOf: primitives), notifiesApp: false)
            }
            let before = live.document
            let regularHeight = "component.library.56.elements.regular.height"
            let smallHeight = "component.library.56.elements.small.height"
            var oldChips = before
            oldChips.mappings[regularHeight] = "space.24"
            oldChips.mappings[smallHeight] = "space.24"
            oldChips.explicitAssignments?.remove(regularHeight)
            oldChips.explicitAssignments?.remove(smallHeight)
            let resized = CatalogElementAssignments.migrate(oldChips)
            try check(resized.mappings[regularHeight] == "size.control.compactHeight"
                && resized.mappings[smallHeight] == "space.24", "chipHeightsUseApprovedDefaults")
            var explicitChip = oldChips
            explicitChip.explicitAssignments = (explicitChip.explicitAssignments ?? []).union([regularHeight])
            try check(CatalogElementAssignments.migrate(explicitChip).mappings[regularHeight] == "space.24",
                "regularChipPreservesExplicitLegacyHeight")
            var legacy = before
            let layoutKeys = Set(CatalogLayoutAssignments.byKey.keys)
            legacy.mappings = legacy.mappings.filter { !layoutKeys.contains($0.key) }
            legacy.explicitAssignments = legacy.explicitAssignments?.subtracting(layoutKeys)
            let migrated = CatalogElementAssignments.migrate(legacy)
            try check(legacy.mappings.allSatisfy { migrated.mappings[$0.key] == $0.value }, "migrationPreservesEverySavedMapping")
            try check(migrated.tokens == legacy.tokens && migrated.primitives == legacy.primitives && migrated.colorAliases == legacy.colorAliases && migrated.valueAliases == legacy.valueAliases && migrated.scalarPrimitives == legacy.scalarPrimitives, "migrationPreservesAllSavedStylesAndAliases")
            try check(migrated.explicitAssignments == legacy.explicitAssignments, "migrationPreservesExplicitChoices")
            try check(CatalogElementAssignments.migrate(migrated) == migrated, "migrationIsIdempotent")
            try check(layoutKeys.count == CatalogLayoutAssignments.entries.count, "independentKeysAreUnique")
            try check(CatalogLayoutAssignments.entries.allSatisfy { migrated.tokens[migrated.mappings[$0.key] ?? ""]?.type == "dimension" }, "everyLayoutAssignmentUsesAnExistingDimensionToken")
            let encoder = JSONEncoder()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try encoder.encode(legacy).write(to: root.appendingPathComponent("working.json"), options: .atomic)
            let store = try make()
            let initial = store.document
            try check(legacy.mappings.allSatisfy { initial.mappings[$0.key] == $0.value }, "oldWorkingFileRelaunchPreservesMappings")
            let keys = ["component.library.14.elements.layout.row.paddingX", "component.library.14.elements.layout.row.paddingY", "component.library.14.elements.layout.row.titleDescriptionGap", "component.input.labelGap", "component.input.helperGap", "component.library.56.elements.layout.regular.paddingY", "component.library.33.elements.layout.contentTopGap"]
            for key in keys {
                try check(initial.mappings[key] != nil, "registered_" + key)
                let inherited = 17.0
                let snapshot = try store.makeSnapshot(store.document)
                try check(CatalogLayoutAssignments.resolve(key, snapshot: snapshot, mode: "dark", inheriting: inherited) == inherited, "uneditedInheritsActualValue_" + key)
                store.assign(key, to: "space.24")
                let edited = store.document
                try check(edited.explicitAssignments?.contains(key) == true && edited.mappings[key] == "space.24", "explicitSelectionSaved_" + key)
                try check(initial.mappings.allSatisfy { $0.key == key || edited.mappings[$0.key] == $0.value }, "selectionDoesNotChangeOtherAssignments_" + key)
                let editedSnapshot = try store.makeSnapshot(edited)
                for mode in ["light", "dark"] {
                    try check(CatalogLayoutAssignments.resolve(key, snapshot: editedSnapshot, mode: mode, inheriting: inherited) == edited.tokens["space.24"]?[mode].designNumber, "resolvesSelectedToken_" + mode + key)
                }
                store.undo(); try check(store.document == initial, "undoRestoresExactDocument_" + key)
                store.redo(); try check(store.document == edited, "redoRestoresExactDocument_" + key)
                try check(try make().document == edited, "relaunchPreservesAssignment_" + key)
                store.undo()
            }
            store.assign(keys[0], to: "space.24")
            let edited = store.document
            store.snapshot("Independent layout")
            store.reset(); store.loadSnapshot(store.snapshots.first { $0.lastPathComponent.hasPrefix("Independent layout-") }!)
            try check(store.document == edited, "snapshotRestoresLayoutAndSavedStyles")
            let export = try store.exportChanges()
            let exported = try String(contentsOf: export, encoding: .utf8)
            try check(exported.contains(keys[0]), "engineeringExportContainsAssignment")
            let catalog = store.catalogDocument(); store.replaceFromCatalog(catalog)
            try check(store.document == edited, "editableInspectorRoundTrip")
            store.reset(); try check(store.document == store.baseline, "resetUsesCurrentBaseline")
            try check(live.document == before, "liveDesignUntouchedByChecks")
            results["layoutAssignments"] = layoutKeys.count
            results["status"] = "passed"
        } catch {
            results["status"] = "failed"
            results["error"] = error.localizedDescription
        }
        let output = ProcessInfo.processInfo.environment["OSAURUS_CATALOG_LAYOUT_CHECKS_OUTPUT"] ?? "/tmp/osaurus-catalog-layout-checks.json"
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
#endif

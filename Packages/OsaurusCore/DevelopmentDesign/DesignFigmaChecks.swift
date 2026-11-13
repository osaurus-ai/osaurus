#if OSAURUS_DESIGN_INSPECTOR
import AppKit
import Foundation

@MainActor enum DesignFigmaChecks {
    static func reassigned(_ snapshot: DesignThemeSnapshot) -> Set<String> {
        (snapshot.document.editedAssignments ?? []).union(snapshot.document.explicitAssignments ?? [])
    }
    /// Focused default-selection persistence check in a disposable store.
    static func runAppDefaults(_ live: DesignWorkingStore) {
        var results: [String: Bool] = [:]
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Osaurus-Default-Checks-" + UUID().uuidString)
            func resource(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "DesignInspectorResources")!) }
            func make() throws -> DesignWorkingStore { try DesignWorkingStore(root: root, tokenData: resource("semantic-tokens"), mappingData: resource("component-mappings"), primitiveData: resource("primitive-colors"), notifiesApp: false) }
            let store = try make(), baseline = store.document
            results.merge(try DesignMessageChecks.run(store)) { _, new in new }
            let inverse = "color.surface.inverse"
            results["inverseAliasBothModes"] = baseline.colorAliases?[inverse]?.light == "neutral/900" && baseline.colorAliases?[inverse]?.dark == "neutral/900"
            results["inverseResolvesFromPrimitives"] = baseline.tokens[inverse]?.light == .string(baseline.primitives!["neutral/900"]!.light) && baseline.tokens[inverse]?.dark == .string(baseline.primitives!["neutral/900"]!.dark)
            var oldLibrary = baseline
            oldLibrary.tokens.removeValue(forKey: inverse); oldLibrary.colorAliases?.removeValue(forKey: inverse)
            try JSONEncoder().encode(oldLibrary).write(to: store.workingFile, options: .atomic)
            let upgraded = try make().document
            results["inverseAddedWithoutChangingSavedDesign"] = upgraded == baseline
            let bubble = "component.library.28.elements.container.background"
            store.assign(bubble, to: inverse)
            let assignedInverse = store.document
            results["inverseCanBeAssigned"] = assignedInverse.mappings[bubble] == inverse
            results["inverseAssignmentSurvivesRelaunch"] = try make().document == assignedInverse
            store.assignPrimitive(inverse, mode: "dark", primitive: "neutral/800")
            results["inverseModesIndependent"] = store.document.tokens[inverse]?.light == baseline.tokens[inverse]?.light && store.document.tokens[inverse]?.dark == .string(baseline.primitives!["neutral/800"]!.dark)
            store.undo(); results["inverseUndo"] = store.document == assignedInverse
            store.redo(); results["inverseRedo"] = store.document.colorAliases?[inverse]?.dark == "neutral/800"
            store.snapshot("Inverse surface")
            let inverseSnapshot = store.document
            store.reset(); store.loadSnapshot(store.snapshots.first { $0.lastPathComponent.hasPrefix("Inverse surface-") }!)
            results["inverseSnapshotRoundTrip"] = store.document == inverseSnapshot
            let inverseExport = try store.exportChanges()
            results["inverseEngineeringExport"] = try String(contentsOf: inverseExport, encoding: .utf8).contains(inverse)
            store.reset()
            let key = "component.library.13.elements.container.radius"
            let role = baseline.mappings[key]!
            results["uneditedUsesAppDefault"] = !Self.reassigned(try store.makeSnapshot(baseline)).contains(key)
            store.assign(key, to: role)
            let selected = store.document
            results["sameTokenSelectionIsExplicit"] = Self.reassigned(try store.makeSnapshot(selected)).contains(key)
            results["valuesAndMappingsPreserved"] = selected.mappings == baseline.mappings && selected.tokens == baseline.tokens && selected.primitives == baseline.primitives
            store.undo(); results["undoRestoresAppDefault"] = store.document == baseline
            store.redo(); results["redoRestoresSelection"] = store.document == selected
            results["relaunchPreservesSelection"] = try make().document == selected
            store.snapshot("Explicit assignment")
            store.reset(); store.loadSnapshot(store.snapshots[0])
            results["snapshotPreservesSelection"] = store.document == selected
            let export = try store.exportChanges()
            results["engineeringExportIncludesSelection"] = try String(contentsOf: export, encoding: .utf8).contains(key)
            let catalog = store.catalogDocument()
            store.replaceFromCatalog(catalog)
            results["catalogRoundTrip"] = store.document == selected
            store.reset(); results["resetRestoresDefaults"] = store.document == baseline
        } catch { results["unexpectedError"] = false }
        let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: "/tmp/osaurus-app-default-checks.json"), options: .atomic)
    }
    /// Explicit opt-in local regression checks; never mutates the user's store.
    static func run(_ live: DesignWorkingStore) {
        var results: [String: Any] = [:]
        do {
            func require(_ value: Bool, _ name: String) throws {
                results[name] = value
                if !value { throw DesignWorkingError.invalid("Figma check: " + name) }
            }
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Osaurus-Figma-Checks-" + UUID().uuidString)
            let tokens = Bundle.module.url(forResource: "semantic-tokens", withExtension: "json", subdirectory: "DesignInspectorResources")!
            let maps = Bundle.module.url(forResource: "component-mappings", withExtension: "json", subdirectory: "DesignInspectorResources")!
            let primitives = Bundle.module.url(forResource: "primitive-colors", withExtension: "json", subdirectory: "DesignInspectorResources")!
            func make() throws -> DesignWorkingStore { try DesignWorkingStore(root:root,tokenData:Data(contentsOf:tokens),mappingData:Data(contentsOf:maps),primitiveData:Data(contentsOf:primitives),notifiesApp:false) }
            let test = try make()
            let baseline = test.document
            var legacy = baseline
            legacy.mappings = legacy.mappings.filter { !$0.key.contains(".elements.") }
            legacy.mappings["component.library.26.radius"] = "radius.large"
            legacy.mappings["component.input.radius"] = "radius.small"
            let migrated = CatalogElementAssignments.migrate(legacy)
            try require(legacy.mappings.allSatisfy { migrated.mappings[$0.key] == $0.value }, "elementsPreserveEverySavedAssignment")
            try require(migrated.tokens == legacy.tokens && migrated.primitives == legacy.primitives && migrated.colorAliases == legacy.colorAliases, "elementsPreserveSavedStyles")
            try require(CatalogElementAssignments.migrate(migrated) == migrated, "elementsMigrationIdempotent")
            for family in 3...55 {
                let prefix = "component.library.\(family)"
                for element in ["container", "row", "badge", "editor", "chip", "image"] {
                    try require(migrated.mappings[prefix + ".elements." + element + ".radius"] == legacy.mappings[prefix + ".radius"], "elementsInheritSavedRadius_\(family)_" + element)
                }
                try require(migrated.mappings[prefix + ".elements.input.radius"] == "radius.small", "nestedInputInheritsSavedRadius_\(family)")
            }
            let rowKey = "component.library.26.elements.row.radius"
            test.assign(rowKey, to: "radius.small")
            try require(test.document.mappings[rowKey] == "radius.small", "independentRowAssignment")
            try require(baseline.mappings.allSatisfy { $0.key == rowKey || test.document.mappings[$0.key] == $0.value }, "rowEditLeavesEveryOtherAssignmentAlone")
            let elementEdit = test.document
            test.undo(); try require(test.document == baseline, "elementUndo")
            test.redo(); try require(test.document == elementEdit, "elementRedo")
            let elementReload = try make(); try require(elementReload.document == elementEdit, "elementRelaunchPersistence")
            test.snapshot("Independent elements regression")
            test.reset(); test.loadSnapshot(test.snapshots[0])
            try require(test.document == elementEdit, "elementSnapshotRestore")
            test.reset()
            for (key, role) in [("component.library.26.background", "color.surface.none"), ("component.library.26.border", "color.border.none"), ("component.button.primary.default.background", "color.surface.none"), ("component.input.border", "color.border.none")] {
                test.assign(key, to:role)
                try require(test.document.mappings[key] == role, "noneAccepted_" + key)
                for mode in ["light","dark"] { try require(test.document.tokens[role]?[mode] == .string("#00000000"), "noneResolved_" + key + mode) }
            }
            let noSurfaces = test.document
            test.undo(); test.redo(); try require(test.document == noSurfaces, "noneUndoRedo")
            let noneReloaded = try make(); try require(noneReloaded.document == noSurfaces, "noneSavedReload")
            let noneExport = try test.exportChanges()
            try require(String(data:Data(contentsOf:noneExport),encoding:.utf8)?.contains("color.surface.none") == true, "noneEngineeringExport")
            test.reset(); try require(test.document == baseline, "noneReset")
            try require(!CatalogAssignmentMenu.allows("color.action.primary.default.foreground",for:"component.input.foreground",kind:"color"), "menuHidesButtonTokensOutsideButtons")
            try require(!CatalogAssignmentMenu.allows("color.surface.raised",for:"component.input.foreground",kind:"color"), "menuHidesSurfaceFromText")
            try require(CatalogAssignmentMenu.allows("color.text.primary",for:"component.input.foreground",kind:"color"), "menuAllowsText")
            try require(CatalogAssignmentMenu.allows("color.status.error.foreground",for:"component.input.foreground",kind:"color"), "menuAllowsStatusText")
            try require(CatalogAssignmentMenu.allows("color.action.primary.default.background",for:"component.button.primary.default.background",kind:"color"), "menuAllowsButtonFill")
            try require(!CatalogAssignmentMenu.allows("color.action.primary.default.foreground",for:"component.button.primary.default.background",kind:"color"), "menuSeparatesButtonFillAndText")
            try require(CatalogAssignmentMenu.allows("color.surface.raised",for:"component.library.26.background",kind:"color"), "menuAllowsSurface")
            try require(!CatalogAssignmentMenu.allows("color.text.primary",for:"component.library.26.background",kind:"color"), "menuHidesTextFromSurface")
            try require(CatalogAssignmentMenu.allows("color.border.default",for:"component.input.border",kind:"color"), "menuAllowsBorder")
            try require(!CatalogAssignmentMenu.allows("color.status.error.background",for:"component.input.border",kind:"color"), "menuHidesFillFromBorder")
            try require(CatalogAssignmentMenu.allows("radius.medium",for:"component.input.radius",kind:"dimension") && !CatalogAssignmentMenu.allows("space.16",for:"component.input.radius",kind:"dimension"), "menuFiltersRadius")
            try require(CatalogAssignmentMenu.allows("space.16",for:"component.input.paddingX",kind:"dimension") && !CatalogAssignmentMenu.allows("radius.medium",for:"component.input.paddingX",kind:"dimension"), "menuFiltersSpacing")
            try require(CatalogAssignmentMenu.group("color.text.primary",kind:"color") == "Text" && CatalogAssignmentMenu.group("color.action.primary.default.background",kind:"color") == "Button · Primary", "menuHeaders")
            // A library expansion must be additive even for older saved snapshots.
            var older = baseline
            older.tokens.removeValue(forKey: "type.labelEmphasis")
            older.valueAliases = older.valueAliases?.filter { !$0.key.hasPrefix("type.labelEmphasis.") }
            older.scalarPrimitives = older.scalarPrimitives?.filter { !$0.key.hasPrefix("values/type/labelEmphasis/") }
            older.mappings["component.button.paddingX"] = "space.24"
            let expanded = try DesignFigmaSync.upgrade(older, baseline: baseline)
            try require(older.tokens.allSatisfy { expanded.tokens[$0.key] == $0.value }, "libraryPreservesSavedTokens")
            try require(expanded.mappings == older.mappings, "libraryPreservesSavedAssignments")
            try require(expanded.tokens["type.labelEmphasis"]?.light.designObject?["lineHeight"] == .number(22), "labelEmphasisLight")
            try require(expanded.tokens["type.labelEmphasis"]?.dark.designObject?["lineHeight"] == .number(13), "labelEmphasisDark")
            let expandedAgain = try DesignFigmaSync.upgrade(expanded, baseline: baseline)
            try require(expandedAgain == expanded, "libraryUpgradeIdempotent")
            for (size, height) in [("default", 32.0), ("small", 28.0), ("extraSmall", 24.0), ("extraExtraSmall", 16.0)] {
                let key = "component.button.size.\(size).height"
                try require(baseline.tokens[baseline.mappings[key] ?? ""]?.dark == .number(height), "buttonHeight_" + size)
            }
            try require(DesignButtonBindings.libraryDefaults.values.allSatisfy { baseline.tokens[$0] != nil }, "buttonAssignmentsResolve")
            test.editPrimitive("neutral/900",mode:"light",hex:"#123456FF")
            try require(test.document != baseline, "primitiveEditAccepted")
            try require(test.document.tokens.values.filter { $0.light == .string("#123456FF") }.count > 1, "primitiveUpdatesMultipleSemanticTokens")
            try require(test.document.tokens.allSatisfy { $0.value.dark == baseline.tokens[$0.key]?.dark }, "primitiveDarkUnchanged")
            test.undo(); try require(test.document == baseline,"undo")
            test.redo(); try require(test.document.primitives?["neutral/900"]?.light == "#123456FF","redo")
            test.reset(); try require(test.document == baseline,"resetToFigma")
            test.edit("type.label",mode:"light",value:.number(17),field:"size")
            try require(test.document.tokens["type.label"]?.light.designObject?["size"] == .number(17),"labelLightEdit")
            try require(test.document.tokens["type.label"]?.dark == baseline.tokens["type.label"]?.dark,"labelDarkUnchanged")
            test.assign("component.button.secondary.default.effect",to:"effect.bevel.raised.neutral")
            try require(test.document.mappings["component.button.secondary.default.effect"] == "effect.bevel.raised.neutral","effectAssignment")
            test.snapshot("Figma local regression")
            let saved = test.document
            let export = try test.exportChanges()
            try require(FileManager.default.fileExists(atPath:export.path),"engineeringExport")
            test.reset(); test.loadSnapshot(test.snapshots[0]); try require(test.document == saved,"snapshotRestore")
            let reloaded = try make(); try require(reloaded.document == saved,"relaunchPersistence")
            for family in ["SF Pro","SF Mono"] {
                let font = NSFont(name:family,size:15) ?? NSFontManager.shared.font(withFamily:family,traits:[],weight:5,size:15)
                results["font_" + family] = font.map { ["family":$0.familyName ?? "", "name":$0.fontName] } ?? [:]
                try require(font != nil,"fontResolved_" + family)
            }
            results["status"] = "passed"
        } catch { results["status"] = "failed"; results["error"] = error.localizedDescription }
        let out = live.root.appendingPathComponent("figma-sync-checks.json")
        try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:out,options:.atomic)
    }
}
#endif

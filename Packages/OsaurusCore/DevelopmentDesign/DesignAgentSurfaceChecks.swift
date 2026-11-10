#if OSAURUS_DESIGN_INSPECTOR
import AppKit
import SwiftUI

/// Opt-in, windowless checks against real native renderers and a temporary
/// working store. Never edits the user's working design or runs a tool/model.
@MainActor enum DesignAgentSurfaceChecks {
    static func run(_ live: DesignWorkingStore) -> Int32 {
        var results: [String: Any] = [:]
        let liveDocument = live.document
        let previousSnapshot = DesignThemeOverlay.shared.current()
        defer { if let previousSnapshot { DesignThemeOverlay.shared.install(previousSnapshot) } }
        do {
            func check(_ value: Bool, _ name: String) throws {
                results[name] = value
                if !value { throw DesignWorkingError.invalid(name) }
            }
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Agent-Surface-Checks-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let entries = AgentContentSurfaceAssignments.entries
            let newKeys = Set(entries.map(\.key))
            var legacy = liveDocument
            legacy.mappings = legacy.mappings.filter { !newKeys.contains($0.key) }
            let migrated = CatalogElementAssignments.migrate(legacy)
            try check(legacy.mappings.allSatisfy { migrated.mappings[$0.key] == $0.value }, "migrationPreservesExistingAssignments")
            try check(migrated.tokens == legacy.tokens && migrated.primitives == legacy.primitives && migrated.colorAliases == legacy.colorAliases && migrated.valueAliases == legacy.valueAliases && migrated.scalarPrimitives == legacy.scalarPrimitives, "migrationPreservesAllStyleValuesAndAliases")
            try check(migrated.explicitAssignments == legacy.explicitAssignments, "migrationPreservesExplicitChoices")
            try check(CatalogElementAssignments.migrate(migrated) == migrated, "migrationIsIdempotent")
            try check(entries.count == newKeys.count, "surfaceKeysAreUnique")
            try check(entries.allSatisfy { migrated.tokens[migrated.mappings[$0.key] ?? ""]?.type == "color" }, "allSurfaceAssignmentsUseExistingSemanticColors")
            try check(entries.allSatisfy { CatalogAssignmentMenu.allows($0.token, for: $0.key, kind: "color") }, "surfacePickersAcceptTheirAssignedTokens")
            try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("working.json"), options: .atomic)
            func make() throws -> DesignWorkingStore {
                func data(_ name: String) throws -> Data {
                    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "DesignInspectorResources")!)
                }
                return try DesignWorkingStore(root: root, tokenData: data("semantic-tokens"), mappingData: data("component-mappings"), primitiveData: data("primitive-colors"), notifiesApp: false)
            }
            let store = try make()
            let initial = store.document
            func install() throws { DesignThemeOverlay.shared.install(try store.makeSnapshot(store.document)) }
            try install()
            let dark = CustomizableTheme.dark()
            let light = CustomizableTheme.light()
            func equal(_ actual: CGColor?, _ expected: Color) -> Bool {
                guard let actual, let a = NSColor(cgColor: actual)?.usingColorSpace(.sRGB),
                      let b = NSColor(expected).usingColorSpace(.sRGB) else { return false }
                return zip([a.redComponent,a.greenComponent,a.blueComponent,a.alphaComponent], [b.redComponent,b.greenComponent,b.blueComponent,b.alphaComponent]).allSatisfy { abs($0 - $1) < 0.005 }
            }
            let call = ToolCallItem(call: .init(id: "surface-check", type: "function", function: .init(name: "read_file", arguments: "{\"sample\":true}")), result: "{\"ok\":true}", duration: 0.4)
            let row = NativeToolCallRowView()
            func configure(_ theme: any ThemeProtocol) {
                row.configure(item: call, index: 0, totalCount: 1, isExpanded: true, width: 640, theme: theme, onToggle: {}, onHeightChanged: {})
            }
            configure(dark)
            try check(equal(row.layer?.backgroundColor, dark.surface.canvas), "actualExpandedToolCardUsesCanvas")
            let header = InspectorActivityHeaderSurface()
            header.configure(theme: dark, selected: false)
            try check(equal(header.layer?.backgroundColor, dark.surface.canvas), "actualToolHeaderUsesCanvas")
            header.configure(theme: dark, selected: true)
            try check(equal(header.layer?.backgroundColor, dark.surface.canvas), "actualExpandedToolHeaderStaysCanvas")
            let pending = NativePendingToolCallView()
            pending.configure(toolName: "read_file", argPreview: nil, argSize: 0, theme: dark)
            try check(equal(pending.layer?.backgroundColor, dark.surface.canvas), "actualPendingToolUsesCanvas")
            let reasoning = NativeThinkingView()
            reasoning.configure(thinking: "Local rendering check.", thinkingLength: nil, width: 640, isStreaming: false, isExpanded: true, duration: 1, theme: dark, blockId: "surface-reasoning", sessionRedactions: [:], onToggle: {}, onHeightChanged: {})
            try check(equal(reasoning.layer?.backgroundColor, dark.surface.canvas), "actualExpandedReasoningUsesCanvas")
            configure(light)
            try check(equal(row.layer?.backgroundColor, light.surface.canvas), "actualToolUsesIndependentLightCanvas")
            let cardKey = AgentContentSurfaceAssignments.key(34, "toolCard")
            let headerKey = AgentContentSurfaceAssignments.key(34, "toolHeader")
            store.assign(cardKey, to: "color.surface.inverse")
            let edited = store.document
            try install(); configure(dark)
            try check(equal(row.layer?.backgroundColor, dark.assignedColor("color.surface.inverse", fallback: dark.surface.canvas)), "inspectorAssignmentChangesActualToolCard")
            header.configure(theme: dark, selected: false)
            try check(equal(header.layer?.backgroundColor, dark.surface.canvas) && edited.mappings[headerKey] == "color.surface.canvas", "cardEditDoesNotChangeHeader")
            try check(initial.mappings.filter { $0.key.hasPrefix("component.library.32.") } == edited.mappings.filter { $0.key.hasPrefix("component.library.32.") }, "codeBlockAssignmentsStayIndependent")
            store.undo(); try check(store.document == initial, "undoRestoresExactDocument")
            store.redo(); try check(store.document == edited, "redoRestoresExactEdit")
            try check(try make().document == edited, "autosaveRelaunchPreservesSurfaceEdit")
            store.snapshot("Agent surfaces")
            store.reset(); store.loadSnapshot(store.snapshots.first { $0.lastPathComponent.hasPrefix("Agent surfaces-") }!)
            try check(store.document == edited, "snapshotRestoresSurfaceEdit")
            let export = try String(contentsOf: store.exportChanges(), encoding: .utf8)
            try check(export.contains(cardKey), "exportContainsNewSurfaceAssignment")
            let editable = store.catalogDocument(); store.replaceFromCatalog(editable)
            try check(store.document == edited, "editableInspectorRoundTripPreservesSurfaces")
            try check(live.document == liveDocument, "userDesignUntouchedByChecks")
            results["surfaceAssignmentCount"] = entries.count
            results["status"] = "passed"
        } catch {
            results["status"] = "failed"
            results["error"] = error.localizedDescription
        }
        let destination = ProcessInfo.processInfo.environment["OSAURUS_AGENT_SURFACE_CHECKS_OUTPUT"] ?? NSTemporaryDirectory() + "/agent-surface-checks.json"
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
        return results["status"] as? String == "passed" ? 0 : 1
    }
}
#endif

import Foundation
import Testing

@testable import OsaurusCore

/// The shipped library holds only assignments that paint. A present mapping is
/// read by its component; an absent one leaves the component's own recipe.
@Suite("Pruned design library")
struct DesignLibraryPruningTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let document = try! JSONDecoder().decode(
        DesignWorkingDocument.self, from: DesignLibraryRuntime.resource("design-library"))

    private static func family(_ key: String) -> Int? {
        let parts = key.split(separator: ".")
        guard parts.count > 3, parts[0] == "component", parts[1] == "library" else { return nil }
        return Int(parts[2])
    }

    @Test func mappingCountIsFrozen() {
        // Changes only when the designer adds or reverts an assignment.
        #expect(Self.document.mappings.count == 7380)
    }

    @Test func everyKeyIsItsOwnRoute() {
        let mappings = Self.document.mappings
        let shadowed = mappings.keys.filter { CatalogElementAssignments.routed($0, mappings: mappings) != $0 }
        #expect(shadowed.isEmpty, "copies that never paint: \(shadowed.sorted().prefix(5))")
    }

    @Test func layoutSlotsArePresentOnlyWhenSet() {
        let explicit = Self.document.explicitAssignments ?? []
        let inherited = Self.document.mappings.keys.filter {
            (CatalogLayoutAssignments.byKey[$0] != nil || $0.contains(".elements.layout.")) && !explicit.contains($0)
        }
        #expect(inherited.isEmpty, "\(inherited.sorted().prefix(5))")
    }

    @Test func everyMappedLayoutSlotPaints() throws {
        let snapshot = try #require(DesignLibraryRuntime.bundledSnapshot())
        for (key, role) in Self.document.mappings where key.contains(".elements.layout.") {
            for mode in ["light", "dark"] {
                let token = try #require(Self.document.tokens[role]?[mode].designNumber, "\(key) → \(role)")
                #expect(CatalogLayoutAssignments.resolve(key, snapshot: snapshot, mode: mode, inheriting: -1) == max(0, token))
            }
        }
    }

    @Test func recipeFamiliesShipOnlyEdits() {
        let edited = (Self.document.editedAssignments ?? []).union(Self.document.explicitAssignments ?? [])
        let unedited = Self.document.mappings.keys.filter { key in
            guard let family = Self.family(key), DesignLibraryPruning.recipeFamilies.contains(family) else { return false }
            return !edited.contains(key) && !key.hasSuffix(DesignLibraryPruning.rowRadiusSuffix)
        }
        #expect(unedited.isEmpty, "\(unedited.sorted().prefix(5))")
    }

    @Test func delegatedBubblePropertiesAreAbsent() {
        for (family, properties) in DesignLibraryPruning.delegatedProperties {
            for property in properties {
                #expect(Self.document.mappings["component.library.\(family).\(property)"] == nil)
            }
        }
    }

    @Test func editRecordsNameShippedAssignments() {
        let keys = Set(Self.document.mappings.keys)
        #expect((Self.document.explicitAssignments ?? []).isSubset(of: keys))
        #expect((Self.document.editedAssignments ?? []).isSubset(of: keys))
        #expect((Self.document.editedTokens ?? []).isSubset(of: Set(Self.document.tokens.keys)))
    }

    @Test func pruningIsStable() {
        let doc = Self.document
        let again = DesignLibraryPruning.pruned(doc,
            edited: (doc.editedAssignments ?? []).union(doc.explicitAssignments ?? []),
            editedTokens: doc.editedTokens ?? [])
        #expect(again.mappings == doc.mappings)
        #expect(again.editedAssignments == doc.editedAssignments)
    }

    @Test func snapshotNeedsNoBaseline() throws {
        let snapshot = try #require(DesignLibraryRuntime.bundledSnapshot())
        #expect(snapshot.changedTokens == (Self.document.editedTokens ?? []))
        #expect(DesignLibraryRuntime.resourceNames == ["design-library"])
    }

    /// A literal key the app reads must name an assignment the catalog can hold,
    /// or the Inspector can never reach it.
    @Test func everyLiteralKeyReadIsACatalogKey() throws {
        let resources = Self.packageRoot.appendingPathComponent("DevelopmentDesign/DesignInspectorResources")
        func data(_ name: String) throws -> Data { try Data(contentsOf: resources.appendingPathComponent(name + ".json")) }
        let definition = try DesignLibraryDefinition.baseline(
            tokenData: data("semantic-tokens"), mappingData: data("component-mappings"), primitiveData: data("primitive-colors"))
        var known = Set(CatalogElementAssignments.migrate(definition.current).mappings.keys)
        known.formUnion(Self.document.mappings.keys)
        known.formUnion(CatalogLayoutAssignments.entries.map(\.key))
        known.formUnion(ChatContextMenuAssignments.defaults.keys)
        let pattern = /"(component\.(?:library\.\d+|button|input|control|focus|contextMenu)\.[A-Za-z0-9.]+)"/
        var unknown: [String] = []
        for folder in ["Views", "Models", "Managers"] {
            let root = Self.packageRoot.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for match in source.matches(of: pattern) {
                    let key = String(match.1)
                    if !key.hasSuffix("."), !known.contains(key) {
                        unknown.append("\(file.lastPathComponent): \(key)")
                    }
                }
            }
        }
        #expect(unknown.isEmpty, "\(unknown.count) keys outside the catalog: \(unknown.sorted().prefix(20))")
    }
}

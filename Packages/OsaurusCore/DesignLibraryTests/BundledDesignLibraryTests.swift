import Foundation
import Testing
@testable import OsaurusCore

@Suite("Bundled design handoff", .serialized)
struct BundledDesignLibraryTests {
    private func savedDocument() throws -> DesignWorkingDocument {
        try JSONDecoder().decode(DesignWorkingDocument.self,
                                 from: DesignLibraryRuntime.resource("design-library"))
    }

    @Test func savedAssignmentsAndPrimitivesSurviveLoading() throws {
        let saved = try savedDocument()
        let snapshot = try #require(DesignLibraryRuntime.bundledSnapshot())
        #expect(snapshot.document.mappings == saved.mappings)
        #expect(snapshot.document.explicitAssignments == saved.explicitAssignments)
        #expect(snapshot.document.primitives == saved.primitives)
        #expect(snapshot.document.colorAliases == saved.colorAliases)
        #expect(snapshot.document.scalarPrimitives == saved.scalarPrimitives)
        #expect(snapshot.document.valueAliases == saved.valueAliases)
        #expect(snapshot.document.tokens == (try saved.resolvingColors()).tokens)
    }

    @Test func bundledThemesUseBothSavedModes() throws {
        let snapshot = try #require(DesignLibraryRuntime.bundledSnapshot())
        #expect(snapshot.dark.colors.surface.canvas == snapshot.document.tokens["color.surface.canvas"]?.dark.designString)
        #expect(snapshot.light.colors.surface.canvas == snapshot.document.tokens["color.surface.canvas"]?.light.designString)
        #expect(snapshot.dark.colors.text.primary == snapshot.document.tokens["color.text.primary"]?.dark.designString)
        #expect(snapshot.light.colors.text.primary == snapshot.document.tokens["color.text.primary"]?.light.designString)
        #expect(snapshot.dark.colors.surface.canvas != snapshot.light.colors.surface.canvas)
        #expect(!snapshot.reassignedProperties.isEmpty)
    }

    @Test func primitiveEditsStayIndependentAndResolveSharedAliases() throws {
        var doc = try savedDocument()
        let original = try doc.resolvingColors()
        let primitive = try #require(doc.colorAliases?["color.surface.canvas"]?.dark)
        doc.primitives?[primitive]?.dark = "#123456FF"
        let changed = try doc.resolvingColors()
        let paths = (doc.colorAliases ?? [:]).filter { $0.value.dark == primitive }.map(\.key)
        #expect(paths.count > 1)
        for path in paths {
            #expect(changed.colorValue(path, mode: "dark")?.designString == "#123456FF")
            #expect(changed.colorValue(path, mode: "light") == original.colorValue(path, mode: "light"))
        }
        #expect(changed.mappings == original.mappings)
        #expect(try savedDocument() == docWithOriginalPrimitives(doc, original: original))
    }

    private func docWithOriginalPrimitives(_ doc: DesignWorkingDocument, original: DesignWorkingDocument) -> DesignWorkingDocument {
        var restored = doc
        restored.primitives = original.primitives
        return restored
    }

    @Test func editorIsOptionalInNormalApp() {
        #if !OSAURUS_DESIGN_INSPECTOR
        #expect(!DevelopmentDesignInspector.isAvailable)
        #endif
        #expect(DesignThemeOverlay.shared.current() != nil)
    }
}

//
//  CapabilitiesIdRecoveryTests.swift
//  osaurus
//
//  The unified `capabilities` tool answered a bare `{}` call — the natural
//  "what do I have?" probe — with `invalid_args`, and a model that reached
//  for it that way re-issued the identical rejected call until the turn
//  collapsed into verbatim repetition (observed live on Raptor). The tool
//  now answers with the enabled-capabilities listing instead, and accepts
//  the id argument shapes models actually emit.
//

import Foundation
import Testing

@testable import OsaurusCore

struct CapabilitiesIdRecoveryTests {
    @Test("schema ids array passes through, trimmed and emptiness-filtered")
    func schemaArrayPassesThrough() {
        #expect(
            CapabilitiesTool.recoveredIds(from: ["ids": ["tool/a", " skill/b "]])
                == ["tool/a", "skill/b"])
        #expect(CapabilitiesTool.recoveredIds(from: ["ids": [" ", ""]]) == nil)
        #expect(CapabilitiesTool.recoveredIds(from: ["ids": [String]()]) == nil)
    }

    @Test("bare-string and stringified-array ids are recovered")
    func stringShapesRecovered() {
        #expect(
            CapabilitiesTool.recoveredIds(from: ["ids": "plugin/browser"])
                == ["plugin/browser"])
        #expect(
            CapabilitiesTool.recoveredIds(from: ["ids": "[\"tool/a\",\"tool/b\"]"])
                == ["tool/a", "tool/b"])
    }

    @Test("the singular id spelling is accepted, string or array")
    func singularSpellingAccepted() {
        #expect(
            CapabilitiesTool.recoveredIds(from: ["id": "skill/notes"])
                == ["skill/notes"])
        #expect(
            CapabilitiesTool.recoveredIds(from: ["id": ["tool/x"]])
                == ["tool/x"])
        // Plural wins when both are present.
        #expect(
            CapabilitiesTool.recoveredIds(from: ["ids": ["tool/a"], "id": "tool/b"])
                == ["tool/a"])
    }

    @Test("no id-shaped argument means nil - the caller lists instead of rejecting")
    func missingMeansNil() throws {
        #expect(CapabilitiesTool.recoveredIds(from: [:]) == nil)
        #expect(CapabilitiesTool.recoveredIds(from: ["query": "browse"]) == nil)
        #expect(CapabilitiesTool.recoveredIds(from: ["ids": 7]) == nil)

        // Source pins: both tools answer the no-ids case with the enabled
        // listing (the loop-breaker), not an invalid_args envelope the model
        // will re-issue verbatim.
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()  // Tools/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        let source = try String(
            contentsOf: root.appendingPathComponent("Tools/CapabilityTools.swift"),
            encoding: .utf8)
        #expect(!source.contains("Provide either a non-empty `query` or non-empty `ids`."))
        #expect(
            source.components(
                separatedBy: "CapabilitiesDiscoverTool.listEnabledCapabilities"
            ).count >= 3)
    }
}

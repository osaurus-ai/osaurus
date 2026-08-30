import Foundation
import Testing

@testable import OsaurusCore

/// A plugin group load appends every loaded tool's schema to its own tool
/// result. `enabledManifestToolCap` bounds how MANY tools may load, but nothing
/// bounded how BIG the result got — a 9-tool plugin whose skill document
/// already spends ~2.2k tokens left the continuation almost nothing to generate
/// into, and the model answered with empty turn after empty turn until the
/// agent loop gave up ("returned empty output after tool execution").
///
/// These pin the tiering that replaced the unbounded append.
@Suite("Capability loaded-schema budget")
struct CapabilityLoadedSchemaBudgetTests {

    /// Build a tool whose description is `padding` characters long, so a group
    /// can be pushed over the budget deterministically.
    static func tool(name: String, descriptionLength: Int) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: name,
                description: String(repeating: "x", count: descriptionLength),
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "alpha": .object([
                            "type": .string("string"), "description": .string("first"),
                        ]),
                        "beta": .object([
                            "type": .string("integer"), "description": .string("second"),
                        ]),
                    ]),
                    "required": .array([.string("alpha")]),
                ])
            )
        )
    }

    @Test("a small group keeps full schemas")
    func smallGroupKeepsFullSchemas() {
        let specs = [
            Self.tool(name: "alpha_tool", descriptionLength: 40),
            Self.tool(name: "beta_tool", descriptionLength: 40),
        ]
        let rendered = CapabilitiesLoadTool.loadedSchemaBlocks(for: specs)

        #expect(rendered.contains("Schema for `alpha_tool`"))
        #expect(rendered.contains("Schema for `beta_tool`"))
        #expect(rendered.count <= CapabilitiesLoadTool.loadedSchemaBudget)
        // Full tier says nothing about abbreviation.
        #expect(rendered.contains("abbreviated") == false)
        #expect(rendered.contains("schemas omitted") == false)
    }

    @Test("an oversized group degrades a tier instead of truncating mid-JSON")
    func oversizedGroupDegrades() {
        // Descriptions large enough that full schemas blow the budget.
        let specs = (0 ..< 9).map {
            Self.tool(name: "mail_tool_\($0)", descriptionLength: 900)
        }
        let rendered = CapabilitiesLoadTool.loadedSchemaBlocks(for: specs)

        // Whatever tier is chosen, the result must stay bounded and must not
        // end mid-JSON — a fragment is worse than no schema because the model
        // tries to call it.
        #expect(rendered.count <= CapabilitiesLoadTool.loadedSchemaBudget + 400)
        #expect(rendered.hasSuffix("\n"))
        // Every tool must still be nameable, or the model cannot call it.
        for i in 0 ..< 9 {
            #expect(rendered.contains("mail_tool_\(i)"), "tool \(i) vanished from the result")
        }
        // And the model must be told how to recover the full schema.
        #expect(rendered.contains("capabilities_load"))
    }

    @Test("a group that overflows even the skeletons falls back to names")
    func extremeGroupFallsBackToNames() {
        // 40 tools with long descriptions overflow both the full and the
        // compact tier.
        let specs = (0 ..< 40).map {
            Self.tool(name: "huge_tool_\($0)", descriptionLength: 2000)
        }
        let rendered = CapabilitiesLoadTool.loadedSchemaBlocks(for: specs)

        #expect(rendered.contains("schemas omitted"))
        #expect(rendered.contains("huge_tool_0"))
        #expect(rendered.contains("huge_tool_39"))
        #expect(rendered.contains("capabilities_load"))
    }

    @Test("tiering is all-or-nothing so registry order cannot change the result")
    func tieringIsOrderIndependent() {
        let specs = (0 ..< 9).map {
            Self.tool(name: "tool_\($0)", descriptionLength: 900)
        }
        let forward = CapabilitiesLoadTool.loadedSchemaBlocks(for: specs)
        let reversed = CapabilitiesLoadTool.loadedSchemaBlocks(for: specs.reversed())

        // Same tier either way: whichever tier fits, every tool renders the
        // same way, so iteration order only reorders lines rather than leaving
        // some tools full and others abbreviated.
        #expect(forward.contains("schemas omitted") == reversed.contains("schemas omitted"))
        #expect(forward.contains("abbreviated") == reversed.contains("abbreviated"))
        #expect(abs(forward.count - reversed.count) < 50)
    }

    @Test("an empty group renders nothing")
    func emptyGroupRendersNothing() {
        #expect(CapabilitiesLoadTool.loadedSchemaBlocks(for: []).isEmpty)
    }
}

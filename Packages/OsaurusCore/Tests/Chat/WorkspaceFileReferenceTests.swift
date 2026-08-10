import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workspace file delivery")
struct WorkspaceFileReferenceTests {
    @Test func typedReferenceProducesModeSpecificCardAction() throws {
        let vm = ToolEnvelope.success(
            tool: "file_write",
            result: [
                "path": "/workspace/agents/a/report.md",
                "file_reference": [
                    "kind": "workspace_file",
                    "path": "/workspace/agents/a/report.md",
                    "exportable": true,
                ],
            ]
        )
        let host = ToolEnvelope.success(
            tool: "file_edit",
            result: [
                "path": "report.md",
                "file_reference": [
                    "kind": "workspace_file",
                    "path": "report.md",
                    "exportable": false,
                ],
            ]
        )

        let vmCard = try #require(
            WorkspaceFileReference.cardResult(toolResult: vm, toolName: "file_write")
        )
        let hostCard = try #require(
            WorkspaceFileReference.cardResult(toolResult: host, toolName: "file_edit")
        )
        let vmPayload = try #require(ToolEnvelope.successPayload(vmCard) as? [String: Any])
        let hostPayload = try #require(ToolEnvelope.successPayload(hostCard) as? [String: Any])
        #expect((vmPayload["delivery"] as? [String: Any])?["action"] as? String == "export")
        #expect(
            (hostPayload["delivery"] as? [String: Any])?["action"] as? String
                == "open_or_reveal"
        )
    }

    @Test func exporterCopiesAndAtomicallyReplacesBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("destination.bin")
        let expected = Data([0x00, 0x7F, 0xFF, 0x41])
        try expected.write(to: source)
        try Data("old".utf8).write(to: destination)

        try WorkspaceFileExporter.export(source: source, destination: destination)

        #expect(try Data(contentsOf: destination) == expected)
        #expect(try Data(contentsOf: source) == expected)
    }
}

//
//  NativeImageToolArtifactBridgeTests.swift
//  osaurusTests
//
//  Pins native image tool-result promotion into chat artifacts.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Native image tool artifact bridge", .serialized)
struct NativeImageToolArtifactBridgeTests {
    private static func runLocked(_ body: @Sendable (URL) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-native-image-artifact-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: tmp)
            }
            try body(tmp)
        }
    }

    @Test
    func imageGenerateResult_copiesFirstImageIntoChatArtifactStore() async throws {
        try await Self.runLocked { tmp in
            let generatedDir = tmp.appendingPathComponent("generated", isDirectory: true)
            try FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
            let generated = generatedDir.appendingPathComponent("green-apple.png")
            let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
            try bytes.write(to: generated)

            let toolResult = ToolEnvelope.success(
                tool: "image_generate",
                result: [
                    "kind": "native_image_generation_job",
                    "job_id": "job-1",
                    "model": "qwen-image-edit",
                    "status": "completed",
                    "images": [
                        [
                            "path": generated.path,
                            "url": generated.absoluteString,
                            "seed": 7,
                        ]
                    ],
                    "progress": [],
                ] as [String: Any]
            )

            let outcome = NativeImageToolArtifactBridge.processFirstImageArtifact(
                toolName: "image_generate",
                toolResult: toolResult,
                contextId: "chat-1"
            )

            switch try #require(outcome) {
            case .success(let processed):
                let copied = try Data(contentsOf: URL(fileURLWithPath: processed.artifact.hostPath))
                let renderedArtifact = SharedArtifact.fromEnrichedToolResult(
                    ToolEnvelope.success(tool: "image_generate", text: processed.enrichedToolResult)
                )
                #expect(processed.artifact.filename == "green-apple.png")
                #expect(processed.artifact.mimeType == "image/png")
                #expect(processed.artifact.fileSize == bytes.count)
                #expect(processed.artifact.hostPath.hasPrefix(OsaurusPaths.contextArtifactsDir(contextId: "chat-1").path))
                #expect(copied == bytes)
                #expect(renderedArtifact?.filename == "green-apple.png")
            case .failure(let reason):
                Issue.record("expected success, got failure: \(reason)")
            }
        }
    }

    @Test
    func nonImageToolResult_isIgnored() {
        let outcome = NativeImageToolArtifactBridge.processFirstImageArtifact(
            toolName: "file_read",
            toolResult: ToolEnvelope.success(tool: "file_read", text: "hello"),
            contextId: "chat-1"
        )
        if outcome != nil {
            Issue.record("expected non-image tool result to be ignored")
        }
    }
}

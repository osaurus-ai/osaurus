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
                tool: "image",
                result: [
                    "kind": "native_image_generation_job",
                    "mode": "generate",
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
                toolName: "image",
                toolResult: toolResult,
                contextId: "chat-1"
            )

            switch try #require(outcome) {
            case .success(let processed):
                let copied = try Data(contentsOf: URL(fileURLWithPath: processed.artifact.hostPath))
                let renderedArtifact = SharedArtifact.fromEnrichedToolResult(
                    ToolEnvelope.success(tool: "image", text: processed.enrichedToolResult)
                )
                #expect(processed.artifact.filename == "green-apple.png")
                #expect(processed.artifact.mimeType == "image/png")
                #expect(processed.artifact.fileSize == bytes.count)
                #expect(
                    processed.artifact.hostPath.hasPrefix(OsaurusPaths.contextArtifactsDir(contextId: "chat-1").path)
                )
                #expect(copied == bytes)
                #expect(renderedArtifact?.filename == "green-apple.png")
            case .failure(let reason):
                Issue.record("expected success, got failure: \(reason)")
            }
        }
    }

    /// Pins the decoupling the chat loop relies on: the model-facing tool
    /// result stays the compact `toolPayload` (marker-free, no host paths) so a
    /// small quantized model confirms briefly instead of echoing the artifact
    /// metadata JSON, while the card-facing string is the enriched
    /// SHARED_ARTIFACT block. If these two ever collapse back into one string,
    /// the `enriched != resultText` guard in `postProcessToolResult` would stop
    /// firing and the model would again see the metadata block.
    @Test
    func modelFacingResultStaysCompact_whileCardResultIsEnriched() async throws {
        try await Self.runLocked { tmp in
            let generatedDir = tmp.appendingPathComponent("generated", isDirectory: true)
            try FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
            let generated = generatedDir.appendingPathComponent("cow.png")
            let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
            try bytes.write(to: generated)

            // The compact payload is exactly what the model keeps as the `.tool`
            // message after the fix — only the card override is enriched.
            let modelFacingResult = ToolEnvelope.success(
                tool: "image",
                result: [
                    "kind": "native_image_generation_job",
                    "mode": "generate",
                    "job_id": "job-cow",
                    "model": "Z-Image-Turbo-mflux-4bit",
                    "status": "completed",
                    "already_displayed": true,
                    "display_note":
                        "The image is already shown to the user in the chat; do NOT call share_artifact for it.",
                    "images": [
                        [
                            "path": generated.path,
                            "url": generated.absoluteString,
                            "seed": 11,
                        ]
                    ],
                ] as [String: Any]
            )

            let outcome = NativeImageToolArtifactBridge.processFirstImageArtifact(
                toolName: "image",
                toolResult: modelFacingResult,
                contextId: "chat-cow"
            )

            switch try #require(outcome) {
            case .success(let processed):
                let cardFacingResult = ToolEnvelope.success(
                    tool: "image",
                    text: processed.enrichedToolResult
                )

                // The marker token without the trailing newline survives JSON
                // string-encoding (the `\n` does not), so match on it directly.
                let markerToken = "---SHARED_ARTIFACT_START---"

                // Divergence is the whole fix: the chat loop must not overwrite
                // the model result with the card block.
                #expect(modelFacingResult != cardFacingResult)

                // Model-facing result is marker-free, host-path-free, and is NOT
                // parseable as an artifact — so it can't be echoed as one.
                #expect(modelFacingResult.contains(markerToken) == false)
                #expect(modelFacingResult.contains("host_path") == false)
                #expect(SharedArtifact.fromEnrichedToolResult(modelFacingResult) == nil)

                // Card-facing result is the enriched artifact block and still
                // rebuilds into a renderable artifact.
                #expect(cardFacingResult.contains(markerToken))
                #expect(cardFacingResult.contains("host_path"))
                #expect(SharedArtifact.fromEnrichedToolResult(cardFacingResult)?.filename == "cow.png")
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

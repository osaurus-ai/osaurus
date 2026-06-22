//
//  CaptureScreenshotCommandTests.swift
//  osaurusTests
//
//  Focused tests for the permission-gated screenshot capture service and slash command.
//

import Foundation
import Testing

@testable import OsaurusCore

private final class MockScreenshotPermissionChecker: ScreenshotPermissionChecking, @unchecked Sendable {
    var granted: Bool

    init(granted: Bool) {
        self.granted = granted
    }

    func hasScreenRecordingPermission() -> Bool {
        granted
    }
}

private final class MockScreenshotCapturer: ScreenshotImageCapturing, @unchecked Sendable {
    private(set) var includeCursorCalls: [Bool] = []
    var image = ScreenshotImage(
        pngData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
        width: 320,
        height: 200,
        displayID: 42
    )

    func capture(includeCursor: Bool) async throws -> ScreenshotImage {
        includeCursorCalls.append(includeCursor)
        return image
    }
}

@Suite("screenshot slash command", .serialized)
struct CaptureScreenshotCommandTests {

    private static func runLocked(_ body: @Sendable (URL) async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let previous = OsaurusPaths.overrideRoot
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-screenshot-command-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = tmp
            defer {
                OsaurusPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: tmp)
            }
            try await body(tmp)
        }
    }

    @Test func serviceMissingPermissionDoesNotCapture() async throws {
        try await Self.runLocked { _ in
            let permission = MockScreenshotPermissionChecker(granted: false)
            let capturer = MockScreenshotCapturer()
            let service = ScreenshotCaptureService(
                permissionChecker: permission,
                capturer: capturer
            )

            await #expect(throws: ScreenshotCaptureError.missingScreenRecordingPermission) {
                _ = try await service.capture(
                    options: ScreenshotCaptureOptions(contextId: "session-a")
                )
            }

            #expect(capturer.includeCursorCalls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: OsaurusPaths.artifactsDir().path))
        }
    }

    @Test func serviceWritesArtifactAndSanitizesFilename() async throws {
        try await Self.runLocked { _ in
            let capturer = MockScreenshotCapturer()
            let service = ScreenshotCaptureService(
                permissionChecker: MockScreenshotPermissionChecker(granted: true),
                capturer: capturer
            )
            let now = Date(timeIntervalSince1970: 1_771_000_000)

            let captured = try await service.capture(
                options: ScreenshotCaptureOptions(
                    contextId: "session-b",
                    filename: "../Quarterly Report.jpg",
                    description: "current screen",
                    includeCursor: true,
                    now: now
                )
            )

            #expect(capturer.includeCursorCalls == [true])
            #expect(captured.artifact.filename == "Quarterly-Report.png")
            #expect(captured.artifact.mimeType == "image/png")
            #expect(captured.artifact.description == "current screen")
            #expect(captured.width == 320)
            #expect(captured.height == 200)
            #expect(captured.displayID == 42)
            #expect(FileManager.default.fileExists(atPath: captured.artifact.hostPath))
            let stored = try Data(contentsOf: URL(fileURLWithPath: captured.artifact.hostPath))
            #expect(stored == capturer.image.pngData)
        }
    }

    @MainActor
    @Test func capturedArtifactPersistsAndRendersWithoutToolHistory() async throws {
        try await Self.runLocked { _ in
            let capturer = MockScreenshotCapturer()
            let service = ScreenshotCaptureService(
                permissionChecker: MockScreenshotPermissionChecker(granted: true),
                capturer: capturer
            )
            let captured = try await service.capture(
                options: ScreenshotCaptureOptions(
                    contextId: "session-d",
                    filename: "screen.png",
                    description: "screen"
                )
            )
            await MainActor.run {
                let turn = ChatTurn(
                    role: .assistant,
                    content: "",
                    sharedArtifacts: [captured.artifact]
                )

                #expect(turn.toolCalls == nil)
                #expect(turn.toolResults.isEmpty)
                #expect(turn.sharedArtifacts == [captured.artifact])

                let data = ChatTurnData(from: turn)
                #expect(data.toolCalls == nil)
                #expect(data.toolResults.isEmpty)
                #expect(data.sharedArtifacts == [captured.artifact])

                let restored = ChatTurn(from: data)
                #expect(restored.toolCalls == nil)
                #expect(restored.toolResults.isEmpty)
                #expect(restored.sharedArtifacts == [captured.artifact])

                let blocks = ContentBlock.generateBlocks(
                    from: [restored],
                    streamingTurnId: nil,
                    agentName: "Osaurus"
                )
                let artifacts = blocks.compactMap { block -> SharedArtifact? in
                    if case let .sharedArtifact(artifact) = block.kind {
                        return artifact
                    }
                    return nil
                }
                #expect(artifacts == [captured.artifact])
                #expect(
                    !blocks.contains { block in
                        if case .toolCallGroup = block.kind {
                            return true
                        }
                        return false
                    }
                )
            }
        }
    }

    @MainActor
    @Test func screenshotCommandIsBuiltInSlashActionNotRegisteredModelTool() {
        let command = SlashCommand.builtIns.first { $0.name == "screenshot" }
        #expect(command?.kind == .action)
        #expect(command?.isBuiltIn == true)
        #expect(command?.icon == "camera.viewfinder")
        #expect(ToolRegistry.shared.entry(named: "capture_screenshot") == nil)
    }
}

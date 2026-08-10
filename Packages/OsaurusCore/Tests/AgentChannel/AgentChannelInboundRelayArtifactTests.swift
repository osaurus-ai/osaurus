//
//  AgentChannelInboundRelayArtifactTests.swift
//  osaurusTests
//
//  Eligibility rules for forwarding agent-shared artifacts as channel
//  attachment replies.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentChannelInboundRelayArtifactTests {

    private func makeArtifact(
        filename: String,
        hostPath: String,
        isDirectory: Bool = false,
        createdAt: Date
    ) -> SharedArtifact {
        SharedArtifact(
            contextId: "session",
            contextType: .chat,
            filename: filename,
            mimeType: SharedArtifact.mimeType(from: filename),
            fileSize: 1,
            hostPath: hostPath,
            isDirectory: isDirectory,
            createdAt: createdAt
        )
    }

    @Test func replyArtifactsKeepOnlyFreshExistingFilesAndDeduplicate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-relay-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let imagePath = dir.appendingPathComponent("cat.png").path
        try Data([0x89]).write(to: URL(fileURLWithPath: imagePath))

        let runStart = Date()
        let fresh = makeArtifact(
            filename: "cat.png", hostPath: imagePath, createdAt: runStart.addingTimeInterval(1)
        )
        let duplicate = makeArtifact(
            filename: "cat.png", hostPath: imagePath, createdAt: runStart.addingTimeInterval(2)
        )
        // Artifacts from a previous run of a reused channel session.
        let stale = makeArtifact(
            filename: "old.png", hostPath: imagePath, createdAt: runStart.addingTimeInterval(-60)
        )
        // Backing file was cleaned up between completion and delivery.
        let missing = makeArtifact(
            filename: "gone.png",
            hostPath: dir.appendingPathComponent("gone.png").path,
            createdAt: runStart.addingTimeInterval(1)
        )
        let directory = makeArtifact(
            filename: "site", hostPath: dir.path, isDirectory: true,
            createdAt: runStart.addingTimeInterval(1)
        )
        let pathless = makeArtifact(
            filename: "inline.txt", hostPath: "", createdAt: runStart.addingTimeInterval(1)
        )

        let eligible = AgentChannelInboundRelay.replyArtifacts(
            [stale, fresh, duplicate, missing, directory, pathless],
            createdAfter: runStart
        )
        #expect(eligible.count == 1)
        #expect(eligible.first?.filename == "cat.png")
        #expect(eligible.first?.hostPath == imagePath)
    }
}

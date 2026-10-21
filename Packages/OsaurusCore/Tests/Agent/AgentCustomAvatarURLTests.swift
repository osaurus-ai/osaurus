//
//  AgentCustomAvatarURLTests.swift
//  OsaurusCoreTests
//
//  `customAvatarURL` is read from SwiftUI body getters on every render. Its
//  filename component must be appended as a non-directory so URL
//  construction never probes the filesystem; only the cached existence check
//  may touch disk.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent custom avatar URL")
struct AgentCustomAvatarURLTests {

    @Test("Resolves an existing avatar as a file URL and drops it once removed")
    func resolvesExistingAvatarAsFileURL() async throws {
        try await StoragePathsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-avatar-url-\(UUID().uuidString)",
                isDirectory: true
            )
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AvatarExistenceCache.shared.invalidateAll()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AvatarExistenceCache.shared.invalidateAll()
                try? fm.removeItem(at: root)
            }

            let avatars = OsaurusPaths.agents().appendingPathComponent("avatars", isDirectory: true)
            try fm.createDirectory(at: avatars, withIntermediateDirectories: true)
            let filename = "\(UUID().uuidString).png"
            let file = avatars.appendingPathComponent(filename, isDirectory: false)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)

            let agent = Agent(name: "Avatar", customAvatarFilename: filename)

            let url = try #require(agent.customAvatarURL)
            #expect(url.lastPathComponent == filename)
            #expect(!url.hasDirectoryPath)
            #expect(!url.absoluteString.hasSuffix("/"))

            try fm.removeItem(at: file)
            AvatarExistenceCache.shared.invalidateAll()
            #expect(agent.customAvatarURL == nil)
        }
    }

    @Test("Returns nil when no custom avatar is configured")
    func nilWithoutFilename() {
        #expect(Agent(name: "NoAvatar").customAvatarURL == nil)
        #expect(Agent(name: "Empty", customAvatarFilename: "").customAvatarURL == nil)
    }
}

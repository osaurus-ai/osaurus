import Foundation
import Testing

@testable import OsaurusCore

@Suite("ModelRuntime DFlash drafter ownership")
struct ModelRuntimeDFlashLifecycleTests {
    @Test func lastOwnerEvictsButSharedOwnerRetains() {
        let path = URL(fileURLWithPath: "/tmp/dflash-lifecycle/model/dflash2")
        #expect(ModelRuntime.shouldEvictDFlashDrafter(retiredPath: path, residentPaths: []))
        #expect(!ModelRuntime.shouldEvictDFlashDrafter(retiredPath: path, residentPaths: [path]))
        #expect(ModelRuntime.shouldEvictDFlashDrafter(
            retiredPath: path, residentPaths: [URL(fileURLWithPath: "/tmp/dflash-lifecycle/other/dflash2")]))
    }

    @Test func symlinkAliasStillOwnsTheSameDrafter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("drafter")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        #expect(!ModelRuntime.shouldEvictDFlashDrafter(retiredPath: original, residentPaths: [alias]))
        #expect(!ModelRuntime.shouldEvictDFlashDrafter(retiredPath: alias, residentPaths: [original]))
    }

    @Test func evictionIsInsideDrainedTeardownAndOutsideQuitPath() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Services/ModelRuntime.swift"), encoding: .utf8)
        let unloadStart = try #require(source.range(of: "private func unloadClaimed("))
        let unloadEnd = try #require(source.range(of: "nonisolated static func shouldEvictDFlashDrafter("))
        let unload = String(source[unloadStart.lowerBound..<unloadEnd.lowerBound])
        let synchronize = try #require(unload.range(of: "Stream.gpu.synchronize()"))
        let evict = try #require(unload.range(of: "DFlash2DrafterResolver.shared.evict(path:"))
        #expect(synchronize.lowerBound < evict.lowerBound)
        let clearStart = try #require(source.range(of: "func clearAll(quit: Bool = false)"))
        let clear = String(source[clearStart.lowerBound...])
        let quit = try #require(clear.range(of: "if quit {\n            if hasStuckLease"))
        let gate = try #require(clear.range(of: "// Normal (non-quit) teardown"))
        #expect(!clear[quit.lowerBound..<gate.lowerBound].contains("DFlash2DrafterResolver"))
        let evictAll = try #require(clear.range(of: "DFlash2DrafterResolver.shared.evictAll()"))
        #expect(gate.lowerBound < evictAll.lowerBound)
    }
}

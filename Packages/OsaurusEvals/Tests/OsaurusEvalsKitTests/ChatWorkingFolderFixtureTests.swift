//
//  ChatWorkingFolderFixtureTests.swift
//  OsaurusEvalsKitTests
//
//  `workspaceFiles` on an orchestrator case attaches a seeded folder to the
//  chat; a case without it attaches none.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

@MainActor
struct ChatWorkingFolderFixtureTests {
    private func files(_ json: String) throws -> [EvalCase.WorkspaceFile] {
        try JSONDecoder().decode([EvalCase.WorkspaceFile].self, from: Data(json.utf8))
    }

    @Test
    func noFixtureAttachesNoFolder() throws {
        #expect(try EvalRunner.seedChatWorkingFolder(nil) == nil)
    }

    @Test
    func anEmptyListAttachesAnEmptyFolder() throws {
        let folder = try #require(try EvalRunner.seedChatWorkingFolder([]))
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test
    func seededFilesLandUnderTheFolder() throws {
        let seeded = try files(
            ##"[{"path":"README.md","contents":"# Bluefin\n"},{"path":"src/main.py","contents":"print(1)\n"}]"##)
        let folder = try #require(try EvalRunner.seedChatWorkingFolder(seeded))
        defer { try? FileManager.default.removeItem(at: folder) }
        let readme = try String(contentsOf: folder.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(readme == "# Bluefin\n")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("src/main.py").path))
    }
}

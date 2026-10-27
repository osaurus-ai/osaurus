import Foundation
import XCTest

@testable import OsaurusCLICore

final class PullCommandModelsDirectoryTests: XCTestCase {
    func testEnvironmentWinsOverAppBookmarkAndSharedSetting() throws {
        try withFixture { home, app, shared in
            let bookmark = try directory("bookmarked", under: home).resolvingSymlinksInPath()
            app.set(try bookmark.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                forKey: "ModelDirectoryBookmark")
            shared.set(home.appendingPathComponent("shared").path, forKey: "modelsDirectoryPath")
            let explicit = home.appendingPathComponent("explicit")
            let result = PullCommand.resolveLocalDirectory(
                for: "org/model", environment: ["OSU_MODELS_DIR": "  \(explicit.path)\n"],
                appDefaults: app, sharedDefaults: shared, home: home)
            XCTAssertEqual(result?.path, explicit.appendingPathComponent("org/model").path)
        }
    }

    func testAppBookmarkWinsOverSharedSetting() throws {
        try withFixture { home, app, shared in
            let bookmark = try directory("bookmarked", under: home).resolvingSymlinksInPath()
            app.set(try bookmark.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                forKey: "ModelDirectoryBookmark")
            shared.set(home.appendingPathComponent("shared").path, forKey: "modelsDirectoryPath")
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                bookmark.appendingPathComponent("org/model").path)
        }
    }

    func testSharedSettingSurvivesInvalidBookmarkAndBlankEnvironment() throws {
        try withFixture { home, app, shared in
            app.set(Data("invalid bookmark".utf8), forKey: "ModelDirectoryBookmark")
            let selected = home.appendingPathComponent("shared")
            shared.set(selected.path, forKey: "modelsDirectoryPath")
            let result = PullCommand.resolveLocalDirectory(
                for: "org/model", environment: ["OSU_MODELS_DIR": " \n"],
                appDefaults: app, sharedDefaults: shared, home: home)
            XCTAssertEqual(result?.path, selected.appendingPathComponent("org/model").path)
        }
    }

    func testFreshInstallUsesCurrentAppDefault() throws {
        try withFixture { home, app, shared in
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                home.appendingPathComponent("MLXModels/org/model").path)
        }
    }

    func testExplicitLegacyCLIFolderRemainsSelectable() throws {
        try withFixture { home, app, shared in
            let selected = home.appendingPathComponent(".osaurus/models")
            let result = PullCommand.resolveLocalDirectory(
                for: "org/model", environment: ["OSU_MODELS_DIR": selected.path],
                appDefaults: app, sharedDefaults: shared, home: home)
            XCTAssertEqual(result?.path, selected.appendingPathComponent("org/model").path)
        }
    }

    func testVisibleModelRootsUseAppDefaultsAndIgnoreOldCLIFolder() throws {
        try withFixture { home, app, shared in
            let current = try directory("MLXModels", under: home)
            let legacy = try directory("Documents/MLXModels", under: home)
            let fallback = try directory(".osaurus/models", under: home)
            try Data().write(to: current.appendingPathComponent(".hidden"))
            try Data().write(to: legacy.appendingPathComponent("existing-model"))
            try Data().write(to: fallback.appendingPathComponent("existing-model"))
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                legacy.appendingPathComponent("org/model").path)
            try Data().write(to: current.appendingPathComponent("existing-model"))
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                current.appendingPathComponent("org/model").path)
            try FileManager.default.removeItem(at: current)
            try FileManager.default.removeItem(at: legacy)
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                current.appendingPathComponent("org/model").path)
        }
    }

    func testEmptyExistingRootsUseAppDefaultsAndIgnoreOldCLIFolder() throws {
        try withFixture { home, app, shared in
            let current = try directory("MLXModels", under: home)
            let legacy = try directory("Documents/MLXModels", under: home)
            _ = try directory(".osaurus/models", under: home)
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                current.appendingPathComponent("org/model").path)
            try FileManager.default.removeItem(at: current)
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                legacy.appendingPathComponent("org/model").path)
            try FileManager.default.removeItem(at: legacy)
            XCTAssertEqual(try resolved(home: home, app: app, shared: shared).path,
                current.appendingPathComponent("org/model").path)
        }
    }

    func testRepositoryTraversalIsRejectedBeforeAnyDownload() throws {
        try withFixture { home, app, shared in
            for id in ["", "../model", "org/../model", "/tmp/model", "org//model", "org/./model",
                "org\\model", "org/model\0"] {
                XCTAssertNil(PullCommand.resolveLocalDirectory(for: id, environment: [:],
                    appDefaults: app, sharedDefaults: shared, home: home), "accepted \(id)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("MLXModels").path))
        }
    }

    func testRepositorySymlinkEscapesAreRejectedIncludingModelLeaf() throws {
        try withFixture { home, app, shared in
            let base = try directory("MLXModels", under: home)
            let outside = try directory("outside", under: home)
            let organization = base.appendingPathComponent("org")
            try FileManager.default.createSymbolicLink(at: organization, withDestinationURL: outside)
            XCTAssertNil(PullCommand.resolveLocalDirectory(for: "org/model", environment: [:],
                appDefaults: app, sharedDefaults: shared, home: home))
            try FileManager.default.removeItem(at: organization)
            try FileManager.default.createDirectory(at: organization, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: organization.appendingPathComponent("model"),
                withDestinationURL: outside)
            XCTAssertNil(PullCommand.resolveLocalDirectory(for: "org/model", environment: [:],
                appDefaults: app, sharedDefaults: shared, home: home))
        }
    }

    private func resolved(home: URL, app: UserDefaults, shared: UserDefaults) throws -> URL {
        try XCTUnwrap(PullCommand.resolveLocalDirectory(for: "org/model", environment: [:],
            appDefaults: app, sharedDefaults: shared, home: home))
    }

    private func directory(_ name: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withFixture(_ body: (URL, UserDefaults, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pull-path-\(UUID().uuidString)")
        let appSuite = "test.osaurus.pull.app.\(UUID().uuidString)"
        let sharedSuite = "test.osaurus.pull.shared.\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: appSuite))
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
        defer {
            app.removePersistentDomain(forName: appSuite)
            shared.removePersistentDomain(forName: sharedSuite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root, app, shared)
    }
}

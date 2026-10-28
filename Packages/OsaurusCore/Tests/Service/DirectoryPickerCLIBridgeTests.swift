import Darwin
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Directory picker CLI bridge")
@MainActor
struct DirectoryPickerCLIBridgeTests {
    private let bookmarkKey = "ModelDirectoryBookmark"
    private let sharedPathKey = "modelsDirectoryPath"

    private struct Fixture {
        let root: URL
        let appDomain: String
        let sharedDomain: String
        let app: UserDefaults
        let shared: UserDefaults

        init() throws {
            let id = UUID().uuidString
            let tempParent = FileManager.default.temporaryDirectory.path
            let physicalParent = try #require(tempParent.withCString { realpath($0, nil) })
            defer { free(physicalParent) }
            root = URL(
                fileURLWithFileSystemRepresentation: physicalParent,
                isDirectory: true,
                relativeTo: nil
            ).appendingPathComponent("directory-cli-\(id)", isDirectory: true)
            let appName = "test.osaurus.directory.app.\(id)"
            let sharedName = "test.osaurus.directory.shared.\(id)"
            appDomain = appName
            sharedDomain = sharedName
            app = try #require(UserDefaults(suiteName: appName))
            shared = try #require(UserDefaults(suiteName: sharedName))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func directory(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func cleanup() {
            app.removePersistentDomain(forName: appDomain)
            shared.removePersistentDomain(forName: sharedDomain)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func filePickerSavePublishesBookmarkSelectionAndSharedPathBeforeNotification() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let selected = try fixture.directory("chosen models")
        var cached: URL?
        var changes = 0
        var stateAtChange: String?
        let service = DirectoryPickerService(
            defaults: fixture.app, sharedDefaults: fixture.shared,
            publishBookmarkCache: { cached = $0 },
            directoryChanged: {
                changes += 1
                stateAtChange = fixture.shared.string(forKey: sharedPathKey)
            }
        )
        service.saveDirectoryFromFilePicker(selected)
        #expect(service.selectedDirectory == selected)
        #expect(service.hasValidDirectory)
        #expect(cached == selected)
        #expect(fixture.shared.string(forKey: sharedPathKey) == selected.path)
        #expect(stateAtChange == selected.path)
        #expect(changes == 1)
        let bookmark = try #require(fixture.app.data(forKey: bookmarkKey))
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #expect(resolved == selected)
    }

    @Test func plainBookmarkResolutionRepairsStaleSharedMirrorOnReopen() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let selected = try fixture.directory("restored")
        fixture.app.set(try selected.bookmarkData(options: []), forKey: bookmarkKey)
        fixture.shared.set("/stale-prior-selection", forKey: sharedPathKey)
        var cached: URL?
        var changes = 0
        let service = DirectoryPickerService(
            defaults: fixture.app, sharedDefaults: fixture.shared,
            publishBookmarkCache: { cached = $0 }, directoryChanged: { changes += 1 }
        )
        #expect(service.selectedDirectory == selected)
        #expect(service.hasValidDirectory)
        #expect(cached == selected)
        #expect(fixture.shared.string(forKey: sharedPathKey) == selected.path)
        #expect(changes == 0)
    }

    @Test func resetClearsBookmarkMirrorAndPublishedSelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let selected = try fixture.directory("reset")
        fixture.app.set(try selected.bookmarkData(options: []), forKey: bookmarkKey)
        var cached: URL?
        var changes = 0
        let service = DirectoryPickerService(
            defaults: fixture.app, sharedDefaults: fixture.shared,
            publishBookmarkCache: { cached = $0 }, directoryChanged: { changes += 1 }
        )
        #expect(cached == selected)
        service.resetDirectory()
        #expect(service.selectedDirectory == nil)
        #expect(!service.hasValidDirectory)
        #expect(cached == nil)
        #expect(fixture.app.object(forKey: bookmarkKey) == nil)
        #expect(fixture.shared.object(forKey: sharedPathKey) == nil)
        #expect(changes == 1)
    }

    @Test(arguments: [false, true])
    func missingBookmarkRetainsSharedFallbackButInvalidBookmarkClearsIt(invalidBookmark: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.shared.set("/stale-prior-selection", forKey: sharedPathKey)
        fixture.shared.set("keep", forKey: "unrelated")
        fixture.app.set("keep", forKey: "unrelated")
        if invalidBookmark { fixture.app.set(Data("not-a-bookmark".utf8), forKey: bookmarkKey) }
        var cachePublications: [URL?] = []
        var changes = 0
        let service = DirectoryPickerService(
            defaults: fixture.app, sharedDefaults: fixture.shared,
            publishBookmarkCache: { cachePublications.append($0) }, directoryChanged: { changes += 1 }
        )
        #expect(service.selectedDirectory == nil)
        #expect(!service.hasValidDirectory)
        #expect(fixture.app.object(forKey: bookmarkKey) == nil)
        if invalidBookmark {
            #expect(fixture.shared.object(forKey: sharedPathKey) == nil)
        } else {
            #expect(fixture.shared.string(forKey: sharedPathKey) == "/stale-prior-selection")
        }
        #expect(fixture.app.string(forKey: "unrelated") == "keep")
        #expect(fixture.shared.string(forKey: "unrelated") == "keep")
        #expect(cachePublications == [nil])
        #expect(changes == 0)
    }

    @Test func failedSelectionPreservesLastSuccessfulBookmarkAndMirror() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.directory("original")
        let bookmark = try original.bookmarkData(options: [])
        fixture.app.set(bookmark, forKey: bookmarkKey)
        var cached: URL?
        var changes = 0
        let service = DirectoryPickerService(
            defaults: fixture.app, sharedDefaults: fixture.shared,
            publishBookmarkCache: { cached = $0 }, directoryChanged: { changes += 1 }
        )
        let missing = fixture.root.appendingPathComponent("not-present", isDirectory: true)
        service.saveDirectoryFromFilePicker(missing)
        #expect(service.selectedDirectory == original)
        #expect(service.hasValidDirectory)
        #expect(cached == original)
        #expect(fixture.app.data(forKey: bookmarkKey) == bookmark)
        #expect(fixture.shared.string(forKey: sharedPathKey) == original.path)
        #expect(changes == 0)
    }

    @Test func successiveSelectionsAndReopenKeepTheLatestPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.directory("first")
        let second = try fixture.directory("second")
        var cachePublications: [URL?] = []
        var changes = 0
        let service = DirectoryPickerService(
            defaults: fixture.app, sharedDefaults: fixture.shared,
            publishBookmarkCache: { cachePublications.append($0) }, directoryChanged: { changes += 1 }
        )
        service.saveDirectoryFromFilePicker(first)
        service.saveDirectoryFromFilePicker(second)
        #expect(service.selectedDirectory == second)
        #expect(fixture.shared.string(forKey: sharedPathKey) == second.path)
        #expect(changes == 2)
        let reopened = DirectoryPickerService(
            defaults: fixture.app, sharedDefaults: fixture.shared,
            publishBookmarkCache: { cachePublications.append($0) }, directoryChanged: { changes += 1 }
        )
        #expect(reopened.selectedDirectory == second)
        #expect(reopened.hasValidDirectory)
        let lastCached = cachePublications.last ?? nil
        #expect(lastCached == second)
        #expect(fixture.shared.string(forKey: sharedPathKey) == second.path)
        #expect(changes == 2)
    }

    private final class ReloadEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test func cliReloadInvalidatesBeforeExactlyOneLocalModelsChanged() {
        let center = NotificationCenter()
        let events = ReloadEvents()
        let observer = center.addObserver(forName: .localModelsChanged, object: nil, queue: nil) { _ in
            events.append("changed")
        }
        defer { center.removeObserver(observer) }
        AppDelegate.reloadLocalModelsAfterCLIInstall(
            invalidateCache: { events.append("invalidate") }, notifications: center
        )
        #expect(events.snapshot() == ["invalidate", "changed"])
        #expect(AppDelegate.controlModelsReloadNotification.rawValue == "com.dinoki.osaurus.control.modelsReload")
    }

    @Test func nativeControlObserverRoutesModelsReloadWithoutHTTP() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        root.deleteLastPathComponent()
        root.deleteLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("AppDelegate.swift"), encoding: .utf8)
        #expect(source.contains("selector: #selector(handleModelsReloadCommand(_:))"))
        #expect(source.contains("name: Self.controlModelsReloadNotification"))
        let start = try #require(source.range(of: "@objc private func handleModelsReloadCommand"))
        let end = try #require(source.range(of: "/// Local process notification only", range: start.upperBound..<source.endIndex))
        let handler = String(source[start.lowerBound..<end.lowerBound])
        #expect(handler.contains("Task { @MainActor in"))
        #expect(handler.contains("Self.reloadLocalModelsAfterCLIInstall()"))
        #expect(!handler.contains("HTTP"))
        #expect(!handler.contains("accessKey"))
    }
}

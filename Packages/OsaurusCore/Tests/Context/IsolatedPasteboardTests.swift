//
//  IsolatedPasteboardTests.swift
//  osaurusTests
//
//  Regression coverage for Sentry APPLE-MACOS-1QM: the clipboard poller must
//  read through its own pasteboard connection (`IsolatedPasteboard`), never
//  through `NSPasteboard.general`, which AppKit reads on the main thread and
//  whose type cache is not thread-safe. The tests use a private named
//  pasteboard so a run never touches the user's clipboard; the pasteboard
//  server keeps the `NSPasteboard` writer and the isolated reader coherent
//  exactly as it does for the general pasteboard.
//

import AppKit
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IsolatedPasteboardTests {

    private func makePair() throws -> (writer: NSPasteboard, reader: IsolatedPasteboard) {
        let name = "com.dinoki.osaurus.tests.isolated-pasteboard.\(UUID().uuidString)"
        let writer = NSPasteboard(name: NSPasteboard.Name(name))
        let reader = try #require(IsolatedPasteboard(name: name))
        return (writer, reader)
    }

    /// AppKit returns before the server's change notification necessarily
    /// reaches an independent Pasteboard Manager connection. Observe that
    /// notification, not the eventual payload: wrong/missing payload and extra
    /// generations must still fail the assertions in each test.
    private func awaitPublication(in reader: IsolatedPasteboard) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !reader.synchronize() {
            try #require(ContinuousClock.now < deadline, "pasteboard server did not publish the write")
            await Task.yield()
        }
    }

    @Test func readerIsNotTheAppKitSharedObject() throws {
        // The whole fix: a distinct connection, so the poller shares no
        // mutable state with `NSPasteboard.general`.
        let reader = try #require(IsolatedPasteboard())
        #expect(type(of: reader) != type(of: NSPasteboard.general))
        #expect(reader.changeCount == 0)
    }

    @Test func stringWrittenByNSPasteboardIsReadBack() async throws {
        let (writer, reader) = try makePair()
        defer { writer.releaseGlobally() }
        #expect(reader.synchronize() == false, "nothing changed since the connection was made")

        writer.clearContents()
        try #require(writer.setString("hello from AppKit", forType: .string))

        try await awaitPublication(in: reader)
        #expect(reader.changeCount == 1)
        #expect(reader.string(forType: .string) == "hello from AppKit")
        #expect(reader.data(forType: .png) == nil)
        #expect(reader.string(forType: .fileURL) == nil)
    }

    @Test func changeCountAdvancesOncePerGeneration() async throws {
        let (writer, reader) = try makePair()
        defer { writer.releaseGlobally() }

        writer.clearContents()
        try #require(writer.setString("one", forType: .string))
        try await awaitPublication(in: reader)
        #expect(reader.synchronize() == false, "no new generation, no new count")
        #expect(reader.changeCount == 1)
        #expect(reader.string(forType: .string) == "one")

        writer.clearContents()
        try #require(writer.setString("two", forType: .string))
        try await awaitPublication(in: reader)
        #expect(reader.changeCount == 2)
        #expect(reader.string(forType: .string) == "two")
        #expect(reader.synchronize() == false, "the second publication is observed exactly once")
    }

    @Test func fileURLAndImageDataRoundTrip() async throws {
        let (writer, reader) = try makePair()
        defer { writer.releaseGlobally() }

        let url = URL(fileURLWithPath: "/tmp/osaurus-isolated-pasteboard.txt")
        writer.clearContents()
        try #require(writer.setString(url.absoluteString, forType: .fileURL))
        try await awaitPublication(in: reader)
        #expect(reader.string(forType: .fileURL) == url.absoluteString)

        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        writer.clearContents()
        try #require(writer.setData(bytes, forType: .png))
        try await awaitPublication(in: reader)
        #expect(reader.data(forType: .png) == bytes)
        #expect(reader.string(forType: .string) == nil)
    }

    @Test func detectContentRunsAgainstTheIsolatedReader() async throws {
        let (writer, reader) = try makePair()
        defer { writer.releaseGlobally() }

        writer.clearContents()
        try #require(writer.setString("  plain text payload  ", forType: .string))
        try await awaitPublication(in: reader)
        #expect(ClipboardService.detectContent(in: reader) == .text("  plain text payload  "))

        writer.clearContents()
        try #require(writer.setString("   \n", forType: .string))
        try await awaitPublication(in: reader)
        #expect(ClipboardService.detectContent(in: reader) == nil)
    }

    @Test func clipboardServiceNeverReadsTheSharedPasteboardOffMain() throws {
        // Source contract: the poller's reads go through `IsolatedPasteboard`
        // on its queue; `NSPasteboard.general` must not appear in the service.
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Services/Context/ClipboardService.swift"),
            encoding: .utf8)
        // Call sites only; the comments explaining the fix name the object.
        #expect(!source.contains("NSPasteboard.general."))
        #expect(!source.contains("(NSPasteboard.general)"))
        #expect(!source.contains("= NSPasteboard.general"))
        #expect(source.contains("IsolatedPasteboard"))
        #expect(source.contains("Sentry APPLE-MACOS-1QM"))
    }
    @Test func firstServicePollCompletesWithoutQueueReentrancy() async {
        // Await the production poll, rather than merely scheduling work that
        // could deadlock after the test has already passed.
        await ClipboardService.shared.refreshFromPasteboardIfChanged()
        await ClipboardService.shared.refreshFromPasteboardIfChanged()
    }

}

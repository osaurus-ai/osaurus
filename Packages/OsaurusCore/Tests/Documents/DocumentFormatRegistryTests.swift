//
//  DocumentFormatRegistryTests.swift
//  osaurusTests
//
//  Contract tests for the registry. Covers the three invariants we care
//  about for PR 1: adapters are routed by `canHandle`, later registrations
//  win ties, and `unregisterAll` is a no-op when nothing matches. The
//  thread-safety test just asserts that the internal lock serialises
//  concurrent registrations without losing entries.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("DocumentFormatRegistry")
struct DocumentFormatRegistryTests {

    // MARK: - Adapter routing

    @Test func adapter_returnsNilWhenNoneRegistered() {
        let registry = DocumentFormatRegistry()
        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/unknown.xyz")) == nil)
    }

    @Test func adapter_routesByCanHandle() {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: FakeAdapter(formatId: "pdf", extensions: ["pdf"]))
        registry.register(adapter: FakeAdapter(formatId: "docx", extensions: ["docx"]))

        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/a.pdf"))?.formatId == "pdf")
        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/a.docx"))?.formatId == "docx")
        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/a.rtf")) == nil)
    }

    @Test func adapter_laterRegistrationWinsTie() {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: FakeAdapter(formatId: "pdf-builtin", extensions: ["pdf"]))
        registry.register(adapter: FakeAdapter(formatId: "pdf-plugin", extensions: ["pdf"]))

        #expect(registry.adapter(for: URL(fileURLWithPath: "/tmp/a.pdf"))?.formatId == "pdf-plugin")
    }

    // MARK: - Emitter and streamer

    @Test func emitter_pickedByCanEmit() {
        let registry = DocumentFormatRegistry()
        registry.register(emitter: FakeEmitter(formatId: "xlsx"))
        registry.register(emitter: FakeEmitter(formatId: "docx"))

        #expect(registry.emitter(for: Self.fakeDocument(formatId: "docx"))?.formatId == "docx")
        #expect(registry.emitter(for: Self.fakeDocument(formatId: "xlsx"))?.formatId == "xlsx")
        #expect(registry.emitter(for: Self.fakeDocument(formatId: "pdf")) == nil)
    }

    @Test func streamer_pickedByFormatId() {
        let registry = DocumentFormatRegistry()
        registry.register(streamer: FakeStreamer(formatId: "csv"))

        #expect(registry.streamer(forFormatId: "csv")?.formatId == "csv")
        #expect(registry.streamer(forFormatId: "xlsx") == nil)
    }

    // MARK: - Unregistration

    @Test func unregisterAll_dropsAllRegistrationsForFormatId() {
        let registry = DocumentFormatRegistry()
        registry.register(adapter: FakeAdapter(formatId: "xlsx", extensions: ["xlsx"]))
        registry.register(emitter: FakeEmitter(formatId: "xlsx"))
        registry.register(streamer: FakeStreamer(formatId: "xlsx"))

        #expect(registry.registeredFormatIds() == ["xlsx"])
        #expect(registry.unregisterAll(formatId: "xlsx"))
        #expect(registry.registeredFormatIds().isEmpty)
        #expect(registry.unregisterAll(formatId: "xlsx") == false)
    }

    // MARK: - Thread safety

    @Test func register_isThreadSafe() async {
        let registry = DocumentFormatRegistry()
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 200 {
                group.addTask {
                    registry.register(adapter: FakeAdapter(formatId: "fmt-\(index)", extensions: ["x"]))
                }
            }
        }
        #expect(registry.registeredFormatIds().count == 200)
    }

    // MARK: - Fixtures

    private static func fakeDocument(formatId: String) -> StructuredDocument {
        StructuredDocument(
            formatId: formatId,
            filename: "fixture.\(formatId)",
            fileSize: 0,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: EmptyRepresentation()
            ),
            textFallback: ""
        )
    }

    private struct EmptyRepresentation: StructuredRepresentation {}

    private struct FakeAdapter: DocumentFormatAdapter {
        let formatId: String
        let extensions: Set<String>

        func canHandle(url: URL, uti: String?) -> Bool {
            extensions.contains(url.pathExtension.lowercased())
        }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            DocumentFormatRegistryTests.fakeDocument(formatId: formatId)
        }
    }

    private struct FakeEmitter: DocumentFormatEmitter {
        let formatId: String

        func canEmit(_ document: StructuredDocument) -> Bool {
            document.formatId == formatId
        }

        func emit(_ document: StructuredDocument, to url: URL) async throws {}
    }

    private struct FakeStreamer: DocumentFormatStreamer {
        typealias Element = String
        let formatId: String

        func stream(url: URL) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }
}

//
//  DocumentParserShimTests.swift
//  osaurusTests
//
//  Integration tests for the `DocumentParser.parseAll` shim: verifies that
//  the registry is consulted first, that `.emptyContent` from a registered
//  adapter falls through to the legacy switch, and that errors bubble up
//  translated into the legacy `ParseError` surface. Uses the shared
//  registry (register + `unregisterAll` in teardown) so the shim's call
//  site is exactly the one reached from production.
//

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import OsaurusCore

@Suite("DocumentParser.parseAll registry shim", .serialized)
struct DocumentParserShimTests {

    // A fixture-extension adapter so tests don't collide with built-ins.
    private static let fixtureFormatId = "test-fixture-shim"
    private static let fixtureExtension = "fixtureshim"

    private func registerFixture(content: String) {
        DocumentFormatRegistry.shared.register(
            adapter: FixtureAdapter(
                formatId: Self.fixtureFormatId,
                extensions: [Self.fixtureExtension],
                produce: content
            )
        )
    }

    private func cleanUp() {
        DocumentFormatRegistry.shared.unregisterAll(formatId: Self.fixtureFormatId)
    }

    // MARK: - Routing

    @Test func parseAll_routesThroughRegistry_whenAdapterClaims() throws {
        registerFixture(content: "routed-through-registry")
        defer { cleanUp() }

        let url = try writeFile(content: "ignored", ext: Self.fixtureExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let attachments = try DocumentParser.parseAll(url: url)
        #expect(attachments.count == 1)
        #expect(attachments.first?.documentContent == "routed-through-registry")
    }

    @Test func parseAll_fallsThroughOnEmptyContent() throws {
        // Fixture adapter with empty payload → adapter throws .emptyContent →
        // shim should try the legacy switch, which for an unknown extension
        // surfaces `ParseError.unsupportedFormat`.
        registerFixture(content: "")
        defer { cleanUp() }

        let url = try writeFile(content: "ignored", ext: Self.fixtureExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: DocumentParser.ParseError.self) {
            _ = try DocumentParser.parseAll(url: url)
        }
    }

    @Test func parseAll_preservesLegacyPath_whenNoAdapterMatches() throws {
        // No fixture registered. A plain .txt file still flows through the
        // legacy switch and produces exactly one document attachment.
        let url = try writeFile(content: "legacy path still works", ext: "txt")
        defer { try? FileManager.default.removeItem(at: url) }

        let attachments = try DocumentParser.parseAll(url: url)
        #expect(attachments.count == 1)
        #expect(attachments.first?.documentContent == "legacy path still works")
    }

    @Test func parseAll_timesOutSlowRegistryAdapter() throws {
        DocumentFormatRegistry.shared.register(
            adapter: SlowFixtureAdapter(
                formatId: Self.fixtureFormatId,
                extensions: [Self.fixtureExtension],
                sleepNanoseconds: 2_000_000_000
            )
        )
        defer { cleanUp() }

        let url = try writeFile(content: "ignored", ext: Self.fixtureExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Date()
        do {
            try DocumentParser.withRegistryAdapterTimeoutForTesting(0.05) {
                _ = try DocumentParser.parseAll(url: url)
            }
            Issue.record("Expected slow adapter to time out")
        } catch let error as DocumentParser.ParseError {
            guard case .readFailed(let reason) = error else {
                Issue.record("Expected readFailed timeout, got \(error)")
                return
            }
            #expect(reason.contains("timed out"))
        }

        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    // MARK: - Bootstrap

    @Test func bootstrap_registersExpectedBuiltInsOnIsolatedRegistry() {
        let registry = DocumentFormatRegistry()
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        let ids = registry.registeredFormatIds()
        #expect(ids.contains("plaintext"))
        #expect(ids.contains("csv"))
        #expect(ids.contains("tsv"))
        #expect(ids.contains("pdf"))
        #expect(ids.contains("pptx"))
        #expect(ids.contains("richdoc"))
        #expect(ids.contains("xlsx"))
    }

    @Test func canParse_acceptsRegisteredStructuredOfficeFormats() {
        DocumentAdaptersBootstrap.registerBuiltIns()

        for ext in ["xlsx", "pptx", "potx"] {
            #expect(DocumentParser.canParse(url: URL(fileURLWithPath: "/tmp/fixture.\(ext)")))
        }
    }

    @Test func supportedDocumentTypes_includeStructuredOfficePickerTypes() throws {
        let xlsx = try #require(UTType(filenameExtension: "xlsx"))
        let pptx = try #require(UTType(filenameExtension: "pptx"))
        let potx = try #require(UTType(filenameExtension: "potx"))
        let supported = Set(DocumentParser.supportedDocumentTypes)

        #expect(supported.contains(xlsx))
        #expect(supported.contains(pptx))
        #expect(supported.contains(potx))
    }

    // MARK: - Fixtures

    private func writeFile(content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-shim-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private struct FixtureAdapter: DocumentFormatAdapter {
        let formatId: String
        let extensions: Set<String>
        let produce: String

        func canHandle(url: URL, uti: String?) -> Bool {
            extensions.contains(url.pathExtension.lowercased())
        }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            guard !produce.isEmpty else {
                throw DocumentAdapterError.emptyContent
            }
            return StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: 0,
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: PlainTextRepresentation(text: produce)
                ),
                textFallback: produce
            )
        }
    }

    private struct SlowFixtureAdapter: DocumentFormatAdapter {
        let formatId: String
        let extensions: Set<String>
        let sleepNanoseconds: UInt64

        func canHandle(url: URL, uti: String?) -> Bool {
            extensions.contains(url.pathExtension.lowercased())
        }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            try await Task.sleep(nanoseconds: sleepNanoseconds)
            return StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: 0,
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: PlainTextRepresentation(text: "late")
                ),
                textFallback: "late"
            )
        }
    }
}

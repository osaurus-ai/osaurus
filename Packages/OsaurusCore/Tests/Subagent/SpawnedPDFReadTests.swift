//
//  SpawnedPDFReadTests.swift
//  OsaurusCoreTests
//
//  Proves the narrow spawned-worker PDF contract: host text-layer PDFs use
//  file_read's async PDFAdapter path, image-only PDFs fail honestly, and
//  cancellation drains without publishing a late success. Other rich
//  document routes remain outside spawned ownership.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Spawned PDF reads", .serialized)
@MainActor
struct SpawnedPDFReadTests {
    @Test("owned registry accepts host PDF and extracts its text layer")
    func ownedRegistryExtractsTextLayerPDF() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("article.pdf")
        try Self.writePDF(
            pages: ["McCullough - Jacob Boehme and the Spiritual Roots"],
            to: pdf
        )

        let tool = SpawnedPDFReadRegistryTool(root: root)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let result = try await ToolRegistry.shared.execute(
            name: tool.name,
            argumentsJSON: #"{"path":"article.pdf"}"#,
            permissionGateResolved: true,
            ownsExecutionUntilTermination: true
        )

        #expect(ToolEnvelope.isSuccess(result))
        let payload = try #require(ToolEnvelope.successPayload(result) as? [String: Any])
        let text = try #require(payload["text"] as? String)
        #expect(text.contains("McCullough - Jacob Boehme"))
        #expect(text.contains("cooperative abort-and-drain") == false)
    }

    @Test("image-only PDF fails honestly instead of passing ownership then succeeding")
    func imageOnlyPDFFailsHonestly() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writePDF(pages: [""], to: root.appendingPathComponent("scan.pdf"))

        let tool = SpawnedPDFReadRegistryTool(root: root)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let result = try await ToolRegistry.shared.execute(
            name: tool.name,
            argumentsJSON: #"{"path":"scan.pdf"}"#,
            permissionGateResolved: true,
            ownsExecutionUntilTermination: true
        )

        #expect(ToolEnvelope.isError(result))
        let message = ToolEnvelope.failureMessage(result)
        #expect(message.contains("no extractable text layer"))
        #expect(message.contains("cooperative abort-and-drain") == false)
    }

    @Test("other parser-backed rich documents remain rejected before execution")
    func otherRichDocumentsRemainUnsupported() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("document.docx"))
        let probe = SpawnedPDFReadProbe()

        let tool = SpawnedPDFReadRegistryTool(root: root, probe: probe)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let result = try await ToolRegistry.shared.execute(
            name: tool.name,
            argumentsJSON: #"{"path":"document.docx"}"#,
            permissionGateResolved: true,
            ownsExecutionUntilTermination: true
        )

        #expect(ToolEnvelope.isError(result))
        #expect(ToolEnvelope.failureMessage(result).contains("cooperative abort-and-drain"))
        #expect(!(await probe.started))
    }

    @Test("cancelling an owned PDF read drains and cannot publish success")
    func cancellationDrainsPDFRead() async throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = (0 ..< 240).map { page in
            "Page \(page) " + String(repeating: "cancellation checkpoint ", count: 10)
        }
        try Self.writePDF(pages: pages, to: root.appendingPathComponent("large.pdf"))
        let probe = SpawnedPDFReadProbe()

        let tool = SpawnedPDFReadRegistryTool(root: root, probe: probe)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let operation = OwnedSubagentOperation {
            try await ToolRegistry.shared.execute(
                name: tool.name,
                argumentsJSON: #"{"path":"large.pdf"}"#,
                permissionGateResolved: true,
                ownsExecutionUntilTermination: true
            )
        }

        await Self.waitUntil { await probe.started }
        await operation.abortAndWait()

        #expect(await probe.sawCancellation)
        #expect(await probe.finished)
        #expect(!(await probe.succeeded))
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawned-pdf-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writePDF(pages: [String], to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 640, height: 220)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphicsContext
                NSAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: 12)]
                )
                .draw(at: NSPoint(x: 24, y: 140))
                NSGraphicsContext.restoreGraphicsState()
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        var spins = 4_000
        while !(await predicate()), spins > 0 {
            await Task.yield()
            spins -= 1
        }
        #expect(await predicate())
    }

    private enum FixtureError: Error {
        case contextCreationFailed
    }
}

private actor SpawnedPDFReadProbe {
    private(set) var started = false
    private(set) var sawCancellation = false
    private(set) var finished = false
    private(set) var succeeded = false

    func markStarted() {
        started = true
    }

    func markSucceeded() {
        succeeded = true
        finished = true
    }

    func markCancelled() {
        sawCancellation = true
        finished = true
    }

    func markFailed() {
        finished = true
    }
}

private struct SpawnedPDFReadRegistryTool: OsaurusTool {
    let name = "test_spawned_pdf_read_\(UUID().uuidString.prefix(12))"
    let description = "Test-owned wrapper around the real file_read implementation."
    let parameters: JSONValue?
    private let reader: FileReadTool
    private let probe: SpawnedPDFReadProbe?

    init(root: URL, probe: SpawnedPDFReadProbe? = nil) {
        let reader = FileReadTool(rootPath: root)
        self.reader = reader
        self.parameters = reader.parameters
        self.probe = probe
    }

    var canExposeToSpawnedOperation: Bool {
        reader.canExposeToSpawnedOperation
    }

    func spawnedOperationCancellationSupport(
        argumentsJSON: String
    ) -> SpawnedOperationCancellationSupport {
        reader.spawnedOperationCancellationSupport(argumentsJSON: argumentsJSON)
    }

    func execute(argumentsJSON: String) async throws -> String {
        if let probe {
            await probe.markStarted()
        }
        do {
            let result = try await reader.execute(argumentsJSON: argumentsJSON)
            if let probe {
                await probe.markSucceeded()
            }
            return result
        } catch is CancellationError {
            if let probe {
                await probe.markCancelled()
            }
            throw CancellationError()
        } catch {
            if let probe {
                await probe.markFailed()
            }
            throw error
        }
    }
}

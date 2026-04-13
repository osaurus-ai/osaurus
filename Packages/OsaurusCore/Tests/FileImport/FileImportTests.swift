//
//  FileImportTests.swift
//  osaurusTests
//
//  Tests for the registry-backed file import layer.
//

import Foundation
import Testing

@testable import OsaurusCore

struct FileImportRegistryTests {

    @Test func registryPrefersCoreImporterOverPluginImporter() async throws {
        let registry = FileImportRegistry()
        let pluginImporter = TestImporter(
            descriptor: FileImportDescriptor(
                id: "plugin.txt",
                extensions: ["txt"],
                maxBytes: 1_024,
                source: .nativePlugin,
                outputMode: .normalizedText
            )
        )
        let coreImporter = TestImporter(
            descriptor: FileImportDescriptor(
                id: "core.txt",
                extensions: ["txt"],
                maxBytes: 1_024,
                source: .core,
                outputMode: .normalizedText
            )
        )

        registry.register(pluginImporter, ownerPluginId: "com.test.plugin")
        registry.register(coreImporter)

        let url = URL(fileURLWithPath: "/tmp/example.txt")
        #expect(registry.importer(for: url)?.descriptor.id == "core.txt")
    }

    @Test func registerBuiltInImportersIncludesCoreFormats() {
        let registry = FileImportRegistry()
        FileImportService.registerBuiltInImporters(on: registry)

        let extensions = Set(registry.descriptors().flatMap(\.extensions))
        #expect(extensions.contains("txt"))
        #expect(extensions.contains("pdf"))
        #expect(extensions.contains("docx"))
    }

    @Test func documentParserParsesTextAttachment() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("sample.txt")
        try "alpha\nbeta\n".write(to: url, atomically: true, encoding: .utf8)

        let attachment = try await DocumentParser.parse(url: url)
        #expect(attachment.isDocument)
        #expect(attachment.filename == "sample.txt")
        #expect(attachment.documentContent?.contains("beta") == true)
    }
}

private struct TestImporter: FileImporter {
    let descriptor: FileImportDescriptor

    func importFile(at url: URL) async throws -> [Attachment] {
        [.document(filename: url.lastPathComponent, content: "ok", fileSize: 2)]
    }
}

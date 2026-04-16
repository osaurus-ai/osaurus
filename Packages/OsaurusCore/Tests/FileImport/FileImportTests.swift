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

    @Test func registerBuiltInImportersIncludesExpandedTextFormats() {
        let registry = FileImportRegistry()
        FileImportService.registerBuiltInImporters(on: registry)

        let extensions = Set(registry.descriptors().flatMap(\.extensions))
        #expect(extensions.contains("jsonl"))
        #expect(extensions.contains("ndjson"))
        #expect(extensions.contains("svg"))
        #expect(extensions.contains("plist"))
    }

    @Test func documentParserParsesJsonlAttachment() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("sample.jsonl")
        try """
        {"id":1,"value":"alpha"}
        {"id":2,"value":"beta"}
        """.write(to: url, atomically: true, encoding: .utf8)

        let attachment = try await DocumentParser.parse(url: url)
        #expect(attachment.isDocument)
        #expect(attachment.filename == "sample.jsonl")
        #expect(attachment.documentContent?.contains("\"value\":\"beta\"") == true)
    }

    @Test func documentParserParsesPropertyListAttachment() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("sample.plist")
        let plistObject: [String: Any] = [
            "name": "Osaurus",
            "features": ["attachments", "plugins"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistObject, format: .binary, options: 0)
        try data.write(to: url)

        let attachment = try await DocumentParser.parse(url: url)
        #expect(attachment.isDocument)
        #expect(attachment.filename == "sample.plist")
        #expect(attachment.documentContent?.contains("\"name\" : \"Osaurus\"") == true)
    }

    @Test func documentParserTruncatesOversizedTextContent() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("large.txt")
        try String(repeating: "a", count: FileImportService.maxParsedTextLength + 32)
            .write(to: url, atomically: true, encoding: .utf8)

        let attachment = try await DocumentParser.parse(url: url)
        #expect(attachment.isDocument)
        #expect(attachment.documentContent?.contains("[Document truncated") == true)
    }

    @Test func documentParserRejectsOversizedFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("too-large.txt")
        try Data(repeating: 0x61, count: FileImportService.defaultMaxInputBytes + 1).write(to: url)

        do {
            _ = try await DocumentParser.parse(url: url)
            Issue.record("Expected oversized attachment to throw")
        } catch let error as FileImportError {
            #expect(error == .fileTooLarge(maxBytes: FileImportService.defaultMaxInputBytes))
        }
    }
}

private struct TestImporter: FileImporter {
    let descriptor: FileImportDescriptor

    func importFile(at url: URL) async throws -> [OsaurusCore.Attachment] {
        [OsaurusCore.Attachment.document(filename: url.lastPathComponent, content: "ok", fileSize: 2)]
    }
}

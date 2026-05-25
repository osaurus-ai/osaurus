//
//  PPTXAdapterTests.swift
//  osaurusTests
//
//  Builds tiny OpenXML packages directly in memory so tests exercise the
//  bounded ZIP reader without shelling out or checking binary fixtures into
//  the repository.
//

import Compression
import Foundation
import Testing

@testable import OsaurusCore

@Suite("PPTXAdapter")
struct PPTXAdapterTests {
    @Test func canHandle_acceptsPPTXAndPOTXExtensionsAndUTIs() {
        let adapter = PPTXAdapter()

        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/deck.pptx"), uti: nil))
        #expect(adapter.canHandle(url: URL(fileURLWithPath: "/tmp/template.potx"), uti: nil))
        #expect(
            adapter.canHandle(
                url: URL(fileURLWithPath: "/tmp/deck"),
                uti: "org.openxmlformats.presentationml.presentation"
            )
        )
        #expect(
            adapter.canHandle(
                url: URL(fileURLWithPath: "/tmp/template"),
                uti: "org.openxmlformats.presentationml.template"
            )
        )
        #expect(!adapter.canHandle(url: URL(fileURLWithPath: "/tmp/deck.ppt"), uti: nil))
        #expect(!adapter.canHandle(url: URL(fileURLWithPath: "/tmp/deck.docx"), uti: nil))
    }

    @Test func parse_extractsOrderedSlideTextSpeakerNotesAndAnchors() async throws {
        let fixture = try makePresentationFixture(
            fileExtension: "pptx",
            slides: [
                1: ["First by filename", "Later in the deck"],
                2: ["Quarterly Review", "Revenue & retention", "Next steps"],
            ],
            slideOrder: [2, 1],
            notes: [2: ["Mention pilot customers", "Pause for questions"]],
            externalTargets: ["https://example.com/deck-context"],
            compression: .deflated
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let document = try await PPTXAdapter().parse(url: fixture.url, sizeLimit: 100_000)
        let presentation = try #require(document.representation.underlying as? PresentationDocument)

        #expect(presentation.kind == .presentation)
        #expect(presentation.slides.map(\.number) == [2, 1])
        #expect(presentation.slides[0].text == "Quarterly Review\nRevenue & retention\nNext steps")
        #expect(presentation.slides[0].speakerNotes?.text == "Mention pilot customers\nPause for questions")
        #expect(document.textFallback.contains("Slide 1\nQuarterly Review"))
        #expect(document.textFallback.contains("Speaker notes:\nMention pilot customers"))

        let firstRun = try #require(presentation.slides[0].textRuns.first)
        #expect(document.structure.anchor(id: firstRun.anchorId) != nil)
        #expect(document.structure.elements(kind: .slide).count == 2)
        #expect(
            document.structure.elements(kind: .speakerNotes).first?.anchor.metadata["sourcePart"]
                == "ppt/notesSlides/notesSlide2.xml"
        )
        #expect(document.security.externalReferences.first?.urlString == "https://example.com/deck-context")
    }

    @Test func parse_marksPOTXAsTemplate() async throws {
        let fixture = try makePresentationFixture(
            fileExtension: "potx",
            slides: [1: ["Template title"]],
            slideOrder: [1],
            compression: .stored
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let document = try await PPTXAdapter().parse(url: fixture.url, sizeLimit: 100_000)
        let presentation = try #require(document.representation.underlying as? PresentationDocument)

        #expect(presentation.kind == .template)
        #expect(document.textFallback.contains("Template title"))
    }

    @Test func parse_reportsExternallyAddressedRelationshipsWithoutValidTargetMode() async throws {
        let fixture = try makePresentationFixture(
            fileExtension: "pptx",
            slides: [1: ["External relationships"]],
            slideOrder: [1],
            externalRelationships: [
                RelationshipFixture(
                    id: "urlMissingMode",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                    target: "https://example.com/no-target-mode"
                ),
                RelationshipFixture(
                    id: "fileMalformedMode",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                    target: "file:///tmp/linked-image.png",
                    targetMode: "Externall"
                ),
                RelationshipFixture(
                    id: "schemeRelativeMissingMode",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/video",
                    target: "//cdn.example.com/clip.mp4"
                ),
            ],
            compression: .stored
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let document = try await PPTXAdapter().parse(url: fixture.url, sizeLimit: 100_000)
        let references = document.security.externalReferences
        let targets = Set(references.map(\.urlString))

        #expect(
            targets
                == Set([
                    "https://example.com/no-target-mode",
                    "file:///tmp/linked-image.png",
                    "//cdn.example.com/clip.mp4",
                ])
        )
        #expect(document.security.activeContentTypes.contains(.externalReference))
        #expect(references.first { $0.relationshipId == "urlMissingMode" }?.kind == .hyperlink)
        #expect(references.first { $0.relationshipId == "fileMalformedMode" }?.kind == .image)
        #expect(references.first { $0.relationshipId == "schemeRelativeMissingMode" }?.kind == .media)
        #expect(
            document.security.findings.contains {
                $0.kind == .externalReference && $0.metadata["count"] == "3"
            }
        )
    }

    @Test func parse_refusesFilesAboveSizeLimit() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("too-large.pptx")
        try Data(repeating: 0x41, count: 16).write(to: url)

        do {
            _ = try await PPTXAdapter().parse(url: url, sizeLimit: 15)
            Issue.record("expected sizeLimitExceeded")
        } catch DocumentAdapterError.sizeLimitExceeded(let actual, let limit) {
            #expect(actual == 16)
            #expect(limit == 15)
        } catch {
            Issue.record("expected sizeLimitExceeded, got \(error)")
        }
    }

    @Test func parse_corruptZipThrowsReadFailed() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("corrupt.pptx")
        try Data("not a zip archive".utf8).write(to: url)

        do {
            _ = try await PPTXAdapter().parse(url: url, sizeLimit: 100_000)
            Issue.record("expected readFailed")
        } catch DocumentAdapterError.readFailed(let underlying) {
            #expect(!underlying.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            Issue.record("expected readFailed, got \(error)")
        }
    }

    @Test func bootstrap_registersPPTXAdapter() {
        let registry = DocumentFormatRegistry()

        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)

        #expect(registry.registeredFormatIds().contains(PPTXAdapter.id))
    }

    // MARK: - Fixture generation

    private func makePresentationFixture(
        fileExtension: String,
        slides: [Int: [String]],
        slideOrder: [Int],
        notes: [Int: [String]] = [:],
        externalTargets: [String] = [],
        externalRelationships: [RelationshipFixture] = [],
        compression: FixtureCompression
    ) throws -> (root: URL, url: URL) {
        let root = try makeTempDirectory()
        let url = root.appendingPathComponent("fixture.\(fileExtension)")
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("ppt/presentation.xml", Data(presentationXML(slideOrder: slideOrder).utf8)),
            ("ppt/_rels/presentation.xml.rels", Data(presentationRelationshipsXML(slideOrder: slideOrder).utf8)),
        ]

        for (number, paragraphs) in slides {
            entries.append(("ppt/slides/slide\(number).xml", Data(slideXML(paragraphs).utf8)))
            let slideRelationships = slideRelationshipsXML(
                slideNumber: number,
                hasNotes: notes[number] != nil,
                externalTargets: number == slideOrder.first ? externalTargets : [],
                externalRelationships: number == slideOrder.first ? externalRelationships : []
            )
            if !slideRelationships.isEmpty {
                entries.append(("ppt/slides/_rels/slide\(number).xml.rels", Data(slideRelationships.utf8)))
            }
        }

        for (number, paragraphs) in notes {
            entries.append(("ppt/notesSlides/notesSlide\(number).xml", Data(notesXML(paragraphs).utf8)))
        }

        try writeZip(entries: entries, to: url, compression: compression)
        return (root, url)
    }

    private var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        </Types>
        """
    }

    private func presentationXML(slideOrder: [Int]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <p:sldIdLst>
            \(slideOrder.enumerated().map { index, number in #"<p:sldId id="\#(256 + index)" r:id="rId\#(number)"/>"# }.joined(separator: "\n    "))
          </p:sldIdLst>
        </p:presentation>
        """
    }

    private func presentationRelationshipsXML(slideOrder: [Int]) -> String {
        relationshipsXML(
            slideOrder.map { number in
                RelationshipFixture(
                    id: "rId\(number)",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide",
                    target: "slides/slide\(number).xml"
                )
            }
        )
    }

    private func slideRelationshipsXML(
        slideNumber: Int,
        hasNotes: Bool,
        externalTargets: [String],
        externalRelationships: [RelationshipFixture]
    ) -> String {
        var relationships: [RelationshipFixture] = []
        if hasNotes {
            relationships.append(
                RelationshipFixture(
                    id: "notes\(slideNumber)",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide",
                    target: "../notesSlides/notesSlide\(slideNumber).xml"
                )
            )
        }
        relationships.append(
            contentsOf: externalTargets.enumerated().map { index, target in
                RelationshipFixture(
                    id: "external\(index)",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                    target: target,
                    targetMode: "External"
                )
            }
        )
        relationships.append(contentsOf: externalRelationships)
        guard !relationships.isEmpty else { return "" }
        return relationshipsXML(relationships)
    }

    private func relationshipsXML(_ relationships: [RelationshipFixture]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          \(relationships.map(\.xml).joined(separator: "\n  "))
        </Relationships>
        """
    }

    private func slideXML(_ paragraphs: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld>
            <p:spTree>
              \(paragraphs.map(textShapeXML).joined(separator: "\n"))
            </p:spTree>
          </p:cSld>
        </p:sld>
        """
    }

    private func notesXML(_ paragraphs: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld>
            <p:spTree>
              \(paragraphs.map(textShapeXML).joined(separator: "\n"))
            </p:spTree>
          </p:cSld>
        </p:notes>
        """
    }

    private func textShapeXML(_ text: String) -> String {
        """
        <p:sp>
          <p:txBody>
            <a:p>
              <a:r><a:t>\(escapeXML(text))</a:t></a:r>
            </a:p>
          </p:txBody>
        </p:sp>
        """
    }

    private func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-pptx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeZip(
        entries: [(String, Data)],
        to destination: URL,
        compression: FixtureCompression
    ) throws {
        var output = Data()
        var centralDirectory = Data()
        var centralRecords: [CentralRecord] = []

        for (path, data) in entries {
            let encoded = compression.encoded(data)
            let pathData = Data(path.utf8)
            let localOffset = output.count

            output.appendUInt32(0x0403_4B50)
            output.appendUInt16(20)
            output.appendUInt16(0)
            output.appendUInt16(encoded.method)
            output.appendUInt16(0)
            output.appendUInt16(0)
            output.appendUInt32(crc32(data))
            output.appendUInt32(UInt32(encoded.data.count))
            output.appendUInt32(UInt32(data.count))
            output.appendUInt16(UInt16(pathData.count))
            output.appendUInt16(0)
            output.append(pathData)
            output.append(encoded.data)

            centralRecords.append(
                CentralRecord(
                    pathData: pathData,
                    method: encoded.method,
                    crc32: crc32(data),
                    compressedSize: UInt32(encoded.data.count),
                    uncompressedSize: UInt32(data.count),
                    localOffset: UInt32(localOffset)
                )
            )
        }

        let centralDirectoryOffset = output.count
        for record in centralRecords {
            centralDirectory.appendUInt32(0x0201_4B50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(record.method)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(record.crc32)
            centralDirectory.appendUInt32(record.compressedSize)
            centralDirectory.appendUInt32(record.uncompressedSize)
            centralDirectory.appendUInt16(UInt16(record.pathData.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(record.localOffset)
            centralDirectory.append(record.pathData)
        }
        output.append(centralDirectory)

        output.appendUInt32(0x0605_4B50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(centralRecords.count))
        output.appendUInt16(UInt16(centralRecords.count))
        output.appendUInt32(UInt32(centralDirectory.count))
        output.appendUInt32(UInt32(centralDirectoryOffset))
        output.appendUInt16(0)
        try output.write(to: destination)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private struct RelationshipFixture {
    let id: String
    let type: String
    let target: String
    var targetMode: String?

    var xml: String {
        let mode = targetMode.map { #" TargetMode="\#($0)""# } ?? ""
        return #"<Relationship Id="\#(id)" Type="\#(type)" Target="\#(target)"\#(mode)/>"#
    }
}

private enum FixtureCompression {
    case stored
    case deflated

    func encoded(_ data: Data) -> (method: UInt16, data: Data) {
        switch self {
        case .stored:
            return (0, data)
        case .deflated:
            var output = [UInt8](repeating: 0, count: max(64, data.count + 64))
            let written = data.withUnsafeBytes { sourceBuffer in
                guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    &output,
                    output.count,
                    source,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            guard written > 0, written < data.count else {
                return (0, data)
            }
            return (8, Data(output.prefix(written)))
        }
    }
}

private struct CentralRecord {
    let pathData: Data
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localOffset: UInt32
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0x00FF))
        append(UInt8((value >> 8) & 0x00FF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0x0000_00FF))
        append(UInt8((value >> 8) & 0x0000_00FF))
        append(UInt8((value >> 16) & 0x0000_00FF))
        append(UInt8((value >> 24) & 0x0000_00FF))
    }
}

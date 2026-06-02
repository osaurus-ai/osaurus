//
//  PPTXAdapterTests.swift
//  osaurusTests
//
//  Builds tiny OpenXML packages directly in memory so tests exercise the
//  bounded ZIP reader without shelling out or checking binary fixtures into
//  the repository.
//

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

    @Test func parse_preservesSlideTableCellsAndStructureAnchors() async throws {
        let fixture = try makePresentationFixture(
            fileExtension: "pptx",
            slides: [1: ["Regional forecast"]],
            slideOrder: [1],
            tables: [
                1: [
                    [
                        ["Region", "Revenue"],
                        ["North", "1200"],
                        ["South", "900"],
                        ["West", ""],
                    ]
                ]
            ],
            compression: .stored
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let document = try await PPTXAdapter().parse(url: fixture.url, sizeLimit: 100_000)
        let presentation = try #require(document.representation.underlying as? PresentationDocument)
        let table = try #require(presentation.slides.first?.tables.first)

        #expect(table.rows.count == 4)
        #expect(table.columnCount == 2)
        #expect(table.rows[0].cells.map(\.text) == ["Region", "Revenue"])
        #expect(table.rows[2].cells.map(\.text) == ["South", "900"])
        #expect(table.rows[3].cells.map(\.text) == ["West", ""])
        #expect(table.rows[1].cells[0].paragraphIndexes.isEmpty == false)
        #expect(table.rows[3].cells[1].paragraphIndexes.isEmpty)
        #expect(document.textFallback.contains("Regional forecast"))
        #expect(document.textFallback.contains("Region"))
        #expect(document.textFallback.contains("1200"))

        let tableElement = try #require(document.structure.elements(kind: .table).first)
        let cells = document.structure.elements(kind: .tableCell)
        #expect(document.structure.elements(kind: .tableRow).count == 4)
        #expect(cells.count == 8)
        #expect(tableElement.anchor.metadata["rowCount"] == "4")
        #expect(tableElement.anchor.metadata["columnCount"] == "2")
        #expect(cells.map(\.text).contains("Revenue"))
        let north = try #require(cells.first { $0.text == "North" })
        #expect(north.anchor.sourceRange?.start.slideIndex == 0)
        #expect(north.anchor.sourceRange?.start.rowIndex == 1)
        #expect(north.anchor.sourceRange?.start.columnIndex == 0)
        #expect(north.anchor.textRange?.endUTF16Offset ?? 0 <= document.textFallback.utf16.count)
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

    @Test func parse_reportsMacroEmbeddedObjectExternalAndHiddenSlideSignals() async throws {
        let fixture = try makePresentationFixture(
            fileExtension: "pptx",
            slides: [
                1: ["Visible plan"],
                2: ["Hidden acquisition appendix"],
            ],
            slideOrder: [1, 2],
            hiddenSlides: [2],
            externalRelationships: [
                RelationshipFixture(
                    id: "linkedDeck",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink",
                    target: "https://example.com/source-deck",
                    targetMode: "External"
                )
            ],
            extraSlideRelationships: [
                1: [
                    RelationshipFixture(
                        id: "oleObject",
                        type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/oleObject",
                        target: "../embeddings/oleObject1.bin"
                    ),
                    RelationshipFixture(
                        id: "embeddedPackage",
                        type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/package",
                        target: "../embeddings/package1.bin"
                    ),
                    RelationshipFixture(
                        id: "activeXControl",
                        type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/control",
                        target: "../activeX/activeX1.bin"
                    ),
                    RelationshipFixture(
                        id: "vbaProject",
                        type: "http://schemas.microsoft.com/office/2006/relationships/vbaProject",
                        target: "../vbaProject.bin"
                    ),
                ]
            ],
            extraEntries: [
                ("ppt/vbaProject.bin", Data([0x56, 0x42, 0x41])),
                ("ppt/embeddings/oleObject1.bin", Data([0x4F, 0x4C, 0x45])),
                ("ppt/embeddings/package1.bin", Data([0x50, 0x4B, 0x03, 0x04])),
                ("ppt/activeX/activeX1.bin", Data([0x41, 0x58])),
            ],
            compression: .stored
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let document = try await PPTXAdapter().parse(url: fixture.url, sizeLimit: 100_000)
        let presentation = try #require(document.representation.underlying as? PresentationDocument)
        let hiddenSlide = try #require(presentation.slides.first { $0.number == 2 })

        #expect(hiddenSlide.isHidden)
        #expect(document.structure.elements(kind: .slide)[1].anchor.metadata["isHidden"] == "true")
        #expect(document.security.activeContentTypes.contains(.macro))
        #expect(document.security.activeContentTypes.contains(.embeddedFile))
        #expect(document.security.activeContentTypes.contains(.externalReference))
        #expect(
            document.security.externalReferences.contains {
                $0.relationshipId == "linkedDeck" && $0.kind == .hyperlink
            }
        )
        #expect(
            document.security.findings.contains {
                $0.kind == .macro && $0.severity == .high && $0.metadata["partCount"] == "1"
            }
        )
        #expect(
            document.security.findings.contains {
                $0.kind == .embeddedFile && $0.severity == .medium && $0.metadata["partCount"] == "3"
            }
        )
        #expect(
            document.security.findings.contains {
                $0.metadata["feature"] == "hiddenSlides"
                    && $0.metadata["count"] == "1"
                    && $0.metadata["slideNumbers"] == "2"
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
        tables: [Int: [[[String]]]] = [:],
        hiddenSlides: Set<Int> = [],
        externalTargets: [String] = [],
        externalRelationships: [RelationshipFixture] = [],
        extraSlideRelationships: [Int: [RelationshipFixture]] = [:],
        extraEntries: [(String, Data)] = [],
        compression: OpenXMLZipFixture.Compression
    ) throws -> (root: URL, url: URL) {
        let root = try makeTempDirectory()
        let url = root.appendingPathComponent("fixture.\(fileExtension)")
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("ppt/presentation.xml", Data(presentationXML(slideOrder: slideOrder).utf8)),
            ("ppt/_rels/presentation.xml.rels", Data(presentationRelationshipsXML(slideOrder: slideOrder).utf8)),
        ]

        for (number, paragraphs) in slides {
            entries.append(
                (
                    "ppt/slides/slide\(number).xml",
                    Data(
                        slideXML(
                            paragraphs,
                            tables: tables[number] ?? [],
                            isHidden: hiddenSlides.contains(number)
                        ).utf8
                    )
                )
            )
            let slideRelationships = slideRelationshipsXML(
                slideNumber: number,
                hasNotes: notes[number] != nil,
                externalTargets: number == slideOrder.first ? externalTargets : [],
                externalRelationships: number == slideOrder.first ? externalRelationships : [],
                extraRelationships: extraSlideRelationships[number] ?? []
            )
            if !slideRelationships.isEmpty {
                entries.append(("ppt/slides/_rels/slide\(number).xml.rels", Data(slideRelationships.utf8)))
            }
        }

        for (number, paragraphs) in notes {
            entries.append(("ppt/notesSlides/notesSlide\(number).xml", Data(notesXML(paragraphs).utf8)))
        }

        entries.append(contentsOf: extraEntries)
        try OpenXMLZipFixture.write(entries: entries, to: url, compression: compression)
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
        externalRelationships: [RelationshipFixture],
        extraRelationships: [RelationshipFixture]
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
        relationships.append(contentsOf: extraRelationships)
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

    private func slideXML(_ paragraphs: [String], tables: [[[String]]] = [], isHidden: Bool = false) -> String {
        let showAttribute = isHidden ? #" show="0""# : ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"\(showAttribute)>
              <p:cSld>
                <p:spTree>
                  \(paragraphs.map(textShapeXML).joined(separator: "\n"))
                  \(tables.map(tableXML).joined(separator: "\n"))
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

    private func tableXML(_ rows: [[String]]) -> String {
        """
        <p:graphicFrame>
          <a:graphic>
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">
              <a:tbl>
                <a:tblPr/>
                <a:tblGrid>
                  \((0 ..< (rows.map(\.count).max() ?? 0)).map { _ in #"<a:gridCol w="2000000"/>"# }.joined(separator: "\n        "))
                </a:tblGrid>
                \(rows.map(tableRowXML).joined(separator: "\n        "))
              </a:tbl>
            </a:graphicData>
          </a:graphic>
        </p:graphicFrame>
        """
    }

    private func tableRowXML(_ cells: [String]) -> String {
        """
        <a:tr h="370840">
          \(cells.map(tableCellXML).joined(separator: "\n  "))
        </a:tr>
        """
    }

    private func tableCellXML(_ text: String) -> String {
        """
        <a:tc>
          <a:txBody>
            <a:p>
              <a:r><a:t>\(escapeXML(text))</a:t></a:r>
            </a:p>
          </a:txBody>
        </a:tc>
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

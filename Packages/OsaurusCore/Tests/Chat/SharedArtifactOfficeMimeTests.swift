//
//  SharedArtifactOfficeMimeTests.swift
//  osaurusTests
//
//  `share_artifact` on a document produced by `file_write` must surface a
//  typed card (Word / Spreadsheet / Presentation), not a generic "File".
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SharedArtifact Office MIME types")
struct SharedArtifactOfficeMimeTests {

    private func artifact(named filename: String) -> SharedArtifact {
        SharedArtifact(
            contextId: "ctx",
            contextType: .chat,
            filename: filename,
            mimeType: SharedArtifact.mimeType(from: filename),
            fileSize: 1,
            hostPath: "/tmp/\(filename)"
        )
    }

    @Test
    func ooxmlExtensionsMapToTypedMimesAndLabels() {
        let docx = artifact(named: "brief.docx")
        #expect(docx.mimeType == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(docx.categoryLabel == "Word Document")
        #expect(docx.isOfficeDocument)

        let xlsx = artifact(named: "budget.XLSX")
        #expect(xlsx.mimeType == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        #expect(xlsx.categoryLabel == "Spreadsheet")

        let pptx = artifact(named: "deck.pptx")
        #expect(pptx.mimeType == "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        #expect(pptx.categoryLabel == "Presentation")
    }

    @Test
    func legacyOfficeExtensionsAreTypedToo() {
        #expect(artifact(named: "old.doc").categoryLabel == "Word Document")
        #expect(artifact(named: "old.xls").categoryLabel == "Spreadsheet")
        #expect(artifact(named: "old.ppt").categoryLabel == "Presentation")
        #expect(artifact(named: "notes.rtf").categoryLabel == "Word Document")
    }

    @Test
    func nonOfficeFilesAreUnaffected() {
        let pdf = artifact(named: "report.pdf")
        #expect(pdf.isPDF)
        #expect(!pdf.isOfficeDocument)
        #expect(pdf.categoryLabel == "PDF")
        #expect(artifact(named: "data.bin").categoryLabel == "File")
    }
}

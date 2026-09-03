//
//  ToolDisplayNameRedactionTests.swift
//  osaurusTests
//
//  Pins the friendly chip labels for the redaction tools (a raw
//  `detect_pii` previously fell through the humanizer as "Detect pii")
//  and the humanizer's whole-word acronym casing.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolDisplayNameRedactionTests {

    @Test func detectPII_hasFriendlyLabels() {
        #expect(
            ToolDisplayName.friendly(for: "detect_pii", running: true)
                == L("Scanning for personal information"))
        #expect(
            ToolDisplayName.friendly(for: "detect_pii", running: false)
                == L("Scanned for personal information"))
    }

    @Test func redactFile_hasFriendlyLabels() {
        #expect(
            ToolDisplayName.friendly(for: "redact_file", running: true)
                == L("Redacting personal information"))
        #expect(
            ToolDisplayName.friendly(for: "redact_file", running: false)
                == L("Redacted personal information"))
    }

    @Test func humanizer_upcasesPIIAcronym() {
        // Uncurated names containing the acronym must render it uppercase.
        let title = ToolDisplayName.friendly(for: "scan_pii_report", running: false)
        #expect(title.contains("PII"))
        #expect(!title.contains("pii"))
    }
}

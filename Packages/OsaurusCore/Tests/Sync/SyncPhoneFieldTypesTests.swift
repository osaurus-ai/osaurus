//
//  SyncPhoneFieldTypesTests.swift
//  OsaurusCoreTests
//
//  The Mac, not the phone, decides which fields a phone's values count for:
//  a form answered on the iPhone and a workflow started from it take the
//  phone's values only for the field types it fills in. A file or folder is
//  a path on this Mac, and a secret isn't written into synced data.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct SyncPhoneFieldTypesTests {

    private static let fields = [
        DialogField(key: "topic", label: "Topic"),
        DialogField(key: "count", label: "Count", type: .number),
        DialogField(key: "folder", label: "Folder", type: .folder, required: false, defaultValue: .string("/Mac")),
        DialogField(key: "file", label: "File", type: .file, required: false),
        DialogField(key: "key", label: "Key", type: .secret, required: false),
    ]

    @Test("a form answer keeps the phone's values only for the fields it fills in")
    func formAnswer() {
        let given: [String: JSONValue] = [
            "topic": .string("Q3"),
            "count": .number(2),
            "folder": .string("/Users/me/.ssh"),
            "file": .string("/etc/passwd"),
            "key": .string("sk-from-phone"),
            "extra": .string("not a field"),
        ]
        let kept = WorkflowDialogAttention.phoneValues(given, fields: Self.fields, prefill: ["file": .string("/a.txt")])
        #expect(kept["topic"] == .string("Q3"))
        #expect(kept["count"] == .number(2))
        // The Mac's own starting values, never the phone's.
        #expect(kept["folder"] == .string("/Mac"))
        #expect(kept["file"] == .string("/a.txt"))
        #expect(kept["key"] == nil)
        #expect(kept["extra"] == nil)
    }

    @Test("every type the phone may fill in is kept")
    func phoneTypesKept() {
        let fields = WorkflowDialogAttention.phoneTypes.map { DialogField(key: $0.rawValue, label: "", type: $0) }
        let given = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, JSONValue.string("v")) })
        #expect(WorkflowDialogAttention.phoneValues(given, fields: fields, prefill: [:]) == given)
    }

    @Test("the library and the forms agree on what the phone fills in")
    func sameTypes() {
        #expect(SyncWorkflowLibrary.phoneTypes == WorkflowDialogAttention.phoneTypes)
        #expect(!SyncWorkflowLibrary.phoneTypes.contains(.file))
        #expect(!SyncWorkflowLibrary.phoneTypes.contains(.folder))
        #expect(!SyncWorkflowLibrary.phoneTypes.contains(.secret))
    }
}

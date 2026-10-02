//
//  PhoneAgentEditingTests.swift
//  OsaurusCoreTests
//
//  The phone's agent edits (`PATCH /agents/{id}`): only the fields sent
//  change, `null` puts temperature and max tokens back to the default, and
//  anything out of range or of the wrong type is refused before it lands.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Phone agent edits")
struct PhoneAgentEditingTests {
    private func patch(_ json: String) throws -> PhoneAgentEditing.Patch {
        try PhoneAgentEditing.patch(from: Data(json.utf8))
    }

    @Test func onlyTheFieldsSentChange() throws {
        let edit = try patch(#"{"name":"Scout","memory_enabled":false,"temperature":0.4}"#)
        #expect(edit.name == "Scout")
        #expect(edit.memoryEnabled == false)
        #expect(edit.temperature == .set(0.4))
        #expect(edit.toolsEnabled == nil)
        #expect(edit.maxTokens == nil)
        #expect(edit.systemPrompt == nil)
    }

    @Test func nullGoesBackToTheDefault() throws {
        let edit = try patch(#"{"temperature":null,"max_tokens":null}"#)
        #expect(edit.temperature == .clear)
        #expect(edit.maxTokens == .clear)
    }

    @Test func refusesWhatCannotLand() {
        for body in [
            #"{}"#,
            #"[]"#,
            #"{"temperature":2.5}"#,
            #"{"max_tokens":0}"#,
            #"{"max_tokens":12.5}"#,
            #"{"tools_enabled":1}"#,
            #"{"name":3}"#,
        ] {
            #expect(throws: PhoneAgentEditing.EditError.self) { try patch(body) }
        }
    }
}

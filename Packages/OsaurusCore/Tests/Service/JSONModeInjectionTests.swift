//
//  JSONModeInjectionTests.swift
//  osaurusTests
//
//  Coverage for `ModelRuntime.applyJSONMode` — the local-side JSON-mode
//  prompt injection added when a request carries
//  `response_format: {type: "json_object"}`. The helper must:
//    1. Be a no-op when jsonMode is false.
//    2. Append the JSON directive to an existing system message.
//    3. Insert a fresh system message at index 0 when none exists.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct JSONModeInjectionTests {

    @Test func disabledModeReturnsMessagesUnchanged() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are helpful."),
            ChatMessage(role: "user", content: "Hi"),
        ]
        let augmented = ModelRuntime.applyJSONMode(messages, jsonMode: false)
        #expect(augmented.count == messages.count)
        #expect(augmented[0].content == "You are helpful.")
    }

    @Test func enabledModeAppendsDirectiveToExistingSystemMessage() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "You are helpful."),
            ChatMessage(role: "user", content: "Give me an order."),
        ]
        let augmented = ModelRuntime.applyJSONMode(messages, jsonMode: true)
        #expect(augmented.count == messages.count)
        #expect(augmented[0].role == "system")
        let sysContent = augmented[0].content ?? ""
        #expect(sysContent.contains("You are helpful."))
        #expect(sysContent.contains("single valid JSON object"))
    }

    @Test func enabledModeInsertsSystemMessageWhenAbsent() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "Give me an order.")
        ]
        let augmented = ModelRuntime.applyJSONMode(messages, jsonMode: true)
        #expect(augmented.count == messages.count + 1)
        #expect(augmented[0].role == "system")
        #expect((augmented[0].content ?? "").contains("single valid JSON object"))
    }

    @Test func enabledModePreservesNonSystemMessageOrder() {
        let messages: [ChatMessage] = [
            ChatMessage(role: "user", content: "first user"),
            ChatMessage(role: "assistant", content: "first assistant"),
            ChatMessage(role: "user", content: "second user"),
        ]
        let augmented = ModelRuntime.applyJSONMode(messages, jsonMode: true)
        // System inserted at index 0 — original ordering shifted by one.
        #expect(augmented[0].role == "system")
        #expect(augmented[1].content == "first user")
        #expect(augmented[2].content == "first assistant")
        #expect(augmented[3].content == "second user")
    }
}

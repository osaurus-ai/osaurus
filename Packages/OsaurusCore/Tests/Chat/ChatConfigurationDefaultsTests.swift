//
//  ChatConfigurationDefaultsTests.swift
//  osaurusTests
//
//  Locks in the opt-in default for AI-generated greetings and the
//  Codable round-trip for the new `generativeGreetingsEnabled` flag.
//  Without these, an accidental flip of the default back to `true`
//  would re-introduce the multi-second cold-start wait that the
//  opt-in revamp was designed to remove (and the round-trip check
//  protects against the same auto-synthesized-Codable footgun that
//  ate the legacy `enableGenerativeGreetings` flag in 2026-04).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ChatConfiguration generative greetings defaults")
struct ChatConfigurationDefaultsTests {

    @Test("default config has AI greetings OFF")
    func defaultIsOff() {
        let cfg = ChatConfiguration.default
        #expect(cfg.generativeGreetingsEnabled == false)
    }

    @Test("Codable round-trip preserves the OFF default")
    func codableRoundTripOff() throws {
        let original = ChatConfiguration.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.generativeGreetingsEnabled == original.generativeGreetingsEnabled)
        #expect(decoded.generativeGreetingsEnabled == false)
    }

    @Test("Codable round-trip preserves an explicit ON setting")
    func codableRoundTripOn() throws {
        var cfg = ChatConfiguration.default
        cfg.generativeGreetingsEnabled = true
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.generativeGreetingsEnabled == true)
    }

    @Test("legacy JSON missing the field decodes to OFF (migration safety net)")
    func legacyJSONMissingFieldDefaultsOff() throws {
        // Mimic a persisted config written by an older build that
        // never serialized `generativeGreetingsEnabled`. The new
        // decoder must treat the missing key as `false` so users who
        // upgrade aren't silently opted in to slow generations.
        let legacyJSON = """
            {
              "systemPrompt": "",
              "disableTools": false,
              "enableClipboardMonitoring": true,
              "greetingPersona": ""
            }
            """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(ChatConfiguration.self, from: data)
        #expect(decoded.generativeGreetingsEnabled == false)
    }
}

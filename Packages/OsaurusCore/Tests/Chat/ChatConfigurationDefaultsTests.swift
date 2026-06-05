//
//  ChatConfigurationDefaultsTests.swift
//  osaurusTests
//
//  Locks in the opt-in default for AI-generated greetings, which is now
//  a per-agent flag on `AgentSettings.generativeGreetingsEnabled` (the
//  global `ChatConfiguration` master switch was removed). Without these,
//  an accidental flip of the default back to `true`, or a regression in
//  the legacy tri-state migration, would re-introduce the multi-second
//  cold-start wait the opt-in design was built to avoid.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("AgentSettings generative greetings defaults")
struct ChatConfigurationDefaultsTests {

    @Test("default agent settings have AI greetings OFF")
    func defaultIsOff() {
        #expect(AgentSettings.defaultDisabled.generativeGreetingsEnabled == false)
    }

    @Test("Codable round-trip preserves an explicit ON setting")
    func codableRoundTripOn() throws {
        var settings = AgentSettings.defaultDisabled
        settings.generativeGreetingsEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(decoded.generativeGreetingsEnabled == true)
    }

    @Test("missing key decodes to OFF (migration safety net)")
    func missingFieldDefaultsOff() throws {
        let json = "{}"
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        #expect(decoded.generativeGreetingsEnabled == false)
    }

    @Test("explicit Bool key wins on decode")
    func explicitBoolDecodes() throws {
        let json = #"{"generativeGreetingsEnabled": true}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        #expect(decoded.generativeGreetingsEnabled == true)
    }

    @Test("legacy tri-state .enabled migrates to ON")
    func legacyEnabledMigrates() throws {
        let json = #"{"generativeGreetings": "enabled"}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        #expect(decoded.generativeGreetingsEnabled == true)
    }

    @Test("legacy tri-state .followGlobal and .disabled migrate to OFF")
    func legacyInheritAndDisabledMigrateOff() throws {
        for raw in ["followGlobal", "disabled"] {
            let json = #"{"generativeGreetings": "\#(raw)"}"#
            let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
            #expect(decoded.generativeGreetingsEnabled == false)
        }
    }
}

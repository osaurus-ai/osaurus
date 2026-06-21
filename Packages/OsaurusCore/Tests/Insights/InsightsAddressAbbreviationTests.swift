//
//  InsightsAddressAbbreviationTests.swift
//  osaurusTests
//
//  Guards the Insights detail header's address-shortening helpers
//  (`InsightsDetailPane.abbreviatedHost` / `.abbreviatedPath`). A
//  remote-agent run's relay host and request path both embed a 0x + 40-hex
//  crypto address; rendered verbatim they overflow the fixed-size pill row
//  and stretch the monospaced path across the whole header. Both helpers
//  collapse just the address to `0xABCD…F291` (matching
//  `RemoteAgent.shortAddress`) while leaving everything else intact.
//

import Testing

@testable import OsaurusCore

@MainActor
@Suite("Insights Address Abbreviation")
struct InsightsAddressAbbreviationTests {

    // MARK: Host pill

    @Test("Long agent host collapses its address label, keeps the domain")
    func abbreviatesAgentHost() {
        let host = "0x7F5b0b5177A0f45A9FE9C8b8F18e0E5b6d557C7a.agent.osaurus.ai"
        #expect(InsightsDetailPane.abbreviatedHost(host) == "0x7F5b…7C7a.agent.osaurus.ai")
    }

    @Test("Bare address host (no domain) still collapses")
    func abbreviatesBareAddressHost() {
        let host = "0x7F5b0b5177A0f45A9FE9C8b8F18e0E5b6d557C7a"
        #expect(InsightsDetailPane.abbreviatedHost(host) == "0x7F5b…7C7a")
    }

    @Test("Short hostnames pass through unchanged")
    func leavesOrdinaryHostsAlone() {
        #expect(InsightsDetailPane.abbreviatedHost("192.168.1.5") == "192.168.1.5")
        #expect(InsightsDetailPane.abbreviatedHost("Toms-MacBook.local") == "Toms-MacBook.local")
        #expect(InsightsDetailPane.abbreviatedHost("relay.example.com") == "relay.example.com")
        #expect(InsightsDetailPane.abbreviatedHost("localhost") == "localhost")
    }

    // MARK: Request path

    @Test("Agent-run path collapses the address segment, keeps the rest")
    func abbreviatesAgentRunPath() {
        let path = "/v1/agents/0x7F5b0b5177A0f45A9FE9C8b8F18e0E5b6d557C7a/run"
        #expect(InsightsDetailPane.abbreviatedPath(path) == "/v1/agents/0x7F5b…7C7a/run")
    }

    @Test("Ordinary paths are left untouched")
    func leavesOrdinaryPathsAlone() {
        #expect(InsightsDetailPane.abbreviatedPath("/v1/chat/completions") == "/v1/chat/completions")
        #expect(InsightsDetailPane.abbreviatedPath("/v1/models") == "/v1/models")
    }

    @Test("Short 0x segments are not collapsed")
    func leavesShortHexAlone() {
        #expect(InsightsDetailPane.abbreviatedPath("/x/0xABCD/y") == "/x/0xABCD/y")
    }
}

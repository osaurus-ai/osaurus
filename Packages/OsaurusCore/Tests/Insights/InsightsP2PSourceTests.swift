//
//  InsightsP2PSourceTests.swift
//  osaurusTests
//
//  Pins the host-side "p2p" visibility surface added for remote-agent calls:
//    1. `InsightsService.inboundSource` labels Secure-Channel peer traffic as
//       `.p2p`, in-app chat as `.chatUI`, and everything else as `.httpAPI`.
//    2. `RequestSource.p2p` exposes the new category's display/short labels and
//       is enumerable so the Insights filter pill can render it.
//    3. A `RequestLog` (the shape `/agents/{id}/run` now logs) retains the
//       enriched `responseBody` + `toolCalls` so the Insights detail pane can
//       show the full answer and every executed tool on the host.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Insights p2p source + agent-run enrichment")
struct InsightsP2PSourceTests {

    // MARK: - Source resolution (the single p2p chokepoint)

    @Test func inboundSource_chatMethodIsChatUI() {
        #expect(InsightsService.inboundSource(method: "CHAT", transport: nil) == .chatUI)
        // CHAT (in-app) always wins, even if a transport is attached.
        #expect(
            InsightsService.inboundSource(method: "CHAT", transport: .secureChannel) == .chatUI
        )
    }

    @Test func inboundSource_secureChannelIsP2P() {
        // Any inbound peer request over the Secure Channel — remote chat
        // completions AND remote agent runs — is categorized p2p.
        #expect(
            InsightsService.inboundSource(method: "POST", transport: .secureChannel) == .p2p
        )
    }

    @Test func inboundSource_directLocalAndNilStayHTTP() {
        #expect(InsightsService.inboundSource(method: "POST", transport: .direct) == .httpAPI)
        #expect(InsightsService.inboundSource(method: "POST", transport: .local) == .httpAPI)
        #expect(InsightsService.inboundSource(method: "POST", transport: nil) == .httpAPI)
        #expect(InsightsService.inboundSource(method: "GET", transport: nil) == .httpAPI)
    }

    // MARK: - RequestSource category labels

    @Test func p2pSource_labels() {
        #expect(RequestSource.p2p.rawValue == "P2P")
        #expect(RequestSource.p2p.shortName == "P2P")
        // Acronym: stays "P2P" whether localized or falling back to the key.
        #expect(RequestSource.p2p.displayName == "P2P")
        // Enumerable so `FilterPills` (driven by CaseIterable) renders the pill.
        #expect(RequestSource.allCases.contains(.p2p))
    }

    @Test func sourceFilter_includesP2P() {
        #expect(SourceFilter.allCases.contains(.p2p))
        #expect(SourceFilter.p2p.rawValue == "P2P")
    }

    // MARK: - Agent-run enrichment shape

    @Test func requestLog_retainsResponseBodyAndToolCalls() {
        let toolCalls = [
            ToolCallLog(
                name: "read_file",
                arguments: #"{"path":"notes.md"}"#,
                result: "ok: 3 lines",
                isError: false
            ),
            ToolCallLog(
                name: "write_file",
                arguments: #"{"path":"out.md","contents":"hi"}"#,
                result: "wrote 2 bytes",
                isError: false
            ),
        ]
        let log = RequestLog(
            source: .p2p,
            method: "POST",
            path: "/agents/0xabc/run",
            statusCode: 200,
            durationMs: 1234,
            responseBody: "Here is the summary you asked for.",
            model: "peer/model",
            toolCalls: toolCalls,
            connection: RequestConnectionInfo(transport: .secureChannel, mode: .remoteAgentRun)
        )

        #expect(log.source == .p2p)
        #expect(log.responseBody == "Here is the summary you asked for.")
        #expect(log.toolCalls?.count == 2)
        #expect(log.toolCalls?.first?.name == "read_file")
        #expect(log.toolCalls?.first?.arguments == #"{"path":"notes.md"}"#)
        #expect(log.toolCalls?.first?.result == "ok: 3 lines")
        #expect(log.toolCalls?.last?.name == "write_file")
        #expect(log.connection?.transport == .secureChannel)
    }
}

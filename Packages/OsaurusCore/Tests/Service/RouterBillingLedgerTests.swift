//
//  RouterBillingLedgerTests.swift
//  osaurusTests
//
//  Facade-level coverage for the router billing ledger: record -> read,
//  outcome finalization, and the metadata-only diagnostics export. Uses an
//  injected in-memory database so it never touches the Keychain or disk.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct RouterBillingLedgerTests {

    /// Metadata-only by construction. If a future change tries to persist
    /// prompt/response text, the export-shape assertion below must fail.
    private static let forbiddenContentKeys = [
        "prompt", "response", "content", "messages", "text", "message",
    ]

    private func makeLedger() throws -> (RouterBillingLedger, RouterBillingDatabase) {
        let db = RouterBillingDatabase()
        try db.openInMemory()
        return (RouterBillingLedger(database: db), db)
    }

    private func summary(cost: String = "1234", outputTokens: Int = 3) -> RouterBillingSummary {
        RouterBillingSummary(
            costMicro: cost,
            status: "completed",
            tokenSource: "provider",
            inputTokens: 11,
            outputTokens: outputTokens
        )
    }

    @Test func record_thenRecent_returnsTheRow() throws {
        let (ledger, _) = try makeLedger()
        let turnId = UUID()
        let sessionId = UUID()

        let entryId = try #require(
            ledger.record(
                summary: summary(),
                sessionId: sessionId,
                turnId: turnId,
                model: "venice/minimax-m3",
                outcome: .pending
            )
        )

        let rows = ledger.recent()
        let row = try #require(rows.first { $0.id == entryId })
        #expect(row.turnId == turnId.uuidString)
        #expect(row.sessionId == sessionId.uuidString)
        #expect(row.model == "venice/minimax-m3")
        #expect(row.costMicro == "1234")
        #expect(row.outcome == .pending)
    }

    @Test func finalizeOutcome_backfillsRenderedResult() throws {
        let (ledger, _) = try makeLedger()
        let entryId = try #require(
            ledger.record(
                summary: summary(),
                sessionId: nil,
                turnId: UUID(),
                model: "venice/minimax-m3",
                outcome: .pending
            )
        )

        ledger.finalizeOutcome(entryId: entryId, outcome: .empty)

        let row = try #require(ledger.recent().first { $0.id == entryId })
        #expect(row.outcome == .empty)
    }

    @Test func buildDiagnostics_carriesWalletAndRows_withNoContentFields() throws {
        let (ledger, _) = try makeLedger()
        _ = ledger.record(
            summary: summary(),
            sessionId: UUID(),
            turnId: UUID(),
            model: "venice/minimax-m3",
            outcome: .empty
        )

        let diagnostics = ledger.buildDiagnostics(walletAddress: "0xABCDEF")
        #expect(diagnostics.walletAddress == "0xABCDEF")
        #expect(diagnostics.schemaVersion == RouterBillingLedger.diagnosticsSchemaVersion)
        #expect(diagnostics.entries.count == 1)

        // Encode and assert the on-disk shape carries ONLY metadata.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(diagnostics)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(json["entries"] as? [[String: Any]])
        let entry = try #require(entries.first)

        for key in entry.keys {
            #expect(
                !Self.forbiddenContentKeys.contains(key.lowercased()),
                "billing export leaked a content field: \(key)"
            )
        }
        // And a coarse full-payload guard against accidental text leakage.
        let raw = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in Self.forbiddenContentKeys {
            #expect(!raw.contains("\"\(forbidden)\""), "export payload contains forbidden key \(forbidden)")
        }
    }
}

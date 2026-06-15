import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct CreditsActivityProjectorTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let usageTimestamp = ISO8601DateFormatter().string(from: baseDate)

    private func usage(
        id: String = "usage-1",
        requestId: String? = "run-abc:1",
        model: String = "venice/minimax-m3",
        inputTokens: Int = 11,
        outputTokens: Int = 3,
        cost: String = "1234",
        status: String = "completed",
        tokenSource: String = "provider",
        createdAt: String = CreditsActivityProjectorTests.usageTimestamp
    ) -> OsaurusRouterUsageItem {
        OsaurusRouterUsageItem(
            id: id,
            requestId: requestId,
            model: model,
            provider: "router",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costMicro: cost,
            status: status,
            tokenSource: tokenSource,
            createdAt: createdAt
        )
    }

    private func ledger(
        id: String = UUID().uuidString,
        requestId: String? = "run-abc:1",
        createdAt: Date = CreditsActivityProjectorTests.baseDate,
        sessionId: UUID? = UUID(),
        turnId: UUID? = UUID(),
        model: String? = "venice/minimax-m3",
        inputTokens: Int = 11,
        outputTokens: Int = 3,
        cost: String = "1234",
        status: String = "completed",
        outcome: RouterBillingOutcome = .rendered
    ) -> RouterBillingEntry {
        RouterBillingEntry(
            id: id,
            requestId: requestId,
            createdAt: createdAt,
            sessionId: sessionId?.uuidString,
            turnId: turnId?.uuidString,
            model: model,
            tokenSource: "provider",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costMicro: cost,
            status: status,
            outcome: outcome,
            appVersion: "1.2.3"
        )
    }

    @Test func exactRequestIdMatchAttachesReferencesAndInsights() throws {
        let turnId = UUID()
        let row = try #require(
            CreditsActivityProjector(
                hasInsightsLogForRequestId: { $0 == "run-abc:1" },
                hasInsightsLogForTurnId: { _ in false }
            )
            .rows(
                usageItems: [usage()],
                ledgerEntries: [ledger(turnId: turnId)]
            )
            .first
        )

        #expect(row.matchQuality == .exactRequestId)
        #expect(row.stateLabel == "Completed")
        #expect(row.stateDetail == nil)
        #expect(row.localReference?.turnUUID == turnId)
        #expect(row.insightsReference?.requestId == "run-abc:1")
    }

    @Test func toolOnlyOutcomeKeepsCompletedLabelWithSecondaryDetail() throws {
        let row = try #require(
            CreditsActivityProjector()
                .rows(usageItems: [usage()], ledgerEntries: [ledger(outcome: .toolOnly)])
                .first
        )

        #expect(row.stateLabel == "Completed")
        #expect(row.stateDetail == "Tools only")
    }

    @Test func serverOnlyRowUsesUnifiedVocabularyWithoutDetail() throws {
        let row = try #require(
            CreditsActivityProjector()
                .rows(
                    usageItems: [usage(requestId: nil, status: "aborted")],
                    ledgerEntries: []
                )
                .first
        )

        #expect(row.matchQuality == .none)
        #expect(row.stateLabel == "Stopped")
        #expect(row.stateDetail == nil)
    }

    @Test func missingInsightsLogHidesInsightsReferenceOnly() throws {
        let row = try #require(
            CreditsActivityProjector()
                .rows(usageItems: [usage()], ledgerEntries: [ledger()])
                .first
        )

        #expect(row.matchQuality == .exactRequestId)
        #expect(row.localReference != nil)
        #expect(row.insightsReference == nil)
    }

    @Test func usageRequestIdCanAttachInsightsBeforeLedgerReloads() throws {
        let row = try #require(
            CreditsActivityProjector(
                hasInsightsLogForRequestId: { $0 == "run-live:1" },
                hasInsightsLogForTurnId: { _ in false }
            )
            .rows(
                usageItems: [usage(id: "usage-live", requestId: "run-live:1")],
                ledgerEntries: []
            )
            .first
        )

        #expect(row.matchQuality == .none)
        #expect(row.localReference == nil)
        #expect(row.insightsReference?.requestId == "run-live:1")
    }

    @Test func legacyFuzzyMatchOnlyUsesRowsWithoutRequestId() throws {
        let legacy = ledger(requestId: nil)
        let mismatchedModern = ledger(requestId: "other-request")

        let row = try #require(
            CreditsActivityProjector()
                .rows(usageItems: [usage(requestId: nil)], ledgerEntries: [mismatchedModern, legacy])
                .first
        )

        #expect(row.matchQuality == .legacyFuzzy)
        #expect(row.localReference?.turnId == legacy.turnId)
    }

    @Test func exactRequestIdMatchWorksForOldLedgerRows() throws {
        let oldLocalRow = ledger(
            requestId: "run-abc:old",
            createdAt: CreditsActivityProjectorTests.baseDate.addingTimeInterval(-90 * 86_400)
        )
        let row = try #require(
            CreditsActivityProjector()
                .rows(
                    usageItems: [usage(id: "usage-old", requestId: "run-abc:old")],
                    ledgerEntries: [oldLocalRow]
                )
                .first
        )

        #expect(row.matchQuality == .exactRequestId)
        #expect(row.localReference?.requestId == "run-abc:old")
    }
}

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct WalletActivityProjectorTests {
    private static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static func timestamp(offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: baseDate.addingTimeInterval(offset))
    }

    private func usage(
        id: String = "u1",
        model: String = "venice/minimax-m3",
        provider: String = "router",
        cost: String = "1234",
        status: String = "completed",
        createdAt: String = WalletActivityProjectorTests.timestamp(offset: 0)
    ) -> OsaurusRouterUsageItem {
        OsaurusRouterUsageItem(
            id: id,
            requestId: nil,
            model: model,
            provider: provider,
            inputTokens: 11,
            outputTokens: 3,
            costMicro: cost,
            status: status,
            tokenSource: "provider",
            createdAt: createdAt
        )
    }

    private func transaction(
        id: String = "t1",
        amount: String = "5000000",
        entryType: String = "topup",
        createdAt: String = WalletActivityProjectorTests.timestamp(offset: 0)
    ) -> OsaurusRouterTransactionItem {
        OsaurusRouterTransactionItem(
            id: id,
            amountMicro: amount,
            entryType: entryType,
            refType: nil,
            refId: nil,
            createdAt: createdAt
        )
    }

    @Test func mergesUsageAndTransactionsNewestFirst() {
        let rows = WalletActivityProjector().rows(
            usageItems: [
                usage(id: "u-old", createdAt: Self.timestamp(offset: -300)),
                usage(id: "u-new", createdAt: Self.timestamp(offset: 100)),
            ],
            transactions: [
                transaction(id: "t-mid", createdAt: Self.timestamp(offset: -100))
            ]
        )

        #expect(rows.map(\.id) == ["usage-u-new", "txn-t-mid", "usage-u-old"])
        #expect(rows.map(\.kind) == [.usage, .transaction, .usage])
    }

    @Test func capsRowCountAtLimit() {
        let items = (0..<10).map { i in
            usage(id: "u\(i)", createdAt: Self.timestamp(offset: TimeInterval(i)))
        }
        let rows = WalletActivityProjector().rows(usageItems: items, transactions: [], limit: 4)
        #expect(rows.count == 4)
        #expect(rows.first?.id == "usage-u9")
    }

    @Test func usageRowShowsSpendAsNegativeAmount() {
        let row = WalletActivityProjector().rows(
            usageItems: [usage(cost: "1234500")],
            transactions: []
        )[0]

        #expect(row.title == "venice/minimax-m3")
        #expect(row.amountLabel == "-$1.23")
        #expect(row.isCredit == false)
        #expect(row.stateKind == .success)
    }

    @Test func usageRowFallsBackToProviderThenPlaceholderTitle() {
        let providerRow = WalletActivityProjector().rows(
            usageItems: [usage(model: "")],
            transactions: []
        )[0]
        #expect(providerRow.title == "router")

        let placeholderRow = WalletActivityProjector().rows(
            usageItems: [usage(model: "", provider: "")],
            transactions: []
        )[0]
        #expect(placeholderRow.title == "Model request")
    }

    @Test func usageRowMapsServerStatusToStateKind() {
        let rows = WalletActivityProjector().rows(
            usageItems: [
                usage(id: "ok", status: "completed", createdAt: Self.timestamp(offset: 3)),
                usage(id: "stop", status: "aborted", createdAt: Self.timestamp(offset: 2)),
                usage(id: "bad", status: "mystery", createdAt: Self.timestamp(offset: 1)),
            ],
            transactions: []
        )
        #expect(rows.map(\.stateKind) == [.success, .warning, .error])
    }

    @Test func topUpTransactionRendersAsCredit() {
        let row = WalletActivityProjector().rows(
            usageItems: [],
            transactions: [transaction(amount: "5000000", entryType: "topup")]
        )[0]

        #expect(row.title == "Credits added")
        #expect(row.amountLabel == "+$5.00")
        #expect(row.isCredit)
        #expect(row.stateKind == .success)
    }

    @Test func unknownCreditEntryTypesFallBackToCreditsAdded() {
        let rows = WalletActivityProjector().rows(
            usageItems: [],
            transactions: [
                transaction(
                    id: "agent",
                    amount: "2000000",
                    entryType: "agent_purchase",
                    createdAt: Self.timestamp(offset: 2)
                )
            ]
        )

        #expect(rows.count == 1)
        #expect(rows[0].title == "Credits added")
        #expect(rows[0].amountLabel == "+$2.00")
        #expect(rows[0].isCredit)
    }

    @Test func unknownDebitEntryTypesAreHiddenAsUsageMirrors() {
        let rows = WalletActivityProjector().rows(
            usageItems: [usage(id: "u1", createdAt: Self.timestamp(offset: 2))],
            transactions: [
                // The ledger's per-request debit mirror of the usage row above;
                // listing both would double-count the spend.
                transaction(
                    id: "mirror",
                    amount: "-1234",
                    entryType: "usage",
                    createdAt: Self.timestamp(offset: 2)
                ),
                transaction(
                    id: "fee",
                    amount: "-500000",
                    entryType: "mystery_fee",
                    createdAt: Self.timestamp(offset: 1)
                ),
            ]
        )

        #expect(rows.map(\.id) == ["usage-u1"])
    }

    @Test func recognizedDebitEntryTypesStayVisible() {
        let rows = WalletActivityProjector().rows(
            usageItems: [],
            transactions: [
                transaction(
                    id: "adj",
                    amount: "-250000",
                    entryType: "adjustment",
                    createdAt: Self.timestamp(offset: 2)
                ),
                transaction(
                    id: "ref",
                    amount: "750000",
                    entryType: "refund",
                    createdAt: Self.timestamp(offset: 1)
                ),
            ]
        )

        #expect(rows.map(\.title) == ["Adjustment", "Refund"])
        #expect(rows[0].amountLabel == "-$0.25")
        #expect(rows[0].isCredit == false)
        #expect(rows[1].amountLabel == "+$0.75")
        #expect(rows[1].isCredit)
    }

    @Test func unparseableTimestampsSortLast() {
        let rows = WalletActivityProjector().rows(
            usageItems: [usage(id: "dated", createdAt: Self.timestamp(offset: -3600))],
            transactions: [transaction(id: "undated", createdAt: "not-a-date")]
        )
        #expect(rows.map(\.id) == ["usage-dated", "txn-undated"])
        #expect(rows[1].date == nil)
    }
}

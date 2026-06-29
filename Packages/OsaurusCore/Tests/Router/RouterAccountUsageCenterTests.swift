import Foundation
import Testing

@testable import OsaurusCore

@Suite("Router account usage center")
struct RouterAccountUsageCenterTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let timestamp = ISO8601DateFormatter().string(from: now)

    @Test func snapshot_summarizesAccountUsageTransactionsAndLedger() throws {
        let usageItems = [
            usage(id: "u1", model: "venice/minimax-m3", provider: "venice", cost: "1250"),
            usage(id: "u2", model: "openai/gpt-4.1", provider: "openai", cost: "2000", status: "error"),
        ]
        let transactions = [
            transaction(id: "tx-topup", amount: "5000000", entryType: "topup"),
            transaction(id: "tx-charge", amount: "-3250", entryType: "usage_charge"),
        ]
        let ledgerEntries = [
            ledger(id: "l1", cost: "1250", outcome: .rendered),
            ledger(id: "l2", cost: "2000", outcome: .empty),
            ledger(id: "l3", cost: "0", outcome: .pending),
        ]

        let snapshot = RouterAccountUsageCenter.snapshot(
            routerEnabled: true,
            identityAvailable: true,
            balance: OsaurusRouterBalanceResponse(balanceMicro: "7000000", frozen: false),
            lastError: nil,
            usageItems: usageItems,
            transactions: transactions,
            ledgerEntries: ledgerEntries,
            generatedAt: Self.now
        )

        #expect(snapshot.accountStatus.state == .active)
        #expect(snapshot.accountStatus.formattedBalance == "$7.00")
        #expect(snapshot.credits.requestCount == 2)
        #expect(snapshot.credits.costMicro == "3250")
        #expect(snapshot.credits.inputTokens == 22)
        #expect(snapshot.transactions.creditMicro == "5000000")
        #expect(snapshot.transactions.debitMicro == "3250")
        #expect(snapshot.transactions.netMicro == "4996750")
        #expect(snapshot.ledger.entryCount == 3)
        #expect(snapshot.ledger.costMicro == "3250")
        #expect(snapshot.ledger.pendingCount == 1)
        #expect(snapshot.ledger.issueCount == 1)
        #expect(snapshot.ledger.outcomeBreakdown.map(\.outcome).contains(.empty))
    }

    @Test func accountStatus_distinguishesDisabledMissingIdentityAndFrozen() {
        let disabled = RouterAccountUsageCenter.snapshot(
            routerEnabled: false,
            identityAvailable: true,
            balance: OsaurusRouterBalanceResponse(balanceMicro: "1", frozen: false),
            lastError: nil,
            usageItems: [],
            transactions: [],
            ledgerEntries: []
        )
        #expect(disabled.accountStatus.state == .disabled)

        let missingIdentity = RouterAccountUsageCenter.snapshot(
            routerEnabled: true,
            identityAvailable: false,
            balance: nil,
            lastError: nil,
            usageItems: [],
            transactions: [],
            ledgerEntries: []
        )
        #expect(missingIdentity.accountStatus.state == .missingIdentity)

        let frozen = RouterAccountUsageCenter.snapshot(
            routerEnabled: true,
            identityAvailable: true,
            balance: OsaurusRouterBalanceResponse(balanceMicro: "1", frozen: true),
            lastError: nil,
            usageItems: [],
            transactions: [],
            ledgerEntries: []
        )
        #expect(frozen.accountStatus.state == .frozen)
    }

    @Test func signedRequestDiagnostic_redactsSensitiveHeadersAndFingerprintsSignature() throws {
        let url = try #require(URL(string: "https://router.osaurus.ai/credits/balance"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("0xABCDEF", forHTTPHeaderField: "x-wallet-address")
        request.setValue("1717171717", forHTTPHeaderField: "x-wallet-timestamp")
        request.setValue("0x" + String(repeating: "a", count: 130), forHTTPHeaderField: "x-wallet-signature")
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let diagnostic = RouterSignedRequestDiagnostic(request: request, body: Data())

        #expect(diagnostic.walletAddress == "0xabcdef")
        #expect(diagnostic.signatureFingerprint?.hasPrefix("sha256:") == true)
        #expect(diagnostic.signatureFingerprint != "0x" + String(repeating: "a", count: 130))
        #expect(diagnostic.redactedHeaders["x-wallet-signature"] == RouterAccountUsageCenter.redactedValue)
        #expect(diagnostic.redactedHeaders["authorization"] == RouterAccountUsageCenter.redactedValue)
        #expect(diagnostic.redactedHeaders["accept"] == "application/json")
        #expect(diagnostic.warnings.isEmpty)
    }

    @Test func supportExport_isMetadataOnlyAndDoesNotLeakSecrets() throws {
        let secretSignature = "0x" + String(repeating: "b", count: 130)
        let bearer = "Bearer live-secret-token"
        let url = try #require(URL(string: "https://router.osaurus.ai/credits/estimate"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"prompt":"do not export"}"#.utf8)
        request.setValue("0xABCDEF", forHTTPHeaderField: "x-wallet-address")
        request.setValue("1717171717", forHTTPHeaderField: "x-wallet-timestamp")
        request.setValue(secretSignature, forHTTPHeaderField: "x-wallet-signature")
        request.setValue(bearer, forHTTPHeaderField: "Authorization")
        let diagnostic = RouterSignedRequestDiagnostic(request: request, body: request.httpBody)
        let snapshot = RouterAccountUsageCenter.snapshot(
            routerEnabled: true,
            identityAvailable: true,
            balance: OsaurusRouterBalanceResponse(balanceMicro: "7000000", frozen: false),
            lastError: nil,
            usageItems: [usage()],
            transactions: [transaction()],
            ledgerEntries: [ledger()]
        )

        let export = RouterAccountUsageCenter.supportExport(
            walletAddress: "0xABCDEF",
            snapshot: snapshot,
            signedDiagnostics: [diagnostic],
            usageItems: [usage()],
            transactions: [transaction()],
            ledgerEntries: [ledger()]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = String(decoding: try encoder.encode(export), as: UTF8.self)

        #expect(!payload.contains(secretSignature))
        #expect(!payload.contains(bearer))
        #expect(!payload.contains("live-secret-token"))
        #expect(!payload.contains("do not export"))
        #expect(!payload.contains(#""prompt""#))
        #expect(payload.contains(RouterAccountUsageCenter.redactedValue))
        #expect(export.walletAddress == "0xabcdef")
        #expect(export.walletAddressStatus == .available)
        #expect(export.usage.count == 1)
        #expect(export.ledgerEntries.count == 1)
    }

    @Test func supportExport_usesSignedDiagnosticWalletAddressWithoutPrompting() throws {
        let url = try #require(URL(string: "https://router.osaurus.ai/credits/balance"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(" 0xABCDEF ", forHTTPHeaderField: "x-wallet-address")
        request.setValue("1717171717", forHTTPHeaderField: "x-wallet-timestamp")
        request.setValue("0x" + String(repeating: "c", count: 130), forHTTPHeaderField: "x-wallet-signature")
        let diagnostic = RouterSignedRequestDiagnostic(request: request, body: Data())
        let snapshot = RouterAccountUsageCenter.snapshot(
            routerEnabled: true,
            identityAvailable: true,
            balance: OsaurusRouterBalanceResponse(balanceMicro: "7000000", frozen: false),
            lastError: nil,
            usageItems: [],
            transactions: [],
            ledgerEntries: []
        )

        let export = RouterAccountUsageCenter.supportExport(
            walletAddress: nil,
            snapshot: snapshot,
            signedDiagnostics: [diagnostic],
            usageItems: [],
            transactions: [],
            ledgerEntries: []
        )

        #expect(export.walletAddress == "0xabcdef")
        #expect(export.walletAddressStatus == .available)
    }

    @Test func supportExport_recordsWalletAddressStatusWhenAddressUnavailableWithoutPrompt() throws {
        let snapshot = RouterAccountUsageCenter.snapshot(
            routerEnabled: true,
            identityAvailable: true,
            balance: OsaurusRouterBalanceResponse(balanceMicro: "7000000", frozen: false),
            lastError: nil,
            usageItems: [],
            transactions: [],
            ledgerEntries: []
        )

        let export = RouterAccountUsageCenter.supportExport(
            walletAddress: nil,
            snapshot: snapshot,
            signedDiagnostics: [],
            usageItems: [],
            transactions: [],
            ledgerEntries: []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let payload = String(decoding: try encoder.encode(export), as: UTF8.self)

        #expect(export.walletAddress == nil)
        #expect(export.walletAddressStatus == .unavailableWithoutPrompt)
        #expect(payload.contains(#""walletAddressStatus":"unavailable_without_prompt""#))
        #expect(export.redaction.contains { $0.contains("does not prompt for biometric authentication") })
    }

    private func usage(
        id: String = "usage-1",
        requestId: String? = "run-1",
        model: String = "venice/minimax-m3",
        provider: String = "venice",
        inputTokens: Int = 11,
        outputTokens: Int = 7,
        cost: String = "1250",
        status: String = "completed",
        tokenSource: String = "provider",
        createdAt: String = RouterAccountUsageCenterTests.timestamp
    ) -> OsaurusRouterUsageItem {
        OsaurusRouterUsageItem(
            id: id,
            requestId: requestId,
            model: model,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costMicro: cost,
            status: status,
            tokenSource: tokenSource,
            createdAt: createdAt
        )
    }

    private func transaction(
        id: String = "tx-1",
        amount: String = "5000000",
        entryType: String = "topup",
        refType: String? = "stripe_checkout",
        refId: String? = "cs_test",
        createdAt: String = RouterAccountUsageCenterTests.timestamp
    ) -> OsaurusRouterTransactionItem {
        OsaurusRouterTransactionItem(
            id: id,
            amountMicro: amount,
            entryType: entryType,
            refType: refType,
            refId: refId,
            createdAt: createdAt
        )
    }

    private func ledger(
        id: String = "ledger-1",
        requestId: String? = "run-1",
        createdAt: Date = RouterAccountUsageCenterTests.now,
        cost: String = "1250",
        outcome: RouterBillingOutcome = .rendered
    ) -> RouterBillingEntry {
        RouterBillingEntry(
            id: id,
            requestId: requestId,
            createdAt: createdAt,
            sessionId: UUID().uuidString,
            turnId: UUID().uuidString,
            model: "venice/minimax-m3",
            tokenSource: "provider",
            inputTokens: 11,
            outputTokens: 7,
            costMicro: cost,
            status: "completed",
            outcome: outcome,
            appVersion: "1.2.3"
        )
    }
}

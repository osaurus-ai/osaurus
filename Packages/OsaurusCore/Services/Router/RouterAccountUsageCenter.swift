import Foundation

struct RouterAccountStatusSnapshot: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case active
        case disabled
        case missingIdentity
        case frozen
        case unavailable
    }

    let routerEnabled: Bool
    let identityAvailable: Bool
    let balanceMicro: String?
    let formattedBalance: String
    let frozen: Bool
    let lastError: String?
    let state: State
    let generatedAt: Date

    init(
        routerEnabled: Bool,
        identityAvailable: Bool,
        balance: OsaurusRouterBalanceResponse?,
        lastError: String?,
        generatedAt: Date = Date()
    ) {
        self.routerEnabled = routerEnabled
        self.identityAvailable = identityAvailable
        self.balanceMicro = balance?.balanceMicro
        self.formattedBalance = OsaurusRouter.formatMicroUSD(balance?.balanceMicro ?? "0")
        self.frozen = balance?.frozen == true
        self.lastError = lastError?.isEmpty == false ? lastError : nil
        self.generatedAt = generatedAt

        if !routerEnabled {
            self.state = .disabled
        } else if !identityAvailable {
            self.state = .missingIdentity
        } else if balance?.frozen == true {
            self.state = .frozen
        } else if balance != nil {
            self.state = .active
        } else {
            self.state = .unavailable
        }
    }
}

struct RouterUsageBreakdown: Codable, Equatable, Sendable, Identifiable {
    let name: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let costMicro: String

    var id: String { name }
}

struct RouterCreditsSummary: Codable, Equatable, Sendable {
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let costMicro: String
    let latestUsageAt: Date?
    let providerBreakdown: [RouterUsageBreakdown]
    let statusBreakdown: [RouterUsageBreakdown]
    let modelBreakdown: [RouterUsageBreakdown]
}

struct RouterLedgerOutcomeBreakdown: Codable, Equatable, Sendable, Identifiable {
    let outcome: RouterBillingOutcome
    let entryCount: Int
    let costMicro: String

    var id: String { outcome.rawValue }
}

struct RouterLedgerSummary: Codable, Equatable, Sendable {
    let entryCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let costMicro: String
    let latestEntryAt: Date?
    let pendingCount: Int
    let issueCount: Int
    let outcomeBreakdown: [RouterLedgerOutcomeBreakdown]
    let modelBreakdown: [RouterUsageBreakdown]
}

struct RouterTransactionBreakdown: Codable, Equatable, Sendable, Identifiable {
    let entryType: String
    let transactionCount: Int
    let netAmountMicro: String

    var id: String { entryType }
}

struct RouterTransactionSummary: Codable, Equatable, Sendable {
    let transactionCount: Int
    let creditMicro: String
    let debitMicro: String
    let netMicro: String
    let latestTransactionAt: Date?
    let entryTypeBreakdown: [RouterTransactionBreakdown]
}

struct RouterAccountUsageSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let accountStatus: RouterAccountStatusSnapshot
    let credits: RouterCreditsSummary
    let transactions: RouterTransactionSummary
    let ledger: RouterLedgerSummary
}

struct RouterSignedRequestDiagnostic: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let generatedAt: Date
    let method: String
    let pathAndQuery: String
    let bodySHA256: String
    let bodyBytes: Int
    let walletAddress: String?
    let walletTimestamp: String?
    let walletNonce: String?
    let signatureFingerprint: String?
    let signedHeaderNames: [String]
    let redactedHeaders: [String: String]
    let warnings: [String]

    init(
        request: URLRequest,
        body: Data? = nil,
        generatedAt: Date = Date()
    ) {
        let bodyData = body ?? request.httpBody ?? Data()
        let headers = request.allHTTPHeaderFields ?? [:]
        let method = (request.httpMethod ?? "GET").uppercased()
        let pathAndQuery = request.url.map(OsaurusRouterAuthSigner.pathAndQuery(for:)) ?? ""
        let address = Self.headerValue(headers, named: "x-wallet-address")?.lowercased()
        let timestamp = Self.headerValue(headers, named: "x-wallet-timestamp")
        let nonce = Self.headerValue(headers, named: "x-wallet-nonce")
        let signature = Self.headerValue(headers, named: "x-wallet-signature")

        self.id = "\(method):\(pathAndQuery):\(timestamp ?? "missing"):\(generatedAt.timeIntervalSince1970)"
        self.generatedAt = generatedAt
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.bodySHA256 = OsaurusRouterAuthSigner.sha256Hex(bodyData)
        self.bodyBytes = bodyData.count
        self.walletAddress = address
        self.walletTimestamp = timestamp
        self.walletNonce = nonce?.isEmpty == false ? nonce : nil
        self.signatureFingerprint = signature.map(Self.fingerprint)
        self.signedHeaderNames = headers.keys.map { $0.lowercased() }.sorted()
        self.redactedHeaders = Dictionary(
            uniqueKeysWithValues: headers.map {
                ($0.key.lowercased(), RouterAccountUsageCenter.redactedHeaderValue(headerName: $0.key, value: $0.value))
            }
        )

        var warnings: [String] = []
        if request.url == nil {
            warnings.append("Missing URL")
        }
        for name in ["x-wallet-address", "x-wallet-timestamp", "x-wallet-signature"] {
            if Self.headerValue(headers, named: name)?.isEmpty != false {
                warnings.append("Missing \(name)")
            }
        }
        self.warnings = warnings
    }

    private static func headerValue(_ headers: [String: String], named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func fingerprint(_ value: String) -> String {
        let digest = OsaurusRouterAuthSigner.sha256Hex(Data(value.utf8))
        return "sha256:\(String(digest.prefix(16)))"
    }
}

struct RouterSupportUsageItem: Codable, Equatable, Sendable {
    let id: String
    let requestId: String?
    let model: String
    let provider: String
    let inputTokens: Int
    let outputTokens: Int
    let costMicro: String
    let status: String
    let tokenSource: String
    let createdAt: String

    init(_ item: OsaurusRouterUsageItem) {
        self.id = item.id
        self.requestId = item.requestId
        self.model = item.model
        self.provider = item.provider
        self.inputTokens = item.inputTokens
        self.outputTokens = item.outputTokens
        self.costMicro = item.costMicro
        self.status = item.status
        self.tokenSource = item.tokenSource
        self.createdAt = item.createdAt
    }
}

struct RouterSupportTransactionItem: Codable, Equatable, Sendable {
    let id: String
    let amountMicro: String
    let entryType: String
    let refType: String?
    let refId: String?
    let createdAt: String

    init(_ item: OsaurusRouterTransactionItem) {
        self.id = item.id
        self.amountMicro = item.amountMicro
        self.entryType = item.entryType
        self.refType = item.refType
        self.refId = item.refId
        self.createdAt = item.createdAt
    }
}

struct RouterSupportLedgerEntry: Codable, Equatable, Sendable {
    let id: String
    let requestId: String?
    let createdAt: Date
    let sessionId: String?
    let turnId: String?
    let model: String?
    let tokenSource: String
    let inputTokens: Int
    let outputTokens: Int
    let costMicro: String
    let status: String
    let outcome: RouterBillingOutcome
    let appVersion: String?

    init(_ entry: RouterBillingEntry) {
        self.id = entry.id
        self.requestId = entry.requestId
        self.createdAt = entry.createdAt
        self.sessionId = entry.sessionId
        self.turnId = entry.turnId
        self.model = entry.model
        self.tokenSource = entry.tokenSource
        self.inputTokens = entry.inputTokens
        self.outputTokens = entry.outputTokens
        self.costMicro = entry.costMicro
        self.status = entry.status
        self.outcome = entry.outcome
        self.appVersion = entry.appVersion
    }
}

public enum RouterSupportWalletAddressStatus: String, Codable, Equatable, Sendable {
    case available
    case identityMissing = "identity_missing"
    case unavailableWithoutPrompt = "unavailable_without_prompt"
}

struct RouterSupportExport: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let generatedAt: Date
    let walletAddress: String?
    let walletAddressStatus: RouterSupportWalletAddressStatus
    let account: RouterAccountUsageSnapshot
    let signedRequestDiagnostics: [RouterSignedRequestDiagnostic]
    let usage: [RouterSupportUsageItem]
    let transactions: [RouterSupportTransactionItem]
    let ledgerEntries: [RouterSupportLedgerEntry]
    let redaction: [String]
}

enum RouterAccountUsageCenter {
    static let redactedValue = "<redacted>"

    static func snapshot(
        routerEnabled: Bool,
        identityAvailable: Bool,
        balance: OsaurusRouterBalanceResponse?,
        lastError: String?,
        usageItems: [OsaurusRouterUsageItem],
        transactions: [OsaurusRouterTransactionItem],
        ledgerEntries: [RouterBillingEntry],
        generatedAt: Date = Date()
    ) -> RouterAccountUsageSnapshot {
        RouterAccountUsageSnapshot(
            generatedAt: generatedAt,
            accountStatus: RouterAccountStatusSnapshot(
                routerEnabled: routerEnabled,
                identityAvailable: identityAvailable,
                balance: balance,
                lastError: lastError,
                generatedAt: generatedAt
            ),
            credits: creditsSummary(usageItems),
            transactions: transactionSummary(transactions),
            ledger: ledgerSummary(ledgerEntries)
        )
    }

    static func creditsSummary(_ usageItems: [OsaurusRouterUsageItem]) -> RouterCreditsSummary {
        RouterCreditsSummary(
            requestCount: usageItems.count,
            inputTokens: usageItems.reduce(0) { $0 + $1.inputTokens },
            outputTokens: usageItems.reduce(0) { $0 + $1.outputTokens },
            costMicro: String(sumMicro(usageItems.map(\.costMicro))),
            latestUsageAt: usageItems.compactMap { CreditsActivityProjector.date(fromRouterTimestamp: $0.createdAt) }
                .max(),
            providerBreakdown: usageBreakdown(usageItems, key: \.provider),
            statusBreakdown: usageBreakdown(usageItems, key: \.status),
            modelBreakdown: usageBreakdown(usageItems, key: \.model)
        )
    }

    static func ledgerSummary(_ entries: [RouterBillingEntry]) -> RouterLedgerSummary {
        let outcomeBreakdown = Dictionary(grouping: entries, by: \.outcome)
            .map { outcome, rows in
                RouterLedgerOutcomeBreakdown(
                    outcome: outcome,
                    entryCount: rows.count,
                    costMicro: String(sumMicro(rows.map(\.costMicro)))
                )
            }
            .sorted {
                if $0.entryCount != $1.entryCount { return $0.entryCount > $1.entryCount }
                return $0.outcome.rawValue < $1.outcome.rawValue
            }

        let issueOutcomes: Set<RouterBillingOutcome> = [.empty, .error, .cancelled]

        return RouterLedgerSummary(
            entryCount: entries.count,
            inputTokens: entries.reduce(0) { $0 + $1.inputTokens },
            outputTokens: entries.reduce(0) { $0 + $1.outputTokens },
            costMicro: String(sumMicro(entries.map(\.costMicro))),
            latestEntryAt: entries.map(\.createdAt).max(),
            pendingCount: entries.filter { $0.outcome == .pending }.count,
            issueCount: entries.filter { issueOutcomes.contains($0.outcome) }.count,
            outcomeBreakdown: outcomeBreakdown,
            modelBreakdown: ledgerModelBreakdown(entries)
        )
    }

    static func transactionSummary(_ transactions: [OsaurusRouterTransactionItem]) -> RouterTransactionSummary {
        let amounts = transactions.map { microValue($0.amountMicro) }
        let credits = amounts.filter { $0 > 0 }.reduce(0, +)
        let debits = amounts.filter { $0 < 0 }.reduce(0, +)
        let entryTypeBreakdown = Dictionary(grouping: transactions, by: { normalizedName($0.entryType) })
            .map { entryType, rows in
                RouterTransactionBreakdown(
                    entryType: entryType,
                    transactionCount: rows.count,
                    netAmountMicro: String(sumMicro(rows.map(\.amountMicro)))
                )
            }
            .sorted {
                if $0.transactionCount != $1.transactionCount { return $0.transactionCount > $1.transactionCount }
                return $0.entryType < $1.entryType
            }

        return RouterTransactionSummary(
            transactionCount: transactions.count,
            creditMicro: String(credits),
            debitMicro: String(abs(debits)),
            netMicro: String(credits + debits),
            latestTransactionAt: transactions.compactMap {
                CreditsActivityProjector.date(fromRouterTimestamp: $0.createdAt)
            }.max(),
            entryTypeBreakdown: entryTypeBreakdown
        )
    }

    static func supportExport(
        walletAddress: String?,
        snapshot: RouterAccountUsageSnapshot,
        signedDiagnostics: [RouterSignedRequestDiagnostic],
        usageItems: [OsaurusRouterUsageItem],
        transactions: [OsaurusRouterTransactionItem],
        ledgerEntries: [RouterBillingEntry],
        generatedAt: Date = Date()
    ) -> RouterSupportExport {
        let resolvedWalletAddress = nonPromptingWalletAddress(
            explicitWalletAddress: walletAddress,
            signedDiagnostics: signedDiagnostics
        )

        return RouterSupportExport(
            schemaVersion: RouterSupportExport.schemaVersion,
            generatedAt: generatedAt,
            walletAddress: resolvedWalletAddress,
            walletAddressStatus: walletAddressStatus(
                walletAddress: resolvedWalletAddress,
                snapshot: snapshot
            ),
            account: snapshot,
            signedRequestDiagnostics: signedDiagnostics,
            usage: usageItems.map(RouterSupportUsageItem.init),
            transactions: transactions.map(RouterSupportTransactionItem.init),
            ledgerEntries: ledgerEntries.map(RouterSupportLedgerEntry.init),
            redaction: [
                "Prompt text, response text, tool arguments, tool results, private keys, bearer tokens, cookies, and wallet signatures are not exported.",
                "Signed request diagnostics include request shape, body hash, signed header names, and a signature fingerprint only.",
                "Support export does not prompt for biometric authentication; walletAddress is populated only from non-prompting sources.",
            ]
        )
    }

    static func nonPromptingWalletAddress(
        explicitWalletAddress: String?,
        signedDiagnostics: [RouterSignedRequestDiagnostic]
    ) -> String? {
        if let explicit = normalizedWalletAddress(explicitWalletAddress) {
            return explicit
        }

        return signedDiagnostics.lazy
            .compactMap { normalizedWalletAddress($0.walletAddress) }
            .first
    }

    static func walletAddressStatus(
        walletAddress: String?,
        snapshot: RouterAccountUsageSnapshot
    ) -> RouterSupportWalletAddressStatus {
        if normalizedWalletAddress(walletAddress) != nil {
            return .available
        }
        if !snapshot.accountStatus.identityAvailable {
            return .identityMissing
        }
        return .unavailableWithoutPrompt
    }

    static func redactedHeaderValue(headerName: String, value: String) -> String {
        let lowered = headerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "x-wallet-signature" {
            return redactedValue
        }
        if isSensitiveHeader(lowered) {
            return redactedValue
        }
        if lowered == "x-wallet-address" {
            return value.lowercased()
        }
        return value
    }

    private static func normalizedWalletAddress(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private static func isSensitiveHeader(_ loweredName: String) -> Bool {
        loweredName == "authorization"
            || loweredName == "cookie"
            || loweredName == "set-cookie"
            || loweredName.contains("api-key")
            || loweredName.contains("apikey")
            || loweredName.contains("token")
            || loweredName.contains("secret")
            || loweredName.contains("private")
            || loweredName.contains("signature")
    }

    private static func usageBreakdown(
        _ usageItems: [OsaurusRouterUsageItem],
        key: (OsaurusRouterUsageItem) -> String
    ) -> [RouterUsageBreakdown] {
        Dictionary(grouping: usageItems, by: { normalizedName(key($0)) })
            .map { name, rows in
                RouterUsageBreakdown(
                    name: name,
                    requestCount: rows.count,
                    inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                    outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                    costMicro: String(sumMicro(rows.map(\.costMicro)))
                )
            }
            .sorted(by: breakdownSort)
    }

    private static func ledgerModelBreakdown(_ entries: [RouterBillingEntry]) -> [RouterUsageBreakdown] {
        Dictionary(grouping: entries, by: { normalizedName($0.model ?? "") })
            .map { name, rows in
                RouterUsageBreakdown(
                    name: name,
                    requestCount: rows.count,
                    inputTokens: rows.reduce(0) { $0 + $1.inputTokens },
                    outputTokens: rows.reduce(0) { $0 + $1.outputTokens },
                    costMicro: String(sumMicro(rows.map(\.costMicro)))
                )
            }
            .sorted(by: breakdownSort)
    }

    private static func breakdownSort(_ lhs: RouterUsageBreakdown, _ rhs: RouterUsageBreakdown) -> Bool {
        let lhsCost = microValue(lhs.costMicro)
        let rhsCost = microValue(rhs.costMicro)
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if lhs.requestCount != rhs.requestCount { return lhs.requestCount > rhs.requestCount }
        return lhs.name < rhs.name
    }

    private static func normalizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func sumMicro(_ values: [String]) -> Int64 {
        values.reduce(Int64(0)) { partial, raw in
            let value = microValue(raw)
            let (sum, overflow) = partial.addingReportingOverflow(value)
            if overflow {
                return value >= 0 ? Int64.max : Int64.min
            }
            return sum
        }
    }

    static func microValue(_ raw: String) -> Int64 {
        Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

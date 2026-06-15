import Foundation

struct CreditsActivityProjector {
    var hasInsightsLogForRequestId: (String) -> Bool = { _ in false }
    var hasInsightsLogForTurnId: (UUID) -> Bool = { _ in false }

    func rows(
        usageItems: [OsaurusRouterUsageItem],
        ledgerEntries: [RouterBillingEntry]
    ) -> [CreditsActivityRow] {
        var usedLedgerIds = Set<String>()
        return usageItems.map { item in
            let match = matchedLedgerEntry(for: item, in: ledgerEntries, excluding: usedLedgerIds)
            if let match {
                usedLedgerIds.insert(match.entry.id)
            }
            return CreditsActivityRow(
                usage: item,
                match: match,
                insightsReference: insightsReference(for: item, match: match)
            )
        }
    }

    private func insightsReference(
        for item: OsaurusRouterUsageItem,
        match: CreditsActivityLedgerMatch?
    ) -> CreditsActivityReference? {
        if let matchedEntry = match?.entry,
            let reference = CreditsActivityReference(matchedEntry)
        {
            if let requestId = reference.requestId, hasInsightsLogForRequestId(requestId) {
                return reference
            }
            if let turnId = reference.turnUUID, hasInsightsLogForTurnId(turnId) {
                return reference
            }
        }

        guard let requestId = item.correlationRequestId else { return nil }
        guard hasInsightsLogForRequestId(requestId) else { return nil }
        return CreditsActivityReference(requestId: requestId, sessionId: nil, turnId: nil)
    }

    private func matchedLedgerEntry(
        for item: OsaurusRouterUsageItem,
        in ledgerEntries: [RouterBillingEntry],
        excluding usedLedgerIds: Set<String>
    ) -> CreditsActivityLedgerMatch? {
        if let requestId = item.correlationRequestId {
            let exactMatch = ledgerEntries.first {
                !usedLedgerIds.contains($0.id) && $0.requestId == requestId
            }
            if let exactMatch {
                return CreditsActivityLedgerMatch(entry: exactMatch, quality: .exactRequestId)
            }
        }

        let usageDate = Self.date(fromRouterTimestamp: item.createdAt)
        return
            ledgerEntries
            .filter { !usedLedgerIds.contains($0.id) }
            .filter { ledgerEntryMatches($0, usage: item) }
            .min { lhs, rhs in
                let lhsDelta = usageDate.map { abs(lhs.createdAt.timeIntervalSince($0)) } ?? 0
                let rhsDelta = usageDate.map { abs(rhs.createdAt.timeIntervalSince($0)) } ?? 0
                return lhsDelta < rhsDelta
            }
            .map { CreditsActivityLedgerMatch(entry: $0, quality: .legacyFuzzy) }
    }

    private func ledgerEntryMatches(_ entry: RouterBillingEntry, usage item: OsaurusRouterUsageItem) -> Bool {
        guard entry.requestId == nil else {
            return false
        }

        guard entry.inputTokens == item.inputTokens,
            entry.outputTokens == item.outputTokens,
            entry.costMicro == item.costMicro,
            entry.status.caseInsensitiveCompare(item.status) == .orderedSame,
            entry.tokenSource.caseInsensitiveCompare(item.tokenSource) == .orderedSame
        else {
            return false
        }

        if let model = entry.model, !model.isEmpty, model != item.model {
            return false
        }

        guard let usageDate = Self.date(fromRouterTimestamp: item.createdAt) else {
            return true
        }
        return abs(entry.createdAt.timeIntervalSince(usageDate)) <= 300
    }

    static func date(fromRouterTimestamp raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

struct CreditsActivityLedgerMatch: Equatable {
    let entry: RouterBillingEntry
    let quality: CreditsActivityMatchQuality
}

enum CreditsActivityMatchQuality: Equatable {
    case exactRequestId
    case legacyFuzzy
    case none
}

enum CreditsActivityStateKind: Equatable {
    case success
    case warning
    case error
    case secondary
}

struct CreditsActivityRow: Identifiable, Equatable {
    let id: String
    let model: String
    let detail: String?
    let inputTokens: Int
    let outputTokens: Int
    let costMicro: String
    let stateLabel: String
    /// Secondary nuance shown only for locally-matched rows (e.g. "Tools only").
    /// `nil` keeps server-only rows on the single shared vocabulary.
    let stateDetail: String?
    let stateKind: CreditsActivityStateKind
    let createdAtLabel: String
    let localReference: CreditsActivityReference?
    let insightsReference: CreditsActivityReference?
    let matchQuality: CreditsActivityMatchQuality
}

extension CreditsActivityRow {
    init(
        usage item: OsaurusRouterUsageItem,
        match: CreditsActivityLedgerMatch?,
        insightsReference: CreditsActivityReference?
    ) {
        self.id = "usage-\(item.id)"
        self.model = item.model
        self.detail = item.provider
        self.inputTokens = item.inputTokens
        self.outputTokens = item.outputTokens
        self.costMicro = item.costMicro
        if let match {
            let ledgerEntry = match.entry
            let state = Self.state(for: ledgerEntry.outcome)
            self.stateLabel = state.label
            self.stateDetail = state.detail
            self.stateKind = state.kind
            let reference = CreditsActivityReference(ledgerEntry)
            self.localReference = reference?.sessionUUID == nil ? nil : reference
            self.insightsReference = insightsReference
            self.matchQuality = match.quality
        } else {
            let state = Self.state(forStatus: item.status)
            self.stateLabel = state.label
            self.stateDetail = nil
            self.stateKind = state.kind
            self.localReference = nil
            self.insightsReference = insightsReference
            self.matchQuality = .none
        }
        self.createdAtLabel = Self.shortDate(item.createdAt)
    }

    private static func shortDate(_ raw: String) -> String {
        guard let date = CreditsActivityProjector.date(fromRouterTimestamp: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Map a finalized local outcome onto the shared display vocabulary. The
    /// nuance the ledger captured (reasoning-only, tools-only) rides along as an
    /// optional secondary tag so the primary word matches server-only rows.
    private static func state(
        for outcome: RouterBillingOutcome
    ) -> (label: String, detail: String?, kind: CreditsActivityStateKind) {
        switch outcome {
        case .pending: return ("Pending", nil, .secondary)
        case .rendered: return ("Completed", nil, .success)
        case .reasoningOnly: return ("Completed", "Reasoning only", .success)
        case .toolOnly: return ("Completed", "Tools only", .success)
        case .empty: return ("No reply", nil, .error)
        case .error: return ("Error", nil, .error)
        case .cancelled: return ("Stopped", nil, .warning)
        }
    }

    /// Map a raw server status onto the same vocabulary used for local outcomes,
    /// so a row reads the same whether or not this device has the local record.
    private static func state(
        forStatus status: String
    ) -> (label: String, kind: CreditsActivityStateKind) {
        switch status.lowercased() {
        case "completed", "complete", "succeeded", "success", "ok":
            return ("Completed", .success)
        case "pending", "processing", "in_progress", "running", "queued":
            return ("Pending", .secondary)
        case "aborted", "cancelled", "canceled", "stopped":
            return ("Stopped", .warning)
        case "empty", "no_reply", "no-reply":
            return ("No reply", .error)
        default:
            return ("Error", .error)
        }
    }
}

extension CreditsActivityRow {
    /// Best available human label for the request. Prefers the model id, falls
    /// back to the provider, and is `nil` only when both are empty so the view
    /// can show a localized placeholder.
    var modelDisplay: String? {
        if !model.isEmpty { return model }
        if let detail, !detail.isEmpty { return detail }
        return nil
    }

    /// Provider and time for the row's secondary line. Provider is included only
    /// when the model is the primary label, to avoid repeating it as both.
    var metadataLine: String {
        var parts: [String] = []
        if !model.isEmpty, let detail, !detail.isEmpty {
            parts.append(detail)
        }
        parts.append(createdAtLabel)
        return parts.joined(separator: " · ")
    }

    var tokensLine: String {
        "\(inputTokens.formatted()) in / \(outputTokens.formatted()) out"
    }
}

struct CreditsActivityReference: Equatable {
    let requestId: String?
    let sessionId: String?
    let turnId: String?

    init?(requestId: String?, sessionId: String?, turnId: String?) {
        let requestId = requestId?.isEmpty == false ? requestId : nil
        let sessionId = sessionId?.isEmpty == false ? sessionId : nil
        let turnId = turnId?.isEmpty == false ? turnId : nil
        guard requestId != nil || sessionId != nil || turnId != nil else { return nil }
        self.requestId = requestId
        self.sessionId = sessionId
        self.turnId = turnId
    }

    init?(_ entry: RouterBillingEntry) {
        self.init(requestId: entry.requestId, sessionId: entry.sessionId, turnId: entry.turnId)
    }

    var sessionUUID: UUID? {
        sessionId.flatMap(UUID.init(uuidString:))
    }

    var turnUUID: UUID? {
        turnId.flatMap(UUID.init(uuidString:))
    }

    var chatHelpText: String {
        if let sessionId, let turnId, !turnId.isEmpty {
            return "Open chat session \(sessionId), turn \(turnId)"
        }
        if let sessionId {
            return "Open chat session \(sessionId)"
        }
        return "Open chat session"
    }

    var insightsHelpText: String {
        if let requestId, !requestId.isEmpty {
            return "Open Insights log for request \(requestId)"
        }
        if let turnId, !turnId.isEmpty {
            return "Open Insights log for turn \(turnId)"
        }
        return "Open Insights log"
    }
}

extension OsaurusRouterUsageItem {
    var correlationRequestId: String? {
        if let requestId, !requestId.isEmpty {
            return requestId
        }
        return id.isEmpty ? nil : id
    }
}

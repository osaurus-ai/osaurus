import Foundation

struct MediaVideoQuoteReceipt: Sendable, Equatable {
    var token: String
    var quote: MediaVideoQuote
    var expiresAt: Date
}

/// Process-local, single-use receipts for the public HTTP API. The caller can
/// no longer invent a high `quote_usd`; queueing must present the opaque token
/// returned for the exact price-affecting request shape.
actor MediaQuoteStore {
    static let shared = MediaQuoteStore()

    private struct Entry: Sendable {
        var key: MediaVideoQuoteKey
        var quote: MediaVideoQuote
        var expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 5 * 60) {
        self.lifetime = lifetime
    }

    func issue(for request: MediaVideoGenerationRequest, quote: MediaVideoQuote) -> MediaVideoQuoteReceipt {
        pruneExpired()
        let token = UUID().uuidString.lowercased()
        let expiresAt = Date().addingTimeInterval(lifetime)
        entries[token] = Entry(
            key: MediaVideoQuoteKey(request: request),
            quote: quote,
            expiresAt: expiresAt
        )
        return MediaVideoQuoteReceipt(token: token, quote: quote, expiresAt: expiresAt)
    }

    func consume(token: String, for request: MediaVideoGenerationRequest) throws -> MediaVideoQuote {
        pruneExpired()
        guard let entry = entries.removeValue(forKey: token) else {
            throw MediaGenerationError.invalidRequest(
                "The video quote is missing, expired, or has already been used."
            )
        }
        guard entry.key == MediaVideoQuoteKey(request: request) else {
            throw MediaGenerationError.invalidRequest(
                "The video request no longer matches the approved quote."
            )
        }
        return entry.quote
    }

    private func pruneExpired() {
        let now = Date()
        entries = entries.filter { $0.value.expiresAt > now }
    }
}

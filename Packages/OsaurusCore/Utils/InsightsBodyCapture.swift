import Foundation

/// Bounds already-redacted log bodies; never changes the request sent to a model.
enum InsightsBodyCapture {
    static let maximumBytes = 262_144

    // INVARIANT: the stored UTF-8 body, including its truncation marker, fits the
    // byte budget. Character counts undercount non-ASCII text and grapheme clusters.
    static func truncate(_ body: String, maximumBytes: Int = maximumBytes) -> String {
        precondition(maximumBytes > 0)
        let originalBytes = body.utf8.count
        guard originalBytes > maximumBytes else { return body }
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(originalBytes),
            countStyle: .binary
        )
        let marker = "\n…[truncated, original \(formatted); \(originalBytes) bytes]"
        let prefixBudget = max(0, maximumBytes - marker.utf8.count)
        return utf8Prefix(body, maximumBytes: prefixBudget)
            + utf8Prefix(marker, maximumBytes: maximumBytes)
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        var end = text.startIndex
        var bytes = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let count = text[end ..< next].utf8.count
            guard count <= maximumBytes - bytes else { break }
            bytes += count
            end = next
        }
        return String(text[..<end])
    }
}

#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Original review sheet with synthetic text and a disposable session id.
/// The resolver records a local result only; no message or service is attached.
struct InspectorPrivacyVerification: View {
    @State private var review: RedactionReviewState?
    @State private var result = "None"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original redaction review · synthetic local text")
            Button("Open local redaction review") {
                let text = "Please contact sample@example.invalid about local display number 555-0100."
                let toolText = "Feed: https://feeds.example.invalid/rss — host Jordan Sample."
                let samples: [(String, EntityCategory, String, PrivacySegmentOrigin)] = [
                    ("sample@example.invalid", .email, text, .userInput),
                    ("555-0100", .phone, text, .userInput),
                    ("https://feeds.example.invalid/rss", .url, toolText, .toolResult("web_fetch")),
                    ("Jordan Sample", .person, toolText, .toolResult("web_fetch")),
                ]
                let detections = samples.enumerated().map { index, item in
                    DetectedEntity(category: item.1, original: item.0, range: item.2.range(of: item.0)!,
                        placeholder: Placeholder(category: item.1, index: index + 1), containingText: item.2,
                        origin: item.3)
                }
                let state = RedactionReviewState(
                    detections: detections, sessionId: "inspector-disposable-review", providerName: "Osaurus Cloud")
                state.onResolve = { _ in result = "Local review resolved"; review = nil }
                review = state
            }
            Text("Local review callback: \(result)")
        }
        .sheet(item: $review) { state in RedactionReviewSheet(state: state) }
    }
}
#endif

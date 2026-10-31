import Foundation
import Testing
@testable import OsaurusCore

@Suite("Insights UTF-8 body budget")
struct InsightsBodyCaptureTests {
    @Test func exactBudgetIsUnchanged() {
        for body in [String(repeating: "a", count: 256), String(repeating: "é", count: 128)] {
            #expect(InsightsBodyCapture.truncate(body, maximumBytes: 256) == body)
        }
    }

    @Test func clipsASCIIAndMultibyteBodiesIncludingMarker() {
        for body in [
            String(repeating: "a", count: 400), String(repeating: "医", count: 200),
            String(repeating: "👨‍👩‍👧‍👦", count: 100), String(repeating: "e\u{301}", count: 200),
        ] {
            let captured = InsightsBodyCapture.truncate(body, maximumBytes: 256)
            #expect(captured.utf8.count <= 256)
            #expect(captured.contains("truncated, original"))
            #expect(captured.contains("\(body.utf8.count) bytes"))
            #expect(!captured.contains("\u{FFFD}"))
            let prefix = captured.components(separatedBy: "\n…[truncated")[0]
            #expect(body.hasPrefix(prefix))
        }
    }

    @Test func smallBudgetsStillBoundUTF8() {
        for budget in 1 ... 80 {
            let captured = InsightsBodyCapture.truncate(String(repeating: "🙂", count: 100), maximumBytes: budget)
            #expect(captured.utf8.count <= budget)
            #expect(!captured.contains("\u{FFFD}"))
        }
    }
}

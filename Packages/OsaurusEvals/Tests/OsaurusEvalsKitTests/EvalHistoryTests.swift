import Foundation
import Testing

@testable import OsaurusEvalsKit

/// Locks the append-only `reports/history.jsonl` contract: a matrix projects
/// to one row per model (with skip/err summed from the per-domain cells), the
/// writer only ever appends single-line rows, and the loader round-trips while
/// tolerating blank/garbage lines from a hand-edit or a partial merge.
@Suite
struct EvalHistoryTests {

    private func matrix(generatedAt: String = "2026-06-19T00:00:00Z") -> EvalMatrix {
        EvalMatrix(
            generatedAt: generatedAt,
            domains: ["agent_loop", "capability_claims"],
            models: [
                EvalMatrixModelColumn(
                    modelId: "mlx-community/Qwen3-4B-4bit",
                    startedAt: generatedAt,
                    perDomain: [
                        "agent_loop": .init(passed: 13, scored: 17, skipped: 1, errored: 0),
                        "capability_claims": .init(passed: 4, scored: 6, skipped: 2, errored: 1),
                    ],
                    totalPassed: 17,
                    totalScored: 23,
                    meanDecodeTokensPerSecond: 60.4,
                    meanTtftMs: 179,
                    peakPhysFootprintMb: 10712
                )
            ]
        )
    }

    @Test func rowsProjectTotalsAndSumSkipErr() {
        let rows = EvalHistory.rows(from: matrix(), commit: "abc1234", label: "nightly")
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.model == "mlx-community/Qwen3-4B-4bit")
        #expect(row.passed == 17)
        #expect(row.scored == 23)
        #expect(row.skipped == 3)  // 1 + 2 across domains
        #expect(row.errored == 1)
        #expect(row.commit == "abc1234")
        #expect(row.label == "nightly")
        #expect(row.decodeTokensPerSecond == 60.4)
        #expect(row.peakPhysFootprintMb == 10712)
    }

    @Test func blankCommitAndLabelBecomeNil() {
        let rows = EvalHistory.rows(from: matrix(), commit: "   ", label: "")
        #expect(rows[0].commit == nil)
        #expect(rows[0].label == nil)
    }

    @Test func appendIsAppendOnlyAndRoundTrips() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        // First recorded run.
        try EvalHistory.append(
            EvalHistory.rows(from: matrix(generatedAt: "2026-06-18T00:00:00Z"), commit: "run1", label: nil),
            to: url
        )
        // Second run appends, never rewrites.
        try EvalHistory.append(
            EvalHistory.rows(from: matrix(generatedAt: "2026-06-19T00:00:00Z"), commit: "run2", label: "after-fix"),
            to: url
        )

        let loaded = try EvalHistory.load(from: url)
        #expect(loaded.count == 2)
        #expect(loaded[0].commit == "run1")
        #expect(loaded[1].commit == "run2")
        #expect(loaded[1].label == "after-fix")

        // Each row must be exactly one physical line (JSONL invariant).
        let text = try String(contentsOf: url, encoding: .utf8)
        let nonEmptyLines = text.split(whereSeparator: \.isNewline).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        #expect(nonEmptyLines.count == 2)
    }

    @Test func loaderSkipsBlankAndGarbageLines() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try EvalHistory.append(EvalHistory.rows(from: matrix(), commit: "ok", label: nil), to: url)
        // Simulate a hand-edit / messy merge: blank line + non-JSON noise.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n<<<<<<< HEAD\nnot json at all\n".utf8))
        try handle.close()

        let loaded = try EvalHistory.load(from: url)
        #expect(loaded.count == 1)
        #expect(loaded[0].commit == "ok")
    }

    @Test func emptyRowsIsNoOp() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("osaurus-history-\(UUID().uuidString).jsonl")
        try EvalHistory.append([], to: url)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }
}

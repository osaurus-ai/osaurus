//
//  TTFTTraceStartTests.swift
//  osaurusTests
//
//  The phase a user actually waits through can start before generation does:
//  a send blocks on the pre-send warm-up handshake, which loads the whole
//  container first. The trace used to be created after that, so its clock
//  started once the wait was already over — the reported TTFT excluded it, and
//  no phase in the trace accounted for it either (#2347).
//
//  These pin the arithmetic that puts the wait back inside the trace.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct TTFTTraceStartTests {

    private func firstPhaseMs(_ rendered: String) -> Double? {
        for line in rendered.split(separator: "\n") where line.contains("ms") {
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 3, let value = Double(parts[parts.count - 2]) else { continue }
            return value
        }
        return nil
    }

    /// A backdated start must land in the first phase. Without this the wait is
    /// simply absent from the breakdown — which is the reported defect.
    @Test
    func backdatedStartLandsInTheFirstPhase() {
        let trace = TTFTTrace(start: CFAbsoluteTimeGetCurrent() - 4.5)
        trace.mark("pre_send_wait")

        let rendered = try! #require(trace.render())
        let ms = try! #require(firstPhaseMs(rendered))
        #expect(
            ms >= 4400 && ms <= 4700,
            "the 4.5 s pre-send wait must appear as the first phase; got \(ms) ms")
    }

    /// The default start stays "now", so traces that never saw a handshake are
    /// unchanged and remain comparable with previously captured ones.
    @Test
    func defaultStartMeasuresFromCreation() {
        let trace = TTFTTrace()
        trace.mark("pre_send_wait")

        let rendered = try! #require(trace.render())
        let ms = try! #require(firstPhaseMs(rendered))
        #expect(ms < 250, "a trace with no backdating must start at ~0; got \(ms) ms")
    }

    /// Later phases must stay relative to the previous mark, or backdating would
    /// smear the wait across every row and make traces incomparable.
    @Test
    func laterPhasesAreUnaffectedByBackdating() {
        let trace = TTFTTrace(start: CFAbsoluteTimeGetCurrent() - 3.0)
        trace.mark("pre_send_wait")
        trace.mark("prepare_exec_mode_done")

        let rendered = try! #require(trace.render())
        let lines = rendered.split(separator: "\n").filter { $0.contains("ms") }
        #expect(lines.count >= 2)
        let second = lines[1].split(separator: " ").filter { !$0.isEmpty }
        let secondMs = try! #require(Double(second[second.count - 2]))
        #expect(secondMs < 250, "second phase must not inherit the backdated wait; got \(secondMs)")
    }

    /// An empty trace renders nothing, so `emit()` cannot append blank blocks.
    @Test
    func emptyTraceRendersNothing() {
        #expect(TTFTTrace().render() == nil)
    }

    /// Metrics still round-trip; `awaited_pre_send_handshake` is what separates
    /// "the model was already warm" from "the user waited out a load".
    @Test
    func metadataAppearsInTheRenderedBlock() {
        let trace = TTFTTrace()
        trace.mark("pre_send_wait")
        trace.set("awaited_pre_send_handshake", true)

        let rendered = try! #require(trace.render())
        #expect(rendered.contains("awaited_pre_send_handshake"))
        #expect(rendered.contains("true"))
    }
}

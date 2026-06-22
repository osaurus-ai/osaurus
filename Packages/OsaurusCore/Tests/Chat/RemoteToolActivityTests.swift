//
//  RemoteToolActivityTests.swift
//  osaurusTests
//
//  Pins the display-only contract for remote-agent (Mode 2) tool activity on
//  `ChatTurn`. The remote peer executes tools server-side and streams back only
//  a sanitized `osaurus_agent_tool` trace (name + phase + error state — never
//  raw args/results). These helpers reconstruct a per-turn tool-call group so
//  the observer watches each remote tool transition running → done/failed,
//  while guaranteeing the activity:
//    • is never written into `toolCalls` (the field `turnToMessage` serializes),
//      so a Mode 2 multi-turn history can't carry synthetic, unpaired tool_calls;
//    • renders running (no result) until a terminal trace lands;
//    • marks failures with a `ToolEnvelope` error so the chip renders red;
//    • advances `remoteToolActivityTick` on every mutation so `BlockMemoizer`'s
//      streaming fast-path re-renders the chips.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Remote-agent (Mode 2) tool activity — display only")
struct RemoteToolActivityTests {

    private func makeTurn() -> ChatTurn {
        ChatTurn(role: .assistant, content: "")
    }

    @Test func startedThenFinished_recordsRunningThenResult() {
        let turn = makeTurn()
        turn.noteRemoteToolStarted(callId: "c1", name: "get_weather")

        // Started but not finished → no result yet, so the chip renders as the
        // live "running" shimmer.
        #expect(turn.remoteToolActivity.count == 1)
        #expect(turn.remoteToolActivity.first?.function.name == "get_weather")
        #expect(turn.remoteToolResults["c1"] == nil)
        #expect(turn.hasRemoteToolActivity)

        turn.noteRemoteToolFinished(callId: "c1", name: "get_weather", isError: false)
        let result = turn.remoteToolResults["c1"]
        #expect(result != nil)
        // Success result is a plain, non-error string → green/done node.
        #expect(ToolEnvelope.isError(result ?? "") == false)
    }

    @Test func failure_recordsErrorEnvelope_soChipRendersRed() {
        let turn = makeTurn()
        turn.noteRemoteToolStarted(callId: "c1", name: "shell")
        turn.noteRemoteToolFinished(callId: "c1", name: "shell", isError: true)
        // The row carries a ToolEnvelope error so `NativeToolCallRowView`'s
        // `isErrorResult` paints it red — without ever exposing the remote's
        // raw tool output.
        #expect(ToolEnvelope.isError(turn.remoteToolResults["c1"] ?? ""))
    }

    @Test func doesNotPopulateToolCalls_soHistoryStaysClean() {
        let turn = makeTurn()
        turn.noteRemoteToolStarted(callId: "c1", name: "get_weather")
        turn.noteRemoteToolFinished(callId: "c1", name: "get_weather", isError: false)
        // The serialized history field (`toolCalls`) is never touched: a Mode 2
        // turn must not re-send synthetic, unpaired tool_calls on the next turn.
        #expect(turn.toolCalls == nil)
        #expect(turn.toolResults.isEmpty)
        #expect(turn.remoteToolActivity.count == 1)
    }

    @Test func finishedWithoutStarted_materializesRow() {
        // Some peers may only emit a terminal trace — the row is still created.
        let turn = makeTurn()
        turn.noteRemoteToolFinished(callId: "c9", name: "search", isError: false)
        #expect(turn.remoteToolActivity.count == 1)
        #expect(turn.remoteToolActivity.first?.id == "c9")
        #expect(turn.remoteToolResults["c9"] != nil)
    }

    @Test func started_isIdempotentPerCallId() {
        let turn = makeTurn()
        turn.noteRemoteToolStarted(callId: "c1", name: "get_weather")
        turn.noteRemoteToolStarted(callId: "c1", name: "get_weather")
        #expect(turn.remoteToolActivity.count == 1)
    }

    @Test func started_ignoresBlankName() {
        let turn = makeTurn()
        turn.noteRemoteToolStarted(callId: "c1", name: "   ")
        #expect(turn.remoteToolActivity.isEmpty)
        #expect(turn.hasRemoteToolActivity == false)
    }

    @Test func finalize_settlesRunningRows() {
        let turn = makeTurn()
        turn.noteRemoteToolStarted(callId: "c1", name: "search")
        #expect(turn.remoteToolResults["c1"] == nil)  // shimmering

        turn.finalizeRemoteToolActivity()
        // No longer running → a result is stamped so it can't shimmer forever.
        #expect(turn.remoteToolResults["c1"] != nil)
    }

    @Test func tick_advancesOnEveryMutation() {
        let turn = makeTurn()
        let t0 = turn.remoteToolActivityTick
        turn.noteRemoteToolStarted(callId: "c1", name: "search")
        let t1 = turn.remoteToolActivityTick
        turn.noteRemoteToolFinished(callId: "c1", name: "search", isError: false)
        let t2 = turn.remoteToolActivityTick
        // The memoizer folds this counter into its streaming fast-path signature,
        // so a trace that changes neither content nor thinking still re-renders.
        #expect(t1 > t0)
        #expect(t2 > t1)
    }

    @Test func finalize_isNoOpWhenNoActivity() {
        let turn = makeTurn()
        let before = turn.remoteToolActivityTick
        turn.finalizeRemoteToolActivity()
        #expect(turn.remoteToolActivityTick == before)
        #expect(turn.hasRemoteToolActivity == false)
    }
}

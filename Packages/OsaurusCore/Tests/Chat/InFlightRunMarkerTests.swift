//
//  InFlightRunMarkerTests.swift
//  osaurus
//
//  The in-flight marker's lifecycle: written while local work runs, gone
//  when it ends, and turned into one notice only after an unattributed exit.
//

import Foundation
import Testing

@testable import OsaurusCore

struct InFlightRunMarkerTests {
    private func makeMarker() -> (InFlightRunMarker, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("in-flight-\(UUID().uuidString)")
            .appendingPathComponent(InFlightRunMarker.fileName)
        return (InFlightRunMarker(fileURL: url), url)
    }

    @Test func fileExistsOnlyWhileWorkIsInFlight() {
        let (marker, url) = makeMarker()
        let load = marker.begin(.load, model: "m", sessionId: nil, footprintBytes: 5 << 30, pressure: .normal)
        let generation = marker.begin(.generation, model: "m", sessionId: "s", pressure: .warning)
        #expect(FileManager.default.fileExists(atPath: url.path))
        marker.end(load)
        #expect(FileManager.default.fileExists(atPath: url.path))
        marker.end(generation)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        marker.end(generation)
        marker.end(nil)
    }

    @Test func unattributedExitKeepsTheLatestWorkForItsChat() {
        let (writer, url) = makeMarker()
        let start = Date(timeIntervalSince1970: 1_000_000)
        writer.begin(.generation, model: "chat-model", sessionId: "chat-1", pressure: .normal, now: start)
        writer.begin(
            .load, model: "big-model", sessionId: nil, footprintBytes: 20 << 30, pressure: .warning,
            now: start.addingTimeInterval(5))

        let relaunched = InFlightRunMarker(fileURL: url)
        let kept = relaunched.evaluateAtLaunch(verdict: .unattributed)
        #expect(kept?.phase == .load)
        #expect(kept?.model == "big-model")
        #expect(kept?.sessionId == "chat-1")
        #expect(kept?.footprintBucket == "16-64")
        #expect(kept?.pressure == "warning")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        #expect(relaunched.claimInterrupted(sessionId: "other") == nil)
        #expect(relaunched.claimInterrupted(sessionId: "chat-1")?.model == "big-model")
        #expect(relaunched.claimInterrupted(sessionId: "chat-1") == nil, "shown once")
    }

    @Test func cleanOrFirstLaunchNeverBlamesAModel() {
        for verdict in [TerminationForensics.LaunchVerdict.clean, .firstLaunch] {
            let (writer, url) = makeMarker()
            writer.begin(.handoff, model: "m", sessionId: "chat", pressure: .normal)
            let relaunched = InFlightRunMarker(fileURL: url)
            #expect(relaunched.evaluateAtLaunch(verdict: verdict) == nil)
            #expect(relaunched.pendingInterrupted == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func nothingInFlightMeansNoNotice() {
        let (marker, _) = makeMarker()
        #expect(marker.evaluateAtLaunch(verdict: .unattributed) == nil)
    }

    @Test func interruptedOutcomeNamesWhatWasRunning() {
        let entry = InFlightRunMarker.Entry(
            id: UUID(), phase: .handoff, model: "raptor", sessionId: "s", footprintBucket: nil,
            pressure: "critical", startedAt: Date())
        let outcome = ChatRunOutcome(interrupted: entry)
        #expect(outcome.kind == .interruptedByExit)
        #expect(outcome.retryable)
        #expect(outcome.facts.map(\.value) == ["raptor", L("Running a helper")])
        #expect(outcome.memoryPressure == "critical")
    }
}

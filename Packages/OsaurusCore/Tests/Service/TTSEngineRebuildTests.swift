// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

/// TTS went silent for a user who was switching between AirPods and the built-in speakers.
/// PocketTTS Preview kept working; the chat speaker button and Auto Speak produced nothing —
/// the Stop control appeared and then flipped back on its own, with no error anywhere.
///
/// The cause is an AVAudioEngine contract that is easy to get wrong: on an output-route change
/// the engine tears its graph down and posts `.AVAudioEngineConfigurationChange`, but it goes on
/// reporting `isRunning == true`. `configureEngineIfNeeded` returned early on exactly that
/// condition, so the player node stayed wired to a device that no longer existed. Buffers were
/// still consumed, their completion handlers still fired, playback still "finished" — and not one
/// sample was audible. From the outside that is indistinguishable from the app ignoring the user.
///
/// Exercising a real route change needs real hardware, so this pins the two properties that make
/// the silent path impossible: the engine is not trusted on `isRunning` alone, and a synthesis
/// failure is no longer swallowed by a `print`.
@Suite("TTS survives an output-device change")
struct TTSEngineRebuildTests {
    private static func source() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Service/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Managers/TTSService.swift"),
            encoding: .utf8)
    }

    @Test("A route change forces the audio graph to be rebuilt")
    func routeChangeRebuildsTheEngine() throws {
        let src = try Self.source()

        // Without this observer nothing ever learns the graph died, and every later playback
        // renders into a device that is gone.
        #expect(
            src.contains("AVAudioEngineConfigurationChange"),
            "an output-route change must be observed — the engine will not tell you otherwise"
        )
        #expect(src.contains("needsRebuild"))

        // And the early return must consult it. `isRunning` is true even when the graph is dead,
        // so trusting it alone is precisely the silent-audio bug.
        guard let start = src.range(of: "private func configureIfNeededLocked()") else {
            Issue.record("configureIfNeededLocked not found")
            return
        }
        let body = String(src[start.lowerBound...].prefix(1400))
        #expect(
            body.contains("if needsRebuild"),
            "configureIfNeededLocked must rebuild after a configuration change, not return early"
        )
    }

    @Test("A synthesis failure is reported, not printed into the void")
    func synthesisFailureIsSurfaced() throws {
        let src = try Self.source()
        guard let start = src.range(of: "private func handleStreamError(") else {
            Issue.record("handleStreamError not found")
            return
        }
        let body = String(src[start.lowerBound...].prefix(600))

        // A `print` leaves the user with silence and nothing to send us. They cannot even tell
        // whether the app heard the click.
        #expect(
            !body.contains("print("),
            "a failure the user experiences as silence must be logged and surfaced, not printed"
        )
        #expect(body.contains("TTSLogger.service.error"))
        #expect(
            body.contains("modelState = .failed"),
            "surface the failure in the state the TTS UI already shows"
        )
    }
}

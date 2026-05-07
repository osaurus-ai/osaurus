//
//  TerminalDisplayViewTests.swift
//
//  Pin the streaming + completed-mode contracts for `TerminalDisplayView`:
//
//  Phase A — Streaming hot path (live mode):
//    1. enqueue + flush coalesce a chunk burst into a single layout
//       pass per RunLoop tick (perf-coalesce)
//    2. textStorage stays under the 1 MB cap with a single truncation
//       marker prepended on overflow (perf-text-cap)
//
//  Phase C — Tier-1 TUI:
//    3. `\r`-aware line tracker collapses progress redraws into a
//       single mutable trailing line (tui-line-tracker)
//    4. ANSI escapes get stripped before line tracking
//
//  Phase B — Completed-mode rendering:
//    5. completed snapshot binds without subscriptions, hides
//       [Terminate], renders snapshot through the same line tracker
//    6. completed mode adapts intrinsic height in [60, 140] pt
//    7. duration label respected when provided, hidden otherwise
//
//  Drives the view through the test-only `_test_*` API so we don't
//  need a real LiveExecRegistry.Entry / Combine subscription.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct TerminalDisplayViewTests {

    // MARK: - Phase A: coalescing

    @Test @MainActor func chunkBurstCoalescesToSingleFlush() {
        let view = TerminalDisplayView()
        view._test_prepareForStreaming(theme: LightTheme())

        // 1k single-byte chunks all enqueued in the same synchronous
        // burst — should produce zero in-line flushes (everything
        // deferred) and exactly one flush when we drive it manually.
        for _ in 0 ..< 1_000 {
            view._test_enqueue(Data("a".utf8))
        }
        #expect(view._test_pendingChunkCount == 1_000)
        #expect(view._test_flushCount == 0)

        view._test_flushNow()

        #expect(view._test_pendingChunkCount == 0)
        #expect(view._test_flushCount == 1)
        // 1000 'a's in textStorage (no `\r` / `\n`, so all live tail).
        #expect(view._test_textStorageLength == 1_000)
        #expect(view._test_trailingLiveLineLength == 1_000)
    }

    @Test @MainActor func emptyEnqueueIsNoop() {
        let view = TerminalDisplayView()
        view._test_prepareForStreaming(theme: LightTheme())
        view._test_enqueue(Data())
        view._test_flushNow()
        #expect(view._test_flushCount == 0)
        #expect(view._test_textStorageLength == 0)
    }

    // MARK: - Phase A: text cap

    @Test @MainActor func textStorageCapAppliesHeadDropAndMarker() {
        let view = TerminalDisplayView()
        view._test_prepareForStreaming(theme: LightTheme())

        // Enqueue ~1.5 MB in 1 KB chunks of "x\n" so most lines commit
        // (no perpetual live tail). Without the cap this would push
        // textStorage to ~1.5 MB; with it we head-drop to ~750 KB-ish.
        let line = String(repeating: "x", count: 1023) + "\n"
        let oneKB = Data(line.utf8)
        let total = 1_500
        for _ in 0 ..< total {
            view._test_enqueue(oneKB)
        }
        view._test_flushNow()

        // After cap enforcement the storage MUST be ≤ 1 MB.
        #expect(view._test_textStorageLength <= TerminalStreamRenderer.textStorageCap)
        // And the truncation marker MUST appear exactly once.
        #expect(view._test_truncationMarkerInserted)
        let occurrences =
            view._test_textStorageString.components(
                separatedBy: TerminalStreamRenderer.truncationMarker
            ).count - 1
        #expect(occurrences == 1)
    }

    @Test @MainActor func capOnlyTriggersAfterOverflow() {
        let view = TerminalDisplayView()
        view._test_prepareForStreaming(theme: LightTheme())

        // Smallish payload — well under the cap; marker MUST NOT show.
        view._test_enqueue(Data("hello world\n".utf8))
        view._test_flushNow()
        #expect(!view._test_truncationMarkerInserted)
    }

    // MARK: - Phase C: line tracker integration

    @Test @MainActor func progressBarRedrawsCollapseInPlace() {
        let view = TerminalDisplayView()
        view._test_prepareForStreaming(theme: LightTheme())

        // pip-style frame burst with a final newline + a follow-up
        // committed line ("Installing collected packages: foo").
        view._test_enqueue(Data("Downloading 1%".utf8))
        view._test_enqueue(Data("\rDownloading 50%".utf8))
        view._test_enqueue(Data("\rDownloading 100%\n".utf8))
        view._test_enqueue(Data("Installing collected packages: foo\n".utf8))
        view._test_flushNow()

        let body = view._test_textStorageString
        // The intermediate "1%" / "50%" frames must NOT survive in
        // storage — only the final committed line + the next stable
        // line. This is the whole point of Tier-1 line tracking.
        #expect(body.contains("Downloading 100%"))
        #expect(!body.contains("Downloading 1%"))
        #expect(!body.contains("Downloading 50%"))
        #expect(body.contains("Installing collected packages: foo"))
        // Live tail is empty (final chunk ended with `\n`).
        #expect(view._test_trailingLiveLineLength == 0)
    }

    @Test @MainActor func trailingLiveLineTracksMostRecentFrame() {
        let view = TerminalDisplayView()
        view._test_prepareForStreaming(theme: LightTheme())

        // No terminating `\n` — the live tail should contain the last
        // frame and `trailingLiveLineLength` should match its length.
        view._test_enqueue(Data("step 1\nworking".utf8))
        view._test_flushNow()
        #expect(view._test_trailingLiveLineLength == "working".utf16.count)

        // A second flush with another `\r` overwrite should REPLACE
        // (not stack with) the previous tail. Total tail length now
        // equals only "done".
        view._test_enqueue(Data("\rdone".utf8))
        view._test_flushNow()
        #expect(view._test_trailingLiveLineLength == "done".utf16.count)

        let body = view._test_textStorageString
        #expect(body.contains("step 1"))
        #expect(body.hasSuffix("done"))
        #expect(!body.contains("working"))
    }

    @Test @MainActor func ansiSequencesAreStrippedBeforeTracking() {
        let view = TerminalDisplayView()
        view._test_prepareForStreaming(theme: LightTheme())

        // Coloured progress bar: SGR escapes around "12%" / "50%",
        // then `\r` overwrites. After ANSI strip + tracker, body
        // should contain the final coloured-but-stripped frame.
        view._test_enqueue(Data("\u{1B}[33m12%\u{1B}[0m".utf8))
        view._test_enqueue(Data("\r\u{1B}[33m50%\u{1B}[0m".utf8))
        view._test_enqueue(Data("\rdone\n".utf8))
        view._test_flushNow()

        let body = view._test_textStorageString
        #expect(body.contains("done"))
        #expect(!body.contains("12%"))
        #expect(!body.contains("50%"))
        #expect(!body.contains("\u{1B}"))
    }

    // MARK: - Phase B: completed mode

    @Test @MainActor func completedModeRendersSnapshotAndHidesTerminate() {
        let view = TerminalDisplayView()
        let snapshot = TerminalSnapshot(
            command: "echo hello",
            output: Data("hello\n".utf8),
            exitCode: 0,
            killedByUser: false,
            duration: 1.5
        )
        view.bind(.completed(snapshot), theme: LightTheme())

        let body = view._test_textStorageString
        #expect(body.contains("$ echo hello"))
        #expect(body.contains("hello"))
        #expect(view._test_terminateHidden)
        // Status pill = "exited" for exit 0.
        #expect(view._test_statusLabelString == "exited")
        // Duration provided ⇒ label visible with formatted m:ss.
        #expect(!view._test_elapsedHidden)
        #expect(view._test_elapsedLabelString == "0:01")
    }

    @Test @MainActor func completedModeNonZeroExitShowsExitCode() {
        let view = TerminalDisplayView()
        let snapshot = TerminalSnapshot(
            command: "false",
            output: Data(),
            exitCode: 1
        )
        view.bind(.completed(snapshot), theme: LightTheme())
        #expect(view._test_statusLabelString == "exited (1)")
    }

    @Test @MainActor func completedModeKilledByUserShowsTerminatedLabel() {
        let view = TerminalDisplayView()
        let snapshot = TerminalSnapshot(
            command: "sleep 100",
            output: Data(),
            exitCode: -1,
            killedByUser: true
        )
        view.bind(.completed(snapshot), theme: LightTheme())
        #expect(view._test_statusLabelString == "terminated (user)")
    }

    @Test @MainActor func completedModeDurationOmittedWhenNil() {
        let view = TerminalDisplayView()
        let snapshot = TerminalSnapshot(
            command: "echo",
            output: Data(),
            exitCode: 0,
            duration: nil
        )
        view.bind(.completed(snapshot), theme: LightTheme())
        #expect(view._test_elapsedHidden)
    }

    @Test @MainActor func completedModeStripsPipefailWrapForPrompt() {
        let view = TerminalDisplayView()
        let snapshot = TerminalSnapshot(
            command: "set -o pipefail; ls -la",
            output: Data(),
            exitCode: 0
        )
        view.bind(.completed(snapshot), theme: LightTheme())
        let body = view._test_textStorageString
        // The wrap should be stripped from the displayed prompt.
        #expect(body.contains("$ ls -la"))
        #expect(!body.contains("set -o pipefail"))
    }

    @Test @MainActor func completedModeAppliesProgressCollapseFromSnapshot() {
        // Same snapshot rendering must run the line tracker so the
        // post-completion view matches what streamed live.
        let view = TerminalDisplayView()
        let raw = "Downloading 1%\rDownloading 50%\rDownloading 100%\nDone\n"
        let snapshot = TerminalSnapshot(
            command: "pip install foo",
            output: Data(raw.utf8),
            exitCode: 0
        )
        view.bind(.completed(snapshot), theme: LightTheme())
        let body = view._test_textStorageString
        #expect(body.contains("Downloading 100%"))
        #expect(!body.contains("Downloading 1%"))
        #expect(!body.contains("Downloading 50%"))
        #expect(body.contains("Done"))
    }

    // MARK: - Phase B: adaptive height

    @Test @MainActor func completedModeAdaptiveHeightShrinksForShortOutput() {
        let view = TerminalDisplayView()
        let snapshot = TerminalSnapshot(
            command: "echo hi",
            output: Data("hi\n".utf8),
            exitCode: 0
        )
        view.bind(.completed(snapshot), theme: LightTheme())
        let h = view._test_currentMeasuredHeight
        // Header (30) + min body (60) = 90; cap at header + max body
        // (140) = 170. A two-line body should land near the floor.
        #expect(h >= TerminalDisplayView.headerHeight + TerminalDisplayView.minCompletedBodyHeight)
        #expect(h <= TerminalDisplayView.headerHeight + TerminalDisplayView.maxBodyHeight)
        #expect(h < TerminalDisplayView.headerHeight + TerminalDisplayView.maxBodyHeight)
    }

    @Test @MainActor func completedModeAdaptiveHeightCapsForLongOutput() {
        let view = TerminalDisplayView()
        let many = String(repeating: "line\n", count: 100)
        let snapshot = TerminalSnapshot(
            command: "yes",
            output: Data(many.utf8),
            exitCode: 0
        )
        view.bind(.completed(snapshot), theme: LightTheme())
        let h = view._test_currentMeasuredHeight
        // 100 lines → comfortably past max body; should saturate at
        // header + maxBodyHeight.
        #expect(h == TerminalDisplayView.headerHeight + TerminalDisplayView.maxBodyHeight)
    }
}

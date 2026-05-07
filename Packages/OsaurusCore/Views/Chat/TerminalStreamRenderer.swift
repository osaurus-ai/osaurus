//
//  TerminalStreamRenderer.swift
//  osaurus
//
//  Streaming text pipeline for `TerminalDisplayView`. Owns the path
//  from raw process-output `Data` chunks → coalesced layout passes →
//  `\r`-aware line tracking → `NSTextStorage` mutations on a target
//  `NSTextView`. Pulled out of the view so:
//
//    1. The view focuses on AppKit chrome + bind lifecycle, not the
//       (small but distinct) state machine for buffered text rendering.
//    2. The streaming pipeline can be tested in isolation against any
//       `NSTextView` instance — no need for the full view chrome.
//
//  Two entry points:
//    - `enqueue(_:)` — buffers a chunk and schedules a coalesced flush
//      via `RunLoop.main.perform`. Multiple chunks per tick collapse
//      into a single textStorage mutation + layout pass.
//    - `renderSnapshot(_:)` — one-shot rendering for a completed
//      command. Same ANSI-strip + line-tracker pipeline applied to
//      the entire buffer in one pass.
//
//  Memory cap: textStorage is bounded at ~1 MB. On overflow we
//  head-drop ~25% and prepend a single truncation marker. The model
//  always gets the full unfiltered buffer via `LiveExecSink.bufferedSnapshot`,
//  so the cap is purely a UI concern.
//

import AppKit
import Foundation

@MainActor
final class TerminalStreamRenderer {

    // MARK: Public knobs

    /// AppKit memory cap. 1 MB of monospaced text is ~17k lines —
    /// well past any reasonable in-card scrollback.
    static let textStorageCap: Int = 1_000_000
    /// How many bytes to drop from the head when we hit the cap. ~25%
    /// so we don't trigger again on the very next chunk.
    private static let textStorageDropChunk: Int = 250_000
    static let truncationMarker: String = "\n--- output truncated, see final result ---\n\n"

    /// Target text view. Storage and layout calls go through this.
    let textView: NSTextView

    /// Attribute dicts the renderer applies when appending committed /
    /// live-tail text and the truncation marker. Owners (the view)
    /// recompute these on theme change and write them back.
    var bodyAttrs: [NSAttributedString.Key: Any]
    var markerAttrs: [NSAttributedString.Key: Any]

    /// Closure invoked at the tail of every flush so the owning view
    /// can decide whether to scroll to bottom (its scroll-tracking
    /// state machine lives there, not here).
    var stickyToBottom: () -> Bool = { true }

    // MARK: Private state

    private var pendingChunks: [Data] = []
    private var flushScheduled = false
    private var lineTracker = TerminalLineTracker()
    /// Number of UTF-16 code units in `textStorage` belonging to the
    /// trailing un-committed line. Set after each flush so the next
    /// flush can replace exactly those characters when the live line
    /// changes — no full storage rebuild.
    private var trailingLiveLineLength: Int = 0
    private var truncationMarkerInserted = false
    /// Per-instance counter of completed flush passes. Tests use this
    /// to confirm coalescing actually batches a chunk burst into one
    /// dequeue rather than per-chunk schedules.
    private(set) var flushCount: Int = 0

    // MARK: Init

    init(
        textView: NSTextView,
        bodyAttrs: [NSAttributedString.Key: Any],
        markerAttrs: [NSAttributedString.Key: Any]
    ) {
        self.textView = textView
        self.bodyAttrs = bodyAttrs
        self.markerAttrs = markerAttrs
    }

    // MARK: Public API

    /// Reset all streaming state. Owners call this on rebind so the
    /// next chunk burst starts from a clean slate.
    func reset() {
        pendingChunks.removeAll(keepingCapacity: false)
        flushScheduled = false
        lineTracker.reset()
        trailingLiveLineLength = 0
        truncationMarkerInserted = false
        flushCount = 0
    }

    /// Buffer a chunk and schedule a flush. Cheap — actual layout
    /// happens on the next RunLoop tick.
    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingChunks.append(data)
        scheduleFlush()
    }

    /// Drain `pendingChunks` and apply the line tracker + textStorage
    /// updates in one batched pass. Single layout pass per tick even
    /// if 1000 chunks arrived between schedule and run.
    func flushPendingChunks() {
        flushScheduled = false
        guard !pendingChunks.isEmpty else { return }
        flushCount &+= 1

        // One Data → one String → one ANSI strip pass for the whole
        // burst. Cheaper than per-chunk on chatty pipes.
        var combined = Data()
        let totalCount = pendingChunks.reduce(0) { $0 + $1.count }
        combined.reserveCapacity(totalCount)
        for chunk in pendingChunks { combined.append(chunk) }
        pendingChunks.removeAll(keepingCapacity: true)

        guard let asString = String(data: combined, encoding: .utf8) else {
            // Lossy mid-stream chunk — rare; the next chunk catches us up.
            return
        }
        let stripped = ANSIStripper.strip(asString)
        lineTracker.feed(stripped)

        applyLineTrackerToStorage()

        textView.needsDisplay = true
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        if stickyToBottom() {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// One-shot render of a completed command's full output buffer.
    /// Runs the same ANSI-strip + line-tracker pipeline so the post-
    /// completion view matches what the user saw streaming live.
    /// Caller is responsible for clearing `textView.textStorage` first
    /// (typically by calling `reset()` and then writing any prompt
    /// header) — this method only appends.
    func renderSnapshot(_ data: Data) {
        guard !data.isEmpty,
            let storage = textView.textStorage,
            let raw = String(data: data, encoding: .utf8)
        else { return }
        let stripped = ANSIStripper.strip(raw)
        let rendered = TerminalLineTracker.render(stripped)
        guard !rendered.isEmpty else { return }
        storage.append(NSAttributedString(string: rendered, attributes: bodyAttrs))
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.needsDisplay = true
    }

    // MARK: Private

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        // `RunLoop.main.perform` coalesces multiple schedules in the
        // same tick into a single dequeue. The closure isn't statically
        // MainActor-isolated even though it runs on main, so assume
        // isolation to call MainActor methods.
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPendingChunks()
            }
        }
    }

    /// Reflect the line tracker's current state into `textStorage`:
    ///   1. drop the previous trailing live line characters
    ///   2. append every newly committed line (each + "\n")
    ///   3. append the new trailing live line (no "\n")
    /// Then enforce the cap.
    private func applyLineTrackerToStorage() {
        guard let storage = textView.textStorage else { return }

        if trailingLiveLineLength > 0 {
            let total = storage.length
            let safeLen = min(trailingLiveLineLength, total)
            if safeLen > 0 {
                let range = NSRange(location: total - safeLen, length: safeLen)
                storage.deleteCharacters(in: range)
            }
            trailingLiveLineLength = 0
        }

        let committed = lineTracker.drainNewlyCommittedLines()
        if !committed.isEmpty {
            let joined = committed.joined(separator: "\n") + "\n"
            storage.append(NSAttributedString(string: joined, attributes: bodyAttrs))
        }

        let live = lineTracker.liveLine
        if !live.isEmpty {
            storage.append(NSAttributedString(string: live, attributes: bodyAttrs))
            trailingLiveLineLength = live.utf16.count
        }

        enforceTextStorageCap()
    }

    private func enforceTextStorageCap() {
        guard let storage = textView.textStorage else { return }
        let cap = Self.textStorageCap
        guard storage.length > cap else { return }

        // Drop enough from the head to land at `cap - dropChunk`
        // (~750 KB), so a single big burst doesn't slip past the cap
        // and a steady stream doesn't re-trigger on every chunk.
        let target = max(0, cap - Self.textStorageDropChunk)
        let dropAmount = min(storage.length - target, storage.length)
        if dropAmount > 0 {
            storage.deleteCharacters(in: NSRange(location: 0, length: dropAmount))
        }

        if !truncationMarkerInserted {
            let marker = NSAttributedString(
                string: Self.truncationMarker,
                attributes: markerAttrs
            )
            storage.insert(marker, at: 0)
            truncationMarkerInserted = true
        }
    }
}

// MARK: - Test hooks

extension TerminalStreamRenderer {
    var _test_pendingChunkCount: Int { pendingChunks.count }
    var _test_trailingLiveLineLength: Int { trailingLiveLineLength }
    var _test_truncationMarkerInserted: Bool { truncationMarkerInserted }
}

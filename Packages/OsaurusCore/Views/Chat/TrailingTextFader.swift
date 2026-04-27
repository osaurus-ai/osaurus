//
//  TrailingTextFader.swift
//  osaurus
//
//  Per chunk alpha overlay on a streaming NSTextView

import AppKit
import QuartzCore

@MainActor
final class TrailingTextFader {

    /// Time for one chunk to ramp from alpha 0 → 1.
    var fadeDuration: CFTimeInterval = 0.32

    /// If a single recorded append exceeds this, treat it as a full rebuild and
    /// don't animate (avoids a giant gradient on cache hits / width changes).
    private let appendAnimationCap = 64

    private weak var textView: NSTextView?
    /// Active fade ranges, oldest first. Indices refer to textStorage character offsets.
    private var fadeRanges: [(location: Int, length: Int, birth: CFTimeInterval)] = []
    private var timer: Timer?
    /// Last observed textStorage length for the bound textView. -1 means unbound.
    private var lastLength: Int = -1

    // MARK: - Public API

    /// Bind/refresh the bound textView's length silently — no fade. Use after a
    /// known full rebuild (width change, theme change) where chars didn't truly arrive.
    func resync(textView: NSTextView) {
        bindIfNeeded(textView)
        clearTempAttributes()
        fadeRanges.removeAll()
        lastLength = textView.textStorage?.length ?? 0
        stopTimer()
    }

    /// Diff against last observed length; animate the appended range. Call after
    /// each streaming textStorage edit.
    func recordAppend(textView: NSTextView) {
        let len = textView.textStorage?.length ?? 0
        if self.textView !== textView {
            // first time we see this textView, sync silently rather than fading
            // its full current contents (which would flash on view reuse).
            bindIfNeeded(textView)
            lastLength = len
            return
        }
        if len < lastLength {
            // truncation / regenerate — settle and resync
            clearTempAttributes()
            fadeRanges.removeAll()
            lastLength = len
            stopTimer()
            return
        }
        if len == lastLength { return }

        let appended = len - lastLength
        lastLength = len

        if appended > appendAnimationCap {
            // Big jump — likely a non-incremental rebuild. Don't animate.
            ChatPerfTrace.shared.count("fader.recordAppend.skipBigJump")
            ChatPerfTrace.shared.count("fader.recordAppend.skippedChars", appended)
            return
        }

        ChatPerfTrace.shared.count("fader.recordAppend.animated")
        ChatPerfTrace.shared.count("fader.recordAppend.animatedChars", appended)

        fadeRanges.append((location: len - appended, length: appended, birth: CACurrentMediaTime()))
        startTimerIfNeeded()
        applyAlpha(now: CACurrentMediaTime())
    }

    /// Settle any in-flight fades immediately. Call when streaming ends.
    func snap() {
        clearTempAttributes()
        fadeRanges.removeAll()
        if let tv = textView {
            lastLength = tv.textStorage?.length ?? 0
        }
        stopTimer()
    }

    /// Clear all state — the bound textView is going away.
    func reset() {
        clearTempAttributes()
        textView = nil
        lastLength = -1
        fadeRanges.removeAll()
        stopTimer()
    }

    // MARK: - Private

    private func bindIfNeeded(_ tv: NSTextView) {
        guard self.textView !== tv else { return }
        clearTempAttributes()
        self.textView = tv
        fadeRanges.removeAll()
        stopTimer()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // timer over CADisplayLink to avoid the
        // retain cycle that displayLink(target:) creates and to keep the fader
        // independent of NSView attachment state
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        ChatPerfTrace.shared.count("fader.tick")
        ChatPerfTrace.shared.time("fader.tick") {
            applyAlpha(now: CACurrentMediaTime())
        }
    }

    private func applyAlpha(now: CFTimeInterval) {
        guard let tv = textView,
              let lm = tv.layoutManager,
              let storage = tv.textStorage
        else {
            stopTimer()
            return
        }

        let storageLen = storage.length

        // drop ranges that have settled. Clear their temp attribute so the
        // base storage color shows through cleanly.
        var i = 0
        while i < fadeRanges.count {
            let r = fadeRanges[i]
            if now - r.birth >= fadeDuration {
                let nsr = clampRange(r.location, r.length, in: storageLen)
                if nsr.length > 0 {
                    lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: nsr)
                }
                fadeRanges.remove(at: i)
            } else {
                i += 1
            }
        }

        if fadeRanges.isEmpty {
            stopTimer()
            return
        }

        var attrWrites = 0
        for r in fadeRanges {
            let elapsed = now - r.birth
            let alpha = CGFloat(max(0.0, min(1.0, elapsed / fadeDuration)))
            let nsr = clampRange(r.location, r.length, in: storageLen)
            guard nsr.length > 0 else { continue }
            // preserve per-span colors (syntax highlights, links) by enumerating
            // the storage's foregroundColor and tinting each sub range
            storage.enumerateAttribute(.foregroundColor, in: nsr, options: []) { value, subRange, _ in
                let base = (value as? NSColor) ?? .labelColor
                lm.addTemporaryAttribute(
                    .foregroundColor,
                    value: base.withAlphaComponent(alpha),
                    forCharacterRange: subRange
                )
                attrWrites += 1
            }
        }
        ChatPerfTrace.shared.count("fader.activeRanges", fadeRanges.count)
        ChatPerfTrace.shared.count("fader.attrWrites", attrWrites)
    }

    private func clearTempAttributes() {
        guard let tv = textView,
              let lm = tv.layoutManager,
              let storage = tv.textStorage
        else { return }
        let full = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    }

    private func clampRange(_ loc: Int, _ len: Int, in total: Int) -> NSRange {
        let safeLoc = min(max(loc, 0), total)
        let safeLen = min(max(len, 0), total - safeLoc)
        return NSRange(location: safeLoc, length: safeLen)
    }
}

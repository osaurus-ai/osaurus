//
//  StreamDegenerationDetector.swift
//  osaurus
//
//  Live output guardrails for the streaming path: incremental degeneration
//  detection (abort) and template-leak detection (log-only), fed text deltas
//  by `GenerationEventMapper` as they stream.
//
//  The degeneration detector is an adaptation of the CLI gauntlet's
//  batch-mode `DegenerationDetector` (Packages/OsaurusCLI/Sources/
//  OsaurusCLICore/Commands/DegenerationDetector.swift). The two failure
//  modes seen in the wild are a single character repeated forever
//  (`!!!!!…`) and a short phrase looping (`idea idea idea…`), so both
//  detectors target exactly those shapes:
//
//    - a single non-whitespace character repeated consecutively past its
//      per-class threshold (`minCharacterRun` = 64 for letters/digits,
//      `minCharacterRunPunctuation` = 256 for punctuation/symbols), AND
//      only when the run has GROWN in at least
//      `minCharacterRunGrowthDeltas` (3) distinct deltas — a single-delta
//      paste of a long divider / base64 blob is never a decode loop;
//    - any n-gram of `minNGram`...`maxNGram` (3–12) whitespace-separated
//      tokens occurring `minConsecutiveRepeats` (12) or more times
//      back-to-back.
//
//  THRESHOLDS INTENTIONALLY DIVERGE from the CLI gauntlet's batch
//  detector: this detector ABORTS live user streams and therefore needs
//  anti-false-positive margins (markdown dividers, table padding, base64,
//  "print 100 !", "repeat this 10 times" must all pass), while the
//  gauntlet judges complete transcripts after the fact where a lower bar
//  costs nothing. Do not "re-sync" them.
//
//  "Token" here means a whitespace-separated word, not a model token: the
//  detector runs over streamed text and must not depend on any tokenizer.
//

import Foundation

/// Typed failure a guardrail throws to finish a mapped generation stream.
/// Callers get a real error instead of an endless stream of garbage.
///
/// Deliberately abort-only in this layer: automatic retry-with-safe-settings
/// needs caller-side design (which settings to change, how many attempts,
/// how to splice the retried stream) and is tracked as a follow-up.
public enum StreamGuardrailError: Error, Equatable {
    /// The stream degenerated into a repetition loop. `fragment` carries the
    /// human-readable evidence (the repeating fragment and its counts).
    case degeneration(fragment: String)
}

extension StreamGuardrailError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .degeneration(let fragment):
            return "Generation aborted: output degenerated into repetition (\(fragment))"
        }
    }
}

/// Per-stream guardrail switches, resolved once at stream start.
///
/// Both flags default to **true**: for degeneration, detect+abort is
/// strictly better than streaming unbounded garbage (a triggered stream was
/// already unusable — aborting only converts a hang into a typed failure);
/// for template leaks, detection is log-only and never mutates output, so
/// having it on costs nothing and feeds the capability ledger.
public struct StreamGuardrailSettings: Sendable {
    /// UserDefaults key: `Bool`, default true. Aborts a stream (with
    /// `StreamGuardrailError.degeneration`) when output starts looping.
    public static let degenerationDetectionKey = "ai.osaurus.guardrails.degenerationDetection"
    /// UserDefaults key: `Bool`, default true. Logs (never filters) leaked
    /// chat-template special tokens found in content deltas.
    public static let templateLeakDetectionKey = "ai.osaurus.guardrails.templateLeakDetection"

    public var degenerationDetection: Bool
    public var templateLeakDetection: Bool

    public init(degenerationDetection: Bool, templateLeakDetection: Bool) {
        self.degenerationDetection = degenerationDetection
        self.templateLeakDetection = templateLeakDetection
    }

    /// Read the flags, treating an absent key as ON (see type doc for why
    /// default-true). Injectable defaults for tests.
    public static func resolve(from defaults: UserDefaults = .standard) -> Self {
        Self(
            degenerationDetection: defaults.object(forKey: degenerationDetectionKey) as? Bool ?? true,
            templateLeakDetection: defaults.object(forKey: templateLeakDetectionKey) as? Bool ?? true
        )
    }
}

/// Incremental repetition detector for live streams. Feed it every text
/// delta (`.tokens` AND `.reasoning` — loops routinely start inside the
/// thinking channel); it returns evidence on the first delta at which the
/// accumulated text crosses a threshold, then latches (all later calls
/// return nil — the caller aborts the stream on first trigger anyway).
///
/// Thresholds intentionally DIVERGE from the CLI gauntlet's batch-mode
/// `DegenerationDetector`: streaming abort needs anti-false-positive
/// margins, the gauntlet judges whole transcripts (see the file header).
public struct StreamDegenerationDetector {
    /// Smallest and largest repeating unit considered, in whitespace tokens.
    public static let minNGram = 3
    public static let maxNGram = 12
    /// An n-gram must occur this many times back-to-back to count as a
    /// loop. 12 (vs the gauntlet's 8): the documented failure loops repeat
    /// hundreds of times, so detection stays fast, while a user's "repeat
    /// this 10 times" request streams through untouched.
    public static let minConsecutiveRepeats = 12
    /// A single LETTER or DIGIT repeated this many times consecutively is a
    /// loop (subject to the growth gate below). Whitespace never counts —
    /// indentation, table padding, and blank runs are always legitimate.
    public static let minCharacterRun = 64
    /// Punctuation/symbol runs need a higher bar: markdown dividers
    /// (`----`, `====`), box-drawing, and requested bursts ("print 100 !")
    /// are everyday shapes at 64–100 characters. A real decode loop blows
    /// far past 256 anyway.
    public static let minCharacterRunPunctuation = 256
    /// A run only triggers when it has GROWN in at least this many distinct
    /// `observe()` calls: a genuine loop dribbles out over many small
    /// decode deltas, while a single-delta paste of an arbitrarily long
    /// divider/base64 run is model-completed content, not a stuck decoder.
    public static let minCharacterRunGrowthDeltas = 3

    /// Per-class character-run threshold (see `minCharacterRun` /
    /// `minCharacterRunPunctuation`).
    static func characterRunThreshold(for character: Character) -> Int {
        (character.isLetter || character.isNumber)
            ? minCharacterRun
            : minCharacterRunPunctuation
    }

    /// Tail-buffer bound, in `Character`s. The largest window the n-gram
    /// rule ever needs is `maxNGram × minConsecutiveRepeats` = 144
    /// whitespace tokens; 4096 characters covers that window for tokens
    /// averaging up to ~28 characters (separator included) — well above the
    /// word/short-phrase loops seen in the wild — while keeping the
    /// per-delta rescan O(4 KB) no matter how long the stream runs.
    /// Character runs are tracked incrementally and are NOT bounded by this
    /// buffer. A loop of period ≤ 12 whose unit is longer than ~28 chars
    /// per token could escape the window; accepted as out of scope for this
    /// detector.
    public static let maxTailCharacters = 4096

    /// Accumulated recent text, trimmed to `maxTailCharacters` after each
    /// scan (scan-then-trim, so a single oversized delta is still scanned
    /// in full together with the previous tail).
    private var tail = ""
    /// Character-run state carried across delta boundaries so `!!!!…` split
    /// over many deltas is still caught.
    private var runCharacter: Character?
    private var runLength = 0
    /// Monotonic `observe()` call counter plus per-run growth accounting
    /// backing the ≥`minCharacterRunGrowthDeltas` gate: `runGrowthDeltas`
    /// counts the DISTINCT observe() calls that extended the current run,
    /// `lastGrowthCallIndex` dedupes growth within one delta.
    private var observeCallIndex = 0
    private var runGrowthDeltas = 0
    private var lastGrowthCallIndex = -1
    private var triggered = false

    /// Test hook: current tail size, to assert the bound holds under long
    /// clean streams.
    var tailCharacterCountForTesting: Int { tail.count }

    public init() {}

    /// Observe the next text delta. Returns the repeating-fragment evidence
    /// on first trigger, nil otherwise (including on every call after a
    /// trigger).
    public mutating func observe(_ delta: String) -> String? {
        guard !triggered, !delta.isEmpty else { return nil }

        observeCallIndex += 1
        if let evidence = updateCharacterRun(with: delta) {
            triggered = true
            return evidence
        }

        tail.append(delta)
        if let evidence = detectNGramLoop(in: tail) {
            triggered = true
            return evidence
        }
        trimTail()
        return nil
    }

    // MARK: - Character runs

    /// Advance the cross-delta run counter one character at a time and
    /// trigger the moment a run satisfies BOTH gates — checking only at
    /// delta end would miss a run that crosses its threshold mid-delta.
    ///
    /// Gates (anti-false-positive, see the type/file docs):
    ///   * whitespace is exempt entirely (indentation, table padding);
    ///   * per-class length threshold — 64 for letters/digits, 256 for
    ///     punctuation/symbols (dividers, requested `!` bursts);
    ///   * the run must have grown in ≥ `minCharacterRunGrowthDeltas`
    ///     distinct `observe()` calls, so a single-delta paste of a long
    ///     divider or base64 run never aborts while a decoder stuck
    ///     emitting the same character across many small deltas still does.
    private mutating func updateCharacterRun(with delta: String) -> String? {
        for character in delta {
            if character.isWhitespace {
                // Whitespace runs are always legitimate; also break any
                // tracked run so `!  !  !` never accumulates.
                runCharacter = nil
                runLength = 0
                runGrowthDeltas = 0
                lastGrowthCallIndex = -1
                continue
            }
            if character == runCharacter {
                runLength += 1
            } else {
                runCharacter = character
                runLength = 1
                runGrowthDeltas = 0
                lastGrowthCallIndex = -1
            }
            if lastGrowthCallIndex != observeCallIndex {
                lastGrowthCallIndex = observeCallIndex
                runGrowthDeltas += 1
            }
            if runGrowthDeltas >= Self.minCharacterRunGrowthDeltas,
                runLength >= Self.characterRunThreshold(for: character) {
                return
                    "character \"\(character)\" repeated \(runLength)x consecutively across \(runGrowthDeltas) deltas"
            }
        }
        return nil
    }

    // MARK: - N-gram loops

    /// Same algorithm as the CLI's `DegenerationDetector.detect`, applied to
    /// the bounded tail. A pure single-word loop (`idea idea …`) is caught
    /// by the 3-gram rule once it spans 24 words. The trailing (possibly
    /// incomplete) word counts as a token; that can only trigger one delta
    /// early on text that already looped `minConsecutiveRepeats − 1` full
    /// times, which is degenerate for practical purposes.
    private func detectNGramLoop(in text: String) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        for n in Self.minNGram...Self.maxNGram {
            // A loop of period n needs at least n × repeats tokens; larger
            // n needs strictly more, so once one n is impossible all are.
            guard tokens.count >= n * Self.minConsecutiveRepeats else { break }
            var start = 0
            while start + n * Self.minConsecutiveRepeats <= tokens.count {
                var occurrences = 1
                var next = start + n
                while next + n <= tokens.count,
                    Self.blocksEqual(tokens, start, next, length: n) {
                    occurrences += 1
                    next += n
                }
                if occurrences >= Self.minConsecutiveRepeats {
                    let fragment = tokens[start..<(start + n)].joined(separator: " ")
                    return "\(n)-token n-gram \"\(Self.truncated(fragment))\" repeated \(occurrences)x consecutively"
                }
                start += 1
            }
        }
        return nil
    }

    /// Keep the last `maxTailCharacters`, then drop through the first
    /// whitespace so the buffer always starts at a real token boundary — a
    /// truncated first word must not fabricate (or mask) an n-gram match.
    private mutating func trimTail() {
        guard tail.count > Self.maxTailCharacters else { return }
        var trimmed = tail.suffix(Self.maxTailCharacters)
        if let firstWhitespace = trimmed.firstIndex(where: \.isWhitespace) {
            trimmed = trimmed[trimmed.index(after: firstWhitespace)...]
        }
        tail = String(trimmed)
    }

    private static func blocksEqual(
        _ tokens: [Substring], _ a: Int, _ b: Int, length: Int
    ) -> Bool {
        for offset in 0..<length where tokens[a + offset] != tokens[b + offset] {
            return false
        }
        return true
    }

    private static func truncated(_ fragment: String, limit: Int = 80) -> String {
        fragment.count <= limit ? fragment : String(fragment.prefix(limit)) + "…"
    }
}

/// Detect-and-log ONLY: scans content (`.tokens`) deltas for chat-template
/// special tokens that should never reach user-visible output. A leaked
/// marker means the template-fallback path mismatched the model family —
/// that is data for the capability ledger, not something to hide by
/// filtering, so this detector never mutates the stream.
///
/// Fed `.tokens` deltas only, NOT `.reasoning` — the reasoning channel is
/// engine-internal and legitimately carries family markers.
public struct StreamTemplateLeakDetector {
    /// Exact leak list. `<think>` is deliberately EXCLUDED here (divergence
    /// from the CLI gauntlet's leak list): some families legitimately emit
    /// it in content on the fallback path and the engine owns
    /// reasoning-channel routing, so its presence in content is not by
    /// itself a template mismatch.
    public static let leakTokens: [String] = [
        "<|im_start|>",
        "<|im_end|>",
        "〈|EOS|〉",
        "<tool_call>",
        "]~!b[",
        "[e~[",
        "\u{FFFE}",  // sentinel char some templates use as an internal marker
    ]

    /// Carry one character less than the longest leak token so a token split
    /// across delta boundaries still matches once the rest arrives. This is
    /// the entire buffer — the detector never holds unbounded text.
    private static let carryCharacters: Int = (leakTokens.map(\.count).max() ?? 12) - 1

    private var tail = ""
    private var triggered = false

    public init() {}

    /// Observe the next CONTENT delta. Returns the leaked token on the first
    /// hit for this stream, nil otherwise (later hits stay silent — one log
    /// line per stream is enough signal).
    public mutating func observe(_ delta: String) -> String? {
        guard !triggered, !delta.isEmpty else { return nil }
        tail.append(delta)
        if let token = Self.leakTokens.first(where: { tail.contains($0) }) {
            triggered = true
            tail = ""
            return token
        }
        if tail.count > Self.carryCharacters {
            tail = String(tail.suffix(Self.carryCharacters))
        }
        return nil
    }
}

//
//  StreamRepetitionDetector.swift
//  OsaurusCore — Streaming
//
//  Detects a model that has collapsed into a phrase-repetition loop while
//  content is still streaming, so the turn can be cut instead of spending the
//  whole output budget on the same sentence.
//
//  osaurus#2439, turn 144: a single assistant turn contained roughly two
//  hundred repetitions of "Let me continue:" / "Let me continue with the
//  remaining documentation:" and nothing else. It ran to the output-token
//  ceiling, every token of it was streamed into the transcript, and the user
//  ("it keeps repeating its communications") sat through it. The sampler-side
//  `repetitionPenalty` cannot catch this: its window is at most a few dozen
//  tokens (`ModelRuntime.repetitionContextSizeWithPenalty`), while the
//  repeating unit here is a whole line that recurs hundreds of lines apart.
//
//  The bar is deliberately high. A false positive truncates a legitimate
//  answer mid-sentence, which is worse than a slow one, so a trip requires
//  many substantial repeats inside a short window.
//

import Foundation

/// Line-scale repetition detector fed incrementally from a content stream.
///
/// Not thread-safe; owned by a single stream consumer.
struct StreamRepetitionDetector {

    /// How many recent lines are considered.
    static let windowSize = 16
    /// Identical normalized lines within the window that constitute a loop.
    static let exactRepeatThreshold = 5
    /// Lines within the window sharing an opening phrase that constitute a
    /// loop. Higher than the exact threshold: an opening-phrase family is a
    /// weaker signal, and prose legitimately reuses sentence openings.
    static let prefixRepeatThreshold = 8
    /// Words compared when grouping lines into an opening-phrase family.
    static let prefixWordCount = 3
    /// Cap on an un-terminated line. Prose this long without a newline is
    /// never the short repeated phrase this looks for.
    static let maxPendingLineLength = 4096

    /// Shorter normalized lines are ignored. Repeated punctuation, closing
    /// braces, and table rules are ordinary content, not degeneration.
    static let minimumSignificantLength = 12

    /// True once a loop has been observed. Latches — a stream that has
    /// degenerated does not recover.
    private(set) var hasDetectedLoop = false

    /// The repeated text that tripped the detector, for the notice shown to
    /// the model.
    private(set) var repeatedPhrase: String?

    /// Normalized recent lines, most recent last, paired with whether the
    /// line was a list item.
    private var window: [(text: String, isListItem: Bool)] = []
    /// Characters not yet terminated by a line break.
    private var partialLine = ""
    /// Whether the stream is currently inside a fenced code block, where
    /// repeated identical lines are normal.
    private var insideCodeFence = false

    init() {}

    /// Feed the next chunk of streamed content. Safe to call with arbitrary
    /// chunk boundaries, including mid-line and mid-word.
    mutating func feed(_ chunk: String) {
        guard !hasDetectedLoop, !chunk.isEmpty else { return }
        for character in chunk {
            if character.isNewline {
                ingest(partialLine)
                partialLine = ""
                if hasDetectedLoop { return }
            } else {
                partialLine.append(character)
                // A "line" this long is not a repeated announcement, and
                // holding it duplicates content the turn already stores. A
                // newline-free response would otherwise grow this buffer to
                // the size of the whole answer.
                if partialLine.count > Self.maxPendingLineLength {
                    partialLine.removeAll(keepingCapacity: true)
                }
            }
        }
        // A model looping without newlines still separates its repeats with a
        // markdown rule ("Let me continue:---Let me continue:"). Treat a
        // completed rule as a line break so the loop is caught either way.
        if partialLine.hasSuffix("---") {
            ingest(String(partialLine.dropLast(3)))
            partialLine = ""
        }
    }

    private mutating func ingest(_ rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            insideCodeFence.toggle()
            return
        }
        guard !insideCodeFence else { return }

        let normalized = Self.normalize(trimmed)
        guard normalized.count >= Self.minimumSignificantLength else { return }

        window.append((normalized, Self.isListItem(trimmed)))
        if window.count > Self.windowSize {
            window.removeFirst(window.count - Self.windowSize)
        }

        var exactCounts: [String: Int] = [:]
        var prefixCounts: [String: Int] = [:]
        for line in window {
            exactCounts[line.text, default: 0] += 1
            // List items share an opening by construction ("- [ ] Write the
            // X document" repeated down a checklist), so the opening-phrase
            // family says nothing about them. Verbatim repetition still does.
            guard !line.isListItem else { continue }
            prefixCounts[Self.openingPhrase(of: line.text), default: 0] += 1
        }
        if let hit = exactCounts.first(where: { $0.value >= Self.exactRepeatThreshold }) {
            hasDetectedLoop = true
            repeatedPhrase = hit.key
            return
        }
        if let hit = prefixCounts.first(where: { $0.value >= Self.prefixRepeatThreshold }) {
            hasDetectedLoop = true
            repeatedPhrase = hit.key
        }
    }

    /// Lowercase, collapse runs of whitespace, and drop surrounding
    /// punctuation, so "Let me continue:" and "Let me continue…" are one
    /// phrase rather than two.
    static func normalize(_ line: String) -> String {
        let lowered = line.lowercased()
        let words = lowered.split(whereSeparator: { $0.isWhitespace })
        let joined = words.joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?-—*_#>`"))
    }

    /// A markdown list item / checklist row / numbered step, identified from
    /// the raw trimmed line before normalization strips the marker.
    static func isListItem(_ trimmedLine: String) -> Bool {
        guard let first = trimmedLine.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            // Require the marker to be followed by a space, so an em-dash
            // opener or "**bold**" prose is not mistaken for a list.
            return trimmedLine.dropFirst().first == " "
        }
        if first.isNumber {
            let rest = trimmedLine.drop(while: { $0.isNumber })
            return rest.first == "." || rest.first == ")"
        }
        return false
    }

    /// The first `prefixWordCount` words of an already-normalized line.
    static func openingPhrase(of normalizedLine: String) -> String {
        normalizedLine
            .split(separator: " ")
            .prefix(prefixWordCount)
            .joined(separator: " ")
    }
}

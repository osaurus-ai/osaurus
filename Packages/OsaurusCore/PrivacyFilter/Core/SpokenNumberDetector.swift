//
//  SpokenNumberDetector.swift
//  osaurus
//
//  Numbers written as words, one digit at a time: "four one five five five
//  five zero one five five". Dictation and voice transcripts write a number
//  said aloud that way, and some people type it so, and the built-in
//  patterns, which look for digits, never saw it, so a phone or card number
//  said rather than typed went out unredacted.
//
//  Each run of digit words is read as its digits and put to the same
//  built-in patterns and presets that judge digits as typed: only what they
//  would flag is flagged, under the same switches, with its checksum and
//  length checks. The words themselves are what gets replaced.
//

import Foundation

extension RegexEntityDetector {

    /// Spans of `text` that are numbers read out digit by digit, which the
    /// active rules would flag were they written as digits.
    static func spokenNumberMatches(in text: String, ruleset: EffectiveRuleSet) -> [Match] {
        SpokenDigitRuns.find(in: text).compactMap { run in
            guard let judged = judge(run.digits, ruleset: ruleset) else { return nil }
            return Match(
                category: judged.category,
                original: String(text[run.range]),
                range: run.range,
                label: judged.label,
                validated: judged.validated
            )
        }
    }

    /// How the active rules see `digits`: a rule must match all of it, as a
    /// typed number would be matched whole.
    private static func judge(
        _ digits: String,
        ruleset: EffectiveRuleSet
    ) -> (category: EntityCategory, label: String?, validated: Bool)? {
        let whole = NSRange(location: 0, length: (digits as NSString).length)
        for pattern in ruleset.builtins where pattern.category == .phone || pattern.category == .accountNumber {
            guard let found = pattern.regex.firstMatch(in: digits, options: [], range: whole), found.range == whole,
                pattern.accepts(digits)
            else { continue }
            return (pattern.category, nil, false)
        }
        for rule in ruleset.presets + ruleset.customs {
            guard let found = rule.regex.firstMatch(in: digits, options: [], range: whole), found.range == whole,
                rule.accepts?(digits) ?? true
            else { continue }
            return (rule.category, rule.label, rule.validated)
        }
        return nil
    }
}

/// Runs of digits said one by one, with where each sits in the text.
enum SpokenDigitRuns {

    struct Run: Equatable {
        let range: Range<String.Index>
        let digits: String
    }

    /// Fewer than this is too short to be anything the rules would flag,
    /// and too likely to be ordinary words ("one or two").
    static let minimumDigits = 7

    private static let digitWords: [String: Character] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]
    // swiftlint:disable:next force_try
    private static let word = try! NSRegularExpression(pattern: #"[A-Za-z]+"#)

    static func find(in text: String) -> [Run] {
        let nsText = text as NSString
        let words: [(range: NSRange, text: String)] = word
            .matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { ($0.range, nsText.substring(with: $0.range).lowercased()) }

        var runs: [Run] = []
        var index = 0
        while index < words.count {
            var digits = ""
            var end = index
            var next = index
            while next < words.count {
                // Within a run, words are apart by spaces, commas or dashes only:
                // the pauses of a number read out, not a sentence's end.
                if next > index, !joins(nsText, from: words[next - 1].range, to: words[next].range) { break }
                let current = words[next].text
                if let digit = digitWords[current] {
                    digits.append(digit)
                    next += 1
                } else if current == "oh", !digits.isEmpty {
                    digits.append("0")
                    next += 1
                } else if current == "double" || current == "triple", next + 1 < words.count,
                    joins(nsText, from: words[next].range, to: words[next + 1].range),
                    let digit = digitWords[words[next + 1].text] ?? (words[next + 1].text == "oh" ? "0" : nil)
                {
                    digits.append(String(repeating: digit, count: current == "double" ? 2 : 3))
                    next += 2
                } else {
                    break
                }
                end = next
            }
            if digits.count >= minimumDigits,
                let range = Range(
                    NSRange(
                        location: words[index].range.location,
                        length: NSMaxRange(words[end - 1].range) - words[index].range.location
                    ),
                    in: text
                )
            {
                runs.append(Run(range: range, digits: digits))
                index = end
            } else {
                index += 1
            }
        }
        return runs
    }

    /// Whether only spaces, commas or dashes lie between two words.
    private static func joins(_ text: NSString, from left: NSRange, to right: NSRange) -> Bool {
        let gap = text.substring(with: NSRange(location: NSMaxRange(left), length: right.location - NSMaxRange(left)))
        return gap.allSatisfy { $0.isWhitespace || $0 == "," || $0 == "-" }
    }
}

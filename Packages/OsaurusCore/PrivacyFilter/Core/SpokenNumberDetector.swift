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
//  Email addresses said aloud ("john dot smith at example dot com") are read
//  the same way, and judged by the email rule.
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

// MARK: - Addresses said aloud

extension RegexEntityDetector {

    /// Spans of `text` that are email addresses said aloud ("john dot smith
    /// at example dot com"), which the email rule would flag written out.
    static func spokenEmailMatches(in text: String, ruleset: EffectiveRuleSet) -> [Match] {
        guard let email = ruleset.builtins.first(where: { $0.category == .email }) else { return [] }
        return SpokenEmails.find(in: text).compactMap { spoken in
            let written = spoken.address
            let whole = NSRange(location: 0, length: (written as NSString).length)
            guard let found = email.regex.firstMatch(in: written, options: [], range: whole), found.range == whole,
                email.accepts(written)
            else { return nil }
            return Match(category: .email, original: String(text[spoken.range]), range: spoken.range)
        }
    }
}

/// Email addresses said aloud, with where each sits and what it spells.
/// Only one ending in "dot" and a known ending (com, org, a country…), so
/// "at home" and "at noon" are never read as one; "underscore" and "dash"
/// or "hyphen" join the words either side.
enum SpokenEmails {

    struct Spoken: Equatable {
        let range: Range<String.Index>
        let address: String
    }

    static let endings = [
        "com", "org", "net", "io", "co", "edu", "gov", "me", "app", "dev", "ai", "info", "biz", "xyz", "tech",
        "us", "uk", "ca", "au", "de", "fr", "in", "jp", "nl", "es", "it", "se", "ch", "nz", "ie", "sg",
    ]

    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b([a-z0-9]+(?:\s+(?:dot|underscore|dash|hyphen)\s+[a-z0-9]+)*)\s+at\s+"#
            + #"([a-z0-9]+(?:\s+(?:dot|dash|hyphen)\s+[a-z0-9]+)*\s+dot\s+(?:"#
            + endings.joined(separator: "|") + #"))\b"#,
        options: [.caseInsensitive]
    )

    static func find(in text: String) -> [Spoken] {
        let nsText = text as NSString
        let whole = NSRange(location: 0, length: nsText.length)
        // Forms whose domain is not said word by word count only in a
        // sentence about email, or with a name said with "dot" and the like:
        // "see the docs at example.com" is a website, not an address.
        let aboutEmail = Self.aboutEmail.firstMatch(in: text, range: whole) != nil
        var found: [Spoken] = []
        for (form, needsContext) in [(pattern, false), (writtenDomain, true), (gluedDomain, true)] {
            for match in form.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                let saidName = nsText.substring(with: match.range(at: 1))
                if needsContext, !aboutEmail, !saidName.contains(where: \.isWhitespace) { continue }
                var domain = written(nsText.substring(with: match.range(at: 2)))
                // The glued form's ending, given its dot back.
                if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound {
                    domain += "." + nsText.substring(with: match.range(at: 3)).lowercased()
                }
                // A name said plainly ("john smith at …") may be the address's
                // or just the person's: only the domain is certain, so only it
                // is the span, and the name is left to the name detection
                // rather than overlapping it, which dropped the name.
                let saidWithSeparators = saidName.contains(where: \.isWhitespace)
                let domainStart = match.range(at: 2).location
                let span =
                    saidWithSeparators
                    ? range
                    : Range(NSRange(location: domainStart, length: NSMaxRange(match.range) - domainStart), in: text)
                guard let span else { continue }
                found.append(Spoken(range: span, address: "\(written(saidName))@\(domain)"))
            }
        }
        return found
    }

    /// A domain already written ("john dot smith at example.com").
    // swiftlint:disable:next force_try
    private static let writtenDomain = try! NSRegularExpression(
        pattern: #"\b([a-z0-9]+(?:\s+(?:dot|underscore|dash|hyphen)\s+[a-z0-9]+)*)\s+at\s+"#
            + #"([a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:"# + endings.joined(separator: "|") + #"))\b"#,
        options: [.caseInsensitive]
    )

    /// The speech recogniser writes no punctuation and no "dot": "example
    /// dot com" comes out "examplecom". Only these endings are split off; the
    /// country ones end too many words ("radio", "welcome").
    static let gluedEndings = ["com", "org", "net", "edu", "gov"]

    // swiftlint:disable:next force_try
    private static let gluedDomain = try! NSRegularExpression(
        pattern: #"\b([a-z0-9]+(?:\s+(?:dot|underscore|dash|hyphen)\s+[a-z0-9]+)*)\s+at\s+"#
            + #"([a-z0-9]{2,}?)("# + gluedEndings.joined(separator: "|") + #")\b"#,
        options: [.caseInsensitive]
    )

    /// Words that make a sentence about email.
    // swiftlint:disable:next force_try
    private static let aboutEmail = try! NSRegularExpression(
        pattern: #"\b(?:e-?mail\w*|mail\w*|address\w*|send\w*|sent|writ\w*|reach\w*|contact\w*)\b"#,
        options: [.caseInsensitive]
    )

    /// "john dot smith" → "john.smith", lower case, no spaces.
    private static func written(_ said: String) -> String {
        said.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { word -> String in
                switch word {
                case "dot": return "."
                case "underscore": return "_"
                case "dash", "hyphen": return "-"
                default: return String(word)
                }
            }
            .joined()
    }
}

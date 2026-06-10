//
//  SecretScrubber.swift
//  osaurus
//
//  Post-exec stdout/stderr scrubbing for agent/plugin secrets.
//
//  Secrets are injected into sandbox exec environments as env vars, so a
//  trivial `echo $API_KEY` (or any program that prints its config) would
//  exfiltrate the value straight into the model's context — and from
//  there into transcripts, logs, and compaction summaries. Every exec
//  output path that ran with a secret-bearing environment must pass
//  through `scrub` before the text lands in a tool envelope.
//
//  Replacement is value-based, not pattern-based: we know the exact
//  secret strings we injected, so we replace exact occurrences with a
//  `[REDACTED:KEY]` marker that tells the model WHICH secret it tried
//  to print without revealing it.
//

import Foundation

enum SecretScrubber {
    /// Values shorter than this are never scrubbed: tiny strings
    /// ("1", "true", "dev") would false-positive all over ordinary
    /// output. A real credential below this length offers no security
    /// anyway.
    static let minimumValueLength = 6

    /// Replace every occurrence of each secret VALUE in `text` with
    /// `[REDACTED:<ENV_KEY>]`. Longer values are scrubbed first so a
    /// secret that happens to be a substring of another doesn't leave
    /// a partial tail behind.
    static func scrub(_ text: String, secrets: [String: String]) -> String {
        guard !text.isEmpty, !secrets.isEmpty else { return text }
        var result = text
        let ordered =
            secrets
            .filter { $0.value.count >= minimumValueLength }
            .sorted { $0.value.count > $1.value.count }
        for (key, value) in ordered where result.contains(value) {
            result = result.replacingOccurrences(of: value, with: "[REDACTED:\(key)]")
        }
        return result
    }
}

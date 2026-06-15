//
//  MarkdownLinkText.swift
//  osaurus
//
//  Renders a string containing markdown-style links `[label](url)` as inline,
//  tappable text. Links open in the user's default browser via
//  `NSWorkspace.shared.open` (the app-wide pattern); non-link text is shown
//  verbatim. Used for legal/disclosure copy that mixes plain text with Terms /
//  Privacy Policy links so the sentence wording stays localizable while the
//  URLs come from `OsaurusWebLinks`.
//

import AppKit
import SwiftUI

struct MarkdownLinkText: View {
    let markdown: String
    var font: Font = .system(size: 12)
    var textColor: Color = .secondary
    var linkColor: Color = .accentColor
    var alignment: TextAlignment = .leading

    var body: some View {
        renderedText
            .font(font)
            .foregroundColor(textColor)
            .multilineTextAlignment(alignment)
            .tint(linkColor)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    NSWorkspace.shared.open(url)
                    return .handled
                }
            )
    }

    private var renderedText: Text {
        if let attributed = Self.parseMarkdownLinks(markdown, linkColor: linkColor) {
            return Text(attributed)
        }
        return Text(markdown)
    }

    /// Parses markdown-style links `[text](url)` into an `AttributedString`,
    /// applying `linkColor` to each link run. Returns nil only if the regex
    /// itself cannot be built (never in practice).
    static func parseMarkdownLinks(_ input: String, linkColor: Color) -> AttributedString? {
        var result = AttributedString(input)

        let pattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, options: [], range: nsRange)

        // Process matches in reverse so earlier ranges stay valid as we splice.
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: input),
                let textRange = Range(match.range(at: 1), in: input),
                let urlRange = Range(match.range(at: 2), in: input),
                let url = URL(string: String(input[urlRange]))
            else {
                continue
            }

            let linkText = String(input[textRange])
            var linkString = AttributedString(linkText)
            linkString.foregroundColor = linkColor
            linkString.link = url

            if let attrRange = result.range(of: String(input[fullRange])) {
                result.replaceSubrange(attrRange, with: linkString)
            }
        }

        return result
    }
}

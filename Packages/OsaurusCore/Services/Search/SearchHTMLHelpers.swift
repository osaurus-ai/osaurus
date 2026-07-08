//
//  SearchHTMLHelpers.swift
//  osaurus
//
//  HTML parsing helpers for the native scraper backends and the Readability
//  extraction used by search_and_extract. Ported from the osaurus.search
//  plugin source.
//

import Foundation

enum SearchHTML {
    static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    static func decodeHTMLEntities(_ s: String) -> String {
        var result = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&#x27;", "'"), ("&#x2F;", "/"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);", options: []) {
            let nsResult = NSMutableString(string: result)
            let matches = regex.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result)
            ).reversed()
            for match in matches {
                guard let range = Range(match.range(at: 1), in: result) else { continue }
                let raw = String(result[range])
                let scalar: UInt32?
                if raw.hasPrefix("x") || raw.hasPrefix("X") {
                    scalar = UInt32(raw.dropFirst(), radix: 16)
                } else {
                    scalar = UInt32(raw)
                }
                if let s = scalar, let u = UnicodeScalar(s) {
                    nsResult.replaceCharacters(in: match.range, with: String(u))
                }
            }
            result = nsResult as String
        }
        return result
    }

    static func stripHTML(_ html: String) -> String {
        var t = html
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        return decodeHTMLEntities(t)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sourceDomain(of urlStr: String) -> String? {
        guard let u = URL(string: urlStr), let host = u.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// DDG often wraps result URLs with `?uddg=<encoded-url>`. Unwrap to the real target.
    static func unwrapDDG(_ url: String) -> String {
        guard url.contains("uddg="),
            let comp = URLComponents(string: url.hasPrefix("/") ? "https://duckduckgo.com\(url)" : url),
            let item = comp.queryItems?.first(where: { $0.name == "uddg" }),
            let value = item.value,
            let decoded = value.removingPercentEncoding
        else { return url }
        return decoded
    }

    /// First regex capture group in `s`, or nil.
    static func firstGroup(in s: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
            match.numberOfRanges > group,
            let range = Range(match.range(at: group), in: s)
        else { return nil }
        return String(s[range])
    }

    /// Slice HTML on the *opening* tag of any element whose class list contains
    /// `className` as a whitespace-delimited token (CSS-class semantics). Each
    /// returned chunk runs from one such opening tag up to (but not including)
    /// the next one — good enough for shallow search-result blocks.
    static func sliceByClass(_ html: String, className: String) -> [String] {
        let pattern = "<[a-zA-Z][a-zA-Z0-9]*\\s[^>]*class=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let nsr = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: nsr)
        if matches.isEmpty { return [] }

        let nsHtml = html as NSString
        var validStarts: [Int] = []
        for m in matches {
            let classAttrRange = m.range(at: 1)
            if classAttrRange.location == NSNotFound { continue }
            let classes = nsHtml.substring(with: classAttrRange)
                .split(whereSeparator: { $0.isWhitespace })
            if classes.contains(where: { $0 == Substring(className) }) {
                validStarts.append(m.range.location)
            }
        }
        if validStarts.isEmpty { return [] }
        var chunks: [String] = []
        for (i, start) in validStarts.enumerated() {
            let end = i + 1 < validStarts.count ? validStarts[i + 1] : nsHtml.length
            let len = end - start
            if len <= 0 { continue }
            chunks.append(nsHtml.substring(with: NSRange(location: start, length: len)))
        }
        return chunks
    }

    /// First `attr` value of a `tag` whose class list contains `className`.
    static func firstAttr(in html: String, tag: String, className: String, attr: String) -> String? {
        let cls = NSRegularExpression.escapedPattern(for: className)
        let attrEsc = NSRegularExpression.escapedPattern(for: attr)
        // Match either order: class=...href=... or href=...class=...
        let order1 =
            "<\(tag)\\b[^>]*class=\"[^\"]*\\b\(cls)\\b[^\"]*\"[^>]*\\b\(attrEsc)=\"([^\"]+)\""
        let order2 =
            "<\(tag)\\b[^>]*\\b\(attrEsc)=\"([^\"]+)\"[^>]*class=\"[^\"]*\\b\(cls)\\b"
        for pattern in [order1, order2] {
            if let v = firstGroup(in: html, pattern: pattern) { return v }
        }
        return nil
    }

    /// Inner-HTML of the first element whose class list contains `className`.
    static func firstInnerByClass(in html: String, className: String) -> String? {
        let cls = NSRegularExpression.escapedPattern(for: className)
        let pattern =
            "<([a-zA-Z][a-zA-Z0-9]*)\\b[^>]*class=\"[^\"]*\\b\(cls)\\b[^\"]*\"[^>]*>([\\s\\S]*?)</\\1>"
        return firstGroup(in: html, pattern: pattern, group: 2)
    }

    /// First http/https `href` value found anywhere in `html`.
    static func firstHrefStartingWithHttp(in html: String) -> String? {
        firstGroup(in: html, pattern: "href=\"(https?://[^\"]+)\"")
    }

    /// Detects anti-bot interstitials and other useless responses (e.g. very
    /// small bodies that only contain a captcha shell).
    static func isLikelyChallengePage(_ html: String) -> Bool {
        if html.count < 2048 { return true }
        let lc = html.lowercased()
        if lc.contains("captcha") || lc.contains("just a moment") || lc.contains("checking your browser") {
            return true
        }
        return false
    }

    static func metaContent(in s: String, name: String? = nil, property: String? = nil) -> String? {
        if let name {
            let pattern = "<meta[^>]*\\bname=[\"']\(name)[\"'][^>]*\\bcontent=[\"']([^\"']*)[\"']"
            if let v = firstGroup(in: s, pattern: pattern) { return decodeHTMLEntities(v) }
        }
        if let property {
            let pattern = "<meta[^>]*\\bproperty=[\"']\(property)[\"'][^>]*\\bcontent=[\"']([^\"']*)[\"']"
            if let v = firstGroup(in: s, pattern: pattern) { return decodeHTMLEntities(v) }
        }
        return nil
    }

    static func stripBlocks(_ html: String, tags: [String]) -> String {
        var out = html
        for tag in tags {
            if let regex = try? NSRegularExpression(
                pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
                options: .caseInsensitive
            ) {
                out = regex.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out), withTemplate: " ")
            }
        }
        return out
    }

    static func pickMainContainer(_ html: String) -> String? {
        for tag in ["article", "main"] {
            if let body = firstGroup(in: html, pattern: "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>"), !body.isEmpty {
                return body
            }
        }
        return firstGroup(in: html, pattern: "<body[^>]*>([\\s\\S]*?)</body>")
    }

    static func htmlToMarkdown(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<hr[^>]*>", with: "\n\n---\n\n", options: .regularExpression)
        let blocks: [(String, String, String)] = [
            ("h1", "\n\n# ", "\n\n"), ("h2", "\n\n## ", "\n\n"),
            ("h3", "\n\n### ", "\n\n"), ("h4", "\n\n#### ", "\n\n"),
            ("h5", "\n\n##### ", "\n\n"), ("h6", "\n\n###### ", "\n\n"),
            ("blockquote", "\n\n> ", "\n\n"),
            ("p", "\n\n", "\n\n"),
            ("li", "\n- ", ""),
        ]
        for (tag, prefix, suffix) in blocks {
            s = s.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>", with: prefix, options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "</\(tag)>", with: suffix, options: [.regularExpression, .caseInsensitive])
        }
        let inlines: [(String, String)] = [
            ("strong", "**"), ("b", "**"),
            ("em", "*"), ("i", "*"),
            ("code", "`"),
        ]
        for (tag, marker) in inlines {
            s = s.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>", with: marker, options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "</\(tag)>", with: marker, options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(
            of: "<pre\\b[^>]*>", with: "\n\n```\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</pre>", with: "\n```\n\n", options: [.regularExpression, .caseInsensitive])
        if let regex = try? NSRegularExpression(
            pattern: "<a\\s+[^>]*\\bhref=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            options: .caseInsensitive
        ) {
            let nsResult = NSMutableString(string: s)
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
            for match in matches {
                let href = (s as NSString).substring(with: match.range(at: 1))
                let text = (s as NSString).substring(with: match.range(at: 2))
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                nsResult.replaceCharacters(in: match.range, with: "[\(text)](\(href))")
            }
            s = nsResult as String
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeHTMLEntities(s)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

//
//  SearchHTMLHelpers.swift
//  osaurus
//
//  HTML parsing helpers for the native scraper backends and the Readability
//  extraction used by search_and_extract. Ported from the osaurus.search
//  plugin source.
//

import Darwin
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
    static func isLikelyChallengePage(_ html: String, treatShortAsChallenge: Bool = true) -> Bool {
        if treatShortAsChallenge && html.count < 2048 { return true }
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

    static func canonicalURL(in html: String, baseURL: URL? = nil) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<link\\b[^>]*>",
            options: .caseInsensitive
        ) else { return nil }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            let rel = firstAttr(inTag: tag, attr: "rel")?.lowercased() ?? ""
            guard rel.split(whereSeparator: { $0.isWhitespace }).contains("canonical") else { continue }
            guard let href = firstAttr(inTag: tag, attr: "href"), !href.isEmpty else { continue }
            if let baseURL, let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                let value = resolved.absoluteString
                return unsafeExtractionURLReason(value) == nil ? value : nil
            }
            return unsafeExtractionURLReason(href) == nil ? href : nil
        }
        return nil
    }

    private static func firstAttr(inTag tag: String, attr: String) -> String? {
        let attrEsc = NSRegularExpression.escapedPattern(for: attr)
        let pattern = "\\b\(attrEsc)=[\"']([^\"']+)[\"']"
        return firstGroup(in: tag, pattern: pattern)
    }

    static func unsafeExtractionURLReason(_ rawURL: String) -> String? {
        guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased() else {
            return "invalid URL is blocked"
        }
        guard scheme == "http" || scheme == "https" else {
            return "\(scheme) URLs are blocked"
        }
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return "missing host is blocked"
        }
        return blockedHostReason(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    static func resolvedUnsafeExtractionURLReason(_ rawURL: String) -> String? {
        if let blocked = unsafeExtractionURLReason(rawURL) {
            return blocked
        }
        guard let url = URL(string: rawURL), let host = url.host?.lowercased(), !host.isEmpty else {
            return "invalid URL is blocked"
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard isResolvableHostname(normalizedHost) else { return nil }
        return resolvedBlockedHostReason(normalizedHost, port: url.port)
    }

    private static func blockedHostReason(_ host: String) -> String? {
        if host == "localhost" || host == "ip6-localhost" || host == "ip6-loopback"
            || host.hasSuffix(".localhost") {
            return "localhost is blocked"
        }
        if let octets = parsedIPv4(host) {
            return blockedIPv4Reason(octets)
        }
        if let octets = parsedIPv6(host) {
            return blockedIPv6Reason(octets)
        }
        if host.contains(":") {
            return nil
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.count == 1, isNonCanonicalIPv4Literal(labels[0]) {
            return "non-canonical IPv4 literal is blocked"
        }
        guard labels.count == 4 else {
            return labels.allSatisfy { $0.allSatisfy(\.isNumber) }
                ? "non-canonical IPv4 literal is blocked"
                : nil
        }
        if labels.allSatisfy({ isCanonicalDecimalIPv4Octet($0) }) {
            return blockedIPv4Reason(labels.compactMap(UInt8.init))
        }
        return labels.allSatisfy { $0.allSatisfy(\.isNumber) }
            ? "non-canonical IPv4 literal is blocked"
            : nil
    }

    private static func isCanonicalDecimalIPv4Octet(_ label: String) -> Bool {
        guard !label.isEmpty, label.allSatisfy(\.isNumber) else { return false }
        guard label == "0" || !label.hasPrefix("0") else { return false }
        return UInt8(label) != nil
    }

    private static func isNonCanonicalIPv4Literal(_ host: String) -> Bool {
        host.allSatisfy(\.isNumber) || host.lowercased().hasPrefix("0x")
    }

    private static func parsedIPv4(_ host: String) -> [UInt8]? {
        var addr = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    private static func parsedIPv6(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    private static func blockedIPv6Reason(_ octets: [UInt8]) -> String? {
        guard octets.count == 16 else { return nil }
        if octets.allSatisfy({ $0 == 0 }) {
            return "unspecified IPv6 is blocked"
        }
        if octets.prefix(15).allSatisfy({ $0 == 0 }) && octets[15] == 1 {
            return "loopback IPv6 is blocked"
        }
        if octets[0] == 0xfe && (octets[1] & 0xc0) == 0x80 {
            return "link-local IPv6 is blocked"
        }
        if (octets[0] & 0xfe) == 0xfc {
            return "unique-local IPv6 is blocked"
        }
        if octets[0] == 0xff {
            return "multicast IPv6 is blocked"
        }
        if octets.prefix(10).allSatisfy({ $0 == 0 }) && octets[10] == 0xff && octets[11] == 0xff {
            let v4 = Array(octets[12...15])
            if let blocked = blockedIPv4Reason(v4) {
                return "IPv6-mapped \(blocked)"
            }
        }
        if octets.prefix(12).allSatisfy({ $0 == 0 }) {
            let v4 = Array(octets[12...15])
            if let blocked = blockedIPv4Reason(v4) {
                return "IPv6-compatible \(blocked)"
            }
        }
        return nil
    }

    private static func isResolvableHostname(_ host: String) -> Bool {
        guard parsedIPv4(host) == nil, parsedIPv6(host) == nil else { return false }
        guard !host.isEmpty else { return false }
        return host.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }

    private static func resolvedBlockedHostReason(_ host: String, port: Int?) -> String? {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let service = String(port ?? 443)
        let status = getaddrinfo(host, service, &hints, &result)
        guard status == 0, let result else { return nil }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor {
            if let blocked = blockedSockaddrReason(info.pointee.ai_addr) {
                return "resolved \(blocked)"
            }
            cursor = info.pointee.ai_next
        }
        return nil
    }

    private static func blockedSockaddrReason(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
        guard let address else { return nil }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                blockedIPv4Reason(withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) })
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                blockedIPv6Reason(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) })
            }
        default:
            return nil
        }
    }

    private static func blockedIPv4Reason(_ octets: [UInt8]) -> String? {
        guard octets.count == 4 else { return nil }
        let (a, b) = (octets[0], octets[1])
        if a == 127 { return "IPv4 loopback is blocked" }
        if a == 10 { return "RFC1918 10.0.0.0/8 is blocked" }
        if a == 172 && b >= 16 && b <= 31 { return "RFC1918 172.16.0.0/12 is blocked" }
        if a == 192 && b == 168 { return "RFC1918 192.168.0.0/16 is blocked" }
        if a == 0 { return "RFC1122 0.0.0.0/8 is blocked" }
        if a == 169 && b == 254 { return "link-local/cloud metadata is blocked" }
        if a == 100 && b >= 64 && b <= 127 { return "carrier-grade NAT is blocked" }
        if a >= 224 && a <= 239 { return "multicast is blocked" }
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

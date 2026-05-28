//
//  SSRFTighteningTests.swift
//  OsaurusCoreTests
//
//  Pins the additional SSRF cases added when the plugin authoring
//  surface was hardened: IPv4-mapped / IPv4-compatible IPv6 (the
//  classic blocklist-bypass tricks), IPv6 unique-local, carrier-grade
//  NAT, multicast, and the cloud-metadata diagnostic message.
//
//  The original `SSRFProtectionTests` covered the IPv4 blocklist; this
//  file complements it without duplicating that coverage.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SSRFTighteningTests {

    private func check(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return "bad url" }
        return PluginHostContext.checkSSRF(url: url)
    }

    private func redirectResponse(
        from urlString: String,
        status: Int = 302,
        location: String
    ) throws -> HTTPURLResponse {
        let url = try #require(URL(string: urlString))
        return try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Location": location]
            )
        )
    }

    // MARK: - IPv6-mapped IPv4 bypasses

    @Test func blocksIPv4MappedLoopback() {
        // `::ffff:127.0.0.1` is the canonical IPv4-mapped IPv6 form
        // of 127.0.0.1. Pre-fix, the IPv4 blocklist never ran against
        // this string and the request would go to loopback.
        let result = check("http://[::ffff:127.0.0.1]/")
        #expect(result != nil)
        #expect(result?.contains("loopback") == true)
    }

    @Test func blocksIPv4Mapped10Range() {
        let result = check("http://[::ffff:10.0.0.1]/")
        #expect(result != nil)
        #expect(result?.contains("RFC1918") == true)
    }

    @Test func blocksIPv4MappedMetadataIP() {
        let result = check("http://[::ffff:169.254.169.254]/latest/meta-data/")
        #expect(result != nil)
        #expect(
            result?.contains("link-local") == true || result?.contains("metadata") == true,
            "metadata IP message should be diagnosable, got: \(result ?? "nil")"
        )
    }

    @Test func blocksIPv4Compatible() {
        // `::a.b.c.d` (IPv4-compatible, deprecated but still parsed by
        // the network layer). Same blocklist applies.
        let result = check("http://[::127.0.0.1]/")
        #expect(result != nil)
    }

    // MARK: - IPv6 native ranges

    @Test func blocksIPv6Unspecified() {
        #expect(check("http://[::]/") != nil)
    }

    @Test func blocksIPv6UniqueLocalFc00() {
        // RFC 4193 fc00::/7 — both `fc` and `fd` prefixes.
        let resultFc = check("http://[fc00::1]/")
        #expect(resultFc != nil)
        #expect(resultFc?.contains("unique-local") == true)
    }

    @Test func blocksIPv6UniqueLocalFd00() {
        let resultFd = check("http://[fd12:3456:789a::1]/")
        #expect(resultFd != nil)
        #expect(resultFd?.contains("unique-local") == true)
    }

    @Test func ip6LocalhostHostnameIsBlocked() {
        // `ip6-localhost` and `ip6-loopback` show up in /etc/hosts on
        // some Linuxes; blocking them keeps cross-platform plugins
        // from accidentally relying on the hostname allowlist.
        #expect(check("http://ip6-localhost/") != nil)
        #expect(check("http://ip6-loopback/") != nil)
    }

    // MARK: - Additional IPv4 ranges

    @Test func blocksCarrierGradeNAT() {
        // 100.64.0.0/10 — RFC 6598 CGN. Frequently used in mobile /
        // ISP infrastructure, never publicly routable, easy to target
        // from a misconfigured plugin call.
        #expect(check("http://100.64.0.1/") != nil)
        #expect(check("http://100.127.255.255/") != nil)
        #expect(check("http://100.63.255.255/") == nil, "edge: 100.63 is public")
        #expect(check("http://100.128.0.1/") == nil, "edge: 100.128 is public")
    }

    @Test func blocksMulticast() {
        // 224.0.0.0/4 — class D multicast; not a valid HTTP target.
        #expect(check("http://224.0.0.1/") != nil)
        #expect(check("http://239.255.255.255/") != nil)
        #expect(check("http://240.0.0.1/") == nil, "edge: 240.0.0.1 is reserved but not multicast")
    }

    @Test func metadataIpMessageMentionsCloud() {
        // The 169.254.169.254 message should be diagnosable so an
        // operator reviewing logs sees "oh, plugin tried to hit the
        // metadata endpoint" rather than a generic "blocked".
        let result = check("http://169.254.169.254/latest/meta-data/")
        #expect(result != nil)
        #expect(
            result?.lowercased().contains("metadata") == true,
            "169.254.169.254 message should call out cloud metadata, got: \(result ?? "nil")"
        )
    }

    // MARK: - Redirect targets

    @Test func blocksRedirectToLoopback() throws {
        let original = try URLRequest(url: #require(URL(string: "https://api.example.com/start")))
        let response = try redirectResponse(from: "https://api.example.com/start", location: "http://127.0.0.1/admin")

        let redirect = PluginHostContext.checkedHTTPRedirectRequest(from: original, response: response)

        #expect(redirect.request == nil)
        #expect(redirect.ssrfError?.contains("loopback") == true)
    }

    @Test func blocksRedirectToCloudMetadata() throws {
        let original = try URLRequest(url: #require(URL(string: "https://api.example.com/start")))
        let response = try redirectResponse(
            from: "https://api.example.com/start",
            location: "http://169.254.169.254/latest/meta-data/"
        )

        let redirect = PluginHostContext.checkedHTTPRedirectRequest(from: original, response: response)

        #expect(redirect.request == nil)
        #expect(redirect.ssrfError?.lowercased().contains("metadata") == true)
    }

    @Test func followsRelativePublicRedirect() throws {
        var original = try URLRequest(url: #require(URL(string: "https://api.example.com/start")))
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let response = try redirectResponse(from: "https://api.example.com/start", location: "/v1/next")

        let redirect = PluginHostContext.checkedHTTPRedirectRequest(from: original, response: response)

        #expect(redirect.ssrfError == nil)
        #expect(redirect.request?.url?.absoluteString == "https://api.example.com/v1/next")
        #expect(redirect.request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func stripsCredentialsOnCrossOriginRedirect() throws {
        var original = try URLRequest(url: #require(URL(string: "https://api.example.com/start")))
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        original.setValue("session=secret", forHTTPHeaderField: "Cookie")
        let response = try redirectResponse(
            from: "https://api.example.com/start",
            location: "https://cdn.example.net/next"
        )

        let redirect = PluginHostContext.checkedHTTPRedirectRequest(from: original, response: response)

        #expect(redirect.ssrfError == nil)
        #expect(redirect.request?.url?.absoluteString == "https://cdn.example.net/next")
        #expect(redirect.request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(redirect.request?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func stripsCredentialsOnSameHostSchemeDowngrade() throws {
        var original = try URLRequest(url: #require(URL(string: "https://api.example.com/start")))
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let response = try redirectResponse(
            from: "https://api.example.com/start",
            location: "http://api.example.com/next"
        )

        let redirect = PluginHostContext.checkedHTTPRedirectRequest(from: original, response: response)

        #expect(redirect.ssrfError == nil)
        #expect(redirect.request?.url?.absoluteString == "http://api.example.com/next")
        #expect(redirect.request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Public addresses still pass

    @Test func publicIPv6PassesUnchanged() {
        // Native public IPv6 should not be caught by the new blocklist.
        // We picked an arbitrary global-unicast prefix.
        #expect(check("https://[2001:db8::1]/path") == nil)
    }

    @Test func publicIPv4StillPasses() {
        // Sanity that the new branches didn't accidentally widen the
        // IPv4 blocklist to public addresses.
        #expect(check("https://1.1.1.1/") == nil)
        #expect(check("https://8.8.8.8/") == nil)
    }
}

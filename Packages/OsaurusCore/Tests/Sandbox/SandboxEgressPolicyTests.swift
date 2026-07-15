//
//  SandboxEgressPolicyTests.swift
//
//  Unit coverage for the sandbox egress policy engine and the proxy's
//  pure helpers: mode resolution, allowlist matching (exact + wildcard),
//  IP-literal rejection, DNS-rebinding / private-range blocking, the
//  per-agent + plugin allowlist union, proxy target parsing, and
//  proxy-auth token extraction. All synchronous — no VM, no sockets.
//

import Foundation
import NIOHTTP1
import Testing

@testable import OsaurusCore

@Suite("Sandbox egress policy")
struct SandboxEgressPolicyTests {

    // MARK: - Mode resolution

    @Test func networkOffWinsOverDomains() {
        #expect(
            SandboxEgressPolicy.mode(networkEnabled: false, allowedDomains: ["example.com"])
                == .none
        )
    }

    @Test func emptyDomainsKeepsOpenMode() {
        #expect(SandboxEgressPolicy.mode(networkEnabled: true, allowedDomains: nil) == .open)
        #expect(SandboxEgressPolicy.mode(networkEnabled: true, allowedDomains: []) == .open)
        // Invalid-only lists normalize to empty → open, not a fake filter.
        #expect(
            SandboxEgressPolicy.mode(networkEnabled: true, allowedDomains: ["not a domain!!"])
                == .open
        )
    }

    @Test func validDomainsSelectAllowlistMode() {
        let mode = SandboxEgressPolicy.mode(
            networkEnabled: true,
            allowedDomains: [" API.GitHub.com ", "*.example.com", ""]
        )
        #expect(mode == .allowlist(["api.github.com", "*.example.com"]))
    }

    @Test func vmConfigMapping_failsClosedOnEmptyProxyList() {
        // "proxy" persisted with a broken/empty allowlist must not
        // silently open full egress.
        let broken = SandboxConfiguration(network: "proxy", allowedDomains: [])
        #expect(SandboxManager.egressMode(from: broken) == .none)

        let valid = SandboxConfiguration(network: "proxy", allowedDomains: ["example.com"])
        #expect(SandboxManager.egressMode(from: valid) == .allowlist(["example.com"]))

        #expect(SandboxManager.egressMode(from: SandboxConfiguration(network: "outbound")) == .open)
        #expect(SandboxManager.egressMode(from: SandboxConfiguration(network: "none")) == .none)
    }

    @Test func reconciledSettingsRoundTrip() {
        let proxy = SandboxManager.reconciledNetworkSettings(
            agentNetworkEnabled: true,
            allowedDomains: ["api.github.com"]
        )
        #expect(proxy.network == "proxy")
        #expect(proxy.allowedDomains == ["api.github.com"])

        let open = SandboxManager.reconciledNetworkSettings(
            agentNetworkEnabled: true,
            allowedDomains: nil
        )
        #expect(open.network == "outbound")
        #expect(open.allowedDomains == nil)

        let off = SandboxManager.reconciledNetworkSettings(
            agentNetworkEnabled: false,
            allowedDomains: ["api.github.com"]
        )
        #expect(off.network == "none")
    }

    // MARK: - Host matching

    @Test func exactAndWildcardMatching() {
        let allowlist = ["api.github.com", "*.example.com"]
        #expect(SandboxEgressPolicy.hostAllowed("api.github.com", allowlist: allowlist))
        #expect(SandboxEgressPolicy.hostAllowed("API.GITHUB.COM", allowlist: allowlist))
        #expect(SandboxEgressPolicy.hostAllowed("sub.example.com", allowlist: allowlist))
        #expect(SandboxEgressPolicy.hostAllowed("a.b.example.com", allowlist: allowlist))

        #expect(!SandboxEgressPolicy.hostAllowed("github.com", allowlist: allowlist))
        #expect(!SandboxEgressPolicy.hostAllowed("evil-api.github.com.attacker.io", allowlist: allowlist))
        // Wildcard does NOT match the apex.
        #expect(!SandboxEgressPolicy.hostAllowed("example.com", allowlist: allowlist))
        // Suffix trick: "notexample.com" must not match "*.example.com".
        #expect(!SandboxEgressPolicy.hostAllowed("notexample.com", allowlist: allowlist))
    }

    @Test func ipLiteralsAlwaysRejected() {
        let allowlist = ["example.com", "*.example.com"]
        #expect(!SandboxEgressPolicy.hostAllowed("93.184.216.34", allowlist: allowlist))
        #expect(!SandboxEgressPolicy.hostAllowed("[2606:2800:220:1::1]", allowlist: allowlist))
        #expect(!SandboxEgressPolicy.hostAllowed("127.0.0.1", allowlist: allowlist))
    }

    @Test func trailingDotNormalized() {
        #expect(SandboxEgressPolicy.hostAllowed("example.com.", allowlist: ["example.com"]))
    }

    // MARK: - Pattern validation

    @Test func patternValidation() {
        #expect(SandboxEgressPolicy.isValidPattern("example.com"))
        #expect(SandboxEgressPolicy.isValidPattern("*.example.com"))
        #expect(SandboxEgressPolicy.isValidPattern("api-v2.sub.example.co.uk"))

        #expect(!SandboxEgressPolicy.isValidPattern(""))
        #expect(!SandboxEgressPolicy.isValidPattern("*"))
        #expect(!SandboxEgressPolicy.isValidPattern("*.*.example.com"))
        #expect(!SandboxEgressPolicy.isValidPattern("localhost"))  // single label
        #expect(!SandboxEgressPolicy.isValidPattern("10.0.0.1"))  // IP literal
        #expect(!SandboxEgressPolicy.isValidPattern("exa mple.com"))
        #expect(!SandboxEgressPolicy.isValidPattern("-bad.example.com"))
    }

    // MARK: - Rebinding / private-range blocking

    @Test func blockedV4Ranges() {
        for addr in [
            "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1",
            "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
        ] {
            #expect(SandboxEgressPolicy.isBlockedAddress(addr), "expected \(addr) blocked")
        }
    }

    @Test func allowedPublicV4() {
        for addr in ["93.184.216.34", "8.8.8.8", "172.32.0.1", "100.128.0.1"] {
            #expect(!SandboxEgressPolicy.isBlockedAddress(addr), "expected \(addr) allowed")
        }
    }

    @Test func blockedV6Ranges() {
        for addr in ["::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:192.168.1.1"] {
            #expect(SandboxEgressPolicy.isBlockedAddress(addr), "expected \(addr) blocked")
        }
        #expect(!SandboxEgressPolicy.isBlockedAddress("2606:2800:220:1::1"))
        #expect(!SandboxEgressPolicy.isBlockedAddress("::ffff:8.8.8.8"))
    }

    @Test func garbageFailsClosed() {
        #expect(SandboxEgressPolicy.isBlockedAddress("not-an-address"))
        #expect(SandboxEgressPolicy.isBlockedAddress(""))
    }

    // MARK: - Per-agent + plugin union

    @Test func resolvedAllowlistUnionsPluginDeclarations() {
        let resolved = SandboxEgressPolicy.resolvedAllowlist(
            agentDomains: ["api.github.com"],
            pluginNetworkPermissions: [
                "api.open-meteo.com,archive-api.open-meteo.com",
                "outbound",  // contributes nothing
                "none",  // contributes nothing
                nil,
                "api.github.com",  // dedupe
            ]
        )
        #expect(
            resolved == [
                "api.github.com", "api.open-meteo.com", "archive-api.open-meteo.com",
            ]
        )
    }

    // MARK: - Proxy helpers

    @Test func connectTargetParsing() {
        let head = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "api.github.com:443")
        let target = SandboxEgressProxyHandler.parseTarget(head: head)
        #expect(target == .init(host: "api.github.com", port: 443, isConnect: true, originFormURI: ""))

        let noPort = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "api.github.com")
        #expect(SandboxEgressProxyHandler.parseTarget(head: noPort) == nil)

        let badPort = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "api.github.com:99999")
        #expect(SandboxEgressProxyHandler.parseTarget(head: badPort) == nil)
    }

    @Test func absoluteURITargetParsing() {
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "http://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/APKINDEX.tar.gz?x=1"
        )
        let target = SandboxEgressProxyHandler.parseTarget(head: head)
        #expect(target?.host == "dl-cdn.alpinelinux.org")
        #expect(target?.port == 80)
        #expect(target?.isConnect == false)
        #expect(target?.originFormURI == "/alpine/v3.20/main/x86_64/APKINDEX.tar.gz?x=1")

        // https absolute-URI through a proxy is a protocol error (TLS must
        // use CONNECT); origin-form GETs aren't proxy requests at all.
        let https = HTTPRequestHead(version: .http1_1, method: .GET, uri: "https://example.com/x")
        #expect(SandboxEgressProxyHandler.parseTarget(head: https) == nil)
        let originForm = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/path")
        #expect(SandboxEgressProxyHandler.parseTarget(head: originForm) == nil)
    }

    @Test func proxyTokenExtraction() {
        // curl's form for `http://tok:@proxy`: Basic base64("tok:")
        let basic = Data("my-token:".utf8).base64EncodedString()
        var headers = HTTPHeaders()
        headers.add(name: "Proxy-Authorization", value: "Basic \(basic)")
        #expect(SandboxEgressProxyHandler.extractProxyToken(headers: headers) == "my-token")

        var bearer = HTTPHeaders()
        bearer.add(name: "Proxy-Authorization", value: "Bearer my-token")
        #expect(SandboxEgressProxyHandler.extractProxyToken(headers: bearer) == "my-token")

        #expect(SandboxEgressProxyHandler.extractProxyToken(headers: HTTPHeaders()) == nil)
        var emptyBasic = HTTPHeaders()
        emptyBasic.add(
            name: "Proxy-Authorization",
            value: "Basic \(Data(":".utf8).base64EncodedString())"
        )
        #expect(SandboxEgressProxyHandler.extractProxyToken(headers: emptyBasic) == nil)
    }

    // MARK: - Plugin URL validation parity

    @Test func declaredHostsPermittedInPluginCommands() {
        var plugin = SandboxPlugin(
            name: "Weather",
            description: "d",
            setup: "pip install requests",
            tools: [
                SandboxToolSpec(
                    id: "now",
                    description: "d",
                    run: "curl https://api.open-meteo.com/v1/forecast"
                )
            ]
        )
        // Undeclared host → violation.
        #expect(!SandboxNetworkPolicy.validatePluginCommands(plugin).isEmpty)

        // Declared in permissions.network → allowed.
        plugin.permissions = SandboxPermissions(network: "api.open-meteo.com")
        #expect(SandboxNetworkPolicy.validatePluginCommands(plugin).isEmpty)
    }

    @Test func daemonCommandsAreValidatedToo() {
        var plugin = SandboxPlugin(name: "Daemon", description: "d")
        plugin.daemon = SandboxDaemonSpec(command: "python sync.py --url https://evil.example/x")
        #expect(!SandboxNetworkPolicy.validatePluginCommands(plugin).isEmpty)
    }
}

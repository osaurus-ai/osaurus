//
//  BonjourTests.swift
//  OsaurusCoreTests
//
//  Covers the Bonjour audit remediation: live TXT-record updates vs republish,
//  `osc`/address coupling in the advertised TXT, refusal of unverifiable
//  (osc-without-address) peers at pairing, the `.local` → resolved-IP connect
//  fallback, and the bounded browse/publish retry backoff.
//

import Darwin
import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Advertised TXT record + republish decision

@MainActor
struct BonjourAdvertiserTXTTests {
    @Test func txtRecord_omitsOscAndAddress_whenAddressless() {
        let agent = Agent(name: "Local")
        let fields = NetService.dictionary(fromTXTRecord: BonjourAdvertiser.txtRecord(for: agent))
        // An addressless agent cannot complete a handshake, so it must NOT
        // claim Secure Channel support.
        #expect(fields["osc"] == nil)
        #expect(fields["address"] == nil)
        #expect(fields["id"] != nil)
        #expect(fields["name"].flatMap { String(data: $0, encoding: .utf8) } == "Local")
    }

    @Test func txtRecord_includesOscAndAddress_whenAddressPresent() {
        let agent = Agent(name: "Local", agentAddress: "0xABCDEF")
        let fields = NetService.dictionary(fromTXTRecord: BonjourAdvertiser.txtRecord(for: agent))
        #expect(fields["osc"].flatMap { String(data: $0, encoding: .utf8) } == "1")
        #expect(fields["address"].flatMap { String(data: $0, encoding: .utf8) } == "0xABCDEF")
    }

    @Test func advertisementAction_publishesWhenNewOrNameChanged() {
        let txt = Data("a".utf8)
        #expect(
            BonjourAdvertiser.advertisementAction(
                hasService: false,
                requestedName: nil,
                publishedTXT: nil,
                newName: "N",
                newTXT: txt
            ) == .publish
        )
        #expect(
            BonjourAdvertiser.advertisementAction(
                hasService: true,
                requestedName: "Old",
                publishedTXT: txt,
                newName: "New",
                newTXT: txt
            ) == .publish
        )
    }

    @Test func advertisementAction_updatesTXTWhenOnlyPayloadChanged() {
        // The regression this guards: a description/address edit with an
        // unchanged instance name must reach the wire (update in place) rather
        // than be silently dropped.
        #expect(
            BonjourAdvertiser.advertisementAction(
                hasService: true,
                requestedName: "N",
                publishedTXT: Data("old".utf8),
                newName: "N",
                newTXT: Data("new".utf8)
            ) == .updateTXT
        )
    }

    @Test func advertisementAction_noneWhenUnchanged() {
        let txt = Data("same".utf8)
        #expect(
            BonjourAdvertiser.advertisementAction(
                hasService: true,
                requestedName: "N",
                publishedTXT: txt,
                newName: "N",
                newTXT: txt
            ) == .none
        )
    }

    @Test func publishRetryDelay_backsOffAndCaps() {
        #expect(BonjourAdvertiser.publishRetryDelay(attempt: 0) == 1)
        #expect(BonjourAdvertiser.publishRetryDelay(attempt: 1) == 2)
        #expect(BonjourAdvertiser.publishRetryDelay(attempt: 2) == 4)
        #expect(BonjourAdvertiser.publishRetryDelay(attempt: 10) == 30)  // capped
    }
}

// MARK: - DiscoveredAgent trust + connect helpers

struct DiscoveredAgentTrustTests {
    private func makeAgent(
        address: String? = nil,
        host: String? = "peer.local.",
        resolvedIP: String? = nil,
        osc: Bool = false
    ) -> DiscoveredAgent {
        DiscoveredAgent(
            id: UUID(),
            name: "Peer",
            agentDescription: "",
            address: address,
            host: host,
            resolvedIP: resolvedIP,
            port: 1234,
            supportsSecureChannel: osc,
            serviceName: "peer._osaurus._tcp."
        )
    }

    @Test func unverifiable_whenOscButNoAddress() {
        #expect(makeAgent(address: nil, osc: true).isUnverifiableSecureChannelPeer)
        #expect(makeAgent(address: "", osc: true).isUnverifiableSecureChannelPeer)
    }

    @Test func verifiable_whenOscWithAddress() {
        #expect(makeAgent(address: "0xabc", osc: true).isUnverifiableSecureChannelPeer == false)
    }

    @Test func legacy_noOscNoAddress_isAllowed() {
        // A genuine pre-Secure-Channel peer (plaintext) is not flagged.
        #expect(makeAgent(address: nil, osc: false).isUnverifiableSecureChannelPeer == false)
    }

    @Test func addressFingerprint_shortensLongAddressButKeepsShortAsIs() {
        let long = makeAgent(address: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18")
        let fp = try! #require(long.addressFingerprint)
        #expect(fp.hasPrefix("0x"))
        #expect(fp.contains("…"))
        #expect(fp.count < long.address!.count)

        #expect(makeAgent(address: "0x1234").addressFingerprint == "0x1234")
        #expect(makeAgent(address: nil).addressFingerprint == nil)
    }

    @Test func connectHost_prefersHostThenResolvedIP() {
        #expect(makeAgent(host: "mac.local.", resolvedIP: "10.0.0.5").connectHost == "mac.local.")
        #expect(makeAgent(host: nil, resolvedIP: "10.0.0.5").connectHost == "10.0.0.5")
        #expect(makeAgent(host: "", resolvedIP: "10.0.0.5").connectHost == "10.0.0.5")
        #expect(makeAgent(host: nil, resolvedIP: nil).connectHost == nil)
    }
}

// MARK: - BonjourBrowserCore pure helpers

struct BonjourBrowserCoreTests {
    private func ipv4Data(_ ip: String) -> Data {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1234).bigEndian
        _ = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        return withUnsafeBytes(of: addr) { Data($0) }
    }

    private func ipv6Data(_ ip: String) -> Data {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = UInt16(1234).bigEndian
        _ = ip.withCString { inet_pton(AF_INET6, $0, &addr.sin6_addr) }
        return withUnsafeBytes(of: addr) { Data($0) }
    }

    @Test func firstResolvedIP_returnsIPv4() {
        #expect(BonjourBrowserCore.firstResolvedIP(from: [ipv4Data("192.168.1.42")]) == "192.168.1.42")
    }

    @Test func firstResolvedIP_prefersIPv4OverIPv6() {
        let ip = BonjourBrowserCore.firstResolvedIP(from: [ipv6Data("2001:db8::1"), ipv4Data("10.0.0.5")])
        #expect(ip == "10.0.0.5")
    }

    @Test func firstResolvedIP_fallsBackToIPv6() {
        #expect(BonjourBrowserCore.firstResolvedIP(from: [ipv6Data("2001:db8::1")]) == "2001:db8::1")
    }

    @Test func firstResolvedIP_nilForEmptyOrNil() {
        #expect(BonjourBrowserCore.firstResolvedIP(from: nil) == nil)
        #expect(BonjourBrowserCore.firstResolvedIP(from: []) == nil)
    }

    @Test func searchRetryDelay_backsOffThenGivesUp() {
        #expect(BonjourBrowserCore.searchRetryDelay(attempt: 0) == 1)
        #expect(BonjourBrowserCore.searchRetryDelay(attempt: 1) == 2)
        #expect(BonjourBrowserCore.searchRetryDelay(attempt: 4) == 16)
        // Budget exhausted at maxSearchRetries.
        #expect(BonjourBrowserCore.searchRetryDelay(attempt: BonjourBrowserCore.maxSearchRetries) == nil)
    }
}

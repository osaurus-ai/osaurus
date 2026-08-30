//
//  GlobalProxyConfigurationLocalHostTests.swift
//  OsaurusNetworking
//

import XCTest

import OsaurusNetworking

final class GlobalProxyConfigurationLocalHostTests: XCTestCase {

    private func isRejectedAsUnsafeHost(_ urlString: String) -> Bool {
        do {
            _ = try GlobalProxyConfiguration(urlString: urlString)
            return false
        } catch let error as GlobalProxyConfiguration.ValidationError {
            if case .unsafeHost = error { return true }
            return false
        } catch {
            return false
        }
    }

    /// IPv4-mapped (`::ffff:a.b.c.d`) and IPv4-compatible (`::a.b.c.d`) IPv6
    /// forms address the very same machine-local endpoints as their IPv4 /
    /// plain-IPv6 spellings, so they must be rejected as unsafe proxy hosts
    /// too. Without decoding the embedded IPv4 the local-host guard only saw
    /// `0xff 0xff …` (mapped) or a non-`::1` low word (compatible) and let
    /// loopback / link-local addresses through.
    func testRejectsIPv4MappedAndCompatibleLocalHosts() {
        for url in [
            "http://[::ffff:127.0.0.1]:8080",  // IPv4-mapped loopback
            "http://[::ffff:169.254.1.1]:8080",  // IPv4-mapped link-local
            "http://[::127.0.0.1]:8080",  // IPv4-compatible loopback
        ] {
            XCTAssertTrue(
                isRejectedAsUnsafeHost(url),
                "\(url) is a machine-local endpoint and must be rejected as unsafe"
            )
        }
    }

    /// Regression guard: the plain spellings already worked and must keep
    /// being rejected.
    func testStillRejectsPlainLocalHosts() {
        for url in [
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
            "http://[fe80::1]:8080",
            "http://169.254.1.1:8080",
            "http://localhost:8080",
        ] {
            XCTAssertTrue(isRejectedAsUnsafeHost(url), "\(url) must remain rejected")
        }
    }

    /// Genuinely remote proxies — including a non-local IPv4-mapped address
    /// and a public IPv6 — must NOT be rejected.
    func testAcceptsRemoteHosts() {
        for url in [
            "http://proxy.example.com:8080",
            "http://8.8.8.8:8080",
            "http://[::ffff:8.8.8.8]:8080",  // IPv4-mapped, but public
            "http://[2606:4700:4700::1111]:8080",  // public IPv6
        ] {
            XCTAssertNoThrow(
                try GlobalProxyConfiguration(urlString: url),
                "\(url) is remote and must be accepted"
            )
        }
    }
}

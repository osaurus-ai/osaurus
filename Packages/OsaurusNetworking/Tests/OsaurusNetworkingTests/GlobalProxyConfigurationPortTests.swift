//
//  GlobalProxyConfigurationPortTests.swift
//  OsaurusNetworking
//

import XCTest

import OsaurusNetworking

final class GlobalProxyConfigurationPortTests: XCTestCase {

    /// `URLComponents` happily parses port 0 and ports above 65535, so without a
    /// range check the configuration accepted them and injected an invalid port
    /// into the CFNetwork proxy dictionary.
    func testRejectsZeroAndOutOfRangePorts() {
        for (url, expectedPort) in [
            ("http://proxy.example.com:0", 0),
            ("http://proxy.example.com:70000", 70000),
            ("http://proxy.example.com:99999", 99999),
        ] {
            XCTAssertThrowsError(try GlobalProxyConfiguration(urlString: url), "expected \(url) to be rejected") {
                error in
                XCTAssertEqual(
                    error as? GlobalProxyConfiguration.ValidationError,
                    .invalidPort(expectedPort),
                    "expected .invalidPort(\(expectedPort)) for \(url), got \(error)"
                )
            }
        }
    }

    /// Valid ports (including the 1 and 65535 boundaries) still construct.
    func testAcceptsInRangePorts() throws {
        for (url, expectedPort) in [
            ("http://proxy.example.com:1", 1),
            ("http://proxy.example.com:8080", 8080),
            ("socks://proxy.example.com:65535", 65535),
        ] {
            let config = try GlobalProxyConfiguration(urlString: url)
            XCTAssertEqual(config.port, expectedPort)
        }
    }
}

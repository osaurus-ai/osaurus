//
//  OsaurusCLITests.swift
//  osaurus
//
//  Unit tests for the Osaurus CLI core functionality.
//

import XCTest
@testable import OsaurusCLICore

final class OsaurusCLITests: XCTestCase {
    func testConfiguration() {
        // Just a smoke test to ensure things link
        let root = Configuration.toolsRootDirectory()
        XCTAssertFalse(root.path.isEmpty)
    }
}

//
//  ShellWhichTests.swift
//  osaurus
//
//  Covers `Shell.which`, used by the MCP bundle launcher to resolve a server
//  command to an absolute path (with a fallback to the bare command name).
//

import Foundation
import XCTest

@testable import OsaurusCLICore

final class ShellWhichTests: XCTestCase {

    /// A command that does not exist must resolve to nil, so the launcher takes
    /// its `cmdPath = cmdName` fallback instead of trying to exec an empty path.
    /// Previously `which` returned the empty stdout as `Optional("")`, ignoring
    /// `/usr/bin/which`'s non-zero exit status.
    func testWhichReturnsNilForNonexistentCommand() {
        let bogus = "osaurus-no-such-command-\(UUID().uuidString)"
        XCTAssertNil(Shell.which(bogus))
    }

    /// A real command on PATH must resolve to an absolute, executable path.
    func testWhichResolvesAnExecutableOnPath() throws {
        let resolved = try XCTUnwrap(Shell.which("ls"))
        XCTAssertTrue(resolved.hasPrefix("/"), "expected an absolute path, got \(resolved)")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: resolved),
            "expected \(resolved) to be executable"
        )
        XCTAssertEqual((resolved as NSString).lastPathComponent, "ls")
    }
}

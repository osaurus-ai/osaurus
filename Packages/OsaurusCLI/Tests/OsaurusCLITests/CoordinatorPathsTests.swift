import Foundation
import XCTest
@testable import OsaurusCLICore

final class CoordinatorPathsTests: XCTestCase {
    func testDefaultRootIsTmpOsaurusCoord() throws {
        let paths = try CoordinatorPaths.resolve(environment: [:])
        XCTAssertEqual(paths.root.path, "/tmp/osaurus-coord")
    }

    func testEnvironmentRootOverridesDefault() throws {
        let paths = try CoordinatorPaths.resolve(environment: ["OSAURUS_COORD_ROOT": "/tmp/custom-coord"])
        XCTAssertEqual(paths.root.path, "/tmp/custom-coord")
    }

    func testCliRootOverridesEnvironmentRoot() throws {
        let paths = try CoordinatorPaths.resolve(
            cliRoot: "/tmp/cli-coord",
            environment: ["OSAURUS_COORD_ROOT": "/tmp/env-coord"]
        )
        XCTAssertEqual(paths.root.path, "/tmp/cli-coord")
    }

    func testLockFileComponentEscapesPathSeparators() throws {
        let paths = try CoordinatorPaths(rootPath: "/tmp/coordinator-test")
        XCTAssertEqual(paths.lockFile(for: "Packages/Foo.swift").lastPathComponent, "Packages%2FFoo.swift.lock.json")
    }

    func testFileComponentEscapesDotSegments() {
        // "." and ".." would resolve to the current/parent directory and let a
        // name escape its container; they must be percent-encoded.
        XCTAssertEqual(CoordinatorPaths.fileComponent(for: ".."), "%2E%2E")
        XCTAssertEqual(CoordinatorPaths.fileComponent(for: "."), "%2E")
    }

    func testFileComponentLeavesDotsInsideNamesUntouched() {
        // A dot that is part of a longer name is safe and must pass through.
        XCTAssertEqual(CoordinatorPaths.fileComponent(for: "Foo.swift"), "Foo.swift")
        XCTAssertEqual(CoordinatorPaths.fileComponent(for: "v1.2.3"), "v1.2.3")
    }

    func testLaneDirectoryCannotEscapeLanesContainer() throws {
        let paths = try CoordinatorPaths(rootPath: "/tmp/coordinator-test")
        let lanes = paths.lanesDirectory.standardizedFileURL.path
        for lane in ["..", "."] {
            let dir = paths.laneDirectory(named: lane).standardizedFileURL.path
            XCTAssertTrue(
                dir.hasPrefix(lanes + "/"),
                "laneDirectory(named: \"\(lane)\") must stay strictly under lanes/, got \(dir)"
            )
        }
    }
}

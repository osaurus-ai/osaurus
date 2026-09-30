//
//  SemanticVersionTests.swift
//  OsaurusRepository
//
//  Precedence coverage for SemanticVersion, in particular the prerelease
//  ordering rules from Semantic Versioning 2.0.0 §11.4.
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class SemanticVersionTests: XCTestCase {

    private func sv(_ s: String) -> SemanticVersion {
        guard let v = SemanticVersion.parse(s) else {
            XCTFail("could not parse semver \(s)")
            return SemanticVersion(major: 0, minor: 0, patch: 0)
        }
        return v
    }

    /// Asserts every element is strictly less than every later element (and the
    /// reverse never holds), i.e. the list is a strict total order.
    private func assertStrictlyAscending(
        _ versions: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = versions.map(sv)
        for i in parsed.indices {
            for j in parsed.indices where j > i {
                XCTAssertTrue(
                    parsed[i] < parsed[j],
                    "\(versions[i]) should have lower precedence than \(versions[j])",
                    file: file,
                    line: line
                )
                XCTAssertFalse(
                    parsed[j] < parsed[i],
                    "\(versions[j]) should not have lower precedence than \(versions[i])",
                    file: file,
                    line: line
                )
            }
        }
    }

    /// The canonical precedence chain from SemVer 2.0.0 §11.4.
    func test_prereleasePrecedenceMatchesSemverSpecExample() {
        assertStrictlyAscending([
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ])
    }

    /// §11.4.4: a larger set of pre-release fields has higher precedence than a
    /// smaller set, when all preceding identifiers are equal. This is the case
    /// the old padding-based comparison inverted.
    func test_largerPrereleaseSetHasHigherPrecedence() {
        XCTAssertTrue(sv("1.0.0-alpha") < sv("1.0.0-alpha.1"))
        XCTAssertTrue(sv("1.0.0-beta") < sv("1.0.0-beta.2"))
        XCTAssertFalse(sv("1.0.0-alpha.1") < sv("1.0.0-alpha"))
    }

    /// §11.4.1: identifiers consisting of only digits compare numerically.
    func test_numericIdentifiersCompareNumerically() {
        XCTAssertTrue(sv("1.0.0-beta.2") < sv("1.0.0-beta.11"))
    }

    /// §11.3: a version with a prerelease has lower precedence than the same
    /// version without one.
    func test_prereleaseHasLowerPrecedenceThanRelease() {
        XCTAssertTrue(sv("1.0.0-rc.1") < sv("1.0.0"))
        XCTAssertFalse(sv("1.0.0") < sv("1.0.0-rc.1"))
    }
}

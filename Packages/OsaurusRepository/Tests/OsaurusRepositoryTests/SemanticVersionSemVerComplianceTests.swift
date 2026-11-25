//
//  SemanticVersionSemVerComplianceTests.swift
//  osaurus
//
//  Pins two SemVer-spec correctness properties of `SemanticVersion`:
//    - Comparable total order: build metadata must not break trichotomy
//      (SemVer §10), and `==` must agree with `<`.
//    - `parse` must reject empty prerelease / build identifiers (SemVer §9).
//

import XCTest

@testable import OsaurusRepository

final class SemanticVersionTotalOrderTests: XCTestCase {

    private func v(_ s: String) -> SemanticVersion { SemanticVersion.parse(s)! }

    // SemVer §10: build metadata MUST be ignored when determining precedence,
    // so two versions differing only in build metadata are equal.
    func testBuildMetadataDoesNotAffectEquality() {
        XCTAssertEqual(v("1.0.0+exp.sha.5114f85"), v("1.0.0+21AF26D3"))
        XCTAssertEqual(v("1.0.0"), v("1.0.0+meta"))
    }

    // The Comparable contract: for any two values exactly one of a<b, b<a,
    // a==b holds. With build metadata ignored, build-only differences are
    // equal — not the "none of the three holds" state the synthesized `==`
    // produced.
    func testTotalOrderHoldsForBuildMetadataDifference() {
        let a = v("1.0.0+exp.sha.5114f85")
        let b = v("1.0.0+21AF26D3")
        let trueCount = [a < b, b < a, a == b].filter { $0 }.count
        XCTAssertEqual(trueCount, 1, "exactly one of <, >, == must hold")
        XCTAssertTrue(a == b)
    }

    // `<` already treats numerically-equal prerelease identifiers (1 vs 01)
    // as equal precedence, so `==` must agree to preserve trichotomy.
    func testTotalOrderHoldsForNumericallyEqualPrerelease() {
        let a = v("1.0.0-alpha.1")
        let b = v("1.0.0-alpha.01")
        let trueCount = [a < b, b < a, a == b].filter { $0 }.count
        XCTAssertEqual(trueCount, 1)
        XCTAssertTrue(a == b)
    }

    // Equal values must hash equal so Set / Dictionary dedup correctly.
    func testEqualValuesHashEqualAndDedupInSet() {
        let set: Set<SemanticVersion> = [v("1.0.0+a"), v("1.0.0+b"), v("1.0.0")]
        XCTAssertEqual(set.count, 1)
    }

    // Equality is SemVer-precedence, not field-wise: build metadata is dropped
    // from `==` but preserved in `description` / Codable, so two equal values
    // can intentionally still render (and round-trip) to different strings.
    func testEqualValuesCanRenderDifferently() {
        let withBuild = v("1.0.0+a")
        let plain = v("1.0.0")
        XCTAssertEqual(withBuild, plain)
        XCTAssertNotEqual(withBuild.description, plain.description)
    }

    // Genuine ordering and inequality must be unaffected by the fix.
    func testOrderingAndInequalityUnaffected() {
        XCTAssertTrue(v("1.0.0") < v("2.0.0"))
        XCTAssertTrue(v("1.0.0-alpha") < v("1.0.0"))
        XCTAssertTrue(v("1.0.0-alpha.1") < v("1.0.0-alpha.2"))
        XCTAssertNotEqual(v("1.0.0"), v("1.0.1"))
        XCTAssertNotEqual(v("1.0.0-alpha"), v("1.0.0"))
    }
}

final class SemanticVersionParseValidationTests: XCTestCase {

    // SemVer §9: a prerelease section, when present, is a series of non-empty
    // dot-separated identifiers. `1.0.0-` is invalid — but the permissive
    // split accepted it as `prerelease == ""`, which renders as `1.0.0` yet
    // is unequal to and sorts below a real `1.0.0`.
    func testParseRejectsEmptyPrerelease() {
        XCTAssertNil(SemanticVersion.parse("1.0.0-"))
    }

    // Likewise `1.0.0+` (empty build) is invalid.
    func testParseRejectsEmptyBuild() {
        XCTAssertNil(SemanticVersion.parse("1.0.0+"))
    }

    // An empty inner identifier (`alpha..1`) is also invalid per §9.
    func testParseRejectsEmptyInnerPrereleaseIdentifier() {
        XCTAssertNil(SemanticVersion.parse("1.0.0-alpha..1"))
    }

    // Valid prerelease / build forms must still parse.
    func testParseStillAcceptsValidPrereleaseAndBuild() {
        XCTAssertNotNil(SemanticVersion.parse("1.0.0"))
        XCTAssertNotNil(SemanticVersion.parse("1.0.0-rc.1"))
        XCTAssertNotNil(SemanticVersion.parse("1.0.0+sha.abc"))
        XCTAssertNotNil(SemanticVersion.parse("1.0.0-alpha.1+build.7"))
    }
}

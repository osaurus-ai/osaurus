import Foundation
import XCTest
@testable import OsaurusCore

/// The exact typed parser used after direct/delegated local model selection.
final class Flux3KleinToolParameterTests: XCTestCase {
    private func parse(_ raw: String) throws -> ImageJobParams {
        try ImageTool.paramsForResolvedLocalModel(ImageJobParams(prompt: "combine", sourcePaths: []),
            argumentsJSON: raw, canonical: "flux3-image-klein", defaultGuidance: 1)
    }

    func testAllLegalSidesAndUncappedStepsSurviveDelegationParser() throws {
        for side in stride(from: 64, through: 4096, by: 16) {
            let result = try parse("{\"width\":\(side),\"height\":1008,\"steps\":101}")
            XCTAssertEqual(result.width, side)
            XCTAssertEqual(result.height, 1008)
            XCTAssertEqual(result.steps, 101)
        }
    }

    func testUnsizedEditKeepsTenOrderedReferencesAndNegativePrompt() throws {
        let paths = (1...10).map { "/tmp/ref-\($0).png" }
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: [
            "source_paths": paths, "negative_prompt": "accepted and ignored",
        ]), as: UTF8.self)
        let result = try parse(raw)
        XCTAssertEqual(result.sourcePaths, paths)
        XCTAssertTrue(result.isEdit)
        XCTAssertNil(result.width); XCTAssertNil(result.height); XCTAssertNil(result.steps)
        XCTAssertEqual(result.negativePrompt, "accepted and ignored")
    }

    func testSeedsIncludeZeroAndUInt64MaximumWithoutLoss() throws {
        for seed in [UInt64(0), 42, UInt64.max] {
            XCTAssertEqual(try parse("{\"seed\":\(seed)}").seed, seed)
            XCTAssertEqual(try parse("{\"seed\":\"\(seed)\"}").seed, seed)
        }
        for invalid in ["-1", "1.5", "18446744073709551616", "\"invalid\""] {
            XCTAssertThrowsError(try parse("{\"seed\":\(invalid)}"))
        }
    }

    func testIndependentSizeOverridesAndDefaults() throws {
        let width = try parse(#"{"source_paths":["/tmp/a.png"],"width":1008}"#)
        XCTAssertEqual(width.width, 1008); XCTAssertNil(width.height)
        let height = try parse(#"{"source_paths":["/tmp/a.png"],"height":1328}"#)
        XCTAssertNil(height.width); XCTAssertEqual(height.height, 1328)
        let defaults = try parse("{}")
        XCTAssertNil(defaults.width); XCTAssertNil(defaults.height); XCTAssertNil(defaults.steps)
        XCTAssertNil(defaults.guidance); XCTAssertNil(defaults.seed)
    }
}

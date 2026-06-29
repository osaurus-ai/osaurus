//
//  ShowCommandTests.swift
//  osaurus
//
//  Regression coverage for `ShowCommand.AnyCodableValue.intValue`: a model_info
//  number outside Int64 range must coerce to nil, not trap.
//

import Foundation
import XCTest

@testable import OsaurusCLICore

final class ShowCommandTests: XCTestCase {
    private func decodeValue(_ json: String) throws -> ShowCommand.AnyCodableValue {
        let values = try JSONDecoder().decode(
            [ShowCommand.AnyCodableValue].self,
            from: Data(json.utf8)
        )
        return values[0]
    }

    /// `/api/show` `model_info` can carry a JSON number larger than `Int64.max`.
    /// It decodes as `.double`, and the unguarded `Int(d)` conversion traps —
    /// aborting the whole CLI. `intValue` must return nil instead.
    func testIntValueReturnsNilForOutOfRangeDouble() throws {
        let value = try decodeValue("[99999999999999999999]")
        XCTAssertNil(
            value.intValue,
            "A double outside Int64 range must coerce to nil, not trap the process"
        )
    }

    /// In-range integers and doubles still coerce correctly (no over-correction).
    func testIntValuePreservesInRangeNumbers() throws {
        XCTAssertEqual(try decodeValue("[4096]").intValue, 4096)
        XCTAssertEqual(try decodeValue("[100.0]").intValue, 100)
    }
}

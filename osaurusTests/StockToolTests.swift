//
//  StockToolTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import osaurus

struct StockToolTests {

  @Test func execute_withEmptySymbol_returnsFailure() async throws {
    let tool = StockTool()
    let result = try await tool.execute(argumentsJSON: "{}")

    // Result is a summary line, newline, then JSON string. Validate summary prefix
    #expect(result.hasPrefix("Stock lookup failed:"))

    // Extract JSON payload after newline and validate fields
    if let newlineRange = result.range(of: "\n") {
      let jsonPart = String(result[newlineRange.upperBound...])
      if let data = jsonPart.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        #expect(obj["error"] != nil)
        #expect((obj["source"] as? String) == "yahoo")
      } else {
        // If JSON failed to parse, mark test as failed
        #expect(false)
      }
    } else {
      #expect(false)  // expected newline separator
    }
  }
}

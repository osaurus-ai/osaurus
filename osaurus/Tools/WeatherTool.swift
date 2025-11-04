//
//  WeatherTool.swift
//  osaurus
//
//  Deterministic, offline weather tool (Dinoki-style). No API keys.
//

import Foundation

struct WeatherTool: ChatTool {
  let name: String = "get_weather"
  let toolDescription: String = "Get current weather for a city (offline, approximate)."

  var parameters: JSONValue? {
    // Minimal JSON Schema-like structure (OpenAI compatible)
    return .object([
      "type": .string("object"),
      "properties": .object([
        "location": .object([
          "type": .string("string"),
          "description": .string("City name, e.g., San Francisco"),
        ]),
        "unit": .object([
          "type": .string("string"),
          "enum": .array([.string("celsius"), .string("fahrenheit")]),
          "description": .string("Temperature unit, defaults to celsius"),
        ]),
      ]),
      "required": .array([.string("location")]),
    ])
  }

  func execute(argumentsJSON: String) async throws -> String {
    let args =
      (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
    let locationRaw =
      (args["location"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let unitRaw = ((args["unit"] as? String) ?? "celsius").lowercased()
    let unit = (unitRaw == "fahrenheit") ? "fahrenheit" : "celsius"
    let location = locationRaw.isEmpty ? "San Francisco" : locationRaw

    // Deterministic pseudo-random values based on location + date
    let seed = Self.seed(from: location)
    var rng = LCG(seed: seed)
    let baseTempC = rng.nextRange(min: -5.0, max: 28.0)
    let dayOffset = Self.dayOfYear()
    let seasonal = sin((Double(dayOffset) / 365.0) * 2.0 * Double.pi) * 6.0
    let tempC = (baseTempC + seasonal).rounded()
    let humidity = Int(rng.nextRange(min: 25.0, max: 95.0).rounded())
    let windKph = (rng.nextRange(min: 0.0, max: 38.0) * 10).rounded() / 10
    let conditions = [
      "Sunny", "Partly Cloudy", "Cloudy", "Rain", "Windy", "Foggy", "Thunderstorms", "Snow",
    ]
    let condition = conditions[Int(abs(rng.nextInt()) % conditions.count)]

    let temperature: Double = unit == "fahrenheit" ? (tempC * 9.0 / 5.0 + 32.0) : tempC
    let tempRounded = (temperature * 10).rounded() / 10

    let payload: [String: Any] = [
      "location": location,
      "unit": unit,
      "temperature": tempRounded,
      "humidity": humidity,
      "wind_kph": windKph,
      "condition": condition,
      "source": "offline",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let json = String(data: data, encoding: .utf8) ?? "{}"

    let summary: String
    if unit == "fahrenheit" {
      summary =
        "Weather in \(location): \(Int(tempRounded))°F, \(condition), humidity \(humidity)%, wind \(windKph) kph."
    } else {
      summary =
        "Weather in \(location): \(Int(tempRounded))°C, \(condition), humidity \(humidity)%, wind \(windKph) kph."
    }

    return summary + "\n" + json
  }

  // MARK: - Helpers

  private static func seed(from text: String) -> UInt64 {
    let lower = text.lowercased()
    var hasher = Hasher()
    hasher.combine(lower)
    hasher.combine(dayOfYear())
    return UInt64(bitPattern: Int64(hasher.finalize()))
  }

  private static func dayOfYear() -> Int {
    let cal = Calendar(identifier: .gregorian)
    let today = Date()
    return cal.ordinality(of: .day, in: .year, for: today) ?? 1
  }

  private struct LCG {
    // Simple linear congruential generator
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &* 6_364_136_223_846_793_005 &+ 1 }
    mutating func next() -> UInt64 {
      state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
      return state
    }
    mutating func nextInt() -> Int { Int(truncatingIfNeeded: next()) }
    mutating func nextRange(min: Double, max: Double) -> Double {
      let v = Double(next() % 10_000) / 10_000.0
      return min + (max - min) * v
    }
  }
}

//
//  WeatherTool.swift
//  osaurus
//
//  Weather lookup tool using wttr.in API.
//

import Foundation

struct WeatherTool: ChatTool {
    let name: String = "get_weather"
    let toolDescription: String = "Get current weather for a city via wttr.in"

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
        let fallbackLocation = "San Francisco"
        let userLocation = locationRaw.isEmpty ? fallbackLocation : locationRaw

        // Build wttr.in URL
        let clean = userLocation.replacingOccurrences(of: " ", with: "+")
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return Self.failureResult(reason: "Invalid location", source: "wttr.in")
        }
        let urlString = "https://wttr.in/\(encoded)?format=j1"
        guard let url = URL(string: urlString) else {
            return Self.failureResult(reason: "Invalid URL", source: "wttr.in")
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Osaurus/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return Self.failureResult(reason: "Server returned an error", source: "wttr.in")
            }

            let decoder = JSONDecoder()
            let wttr = try decoder.decode(WttrResponse.self, from: data)
            guard let current = wttr.current_condition.first else {
                return Self.failureResult(reason: "Weather data unavailable", source: "wttr.in")
            }

            // Compose display location from nearest_area when available
            let displayLocation: String = {
                guard let area = wttr.nearest_area?.first else { return userLocation }
                let city = area.areaName?.first?.value ?? userLocation
                let region = area.region?.first?.value
                let country = area.country?.first?.value
                if let r = region, let c = country, !r.isEmpty, !c.isEmpty, r != city {
                    return "\(city), \(r), \(c)"
                } else if let c = country, !c.isEmpty {
                    return "\(city), \(c)"
                } else {
                    return city
                }
            }()

            // Extract condition and measurements
            let condition = current.weatherDesc?.first?.value ?? "Clear conditions"
            let humidity = Int(current.humidity) ?? 0
            let windKph = Double(current.windspeedKmph ?? "0") ?? 0.0

            // Select and round temperature based on unit
            let tempString = (unit == "fahrenheit") ? current.temp_F : current.temp_C
            let tempValue = Double(tempString) ?? 0.0
            let tempRounded = (tempValue * 10).rounded() / 10

            // Build JSON payload
            let payload: [String: Any] = [
                "location": displayLocation,
                "unit": unit,
                "temperature": tempRounded,
                "humidity": humidity,
                "wind_kph": windKph,
                "condition": condition,
                "source": "wttr.in",
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let json = String(data: jsonData, encoding: .utf8) ?? "{}"

            let summary: String
            if unit == "fahrenheit" {
                summary =
                    "Weather in \(displayLocation): \(Int(tempRounded))°F, \(condition), humidity \(humidity)%, wind \(windKph) kph."
            } else {
                summary =
                    "Weather in \(displayLocation): \(Int(tempRounded))°C, \(condition), humidity \(humidity)%, wind \(windKph) kph."
            }

            return summary + "\n" + json
        } catch {
            return Self.failureResult(reason: "\(error.localizedDescription)", source: "wttr.in")
        }
    }

    // MARK: - Helpers

    // wttr.in response models (minimal)
    private struct WttrResponse: Decodable {
        let current_condition: [Current]
        let nearest_area: [Area]?  // optional in case the API omits

        struct Current: Decodable {
            let temp_C: String
            let temp_F: String
            let humidity: String
            let windspeedKmph: String?
            let weatherDesc: [ValueHolder]?
        }

        struct Area: Decodable {
            let areaName: [ValueHolder]?
            let region: [ValueHolder]?
            let country: [ValueHolder]?
        }

        struct ValueHolder: Decodable { let value: String }
    }

    private static func failureResult(reason: String, source: String) -> String {
        let summary = "Weather lookup failed: \(reason)"
        let dict: [String: Any] = ["error": reason, "source": source]
        let data =
            (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return summary + "\n" + json
    }

}

//
//  WeatherTools.swift
//  osaurus
//
//  Built-in `weather_*` tools over WeatherKit. Accept `latitude`/`longitude`
//  or a `location` string (geocoded through CoreLocation). WeatherKit needs
//  the `com.apple.developer.weatherkit` entitlement provisioned on the App
//  ID; when it is missing the framework throws and every tool surfaces a
//  typed `unavailable` error instead of crashing or returning junk.
//

import CoreLocation
import Foundation
import WeatherKit

struct WeatherPlace: Codable, Sendable, Equatable {
    let name: String?
    let coordinate: GeoCoordinate
    let timeZone: String?
}

struct CurrentWeatherInfo: Codable, Sendable, Equatable {
    let asOf: String
    let condition: String
    let symbol: String
    let temperatureC: Double
    let temperatureF: Double
    let apparentTemperatureC: Double
    let humidity: Double
    let dewPointC: Double
    let pressureMb: Double
    let windSpeedKph: Double
    let windDirectionDegrees: Double
    let windGustKph: Double?
    let uvIndex: Int
    let visibilityKm: Double
    let cloudCover: Double
    let isDaylight: Bool
}

struct DailyForecastInfo: Codable, Sendable, Equatable {
    let date: String
    let condition: String
    let symbol: String
    let highC: Double
    let lowC: Double
    let highF: Double
    let lowF: Double
    let precipitationChance: Double
    let precipitationAmountMm: Double
    let snowfallAmountMm: Double
    let windSpeedKph: Double
    let uvIndex: Int
    let sunrise: String?
    let sunset: String?
}

struct HourlyForecastInfo: Codable, Sendable, Equatable {
    let time: String
    let condition: String
    let symbol: String
    let temperatureC: Double
    let temperatureF: Double
    let apparentTemperatureC: Double
    let precipitationChance: Double
    let precipitationAmountMm: Double
    let humidity: Double
    let windSpeedKph: Double
    let uvIndex: Int
    let isDaylight: Bool
}

protocol WeatherServicing: Sendable {
    func current(at coordinate: GeoCoordinate) async throws -> CurrentWeatherInfo
    func daily(at coordinate: GeoCoordinate, days: Int) async throws -> [DailyForecastInfo]
    func hourly(at coordinate: GeoCoordinate, hours: Int) async throws -> [HourlyForecastInfo]
}

final class WeatherKitService: WeatherServicing, @unchecked Sendable {
    private func location(_ c: GeoCoordinate) -> CLLocation { CLLocation(latitude: c.latitude, longitude: c.longitude) }

    static func mapError(_ error: Error) -> AppleToolError {
        let ns = error as NSError
        let text = error.localizedDescription
        let lowered = text.lowercased()
        if lowered.contains("entitlement") || lowered.contains("not authorized") || lowered.contains("unauthorized")
            || lowered.contains("401") || ns.domain.contains("WeatherDaemon") || ns.domain.contains("WeatherKit")
        {
            return .unavailable(
                "WeatherKit is not available for this build of Osaurus (the WeatherKit entitlement is not provisioned): \(text). Weather tools return this error until the capability is enabled for the Osaurus App ID.",
                retryable: false
            )
        }
        if ns.domain == NSURLErrorDomain {
            return .unavailable("Weather data could not be fetched (network): \(text)", retryable: true)
        }
        return .unavailable("Weather lookup failed: \(text)", retryable: true)
    }

    func current(at coordinate: GeoCoordinate) async throws -> CurrentWeatherInfo {
        do {
            let w = try await WeatherService.shared.weather(for: location(coordinate), including: .current)
            return CurrentWeatherInfo(
                asOf: AppleDateParsing.format(w.date),
                condition: w.condition.description, symbol: w.symbolName,
                temperatureC: w.temperature.converted(to: .celsius).value,
                temperatureF: w.temperature.converted(to: .fahrenheit).value,
                apparentTemperatureC: w.apparentTemperature.converted(to: .celsius).value,
                humidity: w.humidity, dewPointC: w.dewPoint.converted(to: .celsius).value,
                pressureMb: w.pressure.converted(to: .millibars).value,
                windSpeedKph: w.wind.speed.converted(to: .kilometersPerHour).value,
                windDirectionDegrees: w.wind.direction.converted(to: .degrees).value,
                windGustKph: w.wind.gust?.converted(to: .kilometersPerHour).value,
                uvIndex: w.uvIndex.value, visibilityKm: w.visibility.converted(to: .kilometers).value,
                cloudCover: w.cloudCover, isDaylight: w.isDaylight
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    func daily(at coordinate: GeoCoordinate, days: Int) async throws -> [DailyForecastInfo] {
        do {
            let forecast = try await WeatherService.shared.weather(for: location(coordinate), including: .daily)
            return forecast.forecast.prefix(days).map { d in
                DailyForecastInfo(
                    date: AppleDateParsing.format(d.date),
                    condition: d.condition.description, symbol: d.symbolName,
                    highC: d.highTemperature.converted(to: .celsius).value, lowC: d.lowTemperature.converted(to: .celsius).value,
                    highF: d.highTemperature.converted(to: .fahrenheit).value, lowF: d.lowTemperature.converted(to: .fahrenheit).value,
                    precipitationChance: d.precipitationChance,
                    precipitationAmountMm: d.precipitationAmount.converted(to: .millimeters).value,
                    snowfallAmountMm: d.snowfallAmount.converted(to: .millimeters).value,
                    windSpeedKph: d.wind.speed.converted(to: .kilometersPerHour).value,
                    uvIndex: d.uvIndex.value,
                    sunrise: d.sun.sunrise.map { AppleDateParsing.format($0) },
                    sunset: d.sun.sunset.map { AppleDateParsing.format($0) }
                )
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    func hourly(at coordinate: GeoCoordinate, hours: Int) async throws -> [HourlyForecastInfo] {
        do {
            let forecast = try await WeatherService.shared.weather(for: location(coordinate), including: .hourly)
            let now = Date().addingTimeInterval(-3600)
            return forecast.forecast.filter { $0.date >= now }.prefix(hours).map { h in
                HourlyForecastInfo(
                    time: AppleDateParsing.format(h.date),
                    condition: h.condition.description, symbol: h.symbolName,
                    temperatureC: h.temperature.converted(to: .celsius).value,
                    temperatureF: h.temperature.converted(to: .fahrenheit).value,
                    apparentTemperatureC: h.apparentTemperature.converted(to: .celsius).value,
                    precipitationChance: h.precipitationChance,
                    precipitationAmountMm: h.precipitationAmount.converted(to: .millimeters).value,
                    humidity: h.humidity, windSpeedKph: h.wind.speed.converted(to: .kilometersPerHour).value,
                    uvIndex: h.uvIndex.value, isDaylight: h.isDaylight
                )
            }
        } catch {
            throw Self.mapError(error)
        }
    }
}

// MARK: - Tools

enum WeatherToolFactory {
    static func makeTools(
        service: WeatherServicing = WeatherKitService(),
        geocoder: MapsServicing = MapKitMapsService()
    ) -> [OsaurusTool] {
        [
            WeatherCurrentTool(service: service, geocoder: geocoder),
            WeatherDailyTool(service: service, geocoder: geocoder),
            WeatherHourlyTool(service: service, geocoder: geocoder),
        ]
    }

    static var placeProperties: [String: JSONValue] {
        [
            "location": AppleSchema.string("Place name or address (geocoded). Use this OR latitude/longitude."),
            "latitude": AppleSchema.number("Latitude (with longitude)."),
            "longitude": AppleSchema.number("Longitude."),
        ]
    }

    /// Resolve coordinates from `latitude`/`longitude` or `location`.
    static func resolvePlace(_ args: [String: Any], geocoder: MapsServicing) async throws -> WeatherPlace {
        if let c = try MapsToolFactory.coordinate(args) {
            let name = try? await geocoder.reverseGeocode(c).first
            return WeatherPlace(name: name?.name ?? name?.city, coordinate: c, timeZone: name?.timeZone)
        }
        if let text = try AppleArgs.string(args, "location") {
            guard let place = try await geocoder.geocode(text, limit: 1).first else {
                throw AppleToolError.notFound("`location` (`\(text)`) could not be geocoded.")
            }
            return WeatherPlace(name: place.name ?? place.city ?? text, coordinate: place.coordinate, timeZone: place.timeZone)
        }
        throw AppleToolError.invalidArgs(
            "Provide `location` (a place name) or `latitude` + `longitude`.", field: "location",
            expected: "a place name, or numeric latitude/longitude"
        )
    }
}

final class WeatherCurrentTool: AppleToolBase, @unchecked Sendable {
    private let service: WeatherServicing
    private let geocoder: MapsServicing
    init(service: WeatherServicing, geocoder: MapsServicing) {
        self.service = service
        self.geocoder = geocoder
        super.init(
            app: .weather, name: "weather_current",
            description: "Current conditions (temperature in °C and °F, feels-like, humidity, wind, UV, visibility) for a place name or coordinates.",
            parameters: AppleSchema.object(WeatherToolFactory.placeProperties), isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let place = try await WeatherToolFactory.resolvePlace(args, geocoder: geocoder)
        return AppleToolPayload(["place": place, "current": try await service.current(at: place.coordinate)])
    }
}

final class WeatherDailyTool: AppleToolBase, @unchecked Sendable {
    private let service: WeatherServicing
    private let geocoder: MapsServicing
    init(service: WeatherServicing, geocoder: MapsServicing) {
        self.service = service
        self.geocoder = geocoder
        super.init(
            app: .weather, name: "weather_daily",
            description: "Daily forecast (highs/lows, condition, precipitation chance, sunrise/sunset) for up to 10 days.",
            parameters: AppleSchema.object(
                WeatherToolFactory.placeProperties.merging(["days": AppleSchema.integer("Number of days (default 7, max 10).")]) { _, n in n }
            ),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let place = try await WeatherToolFactory.resolvePlace(args, geocoder: geocoder)
        let days = min(max(try AppleArgs.int(args, "days") ?? 7, 1), 10)
        let forecast = try await service.daily(at: place.coordinate, days: days)
        return AppleToolPayload(["place": place, "days": forecast, "count": forecast.count])
    }
}

final class WeatherHourlyTool: AppleToolBase, @unchecked Sendable {
    private let service: WeatherServicing
    private let geocoder: MapsServicing
    init(service: WeatherServicing, geocoder: MapsServicing) {
        self.service = service
        self.geocoder = geocoder
        super.init(
            app: .weather, name: "weather_hourly",
            description: "Hour-by-hour forecast starting now (temperature, condition, precipitation chance, wind) for up to 48 hours.",
            parameters: AppleSchema.object(
                WeatherToolFactory.placeProperties.merging(["hours": AppleSchema.integer("Number of hours (default 12, max 48).")]) { _, n in n }
            ),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let place = try await WeatherToolFactory.resolvePlace(args, geocoder: geocoder)
        let hours = min(max(try AppleArgs.int(args, "hours") ?? 12, 1), 48)
        let forecast = try await service.hourly(at: place.coordinate, hours: hours)
        return AppleToolPayload(["place": place, "hours": forecast, "count": forecast.count])
    }
}

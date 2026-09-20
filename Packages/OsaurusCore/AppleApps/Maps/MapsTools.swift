//
//  MapsTools.swift
//  osaurus
//
//  Built-in `location_*` / `maps_*` tools (per-agent opt-in via `AppleApp.maps`).
//  Only `location_current` declares the Location permission requirement;
//  routing tools ask for it lazily when `from` is omitted.
//

import AppKit
import Foundation

enum MapsToolFactory {
    static func makeTools(service: MapsServicing = MapKitMapsService()) -> [OsaurusTool] {
        [
            LocationCurrentTool(service: service),
            LocationGeocodeTool(service: service),
            LocationReverseGeocodeTool(service: service),
            MapsSearchTool(service: service),
            MapsExploreTool(service: service),
            MapsDirectionsTool(service: service),
            MapsETATool(service: service),
            MapsOpenTool(service: service),
        ]
    }

    static let nearSchema = AppleSchema.nested(
        "Bias results around a point.",
        [
            "latitude": AppleSchema.number("Latitude."),
            "longitude": AppleSchema.number("Longitude."),
            "radius_meters": AppleSchema.number("Search radius in meters (default 2000, max 50000)."),
        ],
        required: ["latitude", "longitude"]
    )

    /// `driving` is what models say for `automobile`; accept it in the schema
    /// (not only in the parser) so the validator does not bounce the call.
    static func modeSchema(_ description: String, transit: Bool) -> JSONValue {
        var values = ["automobile", "driving", "walking", "cycling"]
        if transit { values.insert("transit", at: 3) }
        return AppleSchema.string(description, enum: values)
    }

    static func transportMode(_ args: [String: Any], transit: Bool) throws -> MapsTransportType {
        var allowed = ["automobile", "driving", "walking", "cycling"]
        if transit { allowed.append("transit") }
        let raw = try AppleArgs.enumeration(args, "mode", allowed: allowed, default: "automobile") ?? "automobile"
        return MapsTransportType(rawValue: raw == "driving" ? "automobile" : raw) ?? .automobile
    }

    static func coordinate(_ args: [String: Any], latKey: String = "latitude", lngKey: String = "longitude") throws -> GeoCoordinate? {
        let lat = try AppleArgs.double(args, latKey)
        let lng = try AppleArgs.double(args, lngKey)
        guard lat != nil || lng != nil else { return nil }
        guard let lat, let lng else {
            throw AppleToolError.invalidArgs("Provide both `\(latKey)` and `\(lngKey)`.", field: lat == nil ? latKey : lngKey)
        }
        guard (-90...90).contains(lat), (-180...180).contains(lng) else {
            throw AppleToolError.invalidArgs("Coordinates out of range: \(lat), \(lng).", field: latKey, expected: "lat −90…90, lng −180…180")
        }
        return GeoCoordinate(latitude: lat, longitude: lng)
    }

    static func nearRegion(_ args: [String: Any]) throws -> MapsSearchRegion? {
        guard let near = try AppleArgs.object(args, "near") else { return nil }
        guard let center = try coordinate(near) else {
            throw AppleToolError.invalidArgs("`near` needs `latitude` and `longitude`.", field: "near")
        }
        let radius = try AppleArgs.double(near, "radius_meters") ?? 2000
        return MapsSearchRegion(center: center, radiusMeters: min(max(radius, 50), 50_000))
    }

    /// `from` / `to` accept a string (address, place name) or `{latitude, longitude}`;
    /// a missing `from` means the current location.
    static func placeReference(_ args: [String: Any], _ key: String, allowCurrent: Bool) throws -> MapsPlaceReference {
        guard let raw = args[key], !(raw is NSNull) else {
            if allowCurrent { return .currentLocation }
            throw AppleToolError.invalidArgs("Missing required argument `\(key)`.", field: key, expected: "an address / place name or {latitude, longitude}")
        }
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.lowercased() == "current location" || t.lowercased() == "here" {
                if allowCurrent { return .currentLocation }
                throw AppleToolError.invalidArgs("`\(key)` must not be empty.", field: key)
            }
            // "lat,lng" strings are accepted too.
            let parts = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]) {
                return .coordinate(GeoCoordinate(latitude: lat, longitude: lng))
            }
            return .query(t)
        }
        if let d = raw as? [String: Any] {
            if let c = try coordinate(d) { return .coordinate(c) }
            // Models often echo a place from a previous result verbatim:
            // `{name, coordinate: {latitude, longitude}}`.
            if let nested = d["coordinate"] as? [String: Any], let c = try coordinate(nested) { return .coordinate(c) }
            if let q = (d["query"] as? String) ?? (d["address"] as? String) ?? (d["name"] as? String) { return .query(q) }
        }
        throw AppleToolError.invalidArgs("`\(key)` must be a string or {latitude, longitude}.", field: key)
    }

    /// A place is either free text (address, business name, or "lat,lng")
    /// or a `{latitude, longitude}` object. Both branches are declared so the
    /// schema validator accepts what `placeReference` already parses.
    static let placeSchema: JSONValue = .object([
        "description": .string(
            "An address or place name, \"lat,lng\", or {latitude, longitude}. Omit `from` (or say \"current location\") to start from where the Mac is now."
        ),
        "anyOf": .array([
            AppleSchema.string("Address, business name, or \"lat,lng\"."),
            AppleSchema.nested(
                "A place object: {latitude, longitude}, or a place from an earlier result ({name, address, coordinate}).",
                [
                    "latitude": AppleSchema.number("Latitude."),
                    "longitude": AppleSchema.number("Longitude."),
                    "coordinate": AppleSchema.nested(
                        "Coordinates.",
                        ["latitude": AppleSchema.number("Latitude."), "longitude": AppleSchema.number("Longitude.")]
                    ),
                    "name": AppleSchema.string("Place / business name."),
                    "address": AppleSchema.string("Street address."),
                    "query": AppleSchema.string("Free-text place lookup."),
                ]
            ),
        ]),
    ])
}

final class LocationCurrentTool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "location_current",
            description: "Get the Mac's current location (coordinates, accuracy, and the nearest address). macOS asks for Location access the first time.",
            parameters: AppleSchema.object([:]), isWrite: false, requirements: [.location]
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        AppleToolPayload(["location": try await service.currentLocation()])
    }
}

final class LocationGeocodeTool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "location_geocode",
            description: "Turn an address or place description into coordinates and a normalized address.",
            parameters: AppleSchema.object(
                ["address": AppleSchema.string("Address or place text."), "limit": AppleSchema.limit(default: 5, max: 20)],
                required: ["address"]
            ),
            isWrite: false, requirements: []
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let address = try AppleArgs.requiredString(args, "address", expected: "an address")
        let limit = try AppleArgs.limit(args, default: 5, max: 20)
        let places = try await service.geocode(address, limit: limit)
        return AppleToolPayload(["places": places, "count": places.count, "address": address])
    }
}

final class LocationReverseGeocodeTool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "location_reverse_geocode",
            description: "Turn coordinates into the nearest address / place.",
            parameters: AppleSchema.object(
                ["latitude": AppleSchema.number("Latitude."), "longitude": AppleSchema.number("Longitude.")],
                required: ["latitude", "longitude"]
            ),
            isWrite: false, requirements: []
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        guard let coordinate = try MapsToolFactory.coordinate(args) else {
            throw AppleToolError.invalidArgs("Provide `latitude` and `longitude`.", field: "latitude")
        }
        let places = try await service.reverseGeocode(coordinate)
        return AppleToolPayload(["places": places, "count": places.count, "coordinate": coordinate])
    }
}

final class MapsSearchTool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "maps_search",
            description: "Search Apple Maps for places by free text (\"coffee near Union Square\", a business name, an address). Optionally bias to a `near` point. Results include coordinates, address, phone, URL, and a `mapsURL` for maps_open.",
            parameters: AppleSchema.object(
                [
                    "query": AppleSchema.string("What to look for."),
                    "near": MapsToolFactory.nearSchema,
                    "limit": AppleSchema.limit(default: 10, max: 50),
                ],
                required: ["query"]
            ),
            isWrite: false, requirements: []
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let query = try AppleArgs.requiredString(args, "query", expected: "search text")
        let near = try MapsToolFactory.nearRegion(args)
        let limit = try AppleArgs.limit(args, default: 10, max: 50)
        let places = try await service.search(query, near: near, limit: limit)
        return AppleToolPayload(["places": places, "count": places.count, "query": query])
    }
}

final class MapsExploreTool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "maps_explore",
            description: "Find points of interest of one category around a point (e.g. restaurants, cafes, gas stations, parks, pharmacies).",
            parameters: AppleSchema.object(
                [
                    "category": AppleSchema.string("POI category.", enum: MapKitMapsService.poiCategories.keys.sorted()),
                    "near": MapsToolFactory.nearSchema,
                    "limit": AppleSchema.limit(default: 10, max: 50),
                ],
                required: ["category", "near"]
            ),
            isWrite: false, requirements: []
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let category = try AppleArgs.requiredString(args, "category", expected: "a POI category")
        guard let near = try MapsToolFactory.nearRegion(args) else {
            throw AppleToolError.invalidArgs("`near` with latitude/longitude is required.", field: "near")
        }
        let limit = try AppleArgs.limit(args, default: 10, max: 50)
        let places = try await service.explore(category: category, near: near, limit: limit)
        return AppleToolPayload(["places": places, "count": places.count, "category": category.lowercased()])
    }
}

final class MapsDirectionsTool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "maps_directions",
            description: "Turn-by-turn directions with distance and travel time. `mode`: automobile (default), walking, or cycling. Omit `from` to start from the current location (asks for Location access).",
            parameters: AppleSchema.object(
                [
                    "from": MapsToolFactory.placeSchema,
                    "to": MapsToolFactory.placeSchema,
                    "mode": MapsToolFactory.modeSchema("Transport mode: automobile/driving (default), walking, or cycling.", transit: false),
                    "alternatives": AppleSchema.boolean("Also return alternate routes (default false)."),
                ],
                required: ["to"]
            ),
            isWrite: false, requirements: []
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let from = try MapsToolFactory.placeReference(args, "from", allowCurrent: true)
        let to = try MapsToolFactory.placeReference(args, "to", allowCurrent: false)
        let mode = try MapsToolFactory.transportMode(args, transit: false)
        let alternatives = try AppleArgs.bool(args, "alternatives") ?? false
        let routes = try await service.directions(from: from, to: to, transport: mode, alternatives: alternatives)
        return AppleToolPayload(["routes": routes, "count": routes.count, "mode": mode.rawValue])
    }
}

final class MapsETATool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "maps_eta",
            description: "Estimated travel time and distance between two places, including `transit`. Omit `from` for the current location.",
            parameters: AppleSchema.object(
                [
                    "from": MapsToolFactory.placeSchema,
                    "to": MapsToolFactory.placeSchema,
                    "mode": MapsToolFactory.modeSchema("Transport mode: automobile/driving (default), walking, transit, or cycling.", transit: true),
                ],
                required: ["to"]
            ),
            isWrite: false, requirements: []
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let from = try MapsToolFactory.placeReference(args, "from", allowCurrent: true)
        let to = try MapsToolFactory.placeReference(args, "to", allowCurrent: false)
        let mode = try MapsToolFactory.transportMode(args, transit: true)
        return AppleToolPayload(["eta": try await service.eta(from: from, to: to, transport: mode)])
    }
}

final class MapsOpenTool: AppleToolBase, @unchecked Sendable {
    private let service: MapsServicing
    init(service: MapsServicing) {
        self.service = service
        super.init(
            app: .maps, name: "maps_open",
            description: "Open the Maps app showing a search, a pin at coordinates, or directions to a destination. Use after the user asks to see it in Maps.",
            parameters: AppleSchema.object([
                "query": AppleSchema.string("Search text or place name to show."),
                "latitude": AppleSchema.number("Pin latitude (with longitude)."),
                "longitude": AppleSchema.number("Pin longitude."),
                "directions_to": AppleSchema.string("Destination address, place name, or \"lat,lng\" to open directions to."),
                "mode": MapsToolFactory.modeSchema("Transport mode for directions.", transit: true),
            ]),
            isWrite: false, requirements: []
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        var comps = URLComponents(string: "maps://")!
        var items: [URLQueryItem] = []
        if let destRaw = try AppleArgs.string(args, "directions_to") {
            items.append(URLQueryItem(name: "daddr", value: destRaw))
            let mode = try MapsToolFactory.transportMode(args, transit: true)
            let flag: String
            switch mode {
            case .walking: flag = "w"
            case .transit: flag = "r"
            case .automobile, .cycling: flag = "d"
            }
            items.append(URLQueryItem(name: "dirflg", value: flag))
        } else if let c = try MapsToolFactory.coordinate(args) {
            items.append(URLQueryItem(name: "ll", value: "\(c.latitude),\(c.longitude)"))
            if let q = try AppleArgs.string(args, "query") { items.append(URLQueryItem(name: "q", value: q)) }
        } else if let q = try AppleArgs.string(args, "query") {
            items.append(URLQueryItem(name: "q", value: q))
        } else {
            throw AppleToolError.invalidArgs("Pass `query`, `latitude`+`longitude`, or `directions_to`.")
        }
        comps.queryItems = items
        guard let url = comps.url else { throw AppleToolError.execution("Could not build a Maps URL.") }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw AppleToolError.unavailable("Maps could not be opened.", retryable: true) }
        return AppleToolPayload(["opened": true, "url": url.absoluteString])
    }
}

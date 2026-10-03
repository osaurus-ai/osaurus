//
//  MapsService.swift
//  osaurus
//
//  Maps & Location via CoreLocation + MapKit (no AppleScript). Geocoding,
//  place search, POI exploration, directions and ETAs need no TCC grant;
//  only `location_current` (and directions/ETA without an explicit origin)
//  touch the Location permission. Opening Maps uses the `maps://` URL
//  scheme so nothing is scripted and Maps only comes forward when the user
//  asked to see something.
//

import AppKit
import CoreLocation
import Foundation
import MapKit

struct GeoCoordinate: Codable, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct PlaceInfo: Codable, Sendable, Equatable {
    let name: String?
    let coordinate: GeoCoordinate
    let address: String?
    let street: String?
    let city: String?
    let state: String?
    let postalCode: String?
    let country: String?
    let countryCode: String?
    let phone: String?
    let url: String?
    let category: String?
    let timeZone: String?
    let mapsURL: String
}

struct CurrentLocationInfo: Codable, Sendable, Equatable {
    let coordinate: GeoCoordinate
    let horizontalAccuracyMeters: Double
    let altitudeMeters: Double?
    let timestamp: String
    let place: PlaceInfo?
}

struct RouteStepInfo: Codable, Sendable, Equatable {
    let instructions: String
    let distanceMeters: Double
    let notice: String?
}

struct RouteInfo: Codable, Sendable, Equatable {
    let name: String
    let distanceMeters: Double
    let expectedTravelSeconds: Double
    /// "13 min" / "2 h 5 min" — small models misread raw seconds as minutes.
    let expectedTravelText: String
    let distanceText: String
    let transportType: String
    let advisoryNotices: [String]
    let steps: [RouteStepInfo]
    let mapsURL: String
}

struct ETAInfo: Codable, Sendable, Equatable {
    let expectedTravelSeconds: Double
    let distanceMeters: Double
    let expectedTravelText: String
    let distanceText: String
    let transportType: String
    let expectedDeparture: String?
    let expectedArrival: String?

    init(expectedTravelSeconds: Double, distanceMeters: Double, transportType: String, expectedDeparture: String?, expectedArrival: String?) {
        self.expectedTravelSeconds = expectedTravelSeconds
        self.distanceMeters = distanceMeters
        self.expectedTravelText = MapsFormatting.duration(expectedTravelSeconds)
        self.distanceText = MapsFormatting.distance(distanceMeters)
        self.transportType = transportType
        self.expectedDeparture = expectedDeparture
        self.expectedArrival = expectedArrival
    }
}

enum MapsFormatting {
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        let km = meters / 1000
        let miles = meters / 1609.344
        return String(format: "%.1f km (%.1f mi)", km, miles)
    }
}

enum MapsTransportType: String, CaseIterable, Sendable {
    case automobile, walking, transit, cycling

    var mk: MKDirectionsTransportType {
        switch self {
        case .automobile: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        case .cycling: return .cycling
        }
    }
}

/// Either a free-text place / address or explicit coordinates.
enum MapsPlaceReference: Sendable, Equatable {
    case coordinate(GeoCoordinate)
    case query(String)
    case currentLocation
}

struct MapsSearchRegion: Sendable, Equatable {
    var center: GeoCoordinate
    var radiusMeters: Double
}

protocol MapsServicing: Sendable {
    func currentLocation() async throws -> CurrentLocationInfo
    func geocode(_ address: String, limit: Int) async throws -> [PlaceInfo]
    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> [PlaceInfo]
    func search(_ query: String, near: MapsSearchRegion?, limit: Int) async throws -> [PlaceInfo]
    func explore(category: String, near: MapsSearchRegion, limit: Int) async throws -> [PlaceInfo]
    func directions(from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType, alternatives: Bool)
        async throws -> [RouteInfo]
    func eta(from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType) async throws -> ETAInfo
}

final class MapKitMapsService: MapsServicing, @unchecked Sendable {

    // MARK: Current location

    /// Process-wide one-shot locator. ONE `CLLocationManager` for the whole
    /// app (each construction is a synchronous locationd XPC handshake on
    /// the calling thread — building one per call on the main actor was an
    /// app-hang risk), main-actor confined because CoreLocation delivers on
    /// the thread that created the manager. Concurrent callers share the
    /// in-flight fix instead of starting a second request.
    @MainActor
    final class CurrentLocationProvider: NSObject, CLLocationManagerDelegate {
        static let shared = CurrentLocationProvider()

        private lazy var manager: CLLocationManager = {
            let m = CLLocationManager()
            m.delegate = self
            m.desiredAccuracy = kCLLocationAccuracyHundredMeters
            return m
        }()
        private var waiters: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
        private var timeoutTask: Task<Void, Never>?

        /// Default budget for the fix itself (after authorization).
        static let fixTimeout: TimeInterval = 20

        func locate(timeout: TimeInterval = fixTimeout) async throws -> CLLocation {
            let token = UUID()
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CLLocation, Error>) in
                let isFirst = waiters.isEmpty
                waiters[token] = c
                guard isFirst else { return }
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(
                        .failure(
                            AppleToolError.timeout(
                                "Location fix took longer than \(Int(timeout))s. Try again, or make sure Location Services is on."
                            )
                        )
                    )
                }
                manager.requestLocation()
            }
        }

        private func finish(_ result: Result<CLLocation, Error>) {
            timeoutTask?.cancel()
            timeoutTask = nil
            let pending = waiters
            waiters.removeAll()
            for c in pending.values { c.resume(with: result) }
        }

        nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            let last = locations.last
            Task { @MainActor in
                if let last {
                    finish(.success(last))
                } else {
                    finish(.failure(AppleToolError.unavailable("No location fix was returned.", retryable: true)))
                }
            }
        }

        nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            let ns = error as NSError
            let mapped: AppleToolError
            if ns.domain == kCLErrorDomain, ns.code == CLError.denied.rawValue {
                mapped = .permissionDenied(.location)
            } else if ns.domain == kCLErrorDomain, ns.code == CLError.locationUnknown.rawValue {
                // CoreLocation keeps trying after kCLErrorLocationUnknown;
                // let the fix timeout decide.
                return
            } else {
                mapped = .unavailable("Location lookup failed: \(ns.localizedDescription)", retryable: true)
            }
            Task { @MainActor in finish(.failure(mapped)) }
        }
    }

    /// Authorization gate: an undecided status shows the system dialog and
    /// WAITS for the user's answer (`SystemPermissionService` owns the
    /// shared manager + delegate); a "denied" is only reported after the
    /// user actually said no or walked away from the dialog.
    @MainActor
    private func ensureLocationAuthorized() async throws {
        let service = SystemPermissionService.shared
        var status = service.locationAuthorizationStatus
        if status == .notDetermined {
            status = await service.requestLocationAuthorizationAndWait()
        }
        if SystemPermissionService.isLocationAuthorized(status) { return }
        if status == .notDetermined {
            throw AppleToolError.permissionDenied(
                .location,
                detail: "The Location permission dialog was not answered within \(Int(SystemPermissionService.locationDialogTimeout))s. Ask the user to click Allow, then try again."
            )
        }
        throw AppleToolError.permissionDenied(.location)
    }

    private func resolvedCurrentLocation() async throws -> CLLocation {
        // `locationServicesEnabled()` can block briefly; keep it off the main
        // actor (this method is not main-actor bound).
        guard CLLocationManager.locationServicesEnabled() else {
            throw AppleToolError.unavailable(
                "Location Services are turned off in System Settings → Privacy & Security → Location Services.", retryable: false
            )
        }
        try await ensureLocationAuthorized()
        return try await CurrentLocationProvider.shared.locate()
    }

    func currentLocation() async throws -> CurrentLocationInfo {
        let loc = try await resolvedCurrentLocation()
        let coord = GeoCoordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        let place = try? await reverseGeocode(coord).first
        return CurrentLocationInfo(
            coordinate: coord,
            horizontalAccuracyMeters: loc.horizontalAccuracy,
            altitudeMeters: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
            timestamp: AppleDateParsing.format(loc.timestamp),
            place: place
        )
    }

    // MARK: Geocoding

    func geocode(_ address: String, limit: Int) async throws -> [PlaceInfo] {
        let geocoder = CLGeocoder()
        do {
            let marks = try await geocoder.geocodeAddressString(address)
            return Array(marks.compactMap(Self.place(from:)).prefix(limit))
        } catch {
            throw Self.mapGeoError(error, context: "Geocoding `\(address)`")
        }
    }

    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> [PlaceInfo] {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let marks = try await geocoder.reverseGeocodeLocation(location)
            return marks.compactMap(Self.place(from:))
        } catch {
            throw Self.mapGeoError(error, context: "Reverse geocoding \(coordinate.latitude), \(coordinate.longitude)")
        }
    }

    private static func mapGeoError(_ error: Error, context: String) -> AppleToolError {
        let ns = error as NSError
        if ns.domain == kCLErrorDomain {
            switch CLError.Code(rawValue: ns.code) {
            case .geocodeFoundNoResult?: return .notFound("\(context) found no results.")
            case .geocodeCanceled?: return .execution("\(context) was cancelled.")
            case .network?: return .unavailable("\(context) failed: no network connection to Apple's geocoder.", retryable: true)
            default: break
            }
        }
        return .unavailable("\(context) failed: \(error.localizedDescription)", retryable: true)
    }

    // MARK: Search

    private func region(for near: MapsSearchRegion?) -> MKCoordinateRegion? {
        guard let near else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: near.center.latitude, longitude: near.center.longitude),
            latitudinalMeters: near.radiusMeters * 2, longitudinalMeters: near.radiusMeters * 2
        )
    }

    func search(_ query: String, near: MapsSearchRegion?, limit: Int) async throws -> [PlaceInfo] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let region = region(for: near) {
            request.region = region
            // MapKit treats `region` as a hint and otherwise ranks by the
            // Mac's own (IP-approximated) location — a `near` in Cupertino
            // returned cafés 600 km away in live proof. `.required` makes
            // the caller's region authoritative.
            request.regionPriority = .required
        }
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            var places = response.mapItems.compactMap(Self.place(from:))
            if let near {
                // The region is authoritative (see above); order what came
                // back by distance so "closest first" holds.
                let center = CLLocation(latitude: near.center.latitude, longitude: near.center.longitude)
                places.sort {
                    CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: center)
                        < CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude).distance(from: center)
                }
            }
            return Array(places.prefix(limit))
        } catch {
            throw Self.mapSearchError(error, context: "Searching Maps for `\(query)`")
        }
    }

    static let poiCategories: [String: MKPointOfInterestCategory] = [
        "airport": .airport, "amusement_park": .amusementPark, "aquarium": .aquarium, "atm": .atm, "bakery": .bakery,
        "bank": .bank, "beach": .beach, "brewery": .brewery, "cafe": .cafe, "campground": .campground,
        "car_rental": .carRental, "ev_charger": .evCharger, "fire_station": .fireStation, "fitness_center": .fitnessCenter,
        "food_market": .foodMarket, "gas_station": .gasStation, "hospital": .hospital, "hotel": .hotel,
        "laundry": .laundry, "library": .library, "marina": .marina, "movie_theater": .movieTheater, "museum": .museum,
        "national_park": .nationalPark, "nightlife": .nightlife, "park": .park, "parking": .parking,
        "pharmacy": .pharmacy, "police": .police, "post_office": .postOffice, "public_transport": .publicTransport,
        "restaurant": .restaurant, "restroom": .restroom, "school": .school, "stadium": .stadium, "store": .store,
        "theater": .theater, "university": .university, "winery": .winery, "zoo": .zoo,
    ]

    func explore(category: String, near: MapsSearchRegion, limit: Int) async throws -> [PlaceInfo] {
        guard let poi = Self.poiCategories[category.lowercased()] else {
            throw AppleToolError.invalidArgs(
                "Unknown `category` `\(category)`.", field: "category",
                expected: "one of: " + Self.poiCategories.keys.sorted().joined(separator: ", ")
            )
        }
        let request = MKLocalPointsOfInterestRequest(
            center: CLLocationCoordinate2D(latitude: near.center.latitude, longitude: near.center.longitude),
            radius: min(max(near.radiusMeters, 100), MKLocalPointsOfInterestRequest.maxRadius)
        )
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [poi])
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            return Array(response.mapItems.compactMap(Self.place(from:)).prefix(limit))
        } catch {
            throw Self.mapSearchError(error, context: "Exploring `\(category)` near \(near.center.latitude), \(near.center.longitude)")
        }
    }

    private static func mapSearchError(_ error: Error, context: String) -> AppleToolError {
        let ns = error as NSError
        if ns.domain == MKErrorDomain {
            switch MKError.Code(rawValue: UInt(ns.code)) {
            case .placemarkNotFound?: return .notFound("\(context) found no results.")
            case .directionsNotFound?: return .notFound("\(context): no route could be found.")
            case .serverFailure?, .loadingThrottled?: return .unavailable("\(context) failed: Apple Maps is unavailable or throttled. Try again shortly.", retryable: true)
            default: break
            }
        }
        return .unavailable("\(context) failed: \(error.localizedDescription)", retryable: true)
    }

    // MARK: Directions

    /// Resolve a place reference to a map item. `near` biases free-text
    /// lookups toward the other endpoint of the trip: MapKit otherwise ranks
    /// by the Mac's own (IP-approximated) location, which in live proof turned
    /// "Apple Park E7 Espresso Bar" into a 600 km route.
    private func mapItem(for reference: MapsPlaceReference, field: String, near: CLLocationCoordinate2D?) async throws -> MKMapItem {
        switch reference {
        case .currentLocation:
            let loc = try await resolvedCurrentLocation()
            return MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate))
        case .coordinate(let c):
            return MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)))
        case .query(let text):
            // Prefer Maps search (handles business names); fall back to the geocoder.
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            if let near {
                request.region = MKCoordinateRegion(center: near, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
            }
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first { return item }
            let marks = try await geocode(text, limit: 1)
            guard let first = marks.first else {
                throw AppleToolError.notFound("`\(field)` (`\(text)`) could not be found on the map.")
            }
            return MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: first.coordinate.latitude, longitude: first.coordinate.longitude)))
        }
    }

    /// Resolve both trip endpoints, resolving the fixed one first so it can
    /// bias the free-text one.
    private func endpoints(from: MapsPlaceReference, to: MapsPlaceReference) async throws -> (MKMapItem, MKMapItem) {
        if case .query = from {
            let destination = try await mapItem(for: to, field: "to", near: nil)
            let source = try await mapItem(for: from, field: "from", near: destination.placemark.coordinate)
            return (source, destination)
        }
        let source = try await mapItem(for: from, field: "from", near: nil)
        let destination = try await mapItem(for: to, field: "to", near: source.placemark.coordinate)
        return (source, destination)
    }

    func directions(from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType, alternatives: Bool)
        async throws -> [RouteInfo]
    {
        if transport == .transit {
            throw AppleToolError.invalidArgs(
                "Turn-by-turn `transit` directions are not available through MapKit; use `maps_eta` with `mode: transit` or `maps_open`.",
                field: "mode", expected: "automobile | walking | cycling"
            )
        }
        let request = MKDirections.Request()
        (request.source, request.destination) = try await endpoints(from: from, to: to)
        request.transportType = transport.mk
        request.requestsAlternateRoutes = alternatives
        do {
            let response = try await MKDirections(request: request).calculate()
            let mapsURL = Self.directionsURL(from: request.source, to: request.destination, transport: transport)
            return response.routes.map { route in
                RouteInfo(
                    name: route.name,
                    distanceMeters: route.distance,
                    expectedTravelSeconds: route.expectedTravelTime,
                    expectedTravelText: MapsFormatting.duration(route.expectedTravelTime),
                    distanceText: MapsFormatting.distance(route.distance),
                    transportType: transport.rawValue,
                    advisoryNotices: route.advisoryNotices,
                    steps: route.steps.filter { !$0.instructions.isEmpty }.map {
                        RouteStepInfo(instructions: $0.instructions, distanceMeters: $0.distance, notice: $0.notice)
                    },
                    mapsURL: mapsURL
                )
            }
        } catch let error as AppleToolError {
            throw error
        } catch {
            throw Self.mapSearchError(error, context: "Routing")
        }
    }

    func eta(from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType) async throws -> ETAInfo {
        let request = MKDirections.Request()
        (request.source, request.destination) = try await endpoints(from: from, to: to)
        request.transportType = transport.mk
        do {
            let response = try await MKDirections(request: request).calculateETA()
            return ETAInfo(
                expectedTravelSeconds: response.expectedTravelTime,
                distanceMeters: response.distance,
                transportType: transport.rawValue,
                expectedDeparture: AppleDateParsing.format(response.expectedDepartureDate),
                expectedArrival: AppleDateParsing.format(response.expectedArrivalDate)
            )
        } catch let error as AppleToolError {
            throw error
        } catch {
            throw Self.mapSearchError(error, context: "ETA")
        }
    }

    // MARK: URLs

    static func mapsURL(coordinate: CLLocationCoordinate2D, name: String?) -> String {
        var comps = URLComponents(string: "maps://")!
        var items = [URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)")]
        if let name, !name.isEmpty { items.append(URLQueryItem(name: "q", value: name)) }
        comps.queryItems = items
        return comps.url?.absoluteString ?? "maps://"
    }

    static func directionsURL(from: MKMapItem?, to: MKMapItem?, transport: MapsTransportType) -> String {
        var comps = URLComponents(string: "maps://")!
        var items: [URLQueryItem] = []
        if let from { items.append(URLQueryItem(name: "saddr", value: coordinateString(from))) }
        if let to { items.append(URLQueryItem(name: "daddr", value: coordinateString(to))) }
        let flag: String
        switch transport {
        case .automobile: flag = "d"
        case .walking: flag = "w"
        case .transit: flag = "r"
        case .cycling: flag = "d"
        }
        items.append(URLQueryItem(name: "dirflg", value: flag))
        comps.queryItems = items
        return comps.url?.absoluteString ?? "maps://"
    }

    private static func coordinateString(_ item: MKMapItem) -> String {
        let c = item.placemark.coordinate
        return "\(c.latitude),\(c.longitude)"
    }

    // MARK: Mapping

    static func place(from item: MKMapItem) -> PlaceInfo? {
        guard var place = place(from: item.placemark) else { return nil }
        place = PlaceInfo(
            name: item.name ?? place.name, coordinate: place.coordinate, address: place.address, street: place.street,
            city: place.city, state: place.state, postalCode: place.postalCode, country: place.country,
            countryCode: place.countryCode, phone: item.phoneNumber, url: item.url?.absoluteString,
            category: item.pointOfInterestCategory.map { categoryName($0) }, timeZone: item.timeZone?.identifier,
            mapsURL: mapsURL(coordinate: item.placemark.coordinate, name: item.name)
        )
        return place
    }

    static func place(from mark: CLPlacemark) -> PlaceInfo? {
        guard let loc = mark.location else { return nil }
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street, mark.locality, mark.administrativeArea, mark.postalCode, mark.country].compactMap { $0 }.filter { !$0.isEmpty }
        return PlaceInfo(
            name: mark.name, coordinate: GeoCoordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude),
            address: parts.isEmpty ? nil : parts.joined(separator: ", "),
            street: street.isEmpty ? nil : street, city: mark.locality, state: mark.administrativeArea,
            postalCode: mark.postalCode, country: mark.country, countryCode: mark.isoCountryCode,
            phone: nil, url: nil, category: nil, timeZone: mark.timeZone?.identifier,
            mapsURL: mapsURL(coordinate: loc.coordinate, name: mark.name)
        )
    }

    static func categoryName(_ category: MKPointOfInterestCategory) -> String {
        poiCategories.first { $0.value == category }?.key ?? category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "").lowercased()
    }
}

//
//  AppleServiceQueue.swift
//  osaurus
//
//  EventKit / Contacts / SQLite objects are not Sendable and several of the
//  framework calls are synchronous XPC round-trips that must not run on the
//  main actor. Every Apple app service funnels its framework work through
//  one serial background queue and hands plain value types back to the
//  async tool body. Each service owns its own queue so a slow Contacts scan
//  never blocks a Calendar read (one global queue used to serialize them all).
//

import CoreGraphics
import Foundation

struct AppleServiceQueue: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: "ai.osaurus.apple-apps.\(label)", qos: .userInitiated)
    }

    /// Run `work` on this service's serial queue and return its result.
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Bridge a callback-style framework API on this queue: `body` receives
    /// a completion it must call exactly once (from any thread).
    func bridge<T: Sendable>(
        _ body: @escaping @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) throws -> Void
    ) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try body { result in continuation.resume(with: result) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Small helpers shared by the framework-backed services.
enum AppleServiceSupport {
    /// `#RRGGBB` for a CGColor (nil when the color has no RGB components).
    static func hexString(_ cgColor: CGColor?) -> String? {
        guard let cgColor, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let rgb = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
            let comps = rgb.components, comps.count >= 3
        else { return nil }
        let r = Int((comps[0] * 255).rounded()), g = Int((comps[1] * 255).rounded()), b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    /// Case-insensitive "contains" on optional text.
    static func matches(_ text: String?, query: String) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Percent-encode an identifier for use as one path component of a
    /// deep link (`ical://`, `x-apple-reminderkit://`, `addressbook://`).
    /// `:` stays literal — EventKit ids (`A1B2:C3D4`) and Contacts ids
    /// (`UUID:ABPerson`) are matched by the apps in that form — while `/`,
    /// spaces, `?`, `#` and `%` (which would split or break the URL) are
    /// encoded.
    static func pathEncoded(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    /// Truncate a list and report `total` / `truncated`.
    static func page<T>(_ items: [T], limit: Int) -> (items: [T], total: Int, truncated: Bool) {
        let total = items.count
        if total > limit { return (Array(items.prefix(limit)), total, true) }
        return (items, total, false)
    }
}

//
//  AppleServiceQueue.swift
//  osaurus
//
//  EventKit / Contacts / SQLite objects are not Sendable and several of the
//  framework calls are synchronous XPC round-trips that must not run on the
//  main actor. Every Apple app service funnels its framework work through
//  one serial background queue and hands plain value types back to the
//  async tool body.
//

import CoreGraphics
import Foundation

enum AppleServiceQueue {
    private static let queue = DispatchQueue(label: "ai.osaurus.apple-apps.services", qos: .userInitiated)

    /// Run `work` on the serial service queue and return its result.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
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

    /// Truncate a list and report `total` / `truncated`.
    static func page<T>(_ items: [T], limit: Int) -> (items: [T], total: Int, truncated: Bool) {
        let total = items.count
        if total > limit { return (Array(items.prefix(limit)), total, true) }
        return (items, total, false)
    }
}

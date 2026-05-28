//
//  Label.swift
//  osaurus / PrivacyFilter (vendored)
//
//  Vendored from https://github.com/kokluch/privacy-filter-swift
//  @ 2bb396cce542155e1923fff1e08520348f1af1c5. See
//  PrivacyFilter/Vendor/PrivacyFilterKit/README-vendoring.md for the
//  sync protocol and the rewires we keep applied.
//
//  Osaurus-local rewires:
//    • `Label` → `BIOESLabel`
//    • `LabelTable` → `BIOESLabelTable`
//    • `LabelTableError` → `BIOESLabelTableError`
//    Renamed to avoid colliding with SwiftUI's `Label<Title, Icon>`
//    once the vendor lands in the OsaurusCore module namespace.
//    Re-apply on every upstream sync.
//

import Foundation

public enum EntityType: String, Sendable, CaseIterable, Codable {
    case accountNumber = "account_number"
    case address = "private_address"
    case email = "private_email"
    case person = "private_person"
    case phone = "private_phone"
    case url = "private_url"
    case date = "private_date"
    case secret = "secret"
}

public enum Boundary: String, Sendable, Equatable {
    case begin = "B"
    case inside = "I"
    case end = "E"
    case single = "S"
    case outside = "O"
}

public struct BIOESLabel: Sendable, Equatable, Hashable {
    public let id: Int
    public let raw: String
    public let boundary: Boundary
    public let entity: EntityType?

    public init(id: Int, raw: String) {
        self.id = id
        self.raw = raw
        if raw == "O" {
            self.boundary = .outside
            self.entity = nil
            return
        }
        let parts = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
            let boundary = Boundary(rawValue: String(parts[0])),
            let entity = EntityType(rawValue: String(parts[1]))
        else {
            self.boundary = .outside
            self.entity = nil
            return
        }
        self.boundary = boundary
        self.entity = entity
    }
}

public struct BIOESLabelTable: Sendable {
    public let labels: [BIOESLabel]
    public let outsideId: Int

    public init(idToLabel: [Int: String]) throws {
        let sorted = idToLabel.sorted { $0.key < $1.key }
        let parsed = sorted.map { BIOESLabel(id: $0.key, raw: $0.value) }
        guard let outside = parsed.first(where: { $0.boundary == .outside }) else {
            throw BIOESLabelTableError.missingOutsideClass
        }
        self.labels = parsed
        self.outsideId = outside.id
    }

    public subscript(id: Int) -> BIOESLabel {
        labels[id]
    }

    public var count: Int { labels.count }
}

public enum BIOESLabelTableError: Error, Equatable {
    case missingOutsideClass
}

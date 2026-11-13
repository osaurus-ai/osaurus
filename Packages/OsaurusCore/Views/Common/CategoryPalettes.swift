//
//  CategoryPalettes.swift
//  osaurus
//
//  Categorical colors: kinds (an event category, a message role, a model
//  family, a name-hashed avatar) drawn from the theme's `color.data` series.
//  Fixed brand and identity colors live in `BrandPalette`.
//

import SwiftUI

/// Names for the theme's categorical `color.data` series: kinds drawn as
/// text, glyphs, dots, chart series or chip labels (HTTP methods, event
/// categories, message roles, endpoint groups). Status meanings (ok, needs
/// attention, failed) use `theme.status` instead.
enum DataInk: CaseIterable {
    case blue, green, orange, purple, teal, pink, indigo, cyan
    /// Off-series kinds: `gray` carries no identity and `red` reads as an
    /// error, so they take the neutral and error roles.
    case gray, red

    /// The `color.data.N` slot, or nil for the off-series kinds.
    var slot: Int? {
        switch self {
        case .blue: 1
        case .green: 2
        case .orange: 3
        case .purple: 4
        case .teal: 5
        case .pink: 6
        case .indigo: 7
        case .cyan: 8
        case .gray, .red: nil
        }
    }

    /// Request method labels (GET, POST, …) on route and endpoint rows.
    static func httpMethod(_ method: String) -> DataInk? {
        switch method.uppercased() {
        case "GET": .green
        case "POST": .blue
        case "PUT", "PATCH": .orange
        case "DELETE": .red
        default: nil
        }
    }

    /// A stable slot for a name, so the same agent, skill or category keeps
    /// its color across launches (`String.hashValue` is seeded per process).
    static func slot(forSeed seed: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % 8) + 1
    }
}

extension ThemeProtocol {
    func dataSwatch(slot: Int) -> ThemeDataSwatch<Color> {
        if let swatch = colors.data?[String(slot)] { return swatch }
        let seeds = isDark ? ThemeSemanticColors.darkDefaults : ThemeSemanticColors.lightDefaults
        let fallback = seeds.data![String((slot - 1) % 8 + 1)]!
        return fallback.map { Color(themeHex: $0) }
    }

    func dataInk(_ ink: DataInk) -> Color {
        switch ink {
        case .gray: text.tertiary
        case .red: statusInk(.error)
        default: dataSwatch(slot: ink.slot!).ink
        }
    }

    func dataWash(_ ink: DataInk) -> Color {
        switch ink {
        case .gray: border.subtle
        case .red: status.error.background
        default: dataSwatch(slot: ink.slot!).wash
        }
    }

    func dataInk(seed: String) -> Color { dataSwatch(slot: DataInk.slot(forSeed: seed)).ink }
    func dataWash(seed: String) -> Color { dataSwatch(slot: DataInk.slot(forSeed: seed)).wash }

    /// The fill behind an ink that arrives as a plain color (a tile, badge or
    /// banner tinted by its caller): a status tone takes its status fill, a
    /// data slot its wash, the accent the selection fill, anything else the
    /// subtle surface.
    func wash(behind ink: Color) -> Color {
        if let set = statusSet(inking: ink) { return set.background }
        for slot in 1...8 {
            let swatch = dataSwatch(slot: slot)
            if swatch.ink == ink { return swatch.wash }
        }
        if ink == action.primary.default.background || ink == text.link { return selection.background }
        return surface.subtle
    }

    /// The outline paired with `wash(behind:)`: a status tone's border, else
    /// the subtle border.
    func rule(around ink: Color) -> Color {
        statusSet(inking: ink)?.border ?? border.subtle
    }

    private func statusSet(inking ink: Color) -> ThemeStatusSet<Color>? {
        ThemeStatusKind.allCases.lazy.map { status[$0] }.first { $0.foreground == ink || $0.ink == ink }
    }
}

extension ContextBreakdown.Tint {
    var dataInk: DataInk {
        switch self {
        case .purple: .purple
        case .blue: .blue
        case .orange: .orange
        case .green: .green
        case .gray: .gray
        case .cyan: .cyan
        case .teal: .teal
        case .indigo: .indigo
        case .pink: .pink
        }
    }
}

extension CloudModelCategory {
    var dataInk: DataInk {
        switch self {
        case .textToText: .blue
        case .imageToText: .teal
        case .image: .purple
        case .textToVideo: .orange
        case .imageToVideo: .pink
        case .all: .gray
        }
    }
}

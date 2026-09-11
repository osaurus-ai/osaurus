//
//  ModelPriceFormatter.swift
//  osaurus
//
//  Shared price rendering for model picker rows. Providers publish prices
//  in different units (Osaurus Router credits, USD per token, USD per
//  million tokens); the picker items normalize the numeric ones to
//  micro-USD per million tokens and keep the router's ready-made credits
//  string. This formats either into one compact line.
//

import Foundation

enum ModelPriceFormatter {
    /// Price fragment for a picker row's metadata line, or nil when nothing
    /// about price is known. Both prices published as zero reads "Free".
    static func line(for item: ModelPickerItem) -> String? {
        if let display = item.priceDisplay?.trimmingCharacters(in: .whitespacesAndNewlines),
            !display.isEmpty
        {
            return display
        }
        return line(
            inputMicroPerMTok: item.inputPriceMicroPerMTok,
            outputMicroPerMTok: item.outputPriceMicroPerMTok
        )
    }

    /// "$0.30 / $2.50 per M" (input / output), "Free", or nil when neither
    /// price is known. A single known side renders alone ("$0.30 in per M").
    static func line(inputMicroPerMTok input: Int64?, outputMicroPerMTok output: Int64?) -> String? {
        switch (input, output) {
        case (nil, nil):
            return nil
        case let (i?, o?):
            if i == 0 && o == 0 { return L("Free") }
            return "\(usd(microPerMTok: i)) / \(usd(microPerMTok: o)) per M"
        case let (i?, nil):
            if i == 0 { return L("Free") }
            return "\(usd(microPerMTok: i)) in per M"
        case let (nil, o?):
            if o == 0 { return L("Free") }
            return "\(usd(microPerMTok: o)) out per M"
        }
    }

    /// Micro-USD per million tokens -> "$X" per million tokens. Two decimals
    /// for ordinary prices, more for sub-cent ones so "$0.0025" doesn't
    /// collapse to "$0.00".
    static func usd(microPerMTok micro: Int64) -> String {
        let dollars = Double(micro) / 1_000_000
        if dollars == 0 { return "$0" }
        let decimals: Int
        if dollars >= 1 {
            decimals = 2
        } else if dollars >= 0.01 {
            decimals = 2
        } else if dollars >= 0.001 {
            decimals = 3
        } else {
            decimals = 4
        }
        var text = String(format: "%.\(decimals)f", dollars)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "$\(text)"
    }
}

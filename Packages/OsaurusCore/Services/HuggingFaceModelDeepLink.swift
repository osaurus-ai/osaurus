//
//  HuggingFaceModelDeepLink.swift
//  osaurus
//
//  Parses the deep links that open a Hugging Face model in the Model Manager.
//
//  Two shapes are accepted:
//
//    huggingface://?model=<org/repo>&file=<path>
//        The original Osaurus link. Kept for existing callers.
//
//    osaurus://open_from_hf?model=<org/repo>&file=<path>
//        The shape Hugging Face generates for the "Use this model" → Osaurus
//        entry on huggingface.co (`packages/tasks/src/local-apps.ts` in
//        huggingface/huggingface.js). Hugging Face's convention is that every
//        local app owns its scheme and exposes an `open_from_hf` host, so the
//        Hub can't accidentally launch a different app that also registered
//        the generic `huggingface` scheme.
//
//  `model` is required. `file` is optional and only set by the Hub for
//  repositories that carry per-file variants; MLX repos are opened as a whole.
//  Percent-encoded values (`org%2Frepo`) decode through `URLComponents`, so
//  both the raw and the `URLSearchParams`-encoded forms resolve identically.
//

import Foundation

public struct HuggingFaceModelDeepLink: Equatable, Sendable {
    /// Scheme of the original Osaurus link (`huggingface://?model=…`).
    public static let legacyScheme = "huggingface"
    /// Host under the `osaurus://` scheme that Hugging Face's local-app
    /// registry points at (`osaurus://open_from_hf?model=…`).
    public static let osaurusHost = "open_from_hf"

    public let modelId: String
    public let file: String?

    public init(modelId: String, file: String?) {
        self.modelId = modelId
        self.file = file
    }

    /// Returns nil for URLs that are not a model deep link, or that carry no
    /// usable `model` query item. Callers treat nil as "not mine" and keep
    /// dispatching; there is nothing to show without a model id.
    public static func parse(_ url: URL) -> HuggingFaceModelDeepLink? {
        guard Self.matches(url) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []

        func value(_ name: String) -> String? {
            let trimmed = items.first(where: { $0.name.lowercased() == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }

        guard let modelId = value("model") else { return nil }
        return HuggingFaceModelDeepLink(modelId: modelId, file: value("file"))
    }

    /// True when the scheme/host pair is one of the two model deep-link
    /// shapes, regardless of whether the query is well formed.
    public static func matches(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == legacyScheme { return true }
        return scheme == "osaurus" && url.host?.lowercased() == osaurusHost
    }
}

//
//  ScreenContextSettings.swift
//  OsaurusCore — Computer Use
//
//  The opt-in gate for injecting a frozen screen-context snapshot into chat.
//  Off by default and never inferred: nothing is captured or injected until
//  the user explicitly turns it on in Computer Use settings. Mirrors the
//  shape of `CloudVisionConsent` (a tiny UserDefaults-backed observable) so
//  the settings toggle and the chat send path read one source of truth.
//

import Combine
import Foundation

@MainActor
public final class ScreenContextSettings: ObservableObject {
    public static let shared = ScreenContextSettings()

    private let defaultsKey = "ai.osaurus.computeruse.screenContextInjection"
    private let defaults: UserDefaults

    /// Master opt-in. Default `false` — the screen is never sampled and no
    /// context is injected until the user turns this on.
    @Published public private(set) var injectionEnabled: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.injectionEnabled = defaults.bool(forKey: defaultsKey)
    }

    /// Bindable convenience for the settings toggle.
    public func setEnabled(_ on: Bool) {
        guard on != injectionEnabled else { return }
        injectionEnabled = on
        defaults.set(on, forKey: defaultsKey)
    }
}

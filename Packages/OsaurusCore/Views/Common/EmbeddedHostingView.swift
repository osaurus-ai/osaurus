//
//  EmbeddedHostingView.swift
//  osaurus
//

import AppKit
import SwiftUI

extension NSHostingView {
    /// A hosting view placed inside other AppKit content (a table row, a card, a chip) rather than filling a
    /// window. With the default safe-area regions it adds its overlap with a transparent full-size titlebar to
    /// its own size, so a row that scrolls or tiles under the chat window's titlebar grows, moves out from
    /// under it, shrinks, and moves back, until AppKit runs out of constraint passes for the window.
    static func embedded(rootView: Content) -> Self {
        let view = Self(rootView: rootView)
        view.safeAreaRegions = []
        return view
    }
}

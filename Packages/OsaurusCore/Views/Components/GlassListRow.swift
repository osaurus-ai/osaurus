//
//  GlassListRow.swift
//  osaurus
//
//  Rounded list row background with subtle stroke.
//

import SwiftUI

struct GlassListRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.glassEdgeLight.opacity(0.25), lineWidth: 1)
                    )
            )
    }
}

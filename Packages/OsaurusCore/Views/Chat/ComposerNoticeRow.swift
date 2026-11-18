//
//  ComposerNoticeRow.swift
//  osaurus
//
//  The tinted status strip above (or in place of) the chat composer:
//  remote-agent connection, a quiet or stalled run, a conversation hosted
//  for a teammate. One chrome so every composer notice reads the same.
//

import SwiftUI

struct ComposerNoticeRow<Content: View>: View {
    let tone: ThemeStatusSet<Color>
    @ViewBuilder let content: () -> Content

    @Environment(\.theme) private var theme

    var body: some View {
        RemoteAgentNoticeRow(tone: tone, baseTheme: theme, content: content)
    }
}

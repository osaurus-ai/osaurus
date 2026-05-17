//
//  ChatWindowStateThemeRefreshTests.swift
//  osaurusTests
//
//  Focused coverage for chat-window theme background image cache refreshes.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatWindowStateThemeRefreshTests {
    private func makeTheme(
        id: UUID = UUID(),
        backgroundType: ThemeBackground.BackgroundType = .image,
        imageData: String? = nil
    ) -> CustomTheme {
        CustomTheme(
            metadata: ThemeMetadata(id: id, name: "Background Test"),
            background: ThemeBackground(type: backgroundType, imageData: imageData)
        )
    }

    @Test("same theme ID with new background image data re-decodes")
    func sameThemeIdWithNewImageDataRequiresRedecode() {
        let themeId = UUID()
        let oldTheme = makeTheme(id: themeId, imageData: "old-image-data")
        let newTheme = makeTheme(id: themeId, imageData: "new-image-data")

        #expect(ChatWindowState.needsBackgroundImageRedecode(oldConfig: oldTheme, newConfig: newTheme))
    }

    @Test("different theme ID still re-decodes")
    func differentThemeIdRequiresRedecode() {
        let oldTheme = makeTheme(id: UUID(), imageData: "shared-image-data")
        let newTheme = makeTheme(id: UUID(), imageData: "shared-image-data")

        #expect(ChatWindowState.needsBackgroundImageRedecode(oldConfig: oldTheme, newConfig: newTheme))
    }

    @Test("non-image edits on same theme ID do not re-decode")
    func nonImageEditOnSameThemeDoesNotRequireRedecode() {
        let themeId = UUID()
        let oldTheme = makeTheme(id: themeId, imageData: "same-image-data")
        var newTheme = oldTheme
        newTheme.metadata.updatedAt = Date().addingTimeInterval(60)
        newTheme.colors.primaryText = "#abcdef"
        newTheme.background.imageOpacity = 0.5
        newTheme.background.imageFit = .fit

        #expect(!ChatWindowState.needsBackgroundImageRedecode(oldConfig: oldTheme, newConfig: newTheme))
    }

    @Test("leaving image background clears cached image")
    func leavingImageBackgroundRequiresRedecode() {
        let themeId = UUID()
        let oldTheme = makeTheme(id: themeId, imageData: "old-image-data")
        let newTheme = makeTheme(id: themeId, backgroundType: .solid, imageData: nil)

        #expect(ChatWindowState.needsBackgroundImageRedecode(oldConfig: oldTheme, newConfig: newTheme))
    }
}

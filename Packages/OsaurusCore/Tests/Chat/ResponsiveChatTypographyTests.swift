import AppKit
import Testing

@testable import OsaurusCore

@Suite
struct ResponsiveChatTypographyTests {
    @Test @MainActor func chatBodyTypographyMatchesInputSize() throws {
        let blocks: [SelectableTextBlock] = [.paragraph("Hello")]
        let theme = CustomizableTheme(
            config: CustomTheme(typography: ThemeTypography(bodySize: 13)),
            fontScale: 1
        )

        let userText = SelectableTextView.attributedString(
            for: blocks,
            width: 480,
            theme: theme
        )
        let assistantText = SelectableTextView.attributedString(
            for: blocks,
            width: 1000,
            theme: theme
        )

        let userFont = try #require(userText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let assistantFont = try #require(
            assistantText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        #expect(userFont.pointSize == CGFloat(theme.bodySize))
        #expect(assistantFont.pointSize == userFont.pointSize)
    }
}

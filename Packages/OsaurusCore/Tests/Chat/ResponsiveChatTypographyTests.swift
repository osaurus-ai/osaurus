import AppKit
import Testing

@testable import OsaurusCore

@Suite
struct ResponsiveChatTypographyTests {
    @Test @MainActor func chatBodyTypographyMatchesInputSize() throws {
        let blocks: [SelectableTextBlock] = [.paragraph("Hello")]
        var config = CustomTheme.lightDefault
        config.typography.styles.body.size = 13
        let theme = CustomizableTheme(resolved: config, fontScale: 1)

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
        let bodyFont = RichTextInspectionStyle.scope(theme).nsFont(.body)
        #expect(userFont.pointSize == bodyFont.pointSize)
        #expect(assistantFont.pointSize == userFont.pointSize)
    }
}

import AppKit
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct MessageThemeRenderSignatureTests {

    @Test func builtInLightToDarkIsDetectedWithoutLayoutChange() {
        let light = MessageThemeRenderSignature(theme: LightTheme())
        let dark = MessageThemeRenderSignature(theme: DarkTheme())

        #expect(light.textAppearance != dark.textAppearance)
        #expect(light.appearance != dark.appearance)
        #expect(light.layout == dark.layout)
    }

    @Test func builtInDarkToLightIsDetectedWithoutLayoutChange() {
        let dark = MessageThemeRenderSignature(theme: DarkTheme())
        let light = MessageThemeRenderSignature(theme: LightTheme())

        #expect(dark.textAppearance != light.textAppearance)
        #expect(dark.layout == light.layout)
    }

    @Test func customTextColorChangeIsDetectedAtIdenticalTypography() {
        let original = CustomTheme(
            colors: .lightDefaults,
            typography: ThemeTypography(bodySize: 14),
            isDark: false
        )
        var changed = original
        changed.colors.primaryText = "#24354a"

        let oldSignature = MessageThemeRenderSignature(
            theme: CustomizableTheme(config: original, fontScale: 1)
        )
        let newSignature = MessageThemeRenderSignature(
            theme: CustomizableTheme(config: changed, fontScale: 1)
        )

        #expect(oldSignature.textAppearance != newSignature.textAppearance)
        #expect(oldSignature.layout == newSignature.layout)
    }

    @Test func unchangedThemeDoesNotTriggerInvalidation() {
        let first = MessageThemeRenderSignature(theme: CustomizableTheme(config: .lightDefault, fontScale: 1))
        let second = MessageThemeRenderSignature(theme: CustomizableTheme(config: .lightDefault, fontScale: 1))

        #expect(first == second)
    }

    @Test func fontZoomRemainsALayoutChange() {
        let base = CustomizableTheme(config: .lightDefault, fontScale: 1)
        let zoomed = CustomizableTheme(config: .lightDefault, fontScale: 1.1)
        let baseSignature = MessageThemeRenderSignature(theme: base)
        let zoomedSignature = MessageThemeRenderSignature(theme: zoomed)

        #expect(baseSignature.textAppearance == zoomedSignature.textAppearance)
        #expect(baseSignature.layout != zoomedSignature.layout)
    }

    @Test func existingMarkdownRunsRetintWithoutRebuildingTheirLayout() throws {
        let renderer = NativeMarkdownView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        var heightChanges = 0
        renderer.onHeightChanged = { heightChanges += 1 }
        let blocks: [SelectableTextBlock] = [
            .paragraph("Regular **bold** and *italic* with `inline code` and [a link](https://example.com)."),
            .heading(level: 2, text: "Section heading"),
            .blockquote("Quoted paragraph"),
            .listItem(text: "List item", index: 0, ordered: false, indentLevel: 0),
        ]

        renderer.configureWithBlocks(blocks, width: 520, theme: LightTheme(), cacheKey: nil)
        let storage = try #require(renderer._testRenderedTextStorage)
        let originalString = storage.string
        let originalBoldFont = font(in: storage, for: "bold")
        heightChanges = 0

        renderer.configureWithBlocks(blocks, width: 520, theme: DarkTheme(), cacheKey: nil)

        #expect(storage.string == originalString)
        #expect(heightChanges == 0, "color-only theme changes should not trigger row-height work")
        #expect(color(in: storage, for: "Regular")?.isEqual(to: NSColor(DarkTheme().primaryText)) == true)
        #expect(color(in: storage, for: "bold")?.isEqual(to: NSColor(DarkTheme().primaryText)) == true)
        #expect(color(in: storage, for: "italic")?.isEqual(to: NSColor(DarkTheme().primaryText)) == true)
        #expect(color(in: storage, for: "inline code")?.isEqual(to: NSColor(DarkTheme().accentColor)) == true)
        #expect(color(in: storage, for: "a link")?.isEqual(to: NSColor(DarkTheme().accentColor)) == true)
        #expect(color(in: storage, for: "Quoted")?.isEqual(to: NSColor(DarkTheme().secondaryText)) == true)
        #expect(color(in: storage, for: "•")?.isEqual(to: NSColor(DarkTheme().accentColor)) == true)
        #expect(font(in: storage, for: "bold") == originalBoldFont)
    }

    @Test func customPaletteEditRetintsExistingMarkdownRuns() throws {
        let originalConfig = CustomTheme(colors: .lightDefaults)
        var editedConfig = originalConfig
        editedConfig.colors.primaryText = "#24354a"
        let originalTheme = CustomizableTheme(config: originalConfig, fontScale: 1)
        let editedTheme = CustomizableTheme(config: editedConfig, fontScale: 1)
        let renderer = NativeMarkdownView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        let blocks: [SelectableTextBlock] = [.paragraph("Custom palette text")]

        renderer.configureWithBlocks(blocks, width: 520, theme: originalTheme, cacheKey: nil)
        let storage = try #require(renderer._testRenderedTextStorage)
        renderer.configureWithBlocks(blocks, width: 520, theme: editedTheme, cacheKey: nil)

        #expect(color(in: storage, for: "Custom")?.isEqual(to: NSColor(editedTheme.primaryText)) == true)
    }

    @Test func fontZoomRebuildsMarkdownTypography() throws {
        let baseTheme = CustomizableTheme(config: .lightDefault, fontScale: 1)
        let zoomedTheme = CustomizableTheme(config: .lightDefault, fontScale: 1.15)
        let renderer = NativeMarkdownView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        var heightChanges = 0
        renderer.onHeightChanged = { heightChanges += 1 }
        let blocks: [SelectableTextBlock] = [.paragraph("Zoomed text")]

        renderer.configureWithBlocks(blocks, width: 520, theme: baseTheme, cacheKey: nil)
        let storage = try #require(renderer._testRenderedTextStorage)
        let originalFont = try #require(font(in: storage, for: "Zoomed"))
        heightChanges = 0
        renderer.configureWithBlocks(blocks, width: 520, theme: zoomedTheme, cacheKey: nil)

        let zoomedFont = try #require(font(in: storage, for: "Zoomed"))
        #expect(zoomedFont.pointSize > originalFont.pointSize)
        #expect(heightChanges > 0, "typography changes still invalidate the measured height")
    }

    @Test func repeatingTheSameRendererThemeDoesNotInvalidateHeight() throws {
        let renderer = NativeMarkdownView(frame: NSRect(x: 0, y: 0, width: 560, height: 10))
        var heightChanges = 0
        renderer.onHeightChanged = { heightChanges += 1 }
        let blocks: [SelectableTextBlock] = [.paragraph("Stable text")]
        let theme = LightTheme()

        renderer.configureWithBlocks(blocks, width: 520, theme: theme, cacheKey: nil)
        let storage = try #require(renderer._testRenderedTextStorage)
        heightChanges = 0
        renderer.configureWithBlocks(blocks, width: 520, theme: theme, cacheKey: nil)

        #expect(renderer._testRenderedTextStorage === storage)
        #expect(heightChanges == 0)
    }

    private func color(in storage: NSTextStorage, for substring: String) -> NSColor? {
        let range = (storage.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private func font(in storage: NSTextStorage, for substring: String) -> NSFont? {
        let range = (storage.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }
}

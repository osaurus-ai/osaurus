import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Optional sampling slider overrides")
struct SettingsSliderOverrideTests {
    @Test("Reading an inherited slider never creates an override")
    func inheritedReadIsNotAnOverride() {
        var text = ""
        let field = SettingsSliderField(
            label: "Temperature",
            help: "",
            text: Binding(get: { text }, set: { text = $0 }),
            range: 0 ... 2,
            step: 0.1,
            defaultValue: 0.7,
            formatString: "%.1f"
        )
        #expect(!field.overrideEnabled.wrappedValue)
        _ = field.sliderValue.wrappedValue
        #expect(text.isEmpty)
        field.overrideEnabled.wrappedValue = true
        #expect(text == "0.7")
        field.sliderValue.wrappedValue = 1.2
        #expect(text == "1.2")
        field.overrideEnabled.wrappedValue = true
        #expect(text == "1.2")
        field.overrideEnabled.wrappedValue = false
        #expect(text.isEmpty)
        #expect(!field.overrideEnabled.wrappedValue)
    }

    @Test("Saved values and external resets are reflected without asynchronous state")
    func externalChangesAreImmediate() {
        var text = "0.85"
        let field = SettingsSliderField(
            label: "Top P Override",
            help: "",
            text: Binding(get: { text }, set: { text = $0 }),
            range: 0 ... 1,
            step: 0.05,
            defaultValue: 1,
            formatString: "%.2f"
        )
        #expect(field.overrideEnabled.wrappedValue)
        #expect(field.sliderValue.wrappedValue == 0.85)
        text = ""
        #expect(!field.overrideEnabled.wrappedValue)
        _ = field.sliderValue.wrappedValue
        #expect(text.isEmpty)
        text = "0"
        #expect(field.overrideEnabled.wrappedValue)
        #expect(field.sliderValue.wrappedValue == 0)
    }
}

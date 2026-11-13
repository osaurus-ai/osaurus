#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// The existing settings and automation toggle/slider implementations, using
/// disposable bindings. No application or automation setting is persisted.
struct InspectorSettingsGeometryVerification: View {
    let family: Int
    @Environment(\.theme) private var inheritedTheme
    @State private var enabled = true
    @State private var checked = false
    @State private var topP = ""
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(family) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original settings controls · local bindings only")
            if family == 50 {
                Toggle("Enabled", isOn: $enabled).settingsSwitch(showsLabel: true)
                Toggle("Use local condition", isOn: $checked).settingsCheckbox()
            } else {
                SettingsToggle(title: "Local switch", description: "The same SettingsToggle used in settings.", verbatim: true, isOn: $enabled)
                SettingsToggle(title: "Local checkbox", style: .checkbox, verbatim: true, isOn: $checked)
                SettingsSliderRow(label: "Top P Override", help: "Local value only; chat configuration is not modified.",
                    text: $topP, range: 0...1, step: 0.05, defaultValue: 1, formatString: "%.2f")
                Text("Local Top P value: \(topP.isEmpty ? "inherited" : topP)")
            }
        }.environment(\.theme, theme)
    }
}
#endif

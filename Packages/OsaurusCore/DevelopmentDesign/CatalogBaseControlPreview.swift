#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Catalog scaffolding only. Every control below is the existing app control;
/// example labels are inspector chrome and never acquire component assignments.
struct CatalogBaseControlPreview: View {
    let family: Int
    @State private var switchOff = false
    @State private var switchOn = true
    @State private var checkboxOff = false
    @State private var checkboxOn = true
    @State private var choice = "Automatic"
    @State private var workflowSegment = "Design"
    @State private var segment = "Auto"
    @State private var tab: ToolsTab = .all
    @State private var slider = 0.5
    @State private var integer = 8
    @State private var minutes = 30
    @State private var inherited = ""
    @State private var date = Date()
    @State private var timeHour = 9
    @State private var timeMinute = 30
    @State private var shortcut: Hotkey?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch family {
            case 4: toggles
            case 5: menus
            case 6: segmentedAndTabs
            case 7: numbers
            case 8: dates
            case 9: shortcuts
            case 10: badges
            case 11: avatars
            case 12: progress
            default: EmptyView()
            }
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Switch").font(.headline)
            HStack(alignment: .top, spacing: 32) {
                CatalogControlExample(switchOff ? "On" : "Off") {
                    Toggle("Switch", isOn: $switchOff).settingsSwitch().accessibilityLabel("Switch")
                }
                CatalogControlExample(switchOn ? "On" : "Off") {
                    Toggle("Switch", isOn: $switchOn).settingsSwitch().accessibilityLabel("Switch")
                }
                CatalogControlExample("Disabled off") {
                    Toggle("Switch", isOn: .constant(false)).settingsSwitch().disabled(true)
                }
                CatalogControlExample("Disabled on") {
                    Toggle("Switch", isOn: .constant(true)).settingsSwitch().disabled(true)
                }
            }
            Text("Checkbox").font(.headline)
            HStack(alignment: .top, spacing: 32) {
                CatalogControlExample(checkboxOff ? "Checked" : "Unchecked") {
                    Toggle("Checkbox", isOn: $checkboxOff).settingsCheckbox(showsLabel: false).accessibilityLabel("Checkbox")
                }
                CatalogControlExample(checkboxOn ? "Checked" : "Unchecked") {
                    Toggle("Checkbox", isOn: $checkboxOn).settingsCheckbox(showsLabel: false).accessibilityLabel("Checkbox")
                }
                CatalogControlExample("Disabled unchecked") {
                    Toggle("Checkbox", isOn: .constant(false)).settingsCheckbox(showsLabel: false).disabled(true)
                }
                CatalogControlExample("Disabled checked") {
                    Toggle("Checkbox", isOn: .constant(true)).settingsCheckbox(showsLabel: false).disabled(true)
                }
            }
        }
    }

    private var menus: some View {
        VStack(alignment: .leading, spacing: 24) {
            CatalogControlExample("Select") { select.disabled(false) }
            CatalogControlExample("Disabled select") { select.disabled(true) }
            CatalogControlExample("Menu button") {
                SettingsMenuButton(.secondary, "Menu", verbatim: true) {
                    Button("Menu item") {}
                    Button("Disabled menu item") {}.disabled(true)
                }
            }
            CatalogControlExample("Overflow button") {
                SettingsOverflowMenu(help: "More actions") { Button("Menu item") {} }
            }
        }
    }
    private var select: some View {
        SettingsMenuPicker(selection: $choice) {
            Text(verbatim: "Automatic").tag("Automatic")
            Text(verbatim: "On").tag("On")
            Text(verbatim: "Off").tag("Off")
        }.fixedSize()
    }
    private var segmentedAndTabs: some View {
        VStack(alignment: .leading, spacing: 24) {
            CatalogControlExample("Segmented control") {
                AssignedBaseSegmentedPicker(selection: $segment, options: ["Off", "Auto", "On"].map { .init($0, $0, verbatim: true) })
            }
            CatalogControlExample("Compact segmented control · workflow Design / Test") {
                AssignedBaseSegmentedPicker(selection: $workflowSegment,
                    options: ["Design", "Test"].map { .init($0, $0, verbatim: true) },
                    size: .compact, minimumOptionWidth: 96)
            }
            CatalogControlExample("Disabled segmented control") {
                AssignedBaseSegmentedPicker(selection: .constant("Auto"), options: ["Off", "Auto", "On"].map { .init($0, $0, verbatim: true) }).disabled(true)
            }
            CatalogControlExample("Tools · tabs with counts") {
                AnimatedTabSelector(selection: $tab, tabs: [.services, .all, .nativePlugins], counts: [.all: 12, .nativePlugins: 3])
            }
        }
    }
    private var numbers: some View {
        VStack(alignment: .leading, spacing: 24) {
            CatalogControlExample("Slider") {
                AssignedBaseSlider(value: $slider, range: 0...1, step: 0.05, label: "Slider").frame(width: 320)
                    .catalogStandaloneTarget(7, ["selected", "accent", "foreground", "radius", "trackHeight", "thumbSize", "height", "border", "borderWidth"], "Slider", element: "progress")
            }
            CatalogControlExample("Disabled slider") {
                AssignedBaseSlider(value: .constant(0.5), range: 0...1, step: 0.05, label: "Slider").frame(width: 320).disabled(true)
                    .catalogStandaloneTarget(7, ["disabledBackground", "disabledForeground"], "Disabled slider", element: "progress")
            }
            CatalogControlExample("Integer stepper") {
                SettingsStepper(value: $integer, range: 1...64).settingsFieldAccessibility("Integer stepper")
            }
            CatalogControlExample("Unit stepper") {
                SettingsStepper(value: $minutes, range: 0...1440, unit: "min").settingsFieldAccessibility("Unit stepper")
            }
            CatalogControlExample("Inherited value") {
                SettingsStepper(text: $inherited, range: 1...64, defaultValue: 8).settingsFieldAccessibility("Inherited value")
            }
        }
    }
    private var dates: some View {
        VStack(alignment: .leading, spacing: 24) {
            CatalogControlExample("Time · recurring schedules") { ScheduleTimePicker(hour: $timeHour, minute: $timeMinute).fixedSize() }
            CatalogControlExample("Time · one-time schedules") { OnceTimePicker(selectedDate: $date).fixedSize() }
            CatalogControlExample("Disabled time") { ScheduleTimePicker(hour: .constant(21), minute: .constant(30)).disabled(true).fixedSize() }
            CatalogControlExample("Date · workflow forms") { SettingsDatePicker(label: "Date", selection: $date) }
            CatalogControlExample("Date and time · Agent → Resume at") { SettingsDatePicker(label: "Date and time", selection: $date, components: [.date, .hourAndMinute]) }
            CatalogControlExample("Disabled date and time") { SettingsDatePicker(label: "Date and time", selection: $date, components: [.date, .hourAndMinute]).disabled(true) }
            Text("Style the closed fields here. Date fields keep the native macOS calendar; the native date/time format follows your Mac’s region settings. Scheduling time fields include an AM/PM button.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            CatalogControlExample("Shortcut recorder") { HotkeyRecorder(value: $shortcut) }
            CatalogControlExample("Keyboard hints") { PickerCardKeyHints().catalogStandaloneTarget(9, ["text", "secondary"], "Keyboard hints") }
        }
    }
    private var badges: some View {
        VStack(alignment: .leading, spacing: 24) {
            CatalogControlExample("Status badges") {
                HStack(spacing: 12) {
                    StatusChip("Neutral")
                    StatusChip("Accent", tone: .accent)
                    StatusChip("Success", tone: .success)
                    StatusChip("Warning", tone: .warning)
                    StatusChip("Error", tone: .error)
                    StatusChip("Info", tone: .info)
                }
            }
            CatalogControlExample("Dot and icon") {
                HStack(spacing: 12) {
                    StatusChip("Ready", tone: .success, showsDot: true)
                    StatusChip("Routine warning", tone: .warning, icon: "exclamationmark.triangle.fill")
                    StatusChip("Urgent warning", tone: .urgentWarning, icon: "exclamationmark.triangle.fill")
                }
            }
            CatalogControlExample("Count badges") {
                HStack(spacing: 12) { CountBadge(3); CountBadge(128); CountBadge(2, prominence: .attention) }
            }
        }
    }
    @Environment(\.theme) private var theme
    private var avatars: some View {
        HStack(alignment: .top, spacing: 32) {
            CatalogControlExample("Initial") { AgentAvatarView(mascotId: nil, name: "Research", tint: theme.border.focus, diameter: 24) }
            CatalogControlExample("Unnamed") { AgentAvatarView(mascotId: nil, name: "", tint: theme.border.focus, diameter: 24) }
            CatalogControlExample("Mascot") { AgentAvatarView(mascotId: "blue", name: "Osaurus", tint: theme.border.focus, diameter: 24) }
        }.catalogStandaloneTarget(11, ["background", "border", "borderWidth", "radius", "avatarSize"], "Avatar")
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { value in
                CatalogControlExample("Progress · \(Int(value * 100))%") {
                    SettingsProgressBar(value: value).frame(width: 320)
                        .catalogStandaloneTarget(12, ["selected", "accent", "trackHeight", "radius"], "Progress bar")
                }
            }
            CatalogControlExample("Loading indicator") { ProgressView().assignedProgressIndicator().catalogStandaloneTarget(12, ["accent"], "Loading indicator") }
            CatalogControlExample("Skeleton") {
                HStack(spacing: 12) {
                    SettingsSkeletonBar(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsSkeletonBar(width: 140, height: 12)
                        SettingsSkeletonBar(width: 90, height: 9)
                    }
                }.catalogStandaloneTarget(12, ["background", "height"], "Skeleton")
            }
        }
    }
}

struct CatalogControlExample<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).font(.caption).foregroundStyle(theme.text.secondary)
            content
        }
    }
}

private struct CatalogStandaloneTarget: ViewModifier {
    @Environment(\.theme) private var theme
    let family: Int
    let properties: [String]
    let name: String
    let element: String?
    func body(content: Content) -> some View {
        content.nativeCatalogTarget(properties.map { property in
            let key = "component.library.\(family)." + (element.map { "elements.\($0)." } ?? "") + property
            return NativeCatalogAssignment.key(key, theme: theme)
        }, name)
    }
}
private extension View {
    func catalogStandaloneTarget(_ family: Int, _ properties: [String], _ name: String, element: String? = nil) -> some View {
        modifier(CatalogStandaloneTarget(family: family, properties: properties, name: name, element: element))
    }
}
#endif

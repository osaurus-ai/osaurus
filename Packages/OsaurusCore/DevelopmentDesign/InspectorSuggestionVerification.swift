#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Existing menu views with local selection/access callbacks. The real composer
/// remains the proof for command-popup placement and keyboard ownership.
struct InspectorSuggestionVerification: View {
    @State private var commandIndex = 0
    @State private var fileIndex = 0
    @State private var fileState = "Files"
    @State private var selected = "None"
    @State private var accessCallbacks = 0
    private let commands = Array(SlashCommand.builtIns.prefix(2)) + [
        SlashCommand(name: "local-style-check", description: "A custom local example; no command is executed", template: "Local draft")
    ]
    private let files = [
        AtFileItem(name: "Research", path: "/tmp/inspector-local/Research", isDirectory: true),
        AtFileItem(name: "A-long-local-file-name-for-truncation.md", path: "/tmp/inspector-local/example.md", isDirectory: false)
    ]
    var body: some View {
        SettingsSection(title: "Native suggestion menus", layout: .plain, verbatimTitle: true) {
            SlashCommandPopup(commands: commands, selectedIndex: $commandIndex) {
                selected = "/" + $0.name
            }
            Picker("File menu state", selection: $fileState) {
                ForEach(["Files", "Empty", "Denied"], id: \.self) { Text(verbatim: $0).tag($0) }
            }
            AtFileMenuPopup(items: fileState == "Files" ? files : [],
                status: fileState == "Denied" ? .denied : .ok,
                deniedDirectoryName: "Local sample folder", emptyMessage: "No matching local files",
                selectedIndex: $fileIndex, onSelect: { selected = $0.name },
                onGrantAccess: { accessCallbacks += 1 })
            Text(verbatim: "Uses the production menu views. File paths are local sample labels. Selection only records a name; the access button does not request permissions.")
                .font(SettingsFont.caption)
        }
    }
}
#endif

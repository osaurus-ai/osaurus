#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// The app's editor, with disposable view-local content. Styling continues to
/// come from the existing saved assignments; editing the sample never saves a note.
struct CatalogNativeEditorPreview: View {
    @State private var notes = "Project notes\nA second paragraph to check line and paragraph spacing."
    @State private var variant = "Filled"
    @State private var fieldLayout = "Input only"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Editor example", selection: $variant) {
                ForEach(["Filled", "Empty", "Error", "Disabled"], id: \.self) { Text($0) }
            }
            Picker("Field layout", selection: $fieldLayout) {
                ForEach(["Input only", "With label", "With helper text", "With label and helper text"], id: \.self) { Text($0) }
            }
            SettingsFieldRow(label: fieldLayout.contains("label") ? "Project notes" : "",
                hint: fieldLayout.contains("helper") ? (variant == "Error" ? "Enter your project notes." : "Notes for this project.") : nil,
                verbatimHint: true, verbatimLabel: true) {
                SettingsTextEditor(text: $notes, placeholder: "Write your notes…", minHeight: 96,
                    isInvalid: variant == "Error")
                    .disabled(variant == "Disabled")
            }
        }
        .onChange(of: variant) { _, value in
            if value == "Empty" { notes = "" }
            else if notes.isEmpty { notes = "Project notes\nA second paragraph to check line and paragraph spacing." }
        }
    }
}
#endif

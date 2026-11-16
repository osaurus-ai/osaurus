#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// The original native database table with disposable display rows. No database
/// is opened, queried or mutated. Callbacks only update these local counters.
struct InspectorDataGridVerification: View {
    @Environment(\.theme) private var theme
    @State private var selected: Set<String> = []
    @State private var rowCount = 20
    @State private var opened = "None"
    @State private var pageRequests = 0
    @State private var editor = false
    @State private var editorEvents = "None"
    private var rows: [DataGridRowData] {
        (1...rowCount).map { n in
            DataGridRowData(key: "local-\(n)", cells: ["local-\(n)", "Local display row \(n)", n == 3 ? "Removed sample" : "Ready"],
                isDeleted: n == 3, selectable: n != 3)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents → Database → Tables · sample data")
            HStack {
                Button("Append local rows") { rowCount += 40 }
                Text("Rows: \(rowCount) · Selected: \(selected.sorted().joined(separator: ", "))")
            }
            InspectorDatabaseTableNames()
            Button("Open local row editor") { editor = true }
            Text("Local editor callback: \(editorEvents)")
            AgentDataGridRepresentable(columns: [DataGridColumn(title: "id", width: 180),
                DataGridColumn(title: "name", width: 240), DataGridColumn(title: "status", width: 180)],
                rows: rows, showsSelectionColumn: true, showsStatusColumn: true, showsOpenColumn: true,
                selectedRowKeys: $selected, theme: theme,
                onRowOpen: { opened = "Local row \($0 + 1)" }, onNeedsMoreRows: {
                    // The production model has a single-flight loading guard.
                    // A one-shot counter avoids inducing a layout/update loop here.
                    if pageRequests == 0 { pageRequests = 1 }
                })
                .frame(height: 340)
            Text("Select rows or try the row editor with sample data.")
        }.frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $editor) {
            DatabaseRowEditorSheet(row: .init(rowId: .integer(1), tableName: "local_notes",
                columns: [.init(name: "id", type: "INTEGER", nullable: false, defaultValue: nil, primaryKey: true),
                    .init(name: "title", type: "TEXT", nullable: false, defaultValue: nil, primaryKey: false),
                    .init(name: "note", type: "TEXT", nullable: true, defaultValue: nil, primaryKey: false)],
                values: [.integer(1), .text("Disposable local title"), .null], isDeleted: false),
                onSave: { values in editorEvents = "Save: " + (values["title"].map(agentSQLDisplayString) ?? "None"); editor = false },
                onSoftDelete: { editorEvents = "Local Delete"; editor = false },
                onRestore: { editorEvents = "Local Restore"; editor = false },
                onCancel: { editorEvents = "Cancel"; editor = false })
        }
    }
}
#endif

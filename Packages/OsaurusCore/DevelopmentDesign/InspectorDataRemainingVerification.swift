#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

struct InspectorDataRemainingVerification: View {
    @Environment(\.theme) private var theme
    @State private var display = "Knowledge"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sample data for Knowledge, Memory, and Agents → Database")
            Picker("Data display", selection: $display) {
                ForEach(["Knowledge", "Indexing knowledge", "Memory", "Database tables", "Database saved views", "Database history"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu)
            switch display {
            case "Knowledge": KnowledgeView.inspectionPopulatedCard(false)
            case "Indexing knowledge": KnowledgeView.inspectionPopulatedCard(true)
            case "Memory":
                PinnedFactRow(fact: PinnedFact(agentId: "local", content: "Local high-salience fact. Original memory row, no memory database write.", salience: 0.9, useCount: 3, createdAt: "Oct22", tagsCSV: "local,display"), onDelete: {})
                PinnedFactRow(fact: PinnedFact(agentId: "local", content: "Local medium-salience fact.", salience: 0.5, createdAt: "Oct22"), onDelete: {})
                PinnedFactRow(fact: PinnedFact(agentId: "local", content: "Local low-salience fact.", salience: 0.2, createdAt: "Oct22"), onDelete: {})
                EpisodeRow(episode: Episode(agentId: "local", conversationId: "local", summary: "Original populated episode summary with local display values.", topicsCSV: "Design, verification", salience: 0.8, tokenCount: 320, conversationAt: "Oct22"))
                MemoryCountLabel(count: 3)
            case "Database tables": InspectorDataGridVerification()
            case "Database saved views": DatabaseSavedViewsView.inspectionPopulatedRows()
            case "Database history": DatabaseHistoryView.inspectionPopulatedHistory()
            default: EmptyView()
            }
        }.environment(\.theme, theme.catalogFamily(53))
    }
}
#endif

#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

struct InspectorAgentProgressVerification: View {
    @State private var variant = "Task checklist"
    @State private var feed = makeFeed("Subagent · running")
    private static let variants = ["Task checklist", "Completion summary", "Blocked summary", "Subagent · running", "Subagent · completed", "Subagent · failed", "Computer-use event types"]
    private static func makeFeed(_ variant: String) -> SubagentFeed {
        let value = SubagentFeed(toolCallId: "inspector-local-feed-35", kindId: "spawn", title: "Review proposal", suppressActivityMirror: true)
        value.emit(.init(kind: .phase, title: "Reviewing proposal", detail: "Compare the available approaches."))
        value.emit(.init(kind: .progress, title: "Review progress", detail: "Two of three items checked", fraction: 0.67))
        if variant == "Computer-use event types" {
            let kinds: [SubagentActivityEvent.Kind] = [.perceive,.propose,.confirmRequested,.confirmed,.denied,.blocked,.act,.verify,.retry,.reasoning,.response,.narrate,.error]
            for kind in kinds { value.emit(.init(kind: kind, title: kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, detail: "Event detail from the delegated task", success: [.denied,.blocked,.error].contains(kind) ? false : nil)) }
        }
        if variant == "Subagent · completed" { value.finish(success: true, summary: "Proposal review complete") }
        if variant == "Subagent · failed" { value.finish(success: false, summary: "Proposal could not be reviewed") }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Used in Chat", selection: $variant) { ForEach(Self.variants, id: \.self) { Text($0).tag($0) } }
                .onChange(of: variant) { _, value in feed = Self.makeFeed(value) }
            switch variant {
            case "Task checklist": InlineTodoBlock(todo: .parse("- [x] Review the proposal\n- [ ] Compare the alternatives\n- [ ] Confirm the recommendation"))
            case "Completion summary", "Blocked summary": InlineCompleteBlock(summary: variant == "Blocked summary" ? "The review needs additional information." : "The proposal is ready for review.", isBlocked: variant == "Blocked summary", onDismiss: {})
            default: SubagentFeedView(feed: feed).id(ObjectIdentifier(feed)).frame(maxWidth: 800).frame(height: 340)
            }
            Text("Chat · checklists and completion summaries appear in the agent reply. Subagent and computer-use events appear inside the corresponding expanded tool activity. Preview data only; no agent or tool runs.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif

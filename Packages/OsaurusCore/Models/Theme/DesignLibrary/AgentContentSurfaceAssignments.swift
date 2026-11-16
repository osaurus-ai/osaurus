import SwiftUI

/// Editable semantic assignments for actual agent-content surfaces. Nested code
/// blocks retain their independent family-32 surface and saved assignments.
enum AgentContentSurfaceAssignments {
    struct Entry {
        let key: String
        let label: String
        let token: String
    }
    static let entries: [Entry] = {
        var result: [Entry] = []
        let parts: [(Int, String, String)] = [
            (30, "agentHeader", "Agent identity header"), (30, "replyActions", "Agent reply action row"),
            (33, "reasoningCard", "Reasoning card"), (33, "reasoningHeader", "Reasoning header"),
            (33, "reasoningContent", "Expanded reasoning content"), (33, "generation", "Generation status row"),
            (34, "toolCard", "Tool result card"), (34, "toolHeader", "Tool result header"),
            (34, "toolContent", "Expanded tool arguments and result"),
            (34, "activityCard", "Grouped activity card"), (34, "activityHeader", "Grouped activity header"),
            (34, "activityContent", "Expanded grouped activity"), (34, "pendingTool", "Pending tool call"),
            (35, "todo", "Agent task progress"), (35, "completion", "Agent completion card"),
            (35, "subagentFeed", "Subagent activity feed")
        ]
        for (family, part, title) in parts {
            result.append(.init(key: key(family, part), label: title + " — Background", token: "color.surface.canvas"))
            if (part.hasSuffix("Header") && [33, 34].contains(family)) || part == "todo" {
                result.append(.init(key: key(family, part, "hover"), label: title + " — Hover background", token: "color.surface.canvas"))
                result.append(.init(key: key(family, part, "selected"), label: title + " — Expanded background", token: "color.surface.canvas"))
            }
        }
        result.append(.init(key: key(40, "emptyResponse"), label: "Empty agent response notice — Background", token: "color.surface.canvas"))
        result.append(.init(key: key(40, "noticePill"), label: "Conversation summary marker — Background", token: "color.surface.hover"))
        return result
    }()
    static let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
    static func key(_ family: Int, _ part: String, _ state: String = "background") -> String {
        "component.library.\(family).elements.\(part).\(state)"
    }
    static func keys(_ family: Int) -> [String] {
        entries.filter { $0.key.hasPrefix("component.library.\(family).") }.map(\.key)
    }
    static func extend(_ mappings: [String: String]) -> [String: String] {
        var result = mappings
        for entry in entries where result[entry.key] == nil { result[entry.key] = entry.token }
        return result
    }
    static func color(_ family: Int, _ part: String, _ theme: any ThemeProtocol,
                      state: String = "background") -> Color {
        theme.assignedColor(key(family, part, state), fallback: theme.surface.canvas)
    }
}

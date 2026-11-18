//
//  WorkflowFlowStyle.swift
//  osaurus
//
//  How a step and an edge look wherever the flow is drawn: the full view's
//  cards and lines, its inspector, and the step editor's header.
//

import Foundation

enum WorkflowFlowStyle {
    static func icon(_ node: WorkflowNode) -> String {
        switch node.kind {
        case nil: return "circle.dashed"
        case .dialog: return "person.text.rectangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .tool: return "wrench.and.screwdriver"
        case .http: return "network"
        case .wait: return "clock"
        case .map: return "square.stack.3d.down.right"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .state: return "tray.full"
        case .reply: return "arrowshape.turn.up.left"
        case .media(let spec): return spec.action == .video ? "film" : "photo.on.rectangle.angled"
        case .agent(let spec): return spec.workspace == nil ? "person.crop.circle" : "person.2"
        case .inference(let spec):
            switch spec.mode {
            case .generate: return "sparkles"
            case .decide: return "arrow.triangle.branch"
            case .agentic: return "hammer"
            }
        }
    }

    /// The media an edge carries, keyed by "from→to".
    static func edgeTypes(_ def: WorkflowDefinition) -> [String: BindingTypeResolver.ValueType] {
        var out: [String: BindingTypeResolver.ValueType] = [:]
        for edge in def.edges {
            guard let from = def.node(edge.from), let to = def.node(edge.to),
                let type = BindingTypeResolver.edgeType(from: from, to: to, in: def)
            else { continue }
            out["\(edge.from)→\(edge.to)"] = type
        }
        return out
    }
}

//
//  WorkflowFlowMinimap.swift
//  osaurus
//
//  The whole graph in miniature, each step a small block in its run's
//  colors, with the part on screen outlined. Click or drag in it to move.
//

import SwiftUI

struct WorkflowFlowMinimap: View {
    /// Step frames on the canvas, before zoom.
    let frames: [String: CGRect]
    /// The canvas's size, before zoom.
    let content: CGSize
    /// The part of the canvas on screen, in canvas points.
    let visible: CGRect
    let statuses: [String: NodeRunStatus]
    let selected: String?
    /// Centers the view on a canvas point.
    var onMove: (CGPoint) -> Void

    static let maxSize = CGSize(width: 200, height: 150)

    @Environment(\.theme) private var theme

    private var scale: CGFloat {
        guard content.width > 0, content.height > 0 else { return 0 }
        return min(Self.maxSize.width / content.width, Self.maxSize.height / content.height)
    }

    var body: some View {
        let scale = scale
        Canvas { context, _ in
            for (id, frame) in frames {
                let rect = CGRect(
                    x: frame.minX * scale, y: frame.minY * scale,
                    width: max(frame.width * scale, 2), height: max(frame.height * scale, 2))
                let path = Path(roundedRect: rect, cornerRadius: theme.radius.small / 2)
                context.fill(path, with: .color(color(statuses[id])))
                if id == selected {
                    context.stroke(path, with: .color(theme.border.focus), lineWidth: theme.stroke.focus)
                }
            }
            let view = CGRect(
                x: visible.minX * scale, y: visible.minY * scale,
                width: visible.width * scale, height: visible.height * scale)
            let outline = Path(roundedRect: view, cornerRadius: theme.radius.small)
            var wash = context
            wash.opacity = 0.12
            wash.fill(outline, with: .color(theme.text.link))
            context.stroke(outline, with: .color(theme.text.link), lineWidth: theme.stroke.focus)
        }
        .frame(width: content.width * scale, height: content.height * scale)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                guard scale > 0 else { return }
                onMove(CGPoint(x: value.location.x / scale, y: value.location.y / scale))
            }
        )
        .pointingHandCursor()
        .padding(theme.space.s8)
        .settingsChrome(.overlay, radius: theme.radius.large)
        .help(L("Click or drag to move around"))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: L("Overview of the whole workflow")))
    }

    private func color(_ status: NodeRunStatus?) -> Color {
        switch status {
        case .running?, .awaitingUser?: return theme.statusInk(.info)
        case .done?, .pinned?: return theme.statusInk(.success)
        case .failed?: return theme.statusInk(.error)
        default: return theme.border.strong
        }
    }
}

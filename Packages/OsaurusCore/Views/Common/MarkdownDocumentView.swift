//
//  MarkdownDocumentView.swift
//  osaurus
//
//  A non-streaming, self-sizing SwiftUI wrapper around the chat
//  `NativeMarkdownView` so static markdown documents (e.g. a Hugging Face
//  model card / README) can render with the same full-fidelity engine the
//  chat uses — headings, lists, code blocks, links, tables, math — without
//  reimplementing a renderer.
//
//  Sizing: `NativeMarkdownView` lays out at a given width and reports an
//  exact content height via `measuredHeight(for:)` / `onHeightChanged`. We
//  surface that height to SwiftUI through a binding and apply it as a fixed
//  frame, so the document participates correctly in a parent `ScrollView`.
//

import AppKit
import SwiftUI

/// Renders a static markdown string using the chat markdown engine,
/// sizing itself to the rendered content height at the available width.
struct MarkdownDocument: View {
    let text: String

    @Environment(\.theme) private var theme
    @State private var height: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            MarkdownDocumentRepresentable(
                text: text,
                width: geo.size.width,
                theme: theme,
                measuredHeight: $height
            )
        }
        .frame(height: max(height, 1))
        // Keep content (e.g. a tall banner that hasn't settled its height yet)
        // from drawing outside the measured frame and over sibling views.
        .clipped()
    }
}

/// `NSViewRepresentable` bridge to `NativeMarkdownView`, configured for a
/// static (non-streaming) document and reporting its measured height.
private struct MarkdownDocumentRepresentable: NSViewRepresentable {
    let text: String
    let width: CGFloat
    let theme: any ThemeProtocol
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> NativeMarkdownView {
        let view = NativeMarkdownView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onHeightChanged = { [weak view] in
            guard let view else { return }
            propagateHeight(view.measuredHeight(for: width))
        }
        return view
    }

    func updateNSView(_ nsView: NativeMarkdownView, context: Context) {
        guard width > 0.5 else { return }
        nsView.configure(
            text: text,
            width: width,
            theme: theme,
            cacheKey: nil,
            isStreaming: false
        )
        propagateHeight(nsView.measuredHeight(for: width))
    }

    /// Push a new height into the binding on the main actor, guarding
    /// against the layout feedback loop (height change -> SwiftUI relayout
    /// -> updateNSView -> measure -> height change ...).
    private func propagateHeight(_ newHeight: CGFloat) {
        let clamped = max(newHeight, 1)
        DispatchQueue.main.async {
            if abs(measuredHeight - clamped) > 0.5 {
                measuredHeight = clamped
            }
        }
    }
}

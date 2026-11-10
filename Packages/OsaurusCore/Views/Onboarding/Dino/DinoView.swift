//
//  DinoView.swift
//  osaurus
//
//  Renders a `DinoDirector`'s dinosaur in a `size`-point box. The artboard
//  draws the dino in its central quarter and lets jumps, fireballs, and
//  naps spill past it, so the Rive canvas is four times the box, centered
//  and unclipped. It never takes clicks: gestures belong to the box. It
//  stops drawing while its window is hidden or the view is off screen.
//

import AppKit
import RiveRuntime
import SwiftUI

struct DinoView: View {
    @ObservedObject var director: DinoDirector
    let size: CGFloat
    var frameRate: FrameRate = .default

    @State private var isOnScreen = true

    /// Canvas side over dino box side, from the artboard's layout.
    static let renderScale: CGFloat = 4

    var body: some View {
        ZStack {
            switch director.phase {
            case .ready:
                RiveUIViewRepresentable(rive: director.rive)
                    .paused(director.isPaused || !isOnScreen)
                    .frameRate(frameRate)
                    .frame(width: size * Self.renderScale, height: size * Self.renderScale)
                    .transition(.opacity)
            case .failed:
                Image("osaurus-brain", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: director.facingLeft ? -1 : 1)
            case .loading:
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .background(DinoWindowVisibility { isOnScreen = $0 })
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            isOnScreen = true
            director.load()
        }
        .onDisappear { isOnScreen = false }
    }
}

/// Reports whether the hosting window is visible on screen (not hidden,
/// minimized, or fully covered).
private struct DinoWindowVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = onChange
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(occlusionChanged),
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: window
                )
            }
            occlusionChanged()
        }

        /// Deferred: moving between windows happens inside SwiftUI updates.
        @objc private func occlusionChanged() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onChange?(self.window?.occlusionState.contains(.visible) ?? false)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

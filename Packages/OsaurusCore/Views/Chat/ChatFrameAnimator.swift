//
//  ChatFrameAnimator.swift
//  osaurus
//
//  Steps a short animation once per display frame. The chat thread drives
//  its scroll origin and disclosure row heights through this instead of
//  Core Animation so every frame goes through the same layout path a
//  measured height takes: the table, the follow-the-bottom logic and the
//  rows below all see each intermediate value.
//

import AppKit
import QuartzCore

@MainActor
final class ChatFrameAnimator: NSObject {
    enum Curve {
        case easeOut
        case easeInOut

        func value(at t: CGFloat) -> CGFloat {
            let t = min(1, max(0, t))
            switch self {
            case .easeOut:
                let inv = 1 - t
                return 1 - inv * inv * inv
            case .easeInOut:
                return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            }
        }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var curve: Curve = .easeOut
    private var step: ((CGFloat) -> Void)?
    private var completion: (() -> Void)?
    /// Bumped on every run and stop so a queued fallback tick from an
    /// earlier run can't step the current one.
    private var generation = 0

    var isRunning: Bool { step != nil }

    /// Time left in the current run, 0 when idle.
    var remaining: CFTimeInterval {
        guard isRunning else { return 0 }
        return max(0, duration - (CACurrentMediaTime() - startTime))
    }

    /// Start a run, replacing any current one without calling its completion.
    /// `step` receives the eased progress, 0 to 1; the last call is always 1.
    func run(
        duration: CFTimeInterval,
        curve: Curve = .easeOut,
        on view: NSView,
        step: @escaping (CGFloat) -> Void,
        completion: (() -> Void)? = nil
    ) {
        stop()
        guard duration > 0 else {
            step(1)
            completion?()
            return
        }
        self.duration = duration
        self.curve = curve
        self.step = step
        self.completion = completion
        startTime = CACurrentMediaTime()
        generation += 1
        // A display link only ticks for a window on screen.
        if view.window?.isVisible == true {
            let link = view.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            scheduleFallbackTick(generation)
        }
    }

    /// Cancel the current run where it stands. Its completion is not called.
    func stop() {
        generation += 1
        link?.invalidate()
        link = nil
        step = nil
        completion = nil
    }

    /// Jump the current run to its end and call its completion.
    func finish() {
        guard let step else { return }
        let completion = completion
        stop()
        step(1)
        completion?()
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        tick()
    }

    private func scheduleFallbackTick(_ generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            guard let self, self.generation == generation, self.isRunning else { return }
            self.tick()
            if self.generation == generation, self.isRunning { self.scheduleFallbackTick(generation) }
        }
    }

    private func tick() {
        guard let step else { return }
        let t = CGFloat((CACurrentMediaTime() - startTime) / duration)
        if t >= 1 {
            finish()
            return
        }
        step(curve.value(at: t))
    }
}

/// A disclosure view's height while it opens or closes (tool rows, thinking,
/// activity groups). Steps from the height on screen toward the view's
/// current measured height, re-read every frame, so content that measures
/// late (a result laying out, a markdown block highlighting) extends the
/// same motion instead of snapping after it. Each frame goes through the
/// view's own height constraint and `onHeightChanged`, so the group, the
/// cell and the table row below move with it. The view clips to its bounds
/// while running: expanded content is revealed by the growing edge, and
/// collapsing content stays drawn until the edge has passed it.
@MainActor
final class DisclosureHeightAnimation {
    static var duration: CFTimeInterval { ChatFrameAnimator.reduceMotion ? 0 : 0.24 }

    private let animator = ChatFrameAnimator()
    private weak var view: NSView?
    private var restoresMasking: Bool?

    /// The interpolated height while running, nil at rest.
    private(set) var displayed: CGFloat?

    var isRunning: Bool { animator.isRunning }

    /// Set while the view configures: its children report heights as they
    /// are built, and applying those would move the view to the new height
    /// before a disclosure starts from the old one.
    var isConfiguring = false

    /// Whether a height change should wait: the view applies or animates
    /// once at the end of configure, and a run in flight reads the new
    /// measurement on its next frame.
    var holdsHeight: Bool { isConfiguring || isRunning }

    /// Height to lay the view out at for its measured `target`.
    func height(measured target: CGFloat) -> CGFloat { displayed ?? target }

    /// Replaces a run in flight without calling its `finish`: a collapse
    /// reversed into an expand must not hide the content at its end.
    func run(
        on view: NSView,
        from start: CGFloat,
        target: @escaping () -> CGFloat,
        apply: @escaping (CGFloat) -> Void,
        finish: @escaping () -> Void
    ) {
        animator.stop()
        guard Self.duration > 0, view.window != nil, abs(target() - start) > 0.5 else {
            endMasking()
            displayed = nil
            apply(target())
            finish()
            return
        }
        self.view = view
        if restoresMasking == nil, let layer = view.layer {
            restoresMasking = layer.masksToBounds
            layer.masksToBounds = true
        }
        displayed = start
        animator.run(
            duration: Self.duration,
            curve: .easeInOut,
            on: view,
            step: { [weak self, weak view] progress in
                guard let self else { return }
                guard view?.window != nil else {
                    self.animator.finish()
                    return
                }
                let height = start + (target() - start) * progress
                self.displayed = height
                apply(height)
            },
            completion: { [weak self] in
                guard let self else { return }
                self.displayed = nil
                self.endMasking()
                apply(target())
                finish()
            }
        )
    }

    /// Drop a run in flight without applying or finishing it, for a view
    /// being reused for different content.
    func cancel() {
        animator.stop()
        displayed = nil
        endMasking()
    }

    private func endMasking() {
        if let restoresMasking { view?.layer?.masksToBounds = restoresMasking }
        restoresMasking = nil
    }
}

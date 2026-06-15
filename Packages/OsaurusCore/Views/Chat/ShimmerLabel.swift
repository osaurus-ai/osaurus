//
//  ShimmerLabel.swift
//  osaurus
//
//  A single-line label whose text is filled with a horizontally-sweeping
//  shimmer gradient while animating — the in-progress affordance common to AI
//  chat interfaces (a light band travels across the text). When stopped it
//  renders the text in a solid base color. Used for "running" tool-call titles,
//  the pending tool title, and the streaming "Thinking" title.
//
//  Implementation: a CAGradientLayer (base → highlight → base) masked by a
//  CATextLayer of the same string, with the gradient's `locations` animated so
//  the bright band sweeps across the glyphs.
//

import AppKit
import QuartzCore

final class ShimmerLabel: NSView {

    private let gradientLayer = CAGradientLayer()
    private let textMaskLayer = CATextLayer()

    private var text: String = ""
    private var font: NSFont = .systemFont(ofSize: 12, weight: .semibold)
    private var baseColor: NSColor = .secondaryLabelColor
    private var highlightColor: NSColor = .labelColor
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradientLayer)
        gradientLayer.mask = textMaskLayer
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)

        textMaskLayer.truncationMode = .end
        textMaskLayer.isWrapped = false
        textMaskLayer.alignmentMode = .left
        textMaskLayer.foregroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, font: NSFont, baseColor: NSColor, highlightColor: NSColor) {
        self.text = text
        self.font = font
        self.baseColor = baseColor
        self.highlightColor = highlightColor

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        textMaskLayer.contentsScale = scale
        gradientLayer.contentsScale = scale
        textMaskLayer.font = font
        textMaskLayer.fontSize = font.pointSize
        textMaskLayer.string = text

        applyColors()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
        textMaskLayer.frame = bounds
        if animating { addSweepAnimation() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // CA animations are dropped when a layer leaves the window; re-add on return.
        if window != nil, animating { addSweepAnimation() }
    }

    func start() {
        guard !animating else { return }
        animating = true
        applyColors()
        addSweepAnimation()
    }

    func stop() {
        animating = false
        gradientLayer.removeAnimation(forKey: "shimmer")
        // Solid base color when idle.
        gradientLayer.colors = [baseColor.cgColor, baseColor.cgColor, baseColor.cgColor]
    }

    private func applyColors() {
        gradientLayer.colors =
            animating
            ? [baseColor.cgColor, highlightColor.cgColor, baseColor.cgColor]
            : [baseColor.cgColor, baseColor.cgColor, baseColor.cgColor]
        gradientLayer.locations = [0.0, 0.5, 1.0]
    }

    private func addSweepAnimation() {
        // `layout()` and `viewDidMoveToWindow()` both call this while running.
        // Re-adding under the same key replaces the in-flight animation and
        // snaps the sweep back to its start, which reads as a stutter during
        // token streaming (frequent re-layouts). Only add when none is live.
        guard gradientLayer.animation(forKey: "shimmer") == nil else { return }
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-1.0, -0.5, 0.0]
        anim.toValue = [1.0, 1.5, 2.0]
        anim.duration = 1.3
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        gradientLayer.add(anim, forKey: "shimmer")
    }
}

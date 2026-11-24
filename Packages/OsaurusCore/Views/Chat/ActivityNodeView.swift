//
//  ActivityNodeView.swift
//  osaurus
//
//  The rounded-square status node shared by every transcript activity row:
//  tool calls, the pending tool call, reasoning and the grouped activity
//  header. A `CAShapeLayer` draws the tinted fill and the status ring so the
//  ring can be traced on during a reveal; while running, a conic highlight
//  travels around the ring and the glyph breathes. When a run finishes the
//  node settles with a short pop in its outcome color.
//

import AppKit
import QuartzCore

enum ActivityNodeStyle {
    /// Side of the node in every activity row.
    static let side: CGFloat = 24

    /// The theme's medium radius, held to a squircle-like proportion so the
    /// node stays a rounded square rather than turning into a circle.
    static func cornerRadius(side: CGFloat, theme: any ThemeProtocol) -> CGFloat {
        min(CGFloat(theme.radius.medium), side * 0.3)
    }

    /// The card outline every activity surface shares.
    static func applyCard(_ layer: CALayer?, theme: any ThemeProtocol, borderWidth: CGFloat) {
        layer?.borderColor = NSColor(theme.isDark ? theme.border.default : theme.border.subtle).cgColor
        layer?.borderWidth = borderWidth
        layer?.cornerRadius = CGFloat(theme.radius.large)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

final class ActivityNodeView: NSView {
    /// Duration of the clockwise ring trace on reveal.
    static let ringDrawDuration: CFTimeInterval = 0.34
    private static let ringDrawKey = "ring.draw"
    private static let orbitKey = "node.orbit"
    private static let breatheKey = "node.breathe"
    private static let orbitPeriod: CFTimeInterval = 1.1
    private static let breathePeriod: CFTimeInterval = 0.8
    private static let popDuration: CFTimeInterval = 0.38
    private static let swellDuration: CFTimeInterval = 0.42

    /// Status glyph, centered. Owners set its image and size it through
    /// `glyphSize`.
    let glyph = NSImageView()

    var cornerRadius: CGFloat = 7 {
        didSet { if cornerRadius != oldValue { updatePath() } }
    }
    var glyphSize: CGFloat = 13 {
        didSet {
            glyphWidth?.constant = glyphSize
            glyphHeight?.constant = glyphSize
        }
    }
    var ringWidth: CGFloat {
        get { shape.lineWidth }
        set {
            shape.lineWidth = newValue
            orbitMask.lineWidth = newValue + 0.75
            updatePath()
        }
    }

    private(set) var isRunning = false

    private let shape = CAShapeLayer()
    private let orbitHost = CALayer()
    private let orbitMask = CAShapeLayer()
    private let orbitGradient = CAGradientLayer()
    private var glyphWidth: NSLayoutConstraint?
    private var glyphHeight: NSLayoutConstraint?
    private var drawPending = false
    /// Absolute begin time captured at `drawRing` so a deferred layout pass
    /// can't desync the ring from animations scheduled alongside it.
    private var pendingBeginAt: CFTimeInterval = 0
    /// Target fill captured before `drawRing` clears the model value, so the
    /// fill doesn't render at its final color before the ring traces.
    private var pendingFillTarget: CGColor?

    private static let suppressedActions: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "strokeEnd": NSNull(), "strokeColor": NSNull(),
        "fillColor": NSNull(), "path": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
        "contents": NSNull(), "transform": NSNull(), "lineWidth": NSNull(), "colors": NSNull(),
        "mask": NSNull(), "frame": NSNull(),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.lineWidth = 1
        shape.strokeEnd = 1
        shape.actions = Self.suppressedActions

        orbitHost.actions = Self.suppressedActions
        orbitHost.isHidden = true
        orbitMask.fillColor = nil
        orbitMask.strokeColor = NSColor.black.cgColor
        orbitMask.lineWidth = 1.75
        orbitMask.actions = Self.suppressedActions
        orbitHost.mask = orbitMask
        orbitGradient.type = .conic
        orbitGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        orbitGradient.endPoint = CGPoint(x: 0.5, y: 1)
        orbitGradient.locations = [0, 0.06, 0.55, 1]
        orbitGradient.actions = Self.suppressedActions
        orbitHost.addSublayer(orbitGradient)
        shape.addSublayer(orbitHost)

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.wantsLayer = true
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.layer?.actions = Self.suppressedActions
        addSubview(glyph)
        let w = glyph.widthAnchor.constraint(equalToConstant: glyphSize)
        let h = glyph.heightAnchor.constraint(equalToConstant: glyphSize)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor), w, h,
        ])
        glyphWidth = w
        glyphHeight = h
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { shape }

    override func layout() {
        super.layout()
        updatePath()
        if drawPending { startDrawIfReady() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, isRunning { addRunningAnimations() }
    }

    // MARK: Colors

    /// Tints the node for `color` over `backing` (the surface it sits on):
    /// a faint fill, a mid-strength ring and a full-strength glyph.
    func apply(color: NSColor, backing: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.fillColor = (backing.blended(withFraction: 0.14, of: color) ?? backing).cgColor
        shape.strokeColor = (backing.blended(withFraction: 0.42, of: color) ?? color).cgColor
        glyph.contentTintColor = color
        // The conic gradient runs counterclockwise from its start angle; the
        // head sits at the start and the tail fades behind it as it orbits
        // clockwise.
        let clear = color.withAlphaComponent(0).cgColor
        orbitGradient.colors = [color.cgColor, color.withAlphaComponent(0.9).cgColor, clear, clear]
        CATransaction.commit()
    }

    // MARK: Running

    func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        if running {
            addRunningAnimations()
        } else {
            orbitHost.isHidden = true
            orbitGradient.removeAnimation(forKey: Self.orbitKey)
            glyph.layer?.removeAnimation(forKey: Self.breatheKey)
        }
    }

    private func addRunningAnimations() {
        guard !ThemeMotion.reduceMotionEnabled else {
            orbitHost.isHidden = true
            return
        }
        orbitHost.isHidden = false
        if orbitGradient.animation(forKey: Self.orbitKey) == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = Self.orbitPeriod
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            orbitGradient.add(spin, forKey: Self.orbitKey)
        }
        if let glyphLayer = glyph.layer, glyphLayer.animation(forKey: Self.breatheKey) == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.55
            breathe.duration = Self.breathePeriod
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.isRemovedOnCompletion = false
            glyphLayer.add(breathe, forKey: Self.breatheKey)
        }
    }

    /// The finish beat: the glyph pops back in and the ring swells briefly.
    /// Call after `apply(color:backing:)` has set the outcome color.
    func playSettle() {
        guard !ThemeMotion.reduceMotionEnabled else { return }
        if let glyphLayer = glyph.layer {
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.6, 1.14, 1]
            pop.keyTimes = [0, 0.6, 1]
            pop.duration = Self.popDuration
            pop.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            glyphLayer.add(pop, forKey: "node.settle")
        }
        let swell = CAKeyframeAnimation(keyPath: "lineWidth")
        swell.values = [shape.lineWidth, shape.lineWidth + 1.5, shape.lineWidth]
        swell.keyTimes = [0, 0.4, 1]
        swell.duration = Self.swellDuration
        swell.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shape.add(swell, forKey: "node.swell")
    }

    // MARK: Ring reveal

    /// Trace the ring in clockwise and fade the fill in, starting at
    /// `beginAt` on the `CACurrentMediaTime()` timeline.
    func drawRing(beginAt: CFTimeInterval) {
        if drawPending || shape.animation(forKey: Self.ringDrawKey) != nil { return }
        drawPending = true
        pendingBeginAt = beginAt
        pendingFillTarget = shape.fillColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeEnd = 0
        shape.fillColor = NSColor.clear.cgColor
        CATransaction.commit()
        if bounds.width > 1 {
            startDrawIfReady()
        } else {
            needsLayout = true
        }
    }

    /// Show the full ring with no animation (load / reuse / already drawn).
    func showRingFull() {
        if drawPending || shape.animation(forKey: Self.ringDrawKey) != nil { return }
        shape.strokeEnd = 1
    }

    private func startDrawIfReady() {
        guard drawPending, bounds.width > 1 else { return }
        drawPending = false
        let fillTarget = pendingFillTarget ?? shape.fillColor
        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0
        stroke.toValue = 1
        stroke.fillMode = .both
        stroke.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let fill = CABasicAnimation(keyPath: "fillColor")
        fill.fromValue = NSColor.clear.cgColor
        fill.toValue = fillTarget
        fill.fillMode = .both
        let group = CAAnimationGroup()
        group.animations = [stroke, fill]
        group.duration = Self.ringDrawDuration
        group.beginTime = pendingBeginAt
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeEnd = 1
        shape.fillColor = fillTarget
        CATransaction.commit()
        shape.add(group, forKey: Self.ringDrawKey)
    }

    // MARK: Geometry

    private func updatePath() {
        guard bounds.width > 1 else { return }
        let inset = shape.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = max(0, min(cornerRadius - inset, rect.width / 2, rect.height / 2))
        // Starts at top center and runs clockwise on screen (y grows upward
        // in this layer), so `strokeEnd` traces the ring clockwise.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
            radius: radius)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.midX, y: rect.maxY),
            radius: radius)
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        orbitHost.frame = bounds
        orbitMask.frame = bounds
        orbitMask.path = path
        let side = ceil(hypot(bounds.width, bounds.height))
        orbitGradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        orbitGradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

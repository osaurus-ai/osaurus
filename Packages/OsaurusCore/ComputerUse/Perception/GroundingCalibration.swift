//
//  GroundingCalibration.swift
//  OsaurusCore — Computer Use
//
//  Measures which coordinate frame a local model points in when its bundle
//  doesn't say. The model is shown a few synthetic app screens, each sized to
//  its frame budget and far from 1000 px on a side, and asked to click one
//  labeled button. The schema and prompt name no coordinate convention, so
//  the answer is in whatever frame the model was trained on. Each answer is
//  scored under every candidate frame; the target boxes are placed so no two
//  frames can both hit, and a frame is adopted only when it alone hits on at
//  least `requiredHitFraction` of the screens. Otherwise the model stays on
//  marks and `describe`.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GroundingCalibration {

    static let requiredHitFraction = 2.0 / 3.0
    /// Slack around a target box, in image pixels.
    static let hitTolerance: Double = 3

    struct Trial: Sendable, Equatable {
        var image: CUImage
        var label: String
        /// Target button, image pixels, top-left origin.
        var box: CGRect
    }

    struct Result: Sendable, Equatable {
        var outcome: GroundingCalibrationOutcome
        var hits: [GroundingProfile.CoordinateFrame: Int]
        var trials: Int
        var decodeTokensPerSecond: [Double] = []
    }

    // MARK: Scoring

    /// Score one `target.point` per trial (nil = the model gave none).
    static func score(points: [AgentPoint?], trials: [Trial]) -> Result {
        var hits = Dictionary(uniqueKeysWithValues: GroundingProfile.CoordinateFrame.allCases.map { ($0, 0) })
        for (point, trial) in zip(points, trials) {
            guard let point else { continue }
            for frame in GroundingProfile.CoordinateFrame.allCases
            where hit(point, frame: frame, trial: trial) {
                hits[frame, default: 0] += 1
            }
        }
        let needed = Int((Double(trials.count) * requiredHitFraction).rounded(.up))
        let ranked = hits.sorted { $0.value > $1.value }
        let outcome: GroundingCalibrationOutcome
        if let best = ranked.first, best.value >= needed, best.value > (ranked.dropFirst().first?.value ?? 0) {
            outcome = .frame(best.key)
        } else {
            outcome = .marksOnly
        }
        return Result(outcome: outcome, hits: hits, trials: trials.count)
    }

    static func hit(_ point: AgentPoint, frame: GroundingProfile.CoordinateFrame, trial: Trial) -> Bool {
        let profile = GroundingProfile(frame: frame, source: .calibrated)
        guard
            let pixel = profile.pixelPoint(
                x: point.x, y: point.y,
                width: Double(trial.image.width), height: Double(trial.image.height)
            )
        else { return false }
        return trial.box.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(CGPoint(x: pixel.x, y: pixel.y))
    }

    // MARK: Screens

    /// Screen sizes before fitting to the budget, chosen so no side lands
    /// near 1000 px (where pixels and 0–1000 coincide).
    static let screenSizes: [(Int, Int)] = [(1440, 900), (1680, 1050), (1280, 720), (720, 450), (1920, 1200)]
    static let labels = [
        "Export", "Archive", "Share", "Duplicate", "Rename", "Settings", "Delete", "Refresh", "Print", "Upload",
        "Import", "Merge",
    ]

    /// The synthetic screens for `budget`. Deterministic.
    static func trials(budget: FrameBudget) -> [Trial] {
        var result: [Trial] = []
        for (index, size) in screenSizes.enumerated() {
            let fitted = budget.fitted(width: size.0, height: size.1)
            if let trial = makeTrial(index: index, width: fitted.width, height: fitted.height) {
                result.append(trial)
            }
        }
        return result
    }

    /// Button grid laid out inside a window; the target is the first cell
    /// (in a per-trial order) whose box no two frames can both hit.
    private static func makeTrial(index: Int, width: Int, height: Int) -> Trial? {
        let w = Double(width)
        let h = Double(height)
        let columns = 4
        let rows = 3
        let buttonWidth = max(64, w * 0.11)
        let buttonHeight = max(22, h * 0.05)
        let originX = w * 0.12
        let originY = h * 0.3
        let stepX = (w * 0.82 - originX) / Double(columns)
        let stepY = (h * 0.88 - originY) / Double(rows)
        var cells: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(
                    CGRect(
                        x: originX + Double(column) * stepX,
                        y: originY + Double(row) * stepY,
                        width: buttonWidth,
                        height: buttonHeight
                    )
                )
            }
        }
        let order = cells.indices.map { (($0 * 5) + index * 7) % cells.count }
        guard
            let targetCell = order.first(where: { isDiscriminating(cells[$0], width: w, height: h) })
        else { return nil }
        let labelOffset = index * 3
        let names = cells.indices.map { labels[($0 + labelOffset) % labels.count] }
        guard let image = render(width: width, height: height, cells: cells, names: names) else { return nil }
        return Trial(image: image, label: names[targetCell], box: cells[targetCell])
    }

    /// True when an answer anywhere in `box` under one frame can't land in
    /// `box` under any other frame.
    static func isDiscriminating(_ box: CGRect, width: Double, height: Double) -> Bool {
        let frames = GroundingProfile.CoordinateFrame.allCases
        let padded = box.insetBy(dx: -hitTolerance, dy: -hitTolerance)
        for written in frames {
            let w = GroundingProfile(frame: written, source: .calibrated).pixelsPerUnit(width: width, height: height)
            for read in frames where read != written {
                let r = GroundingProfile(frame: read, source: .calibrated).pixelsPerUnit(width: width, height: height)
                let rx = r.x / w.x
                let ry = r.y / w.y
                let xApart = padded.minX * rx > padded.maxX || padded.maxX * rx < padded.minX
                let yApart = padded.minY * ry > padded.maxY || padded.maxY * ry < padded.minY
                if !(xApart || yApart) { return false }
            }
        }
        return true
    }

    private static func render(width: Int, height: Int, cells: [CGRect], names: [String]) -> CUImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        // CGContext is bottom-left origin; layout rects are top-left.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        }
        context.setFillColor(CGColor(red: 0.36, green: 0.45, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let window = CGRect(x: w * 0.06, y: h * 0.08, width: w * 0.88, height: h * 0.86)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(flipped(window))
        let titleBar = CGRect(x: window.minX, y: window.minY, width: window.width, height: max(22, h * 0.045))
        context.setFillColor(CGColor(gray: 0.88, alpha: 1))
        context.fill(flipped(titleBar))
        let dot = titleBar.height * 0.45
        for (i, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            let rect = CGRect(
                x: titleBar.minX + dot * (0.8 + 1.6 * Double(i)), y: titleBar.midY - dot / 2, width: dot, height: dot
            )
            context.fillEllipse(in: flipped(rect))
        }

        let fontSize = max(10, min(18, w / 90))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        draw("Calibration", font: CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
             centeredIn: titleBar, in: context, height: h, color: CGColor(gray: 0.2, alpha: 1))

        for (rect, name) in zip(cells, names) {
            let path = CGPath(
                roundedRect: flipped(rect), cornerWidth: rect.height * 0.25, cornerHeight: rect.height * 0.25,
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
            context.setLineWidth(1)
            context.strokePath()
            draw(name, font: font, centeredIn: rect, in: context, height: h, color: CGColor(gray: 0.1, alpha: 1))
        }

        guard let drawn = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, drawn, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return CUImage(
            base64: (data as Data).base64EncodedString(), mimeType: "image/png", width: width, height: height,
            region: CUScreenRegion(x: 0, y: 0, w: Double(width), h: Double(height))
        )
    }

    private static func draw(
        _ string: String, font: CTFont, centeredIn rect: CGRect, in context: CGContext, height: CGFloat,
        color: CGColor
    ) {
        let text = NSAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
        )
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let size = CTFontGetSize(font)
        context.textPosition = CGPoint(x: rect.midX - textWidth / 2, y: height - rect.midY - size * 0.35)
        CTLineDraw(line, context)
    }

    // MARK: Run

    /// Show each screen to the model through `step` (the loop's own model
    /// step, with `toolSpec`) and score the answers. A step that
    /// errors or answers without a point is a miss; cancellation and
    /// `isInterrupted` stop the run by throwing `CancellationError`.
    static func run(
        budget: FrameBudget,
        isInterrupted: @Sendable () -> Bool = { false },
        step: ([ChatMessage]) async throws -> ComputerUseLoop.ModelStepResult
    ) async throws -> Result {
        let trials = trials(budget: budget)
        var points: [AgentPoint?] = []
        var speeds: [Double] = []
        for trial in trials {
            if isInterrupted() { throw CancellationError() }
            try Task.checkCancellation()
            do {
                let step = try await step(messages(for: trial))
                if let speed = step.tokensPerSecond { speeds.append(speed) }
                if let call = step.call, case .action(let action) = AgentAction.decode(argumentsJSON: call.arguments) {
                    points.append(action.target?.point)
                } else {
                    points.append(nil)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                points.append(nil)
            }
        }
        var result = score(points: points, trials: trials)
        result.decodeTokensPerSecond = speeds
        return result
    }

    /// The calibration screens have no element list, so marks and `describe`
    /// address nothing: the only target offered is a point, and nothing names
    /// its coordinate convention.
    static let toolSpec = Tool(
        type: "function",
        function: ToolFunction(
            name: AgentAction.toolName,
            description: "Click an element of the screenshot by giving its position as `target.point`.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "verb": .object(["type": .string("string"), "enum": .array([.string("click")])]),
                    "target": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "properties": .object([
                            "point": AgentAction.pointSchema(AgentAction.pointDescription(.unstated))
                        ]),
                        "required": .array([.string("point")]),
                    ]),
                ]),
                "required": .array([.string("verb"), .string("target")]),
            ])
        )
    )

    static let systemPrompt =
        "You operate a computer by calling `agent_action`. You are shown a screenshot of an app window and "
        + "asked to click one of its buttons. Call `agent_action` once with verb `click` and `target.point` "
        + "on that button."

    static func messages(for trial: Trial) -> [ChatMessage] {
        let note = "Click the “\(trial.label)” button."
        return [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(
                role: "user",
                content: note,
                contentParts: [
                    .text(note),
                    .imageUrl(url: "data:\(trial.image.mimeType);base64,\(trial.image.base64)", detail: "high"),
                ]
            ),
        ]
    }
}

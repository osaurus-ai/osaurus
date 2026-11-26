//
//  FrameBudget.swift
//  OsaurusCore — Computer Use
//
//  How large a screenshot the model should see. A frame that is bigger than
//  the model's vision encoder accepts gets resized again inside the runtime,
//  and the model then reads `target.point` in pixels the harness never saw.
//  Fitting the frame here, to the model's own limits, keeps the pixels the
//  model reads and the pixels `ScreenshotPointing` maps back the same.
//
//  `standard` is the general-purpose budget (≤1568 px long edge, ≈1.15 MP),
//  the size frontier vision models take without further resizing. A local
//  bundle narrows it from its `preprocessor_config.json`: a smaller pixel cap
//  and the patch grid the encoder snaps to.
//

import Foundation

public struct FrameBudget: Sendable, Equatable, Hashable, Codable {
    /// Longest side, in pixels.
    public let maxLongEdge: Int
    /// Width × height ceiling, in pixels.
    public let maxPixels: Int
    /// Both sides are rounded down to a multiple of this (the encoder's
    /// patch × merge grid). 1 means no grid.
    public let multiple: Int

    public init(maxLongEdge: Int, maxPixels: Int, multiple: Int = 1) {
        self.maxLongEdge = max(1, maxLongEdge)
        self.maxPixels = max(1, maxPixels)
        self.multiple = max(1, multiple)
    }

    public static let standard = FrameBudget(maxLongEdge: 1568, maxPixels: 1_150_000)

    /// The size a `width`×`height` frame is drawn at. Only ever shrinks; a
    /// frame already inside the budget keeps its size except for snapping to
    /// the grid.
    public func fitted(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        let w = Double(width)
        let h = Double(height)
        let scale = min(
            1,
            Double(maxLongEdge) / max(w, h),
            (Double(maxPixels) / (w * h)).squareRoot()
        )
        func snap(_ side: Double) -> Int {
            let scaled = Int((side * scale).rounded(.down))
            let snapped = (scaled / multiple) * multiple
            return max(multiple, snapped)
        }
        return (snap(w), snap(h))
    }

    /// The budget for a local bundle: `standard`, narrowed by what its
    /// `preprocessor_config.json` declares. A bundle without one (or one this
    /// can't read) keeps `standard`.
    public static func resolve(modelDirectory: URL) -> FrameBudget {
        let url = modelDirectory.appendingPathComponent("preprocessor_config.json")
        guard let data = try? Data(contentsOf: url) else { return .standard }
        return resolve(preprocessorConfig: data)
    }

    /// Read a `preprocessor_config.json`. Processors that declare `merge_size`
    /// resize to a pixel budget on a `patch_size × merge_size` grid, with the
    /// cap in `max_pixels` or, in the newer layout, `size.longest_edge` (both a
    /// pixel count, the way the runtime reads them). Other processors use
    /// `size.longest_edge` as an edge length.
    public static func resolve(preprocessorConfig data: Data) -> FrameBudget {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .standard
        }
        let size = json["size"] as? [String: Any]
        let standard = FrameBudget.standard
        if let merge = positiveInt(json["merge_size"]) {
            let patch = positiveInt(json["patch_size"]) ?? 1
            let cap = positiveInt(json["max_pixels"]) ?? positiveInt(size?["longest_edge"])
            return FrameBudget(
                maxLongEdge: standard.maxLongEdge,
                maxPixels: min(standard.maxPixels, cap ?? standard.maxPixels),
                multiple: patch * merge
            )
        }
        if let edge = positiveInt(size?["longest_edge"]) {
            return FrameBudget(
                maxLongEdge: min(standard.maxLongEdge, edge),
                maxPixels: standard.maxPixels
            )
        }
        return standard
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return int > 0 ? int : nil
    }
}

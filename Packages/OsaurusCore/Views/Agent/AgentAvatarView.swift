//
//  AgentAvatarView.swift
//  osaurus
//
//  Reusable agent avatar that shows a mascot image when one is picked, and
//  falls back to the agent name's first-letter monogram otherwise.
//

import AppKit
import Accelerate
import SwiftUI

/// Catalog of mascot avatars shipped with the app. The `id` is what gets
/// persisted on `Agent.avatar`. `assetName` resolves to an imageset in
/// `OsaurusCore/Resources/Assets.xcassets`
public enum AgentMascot: String, CaseIterable, Identifiable, Sendable {
    case blue, green, orange, purple, red, yellow
    /// The day-one team, drawn from the same `dino.riv` costumes the first
    /// run shows them in.
    case triceBeret = "trice-beret"
    case rexPurse = "rex-purse"
    case brontoScarf = "bronto-scarf"
    case triceBackpack = "trice-backpack"
    case rexMecha = "rex-mecha"

    public var id: String { rawValue }
    public var assetName: String { "osaurus-avatar-\(rawValue)" }


    /// Human-friendly label for accessibility / tooltip surfaces. Avoids
    /// leaking the raw enum case (`"blue"`) into help text — the avatar
    /// strip in onboarding used to read `"Avatar: blue"`.
    public var displayName: String {
        switch self {
        case .blue: return "Blue dino"
        case .green: return "Green dino"
        case .orange: return "Orange dino"
        case .purple: return "Purple dino"
        case .red: return "Red dino"
        case .yellow: return "Yellow dino"
        case .triceBeret: return "Trice in a beret"
        case .rexPurse: return "Rex with a purse"
        case .brontoScarf: return "Bronto in a scarf"
        case .triceBackpack: return "Trice with a backpack"
        case .rexMecha: return "Rex in a mecha helmet"
        }
    }

    /// Asset name for the "create-pose" illustration paired with this
    /// mascot color (used by the onboarding Create Agent step).
    ///
    /// NOTE: the yellow asset ships with a typo in the imageset name
    /// (`osuarus-yellow-create` instead of `osaurus-yellow-create`).
    /// We reference the actual filename so the image loads — rename the
    /// imageset upstream if you want to fix it.
    public var createPoseAssetName: String {
        switch self {
        case .yellow: return "osuarus-yellow-create"
        default: return "osaurus-\(rawValue)-create"
        }
    }
}

/// Renders an agent avatar at the given diameter. Uses the custom image, then
/// the mascot image when `mascotId` matches a known `AgentMascot`, otherwise
/// the first letter of `name` (or `?` when name is empty) tinted in the
/// agent's colour.
struct AgentAvatarView: View {
    let mascotId: String?
    let name: String
    let tint: Color
    let diameter: CGFloat
    /// Optional user-supplied custom avatar image. When present, takes
    /// precedence over `mascotId` and the monogram fallback.
    var customImageURL: URL? = nil
    /// Font size for the monogram fallback. Callers tune this so the letter
    /// reads at the same visual weight as before per call site
    var monogramFontSize: CGFloat = 16
    var borderWidth: CGFloat = 2
    /// When true, the mascot illustration fills the circle edge-to-edge
    /// (no inner inset). Use for hero treatments; leave default for small
    /// list/sidebar avatars where the inset reads as more iconic.
    var bleedsToEdge: Bool = false

    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(11, enabled: baseComponentEnabled) }
    @Environment(\.displayScale) private var displayScale

    private var resolvedDiameter: CGFloat { theme.catalogMetric("avatarSize", fallback: diameter) }
    private var avatarShape: AnyShape {
        #if OSAURUS_DESIGN_SYSTEM
        AnyShape(RoundedRectangle(cornerRadius: theme.catalogMetric("radius", fallback: resolvedDiameter / 2)))
        #else
        AnyShape(Circle())
        #endif
    }
    var body: some View {
        ZStack {
            if let artwork {
                #if OSAURUS_DESIGN_SYSTEM
                avatarShape.fill(theme.assignedColor("component.library.11." + (baseComponentEnabled ? "background" : "disabledBackground"), fallback: theme.surface.raised))
                #else
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.2), tint.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                #endif
                Image(nsImage: artwork)
                #if OSAURUS_DESIGN_SYSTEM
                RoundedRectangle(cornerRadius: theme.catalogMetric("radius", fallback: resolvedDiameter / 2))
                    .strokeBorder(theme.assignedColor("component.library.11.border", fallback: tint.opacity(0.5)), lineWidth: theme.catalogMetric("borderWidth", fallback: borderWidth))
                #else
                Circle().strokeBorder(tint.opacity(0.5), lineWidth: borderWidth)
                #endif
            } else {
                monogram
            }
        }
        .frame(width: resolvedDiameter, height: resolvedDiameter)
        .clipShape(avatarShape)
    }

    /// The custom image, else the mascot, pre-rendered at display size.
    private var artwork: NSImage? {
        if let url = customImageURL,
            let image = AvatarBitmapRenderer.shared.image(customURL: url, pointSize: resolvedDiameter, scale: displayScale)
        {
            return image
        }
        if let mascot = mascotId.flatMap(AgentMascot.init(rawValue:)) {
            return AvatarBitmapRenderer.shared.image(mascot: mascot, pointSize: mascotPointSize, scale: displayScale)
        }
        return nil
    }

    /// No artwork: the name's initial on a soft wash of the agent's own
    /// colour, borderless, so a list of letter avatars reads as a set of
    /// distinct agents rather than a column of keycaps.
    private var monogram: some View {
        ZStack {
            avatarShape.fill(tint.opacity(baseComponentEnabled ? 0.18 : 0.08))
            Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                .glyphSize(min(monogramFontSize, resolvedDiameter * 0.5), weight: .semibold, design: .rounded)
                .foregroundStyle(baseComponentEnabled ? tint : theme.text.disabled)
        }
    }

    /// Mascot edge length in points: full bleed, or inset 8% per side. The
    /// inset is snapped so the leftover margin is a whole number of pixels on
    /// each side; a half-pixel offset would make the GPU resample the bitmap.
    private var mascotPointSize: CGFloat {
        guard !bleedsToEdge else { return resolvedDiameter }
        let scale = max(displayScale, 1)
        let outerPixels = (resolvedDiameter * scale).rounded()
        var innerPixels = (outerPixels * 0.84).rounded()
        if Int(outerPixels - innerPixels) % 2 != 0 { innerPixels -= 1 }
        return max(innerPixels, 1) / scale
    }
}

// MARK: - Avatar Image Cache

/// Tiny URL→NSImage cache keyed by (path, modification-date). Custom avatars
/// live on disk and are read by both SwiftUI and AppKit avatar surfaces; we
/// avoid hitting the filesystem on every body re-evaluation.
final class AvatarImageCache: @unchecked Sendable {
    static let shared = AvatarImageCache()

    struct Entry {
        let mtime: Date
        let image: NSImage
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func image(for url: URL) -> NSImage? {
        entry(for: url)?.image
    }

    func entry(for url: URL) -> Entry? {
        let path = url.path
        let mtime =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast

        lock.lock()
        if let hit = entries[path], hit.mtime == mtime {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let image = NSImage(contentsOf: url) else { return nil }
        let entry = Entry(mtime: mtime, image: image)
        lock.lock()
        entries[path] = entry
        lock.unlock()
        return entry
    }

    func invalidate(url: URL) {
        lock.lock()
        entries.removeValue(forKey: url.path)
        lock.unlock()
        AvatarBitmapRenderer.shared.invalidate(url: url)
    }
}

// MARK: - Avatar Bitmap Renderer

/// Pre-renders avatar artwork at the exact pixel size it is displayed at.
/// The bundled mascots are 1000px+ bitmaps shown in 16–108pt circles; letting
/// Core Animation minify them at draw time (linear sampling, no mipmaps)
/// leaves the outlines soft and jagged. Resampling once with a high-quality
/// filter and drawing the result 1:1 keeps them crisp.
///
/// Output is always square: the source is center-cropped (aspect fill) and
/// resampled to `round(pointSize * scale)` pixels. The returned image's point
/// size is `pixels / scale`, so callers must draw it unscaled.
final class AvatarBitmapRenderer: @unchecked Sendable {
    static let shared = AvatarBitmapRenderer()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]

    static func pixelSize(pointSize: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((pointSize * max(scale, 1)).rounded()))
    }

    func image(mascot: AgentMascot, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        return cached(key: "mascot|\(mascot.rawValue)|\(pixels)", pixels: pixels, scale: scale) {
            Bundle.module.image(forResource: mascot.assetName)
        }
    }

    func image(customURL url: URL, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        guard let entry = AvatarImageCache.shared.entry(for: url) else { return nil }
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        let key = "\(Self.customPrefix(for: url))\(entry.mtime.timeIntervalSinceReferenceDate)|\(pixels)"
        return cached(key: key, pixels: pixels, scale: scale) { entry.image }
    }

    func invalidate(url: URL) {
        let prefix = Self.customPrefix(for: url)
        lock.lock()
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func customPrefix(for url: URL) -> String {
        "custom|\(url.path)|"
    }

    private func cached(
        key: String,
        pixels: Int,
        scale: CGFloat,
        source: () -> NSImage?
    ) -> NSImage? {
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let sourceImage = source(),
            let image = Self.render(sourceImage, pixels: pixels, scale: scale)
        else { return nil }

        lock.lock()
        // Reset-on-overflow cap: keys vary by avatar × size × scale and
        // entries are cheap to re-render.
        if cache.count >= 256 { cache.removeAll() }
        cache[key] = image
        lock.unlock()
        return image
    }

    /// Uncached resample of `source` into a `pixels`-square bitmap whose point
    /// size is `pixels / scale`.
    static func render(_ source: NSImage, pixels: Int, scale: CGFloat) -> NSImage? {
        guard let cgSource = bestCGImage(in: source, minimumPixels: pixels),
            let resampled = resample(cgSource, toSquarePixels: pixels)
        else { return nil }
        let pointSize = CGFloat(pixels) / max(scale, 1)
        return NSImage(cgImage: resampled, size: NSSize(width: pointSize, height: pointSize))
    }

    /// Smallest representation that still covers `minimumPixels`, falling
    /// back to the largest one; avoids decoding a 3x rep for a 16pt avatar.
    private static func bestCGImage(in image: NSImage, minimumPixels: Int) -> CGImage? {
        let candidates: [CGImage] = image.representations.compactMap { rep in
            if let bitmap = rep as? NSBitmapImageRep { return bitmap.cgImage }
            return rep.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let covering = candidates.filter { min($0.width, $0.height) >= minimumPixels }
        if let smallest = covering.min(by: { $0.width * $0.height < $1.width * $1.height }) {
            return smallest
        }
        if let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return largest
        }
        var rect = CGRect(x: 0, y: 0, width: minimumPixels, height: minimumPixels)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func resample(_ source: CGImage, toSquarePixels pixels: Int) -> CGImage? {
        let side = min(source.width, source.height)
        guard side > 0 else { return nil }
        let crop = CGRect(
            x: (source.width - side) / 2,
            y: (source.height - side) / 2,
            width: side,
            height: side
        )
        guard let square = source.cropping(to: crop) else { return nil }

        // Premultiplied alpha so the filter doesn't bleed color from fully
        // transparent pixels into the antialiased edges.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let format = vImage_CGImageFormat(
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                colorSpace: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
            ),
            var sourceBuffer = try? vImage_Buffer(cgImage: square, format: format),
            var destination = try? vImage_Buffer(width: pixels, height: pixels, bitsPerPixel: 32)
        else { return nil }
        defer {
            sourceBuffer.free()
            destination.free()
        }

        let error = vImageScale_ARGB8888(
            &sourceBuffer,
            &destination,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
        )
        guard error == kvImageNoError else { return nil }
        return try? destination.createCGImage(format: format)
    }
}

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

    public var id: String { rawValue }
    public var assetName: String { "osaurus-avatar-\(rawValue)" }

    /// The dino's signature color, used to theme surfaces around the mascot
    /// (e.g. the onboarding hero glow, avatar tint, and selection ring) so
    /// the UI reacts in the selected dino's actual color rather than a
    /// name-hash approximation.
    public var color: Color {
        switch self {
        case .blue: return Color(red: 0.30, green: 0.56, blue: 0.92)
        case .green: return Color(red: 0.36, green: 0.72, blue: 0.42)
        case .orange: return Color(red: 0.95, green: 0.58, blue: 0.24)
        case .purple: return Color(red: 0.62, green: 0.42, blue: 0.92)
        case .red: return Color(red: 0.91, green: 0.38, blue: 0.36)
        case .yellow: return Color(red: 0.95, green: 0.78, blue: 0.27)
        }
    }

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

/// Renders an agent avatar at the given diameter. Uses the mascot image when
/// `mascotId` matches a known `AgentMascot` otherwise draws a tinted circle
/// with the first letter of `name` (or `?` when name is empty)
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

    @Environment(\.displayScale) private var displayScale

    /// Result of the last background render, tagged with the inputs it was
    /// rendered for so a stale image is never shown after they change.
    @State private var loaded: LoadedAvatar?

    private struct LoadedAvatar {
        let key: String
        let custom: NSImage?
        let mascot: NSImage?
    }

    var body: some View {
        let key = renderKey
        let fallback = loaded?.key == key ? loaded : nil
        let renderer = AvatarBitmapRenderer.shared
        // Cache-only lookups: resampling happens off the main thread in
        // `loadImages`, never during body evaluation.
        let customImage =
            customImageURL.flatMap {
                renderer.cachedImage(customURL: $0, pointSize: diameter, scale: displayScale)
            } ?? fallback?.custom
        let mascotImage: NSImage? =
            customImage != nil
            ? nil
            : mascotId.flatMap(AgentMascot.init(rawValue:)).flatMap {
                renderer.cachedImage(mascot: $0, pointSize: mascotPointSize, scale: displayScale)
            } ?? fallback?.mascot

        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.2), tint.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let nsImage = customImage ?? mascotImage {
                Image(nsImage: nsImage)
            } else {
                Text(name.isEmpty ? "?" : name.prefix(1).uppercased())
                    .font(.system(size: monogramFontSize, weight: .bold, design: .rounded))
                    .foregroundColor(tint)
            }

            Circle()
                .strokeBorder(tint.opacity(0.5), lineWidth: borderWidth)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .task(id: key) { await loadImages(key: key) }
    }

    /// Everything that changes which bitmap is shown. Includes the custom
    /// file's mtime so an edited avatar re-renders.
    private var renderKey: String {
        let customPart = customImageURL.map {
            "\($0.path)@\(AvatarBitmapRenderer.modificationDate(of: $0).timeIntervalSinceReferenceDate)"
        }
        return [
            customPart ?? "",
            mascotId ?? "",
            "\(diameter)",
            "\(mascotPointSize)",
            "\(displayScale)",
        ].joined(separator: "|")
    }

    /// Renders whatever is not cached yet on a background queue, then
    /// publishes it so body re-evaluates. Cache hits return immediately.
    private func loadImages(key: String) async {
        let renderer = AvatarBitmapRenderer.shared
        let scale = displayScale
        var custom: NSImage?
        if let url = customImageURL {
            custom = await renderer.renderImage(customURL: url, pointSize: diameter, scale: scale)
        }
        var mascotImage: NSImage?
        if custom == nil, let mascot = mascotId.flatMap(AgentMascot.init(rawValue:)) {
            mascotImage = await renderer.renderImage(mascot: mascot, pointSize: mascotPointSize, scale: scale)
        }
        guard !Task.isCancelled else { return }
        loaded = LoadedAvatar(key: key, custom: custom, mascot: mascotImage)
    }

    /// Mascot edge length in points: full bleed, or inset 8% per side. The
    /// inset is snapped so the leftover margin is a whole number of pixels on
    /// each side; a half-pixel offset would make the GPU resample the bitmap.
    private var mascotPointSize: CGFloat {
        guard !bleedsToEdge else { return diameter }
        let scale = max(displayScale, 1)
        let outerPixels = (diameter * scale).rounded()
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
        let mtime = AvatarBitmapRenderer.modificationDate(of: url)

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

    /// Resampling (PNG decode + high-quality vImage scale) is too slow for
    /// the main thread when many avatars miss at once (display scale change,
    /// memory-pressure cache wipe), so UI callers render here instead.
    private let renderQueue = DispatchQueue(
        label: "com.dinoki.osaurus.avatar-render",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Waiters per cache key, so N avatars sharing a key render it once.
    private var inFlight: [String: [CheckedContinuation<RenderedImage, Never>]] = [:]

    private struct RenderedImage: @unchecked Sendable {
        let image: NSImage?
    }

    static func pixelSize(pointSize: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((pointSize * max(scale, 1)).rounded()))
    }

    /// Synchronous render-on-miss. Blocks the caller for the full resample,
    /// so never call it from a SwiftUI body or main-thread layout; use
    /// `cachedImage` + `renderImage` there instead.
    func image(mascot: AgentMascot, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        return cached(key: Self.mascotKey(mascot, pixels: pixels), pixels: pixels, scale: scale) {
            Bundle.module.image(forResource: mascot.assetName)
        }
    }

    /// Synchronous render-on-miss; see `image(mascot:pointSize:scale:)`.
    func image(customURL url: URL, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        guard let entry = AvatarImageCache.shared.entry(for: url) else { return nil }
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        let key = Self.customKey(url: url, mtime: entry.mtime, pixels: pixels)
        return cached(key: key, pixels: pixels, scale: scale) { entry.image }
    }

    /// Cache-only lookup: never decodes or resamples, safe on the main thread.
    func cachedImage(mascot: AgentMascot, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        return lookup(key: Self.mascotKey(mascot, pixels: pixels))
    }

    /// Cache-only lookup for a custom avatar (one file stat, no decode).
    func cachedImage(customURL url: URL, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        return lookup(key: Self.customKey(url: url, mtime: Self.modificationDate(of: url), pixels: pixels))
    }

    /// Renders on a background queue (deduplicated per key), stores the
    /// result in the cache and returns it. Returns immediately on a hit.
    @MainActor
    func renderImage(mascot: AgentMascot, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        return await renderInBackground(key: Self.mascotKey(mascot, pixels: pixels)) { renderer in
            renderer.image(mascot: mascot, pointSize: pointSize, scale: scale)
        }
    }

    /// Background counterpart of `image(customURL:pointSize:scale:)`.
    @MainActor
    func renderImage(customURL url: URL, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let pixels = Self.pixelSize(pointSize: pointSize, scale: scale)
        let key = Self.customKey(url: url, mtime: Self.modificationDate(of: url), pixels: pixels)
        return await renderInBackground(key: key) { renderer in
            renderer.image(customURL: url, pointSize: pointSize, scale: scale)
        }
    }

    /// Modification date used in custom-avatar cache keys; matches
    /// `AvatarImageCache`'s own staleness check.
    static func modificationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
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

    private static func mascotKey(_ mascot: AgentMascot, pixels: Int) -> String {
        "mascot|\(mascot.rawValue)|\(pixels)"
    }

    private static func customKey(url: URL, mtime: Date, pixels: Int) -> String {
        "\(customPrefix(for: url))\(mtime.timeIntervalSinceReferenceDate)|\(pixels)"
    }

    private func lookup(key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    /// Main-actor isolated so the non-Sendable `NSImage` never crosses an
    /// isolation boundary; only the continuation wait happens here.
    @MainActor
    private func renderInBackground(
        key: String,
        render: @escaping @Sendable (AvatarBitmapRenderer) -> NSImage?
    ) async -> NSImage? {
        if let hit = lookup(key: key) { return hit }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<RenderedImage, Never>) in
            enqueueRender(key: key, continuation: continuation, render: render)
        }
        return result.image
    }

    private func enqueueRender(
        key: String,
        continuation: CheckedContinuation<RenderedImage, Never>,
        render: @escaping @Sendable (AvatarBitmapRenderer) -> NSImage?
    ) {
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            continuation.resume(returning: RenderedImage(image: hit))
            return
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(continuation)
            lock.unlock()
            return
        }
        inFlight[key] = [continuation]
        lock.unlock()

        renderQueue.async { [self] in
            let image = render(self)
            lock.lock()
            let waiters = inFlight.removeValue(forKey: key) ?? []
            lock.unlock()
            for waiter in waiters {
                waiter.resume(returning: RenderedImage(image: image))
            }
        }
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

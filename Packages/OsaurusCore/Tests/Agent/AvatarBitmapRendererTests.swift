//
//  AvatarBitmapRendererTests.swift
//  OsaurusCoreTests
//
//  Avatars are drawn 1:1 from a bitmap pre-rendered at the display's pixel
//  size; anything else lets Core Animation minify the 1000px+ source art at
//  draw time and the outlines go soft. These pin the output geometry, the
//  filter quality, the cache, and custom-avatar invalidation.
//
//  `swift build` copies `Assets.xcassets` uncompiled, so the bundled mascots
//  only resolve under xcodebuild; mascot-backed cases are gated on that.
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

private let mascotAssetsAvailable =
    AvatarBitmapRenderer.shared.image(mascot: .green, pointSize: 1, scale: 1) != nil

@Suite("Avatar bitmap renderer")
struct AvatarBitmapRendererTests {

    private func pixelDimensions(_ image: NSImage) -> (Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg.width, cg.height)
    }

    private func bitmap(width: Int, height: Int, draw: (NSRect) -> Void) throws -> NSBitmapImageRep {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func solid(width: Int, height: Int, color: NSColor) throws -> NSBitmapImageRep {
        try bitmap(width: width, height: height) { rect in
            color.setFill()
            rect.fill()
        }
    }

    /// Mirrors a compiled mascot imageset: one image with 1x and 2x reps.
    private func mascotLikeImage() throws -> NSImage {
        let image = NSImage(size: NSSize(width: 1080, height: 1080))
        image.addRepresentation(try solid(width: 1080, height: 1080, color: .green))
        image.addRepresentation(try solid(width: 2160, height: 2160, color: .green))
        return image
    }

    private func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-renderer-\(UUID().uuidString).png")
    }

    @Test(arguments: [16.0, 26.0, 108.0], [1.0, 2.0])
    func rendersAtExactPixelSize(points: Double, scale: Double) throws {
        let pixels = AvatarBitmapRenderer.pixelSize(pointSize: points, scale: scale)
        let image = try #require(AvatarBitmapRenderer.render(try mascotLikeImage(), pixels: pixels, scale: scale))
        let (width, height) = try #require(pixelDimensions(image))
        #expect(width == Int((points * scale).rounded()))
        #expect(height == width)
        #expect(image.size == NSSize(width: CGFloat(width) / scale, height: CGFloat(width) / scale))
    }

    @Test func fractionalPointSizeRoundsToWholePixels() {
        #expect(AvatarBitmapRenderer.pixelSize(pointSize: 21.84, scale: 2) == 44)
        #expect(AvatarBitmapRenderer.pixelSize(pointSize: 0.1, scale: 1) == 1)
    }

    /// 1px black/white stripes minified 40x must average to mid-gray
    /// everywhere. Point or bilinear sampling (what the GPU does when a huge
    /// bitmap is drawn into a small frame) lands on arbitrary stripes instead.
    @Test func largeDownscaleAveragesInsteadOfAliasing() throws {
        let stripes = try bitmap(width: 2080, height: 2080) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor.black.setFill()
            for x in stride(from: 0, to: Int(rect.width), by: 2) {
                NSRect(x: x, y: 0, width: 1, height: Int(rect.height)).fill()
            }
        }
        let source = NSImage(size: stripes.size)
        source.addRepresentation(stripes)

        let image = try #require(AvatarBitmapRenderer.render(source, pixels: 52, scale: 2))
        let output = try #require(image.representations.first.flatMap { rep -> NSBitmapImageRep? in
            rep.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:))
        })
        for x in 2 ..< 50 {
            for y in 2 ..< 50 {
                let white = try #require(output.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent)
                #expect(abs(white - 0.5) < 0.12, "pixel (\(x), \(y)) = \(white)")
            }
        }
    }

    @Test(.enabled(if: mascotAssetsAvailable))
    func everyMascotRenders() throws {
        for mascot in AgentMascot.allCases {
            let image = try #require(AvatarBitmapRenderer.shared.image(mascot: mascot, pointSize: 26, scale: 2))
            let (width, height) = try #require(pixelDimensions(image))
            #expect(width == 52)
            #expect(height == 52)
        }
    }

    @Test(.enabled(if: mascotAssetsAvailable))
    func repeatedMascotRequestsHitTheCache() throws {
        let first = try #require(AvatarBitmapRenderer.shared.image(mascot: .blue, pointSize: 24, scale: 2))
        let second = try #require(AvatarBitmapRenderer.shared.image(mascot: .blue, pointSize: 24, scale: 2))
        let otherScale = try #require(AvatarBitmapRenderer.shared.image(mascot: .blue, pointSize: 24, scale: 1))
        #expect(first === second)
        #expect(first !== otherScale)
    }

    @Test func customAvatarIsCenterCroppedToSquare() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(try solid(width: 300, height: 200, color: .red), to: url)

        let image = try #require(AvatarBitmapRenderer.shared.image(customURL: url, pointSize: 26, scale: 2))
        let (width, height) = try #require(pixelDimensions(image))
        #expect(width == 52)
        #expect(height == 52)
    }

    @Test func customAvatarCacheHitsUntilInvalidated() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writePNG(try solid(width: 256, height: 256, color: .blue), to: url)

        let first = try #require(AvatarBitmapRenderer.shared.image(customURL: url, pointSize: 30, scale: 2))
        let cached = try #require(AvatarBitmapRenderer.shared.image(customURL: url, pointSize: 30, scale: 2))
        #expect(first === cached)

        AvatarImageCache.shared.invalidate(url: url)
        let refreshed = try #require(AvatarBitmapRenderer.shared.image(customURL: url, pointSize: 30, scale: 2))
        #expect(first !== refreshed)
    }

    @Test func missingCustomFileReturnsNil() {
        #expect(AvatarBitmapRenderer.shared.image(customURL: temporaryURL(), pointSize: 26, scale: 2) == nil)
    }
}

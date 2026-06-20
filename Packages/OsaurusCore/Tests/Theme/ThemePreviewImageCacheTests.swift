//
//  ThemePreviewImageCacheTests.swift
//  OsaurusCoreTests
//

import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme preview image cache")
struct ThemePreviewImageCacheTests {
    @Test("records decoded images, failures, and clears health state")
    func cacheHealthTracksDecodedImagesAndFailures() async throws {
        let cache = ThemePreviewImageCache(countLimit: 4, totalCostLimit: 4096)

        var imageTheme = CustomTheme.darkDefault
        imageTheme.metadata.id = UUID()
        imageTheme.isBuiltIn = false
        imageTheme.background = ThemeBackground(type: .image, imageData: try Self.pngBase64())

        let decoded = await cache.image(for: imageTheme)
        #expect(decoded != nil)
        #expect(cache.cachedImage(for: imageTheme.metadata.id.uuidString) != nil)

        let healthy = await cache.healthSnapshot()
        #expect(healthy.cachedEntryCount == 1)
        #expect(healthy.cachedCostBytes > 0)
        #expect(healthy.failedDecodeCount == 0)
        #expect(healthy.isHealthy)

        var brokenTheme = imageTheme
        brokenTheme.metadata.id = UUID()
        brokenTheme.background.imageData = "not-base64"

        let failed = await cache.image(for: brokenTheme)
        #expect(failed == nil)

        let unhealthy = await cache.healthSnapshot()
        #expect(unhealthy.failedDecodeCount == 1)
        #expect(!unhealthy.isHealthy)

        await cache.removeAll()
        let empty = await cache.healthSnapshot()
        #expect(empty.cachedEntryCount == 0)
        #expect(empty.cachedCostBytes == 0)
        #expect(empty.failedDecodeCount == 0)
    }

    private static func pngBase64() throws -> String {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rep.setColor(NSColor(calibratedRed: 0, green: 0.25, blue: 1, alpha: 1), atX: 0, y: 0)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        return data.base64EncodedString()
    }
}

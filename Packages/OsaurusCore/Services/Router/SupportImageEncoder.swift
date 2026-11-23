//
//  SupportImageEncoder.swift
//  osaurus
//
//  Turns a picked, dropped or pasted image into something a report can
//  carry: at most 2048 pixels on the long side, re-encoded so no camera or
//  location metadata survives, and under the router's 2 MB per image.
//  Images with transparency stay PNG; everything else becomes JPEG.
//

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One image ready to attach. `data` is exactly what is uploaded.
struct SupportImageAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int

    var byteSize: Int { data.count }

    var upload: OsaurusRouterSupportAttachmentUpload {
        OsaurusRouterSupportAttachmentUpload(mimeType: mimeType, dataBase64: data.base64EncodedString())
    }
}

enum SupportImageEncoder {
    static let maxDimension = 2048
    static let maxBytes = OsaurusRouterSupportLimits.maxAttachmentBytes
    /// Smallest long side tried before giving up on an image that will not
    /// compress under `maxBytes`.
    static let minDimension = 512

    enum Failure: Error, Equatable {
        case unreadable
        case tooLarge
    }

    /// File types the picker offers.
    static let pickerTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .webP, .bmp]

    static func encode(fileURL: URL) throws -> SupportImageAttachment {
        guard let data = try? Data(contentsOf: fileURL) else { throw Failure.unreadable }
        return try encode(data: data)
    }

    /// Any format ImageIO reads. Orientation is applied to the pixels, so a
    /// rotated phone photo still looks right once its metadata is gone.
    static func encode(data: Data) throws -> SupportImageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            pixelWidth > 0, pixelHeight > 0
        else { throw Failure.unreadable }

        var longSide = min(maxDimension, max(pixelWidth, pixelHeight))
        while true {
            guard let image = thumbnail(source, longSide: longSide) else { throw Failure.unreadable }
            if let attachment = fitted(image) { return attachment }
            let smaller = Int(Double(longSide) * 0.75)
            guard smaller >= minDimension else { throw Failure.tooLarge }
            longSide = smaller
        }
    }

    /// The first encoding of `image` under `maxBytes`: PNG when it has an
    /// alpha channel, otherwise JPEG at falling quality.
    private static func fitted(_ image: CGImage) -> SupportImageAttachment? {
        if hasAlpha(image) {
            guard let data = encoded(image, type: .png, quality: nil), data.count <= maxBytes else { return nil }
            return attachment(data, mimeType: "image/png", image: image)
        }
        for quality in [0.85, 0.7, 0.55] {
            if let data = encoded(image, type: .jpeg, quality: quality), data.count <= maxBytes {
                return attachment(data, mimeType: "image/jpeg", image: image)
            }
        }
        return nil
    }

    private static func attachment(_ data: Data, mimeType: String, image: CGImage) -> SupportImageAttachment {
        SupportImageAttachment(id: UUID(), data: data, mimeType: mimeType, width: image.width, height: image.height)
    }

    private static func thumbnail(_ source: CGImageSource, longSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// No source properties are copied, so EXIF, GPS and TIFF metadata are
    /// left behind.
    private static func encoded(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Images on the pasteboard, as raw data ImageIO can read. File URLs
    /// first (a copied Finder file), then image data (a copied screenshot).
    @MainActor
    static func pasteboardImageData(_ pasteboard: NSPasteboard = .general) -> [Data] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]
        ) as? [URL], !urls.isEmpty {
            return urls.compactMap { try? Data(contentsOf: $0) }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [data] }
        }
        return []
    }

    static func userMessage(for failure: Failure) -> String {
        switch failure {
        case .unreadable: return L("That file is not an image Osaurus can read.")
        case .tooLarge: return L("That image is too large to attach, even after shrinking it.")
        }
    }
}

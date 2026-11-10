//
//  AttachmentThumbnailLayout.swift
//  osaurus
//
//  Shared sizing rule for image-attachment thumbnails.
//  Used by both the composer pre-send chip (`CachedImageThumbnail`) and
//  the sent-message bubble thumbnail (`UserAttachmentThumbnailView`) so
//  the same image renders with the same shape in both places.
//

import AppKit

enum AttachmentThumbnailLayout {
    /// All images share a height; width follows the original aspect ratio.
    /// Wide images stay fully visible in the horizontally scrolling row.
    static func size(for image: NSImage, height: CGFloat) -> CGSize {
        let s = image.size
        guard s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else {
            return CGSize(width: height, height: height)
        }
        return CGSize(width: height * s.width / s.height, height: height)
    }
}

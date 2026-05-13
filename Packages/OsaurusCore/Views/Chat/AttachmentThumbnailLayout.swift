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
    /// Aspect-ratio clamp range. An image more extreme than 1:2 / 2:1 is
    /// laid out as if it were exactly that extreme — preventing slivers
    /// and runaway widths in attachment rows.
    static let aspectRange: ClosedRange<CGFloat> = 0.5 ... 2.0

    /// Thumbnail render size for `image`, with `longAxis` fixed and the
    /// short axis derived from the (clamped) aspect ratio. The image
    /// renders without cropping; the short axis lands in
    /// `longAxis/2 ... longAxis`.
    static func size(for image: NSImage, longAxis: CGFloat) -> CGSize {
        let s = image.size
        guard s.width > 0, s.height > 0 else {
            return CGSize(width: longAxis, height: longAxis)
        }
        let aspect = min(max(s.width / s.height, aspectRange.lowerBound), aspectRange.upperBound)
        if aspect >= 1 {
            return CGSize(width: longAxis, height: longAxis / aspect)
        } else {
            return CGSize(width: longAxis * aspect, height: longAxis)
        }
    }
}

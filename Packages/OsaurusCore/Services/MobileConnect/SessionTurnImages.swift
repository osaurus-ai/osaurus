//
//  SessionTurnImages.swift
//  osaurus
//
//  The images a stored chat turn carries, as the phone sees them
//  (docs/MOBILE_PROTOCOL.md §14): its image attachments first, then the
//  images an image model generated into it. A generated image is kept as
//  `![prompt](file:///…/generated-images/x.png)` in the turn's text, which
//  a phone can't open, so it is served by index like an attachment.
//

import Foundation

enum SessionTurnImages {

    /// One image of a turn: its size for the listing, its bytes on demand.
    struct Entry {
        let byteCount: Int
        let load: () -> Data?
    }

    static func entries(for turn: ChatTurnData) -> [Entry] {
        let attached = turn.attachments.filter(\.isImage).map { image -> Entry in
            let size: Int
            switch image.kind {
            case .image(let data): size = data.count
            case .imageRef(_, let byteCount): size = byteCount
            default: size = 0
            }
            return Entry(byteCount: size, load: { image.loadImageData() })
        }
        let generated = generatedImageFiles(in: turn.content).map { url -> Entry in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Entry(byteCount: size, load: { try? Data(contentsOf: url) })
        }
        return attached + generated
    }

    /// Markdown image links in `content` that point at files in the Mac's
    /// generated-images folder and still exist. Links anywhere else are left
    /// out: the phone must never be able to read arbitrary Mac files.
    static func generatedImageFiles(in content: String) -> [URL] {
        guard content.contains("](file://") else { return [] }
        let root = OsaurusPaths.generatedImages().resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let range = NSRange(content.startIndex..., in: content)
        return linkPattern.matches(in: content, range: range).compactMap { match in
            guard let linkRange = Range(match.range(at: 1), in: content),
                let url = URL(string: String(content[linkRange])), url.isFileURL
            else { return nil }
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root), FileManager.default.fileExists(atPath: file.path) else { return nil }
            return file
        }
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\((file://[^)\s]+)\)"#)
}

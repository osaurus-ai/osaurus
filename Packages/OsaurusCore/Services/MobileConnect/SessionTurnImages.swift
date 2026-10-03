//
//  SessionTurnImages.swift
//  osaurus
//
//  The images a stored chat turn carries, as the phone sees them
//  (docs/MOBILE_PROTOCOL.md §14): its image attachments first, then the
//  images an image model generated into it, then the images its agent
//  shared with a tool (the `image` tool, `share_artifact`). Generated and
//  shared images live in Mac files a phone can't open, kept as
//  `![prompt](file:///…/generated-images/x.png)` in the turn's text or as
//  a `---SHARED_ARTIFACT_START---` marker in a tool result, so they are
//  served by index like attachments.
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
        var seen = Set<String>()
        let files = (generatedImageFiles(in: turn.content) + sharedImageFiles(in: turn))
            .filter { seen.insert($0.path).inserted }
            .map { url -> Entry in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return Entry(byteCount: size, load: { try? Data(contentsOf: url) })
            }
        return attached + files
    }

    /// Markdown image links in `content` that point at files in the Mac's
    /// generated-images folder and still exist. Links anywhere else are left
    /// out: the phone must never be able to read arbitrary Mac files.
    static func generatedImageFiles(in content: String) -> [URL] {
        guard content.contains("](file://") else { return [] }
        let range = NSRange(content.startIndex..., in: content)
        return linkPattern.matches(in: content, range: range).compactMap { match in
            guard let linkRange = Range(match.range(at: 1), in: content),
                let url = URL(string: String(content[linkRange])), url.isFileURL
            else { return nil }
            return existingFile(url, under: OsaurusPaths.generatedImages())
        }
    }

    /// Images the turn's agent shared: its shared artifacts, and the
    /// markers in its tool results (all a phone run's transcript keeps).
    static func sharedImageFiles(in turn: ChatTurnData) -> [URL] {
        let fromArtifacts = turn.sharedArtifacts.compactMap { artifact -> URL? in
            guard artifact.mimeType.hasPrefix("image/"), !artifact.isDirectory else { return nil }
            return existingFile(URL(fileURLWithPath: artifact.hostPath), under: OsaurusPaths.artifactsDir())
        }
        let fromResults = turn.toolResults.keys.sorted().compactMap { turn.toolResults[$0] }
            .compactMap(sharedImageFile(inToolResult:))
        return fromArtifacts + fromResults
    }

    /// The image a `share_artifact` result points at, when it is one and
    /// the file is still in the Mac's artifacts folder.
    static func sharedImageFile(inToolResult result: String) -> URL? {
        guard result.contains("---SHARED_ARTIFACT_START---"),
            let parsed = SharedArtifact.parseMarkers(from: result),
            (parsed.metadata["mime_type"] as? String)?.hasPrefix("image/") == true,
            let contextId = parsed.metadata["context_id"] as? String
        else { return nil }
        return artifactFile(contextId: contextId, filename: parsed.filename)
    }

    /// A file in `~/.osaurus/artifacts/{contextId}/`, the one place the
    /// phone may fetch shared artifacts from (§14.12).
    static func artifactFile(contextId: String, filename: String) -> URL? {
        let parts = [contextId, filename]
        guard parts.allSatisfy({ !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }) else { return nil }
        let url = OsaurusPaths.contextArtifactsDir(contextId: contextId).appendingPathComponent(filename)
        return existingFile(url, under: OsaurusPaths.artifactsDir())
    }

    /// `url` with symlinks resolved, when it is an existing regular file
    /// inside `root`.
    private static func existingFile(_ url: URL, under root: URL) -> URL? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard file.path.hasPrefix(rootPath),
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        return file
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\((file://[^)\s]+)\)"#)
}

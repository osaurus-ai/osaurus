//
//  KnowledgeDocumentParser.swift
//  osaurus
//
//  Frontmatter extraction + heading-aware chunking for knowledge
//  documents. Frontmatter parsing reuses the module's skill YAML
//  parser so SKILL.md and knowledge markdown stay consistent; the
//  Open Knowledge Format (OKF) reserved fields (`type`, `title`,
//  `description`, `tags`) are recognized, everything else is ignored.
//

import Foundation

/// The OKF-aligned facets extracted from a document's YAML frontmatter.
public struct KnowledgeFrontmatter: Sendable, Equatable {
    public var docType: String
    public var title: String
    public var summary: String
    /// Normalized: trimmed, lowercased, deduplicated.
    public var tags: [String]

    public init(docType: String = "", title: String = "", summary: String = "", tags: [String] = []) {
        self.docType = docType
        self.title = title
        self.summary = summary
        self.tags = tags
    }

    public var tagsCSV: String { tags.joined(separator: ",") }
}

public enum KnowledgeDocumentParser {
    /// Soft chunk target; sections are split at paragraph boundaries
    /// once they exceed the hard maximum.
    static let targetChunkChars = 1600
    static let maxChunkChars = 2400

    // MARK: - Frontmatter

    /// Split a markdown document into frontmatter facets and body. A
    /// document without frontmatter (or with malformed frontmatter)
    /// yields empty facets and the full text as body.
    public static func parse(markdown: String) -> (frontmatter: KnowledgeFrontmatter, body: String) {
        guard let split = Skill.splitFrontmatter(markdown) else {
            return (KnowledgeFrontmatter(), markdown)
        }
        let raw = Skill.parseYamlBlock(split.frontmatterLines)
        var frontmatter = KnowledgeFrontmatter()
        frontmatter.docType = stringValue(raw["type"])
        frontmatter.title = stringValue(raw["title"])
        frontmatter.summary = stringValue(raw["description"])
        frontmatter.tags = tagList(raw["tags"])
        return (frontmatter, split.body)
    }

    /// Display title resolution: frontmatter `title`, else the first
    /// `# heading` in the body, else the filename stem.
    public static func resolveTitle(
        frontmatter: KnowledgeFrontmatter,
        body: String,
        relPath: String
    ) -> String {
        if !frontmatter.title.isEmpty { return frontmatter.title }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return heading }
            }
        }
        let stem = (relPath as NSString).lastPathComponent
        return (stem as NSString).deletingPathExtension
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let str = value as? String {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tags may arrive as a flow-style YAML list (`[a, b]`), a plain
    /// comma-separated string, or (from richer parsers) an array.
    private static func tagList(_ value: Any?) -> [String] {
        guard let value else { return [] }
        var parts: [String]
        if let array = value as? [Any] {
            parts = array.map { stringValue($0) }
        } else {
            var raw = stringValue(value)
            if raw.hasPrefix("["), raw.hasSuffix("]") {
                raw = String(raw.dropFirst().dropLast())
            }
            parts = raw.components(separatedBy: ",")
        }
        var seen: Set<String> = []
        var tags: [String] = []
        for part in parts {
            let tag = part
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            tags.append(tag)
        }
        return tags
    }

    // MARK: - Chunking

    /// Split a markdown body into heading-aware chunks. Each heading
    /// starts a new section carrying its breadcrumb (`Setup > Testing`);
    /// oversized sections are split at paragraph boundaries, keeping
    /// fenced code blocks atomic.
    public static func chunk(body: String) -> [(headingPath: String, content: String)] {
        struct Section {
            var headingPath: String
            var lines: [String] = []
        }

        var sections: [Section] = [Section(headingPath: "")]
        // Heading text per level (1-6); levels below an updated heading reset.
        var headingStack: [String] = Array(repeating: "", count: 6)
        var insideFence = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            }
            if !insideFence, let level = headingLevel(of: trimmed) {
                let text = trimmed
                    .drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                headingStack[level - 1] = text
                for deeper in level ..< 6 where deeper > level - 1 {
                    headingStack[deeper] = ""
                }
                let path = headingStack.prefix(level).filter { !$0.isEmpty }.joined(separator: " > ")
                sections.append(Section(headingPath: path))
                continue
            }
            sections[sections.count - 1].lines.append(line)
        }

        var chunks: [(headingPath: String, content: String)] = []
        for section in sections {
            let content = section.lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            if content.count <= maxChunkChars {
                chunks.append((section.headingPath, content))
            } else {
                for piece in splitOversized(content) {
                    chunks.append((section.headingPath, piece))
                }
            }
        }
        return chunks
    }

    private static func headingLevel(of trimmedLine: String) -> Int? {
        guard trimmedLine.hasPrefix("#") else { return nil }
        let hashes = trimmedLine.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        // Require a space after the hashes (ATX heading), so `#hashtag`
        // text is not treated as a heading.
        let rest = trimmedLine.dropFirst(hashes)
        return rest.first == " " ? hashes : nil
    }

    /// Split an oversized section at paragraph boundaries, packing
    /// paragraphs up to the target size. Fenced code blocks are treated
    /// as single paragraphs so they never split mid-fence.
    private static func splitOversized(_ content: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        var insideFence = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            }
            if trimmed.isEmpty, !insideFence {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: "\n"))
        }

        var pieces: [String] = []
        var buffer = ""
        for paragraph in paragraphs {
            if buffer.isEmpty {
                buffer = paragraph
            } else if buffer.count + paragraph.count + 2 <= targetChunkChars {
                buffer += "\n\n" + paragraph
            } else {
                pieces.append(buffer)
                buffer = paragraph
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }

        // A single paragraph can still exceed the hard cap (giant code
        // block, minified text) — hard-wrap it as a last resort.
        var result: [String] = []
        for piece in pieces {
            if piece.count <= maxChunkChars {
                result.append(piece)
            } else {
                var remaining = Substring(piece)
                while !remaining.isEmpty {
                    let slice = remaining.prefix(maxChunkChars)
                    result.append(String(slice))
                    remaining = remaining.dropFirst(slice.count)
                }
            }
        }
        return result
    }
}

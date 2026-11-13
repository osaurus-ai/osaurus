//
//  MultiPartyVocabularyLintTests.swift
//  osaurusTests
//
//  Words the sharing, devices and approval surfaces no longer use. Each
//  replaced term came back at least once through copy-paste, so string
//  literals in the app sources and every in-app guide are scanned for them.
//  Comments are not scanned. See docs/MULTI_PARTY_UX_AUDIT.md for the glossary.
//

import Foundation
import Testing

struct MultiPartyVocabularyLintTests {
    struct Banned: Sendable {
        let phrase: String
        let use: String
    }

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .resolvingSymlinksInPath()

    /// Banned in Swift string literals and in the guides.
    static let banned: [Banned] = [
        Banned(phrase: "Paired phone", use: "iPhone"),
        Banned(phrase: "paired phone", use: "your iPhone"),
        Banned(phrase: "Paired iPhone", use: "Your iPhone"),
        Banned(phrase: "Reach From Anywhere", use: "Remote Access (agents) or Anywhere (Sync)"),
        Banned(phrase: "Generate Pairing Code", use: "Add a Device"),
        Banned(phrase: "Allow for This Task", use: "Allow for This Conversation"),
        Banned(phrase: "Allow for this task", use: "Allow for This Conversation"),
        Banned(phrase: "Allow Once", use: "Allow"),
        Banned(phrase: "Identity & Recovery", use: "Osaurus ID, or Sharing → Devices → Recovery"),
        Banned(phrase: "Invites & Members", use: "Members"),
        Banned(phrase: "Issued Invites", use: "Guests"),
        Banned(phrase: "Remote Connections", use: "Guests"),
        Banned(phrase: "Open the Sandbox tab", use: "the sandbox folder"),
        Banned(phrase: "Workspace Pool", use: "Workspace Credits"),
        Banned(phrase: "Served From Another Device", use: "On another Mac"),
        Banned(phrase: "relay tunnel", use: "remote access"),
    ]

    /// Banned in the guides only: settings paths that no longer exist.
    static let bannedInGuides: [Banned] = [
        Banned(phrase: "Settings → Mobile", use: "Sharing → Devices (or Devices → Mobile for the 6-digit code)"),
        Banned(phrase: "General → Sync", use: "Sharing → Devices"),
        Banned(phrase: "Osaurus ID → Workspaces", use: "Sharing → Workspaces"),
        Banned(phrase: "→ Relays", use: "Sharing → Access → Remote Access"),
        Banned(phrase: "**Approvals** in the sidebar", use: "Inbox → Needs You"),
    ]

    /// Approval buttons say Allow. Knowledge proposals and the store review
    /// approve content, not a permission, so they keep the word.
    static let approveButtonAllowed: Set<String> = [
        "Views/Knowledge/KnowledgeView.swift",
        "Views/Template/PublishReviewViews.swift",
    ]

    static let swiftRoots = [
        "Views", "Services", "Models", "Managers", "Networking", "Configuration", "PrivacyFilter", "ComputerUse",
        "Tools",
    ]

    @Test func swiftLiteralsUseTheCurrentVocabulary() throws {
        var hits: [String] = []
        for (relative, text) in try Self.files(in: Self.swiftRoots, extension: "swift") {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.drop { $0 == " " || $0 == "\t" }
                if trimmed.hasPrefix("//") { continue }
                let literals = Self.stringLiterals(in: line)
                for literal in literals {
                    for rule in Self.banned where literal.contains(rule.phrase) {
                        hits.append("\(relative):\(index + 1): \"\(rule.phrase)\" → \(rule.use)")
                    }
                    if literal == "Approve", !Self.approveButtonAllowed.contains(relative) {
                        hits.append("\(relative):\(index + 1): \"Approve\" → Allow")
                    }
                }
            }
        }
        #expect(hits.isEmpty, "retired wording in UI strings:\n\(hits.joined(separator: "\n"))")
    }

    @Test func guidesUseTheCurrentVocabularyAndPaths() throws {
        var hits: [String] = []
        let guides = try Self.files(in: ["Resources/Guide"], extension: "md")
        #expect(!guides.isEmpty)
        for (relative, text) in guides {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for rule in Self.banned + Self.bannedInGuides where line.contains(rule.phrase) {
                    // Naming the retired control to say it's gone is allowed.
                    if line.contains("are gone") || line.contains("formerly") || line.contains("still resolve") {
                        continue
                    }
                    hits.append("\(relative):\(index + 1): \"\(rule.phrase)\" → \(rule.use)")
                }
            }
        }
        #expect(hits.isEmpty, "retired wording in guides:\n\(hits.joined(separator: "\n"))")
    }

    @Test func theScannerSkipsCommentsAndFindsInterpolatedLiterals() {
        #expect(Self.stringLiterals(in: #"title("Approve") + label("a \(x) paired phone")"#) == ["Approve", #"a \(x) paired phone"#])
        #expect(Self.stringLiterals(in: #"let s = "say \"hi\"""#) == [#"say \"hi\""#])
    }

    // MARK: - Helpers

    static func files(in roots: [String], extension ext: String) throws -> [(String, String)] {
        var out: [(String, String)] = []
        for root in roots {
            let url = packageRoot.appendingPathComponent(root)
            guard
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in walker where file.pathExtension == ext {
                let path = file.resolvingSymlinksInPath().path
                let relative = String(path.dropFirst(packageRoot.path.count + 1))
                out.append((relative, try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return out
    }

    /// Single-line `"…"` literals, with escapes and interpolations kept verbatim.
    static func stringLiterals(in line: Substring) -> [String] {
        var out: [String] = []
        var current: String?
        var depth = 0
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if var literal = current {
                if c == "\\", i + 1 < chars.count {
                    if chars[i + 1] == "(" { depth += 1 }
                    literal.append(c)
                    literal.append(chars[i + 1])
                    current = literal
                    i += 2
                    continue
                }
                if depth > 0 {
                    if c == "(" { depth += 1 }
                    if c == ")" { depth -= 1 }
                    literal.append(c)
                    current = literal
                } else if c == "\"" {
                    out.append(literal)
                    current = nil
                } else {
                    literal.append(c)
                    current = literal
                }
            } else if c == "\"" {
                current = ""
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                break
            }
            i += 1
        }
        return out
    }

    static func stringLiterals(in line: String) -> [String] {
        stringLiterals(in: Substring(line))
    }
}

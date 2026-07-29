//
//  ChatSessionImporter.swift
//  osaurus
//
//  Parses conversation exports from other assistants (ChatGPT, Claude,
//  Gemini, or a generic JSON schema) into `ChatSessionData` so they can be
//  continued as native sessions. Pure data transformation — no I/O,
//  no persistence; the coordinator owns file access and saving.
//

import Foundation

public enum ChatSessionImporter {

    /// Where an export came from. Drives the `externalSessionKey`
    /// prefix so re-imports of the same conversation can be detected.
    public enum SourceFormat: String, Sendable {
        case chatGPT = "chatgpt"
        case claude = "claude"
        case gemini = "gemini"
        case generic = "import"
    }

    public struct ImportedConversation: Sendable {
        public let session: ChatSessionData
        public let format: SourceFormat
    }

    public enum ImportError: LocalizedError {
        case invalidJSON
        case unrecognizedFormat
        case noConversations

        public var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return L("The file is not valid JSON.")
            case .unrecognizedFormat:
                return L(
                    "Unrecognized export format. Supported: ChatGPT conversations.json, Claude export JSON, Gemini Takeout MyActivity.json, or Osaurus generic import JSON."
                )
            case .noConversations:
                return L("No importable conversations were found in the file.")
            }
        }
    }

    // MARK: - Entry point

    /// Detects the export format and parses every conversation in `data`.
    /// Conversations with no usable messages are dropped rather than
    /// failing the whole import. Zip archives (how ChatGPT and Google
    /// Takeout deliver exports) are unpacked and every recognizable JSON
    /// entry inside is imported.
    public static func parse(data: Data) throws -> [ImportedConversation] {
        if ZipArchive.isArchive(data) {
            return try parseArchive(data)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.invalidJSON
        }

        let conversations: [ImportedConversation]
        if let array = root as? [[String: Any]] {
            if array.contains(where: { $0["mapping"] is [String: Any] }) {
                conversations = array.compactMap { parseChatGPT($0) }
            } else if array.contains(where: { $0["chat_messages"] is [Any] }) {
                conversations = array.compactMap { parseClaude($0) }
            } else if array.contains(where: isGeminiActivityEntry) {
                conversations = array.compactMap { parseGeminiActivity($0) }
            } else {
                throw ImportError.unrecognizedFormat
            }
        } else if let object = root as? [String: Any] {
            if object["mapping"] is [String: Any] {
                conversations = [parseChatGPT(object)].compactMap { $0 }
            } else if object["chat_messages"] is [Any] {
                conversations = [parseClaude(object)].compactMap { $0 }
            } else if let list = object["conversations"] as? [[String: Any]] {
                conversations = list.compactMap { parseGeneric($0) }
            } else if object["messages"] is [Any] {
                conversations = [parseGeneric(object)].compactMap { $0 }
            } else {
                throw ImportError.unrecognizedFormat
            }
        } else {
            throw ImportError.unrecognizedFormat
        }

        guard !conversations.isEmpty else { throw ImportError.noConversations }
        return conversations
    }

    // MARK: - Zip archives

    /// Unpacks a zipped export and imports every JSON entry that parses
    /// as a known format. ChatGPT zips also contain `user.json`,
    /// `message_feedback.json`, etc. — entries that don't look like a
    /// conversation export are skipped, not fatal. Fails only when no
    /// entry yields conversations.
    private static func parseArchive(_ data: Data) throws -> [ImportedConversation] {
        let jsonEntries = try ZipArchive.entries(in: data).filter { entry in
            let name = entry.name.lowercased()
            // AppleDouble metadata ("__MACOSX/…", "._foo.json") isn't JSON.
            return name.hasSuffix(".json") && !name.hasPrefix("__macosx/")
                && !(name.split(separator: "/").last?.hasPrefix("._") ?? false)
        }
        guard !jsonEntries.isEmpty else { throw ImportError.unrecognizedFormat }

        var all: [ImportedConversation] = []
        for entry in jsonEntries {
            let entryData = try ZipArchive.extract(entry, from: data)
            if let conversations = try? parse(data: entryData) {
                all.append(contentsOf: conversations)
            }
        }
        guard !all.isEmpty else { throw ImportError.noConversations }
        return all
    }

    // MARK: - ChatGPT (conversations.json)

    /// ChatGPT exports store each conversation as a message tree
    /// (`mapping` of node id → node with `parent`/`children`) plus a
    /// `current_node` pointer. Only the canonical path — the ancestry of
    /// `current_node` — is imported; abandoned edit branches are dropped.
    private static func parseChatGPT(_ conversation: [String: Any]) -> ImportedConversation? {
        guard let mapping = conversation["mapping"] as? [String: Any] else { return nil }

        let nodes = mapping.compactMapValues { $0 as? [String: Any] }
        var nodeId = (conversation["current_node"] as? String) ?? deepestLeafId(in: nodes)

        // Walk current_node → root via parent pointers, then reverse.
        var ordered: [[String: Any]] = []
        var visited = Set<String>()
        while let id = nodeId, !visited.contains(id), let node = nodes[id] {
            visited.insert(id)
            if let message = node["message"] as? [String: Any] {
                ordered.append(message)
            }
            nodeId = node["parent"] as? String
        }
        ordered.reverse()

        var turns: [ChatTurnData] = []
        for message in ordered {
            guard
                let author = message["author"] as? [String: Any],
                let roleString = author["role"] as? String,
                let role = importedRole(from: roleString)
            else { continue }
            let metadata = message["metadata"] as? [String: Any]
            if metadata?["is_visually_hidden_from_conversation"] as? Bool == true { continue }
            let text = chatGPTText(from: message["content"] as? [String: Any])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            turns.append(
                ChatTurnData(
                    role: role,
                    content: text,
                    createdAt: (message["create_time"] as? Double).map(Date.init(timeIntervalSince1970:))
                )
            )
        }
        guard turns.contains(where: { $0.role == .user }) else { return nil }

        let externalId =
            (conversation["conversation_id"] as? String)
            ?? (conversation["id"] as? String)
        return assemble(
            format: .chatGPT,
            title: conversation["title"] as? String,
            externalId: externalId,
            createdAt: (conversation["create_time"] as? Double).map(Date.init(timeIntervalSince1970:)),
            updatedAt: (conversation["update_time"] as? Double).map(Date.init(timeIntervalSince1970:)),
            turns: turns
        )
    }

    /// Fallback when `current_node` is absent: the leaf reached by the
    /// longest chain of "last child" hops from the root, i.e. the most
    /// recent linearization the ChatGPT UI would show.
    private static func deepestLeafId(in nodes: [String: [String: Any]]) -> String? {
        // JSON `"parent": null` decodes as NSNull, so test for the
        // absence of a string parent rather than a missing key.
        var rootId = nodes.first(where: { !($0.value["parent"] is String) })?.key
        if rootId == nil { rootId = nodes.keys.first }
        var current = rootId
        var visited = Set<String>()
        while let id = current, !visited.contains(id),
            let children = nodes[id]?["children"] as? [String],
            let last = children.last
        {
            visited.insert(id)
            current = last
        }
        return current
    }

    /// Extracts display text from a ChatGPT `content` object. Text and
    /// multimodal parts keep their string segments (images become a
    /// placeholder); code cells are fenced. Everything else — tool
    /// payloads, thoughts — is dropped.
    private static func chatGPTText(from content: [String: Any]?) -> String {
        guard let content else { return "" }
        let type = content["content_type"] as? String ?? "text"
        switch type {
        case "text", "multimodal_text":
            let parts = content["parts"] as? [Any] ?? []
            return parts
                .map { part -> String in
                    if let text = part as? String { return text }
                    return "[attachment omitted]"
                }
                .joined(separator: "\n")
        case "code":
            guard let text = content["text"] as? String, !text.isEmpty else { return "" }
            let language = content["language"] as? String ?? ""
            return "```\(language)\n\(text)\n```"
        default:
            return ""
        }
    }

    // MARK: - Claude (data export)

    /// Claude's data export is an array of conversations with flat
    /// `chat_messages`, `sender` being `human` or `assistant`.
    private static func parseClaude(_ conversation: [String: Any]) -> ImportedConversation? {
        guard let messages = conversation["chat_messages"] as? [[String: Any]] else { return nil }

        var turns: [ChatTurnData] = []
        for message in messages {
            guard let sender = message["sender"] as? String else { continue }
            let role: MessageRole
            switch sender {
            case "human": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            let text = claudeText(from: message)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            turns.append(
                ChatTurnData(
                    role: role,
                    content: text,
                    createdAt: isoDate(message["created_at"] as? String)
                )
            )
        }
        guard turns.contains(where: { $0.role == .user }) else { return nil }

        return assemble(
            format: .claude,
            title: conversation["name"] as? String,
            externalId: conversation["uuid"] as? String,
            createdAt: isoDate(conversation["created_at"] as? String),
            updatedAt: isoDate(conversation["updated_at"] as? String),
            turns: turns
        )
    }

    /// Newer Claude exports carry a `content` array of typed blocks;
    /// older ones only the flat `text` field.
    private static func claudeText(from message: [String: Any]) -> String {
        if let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty {
            let joined =
                blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        return message["text"] as? String ?? ""
    }

    // MARK: - Gemini (Google Takeout MyActivity.json)

    /// Google Takeout exports Gemini history as a flat My Activity log:
    /// an array of entries with `"header": "Gemini Apps"`, the prompt in
    /// `title` behind a `"Prompted "` prefix, the response as HTML in
    /// `safeHtmlItem`, and an ISO-8601 `time`. There is no conversation
    /// grouping in the export, so each entry becomes its own session.
    private static func isGeminiActivityEntry(_ entry: [String: Any]) -> Bool {
        guard entry["title"] is String, entry["time"] is String else { return false }
        let header = entry["header"] as? String ?? ""
        let products = entry["products"] as? [String] ?? []
        return header.contains("Gemini") || header.contains("Bard")
            || products.contains(where: { $0.contains("Gemini") || $0.contains("Bard") })
    }

    private static func parseGeminiActivity(_ entry: [String: Any]) -> ImportedConversation? {
        guard isGeminiActivityEntry(entry), let title = entry["title"] as? String else {
            return nil
        }
        // Non-prompt activity rows ("Used Gemini Apps", …) carry no
        // conversation content.
        let prefix = "Prompted "
        guard title.hasPrefix(prefix) else { return nil }
        let prompt = String(title.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        let time = isoDate(entry["time"] as? String)
        var turns = [ChatTurnData(role: .user, content: prompt, createdAt: time)]

        let response = (entry["safeHtmlItem"] as? [[String: Any]] ?? [])
            .compactMap { $0["html"] as? String }
            .map(plainText(fromHTML:))
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !response.isEmpty {
            turns.append(ChatTurnData(role: .assistant, content: response, createdAt: time))
        }

        return assemble(
            format: .gemini,
            // No per-conversation title in the activity log; derive from
            // the prompt like a fresh chat would.
            title: nil,
            // `time` is the only stable per-entry identifier Takeout gives us.
            externalId: entry["time"] as? String,
            createdAt: time,
            updatedAt: time,
            turns: turns
        )
    }

    /// Minimal HTML → text for Takeout's `safeHtmlItem` responses: block
    /// tags become newlines, list items become dashes, remaining tags are
    /// stripped and common entities decoded. Not a general HTML renderer —
    /// just enough to keep Gemini answers readable as markdown-ish text.
    private static func plainText(fromHTML html: String) -> String {
        var text = html
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>", "</ul>", "</ol>"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<li>", with: "- ", options: .caseInsensitive)
        text = text.replacingOccurrences(
            of: "<[^>]+>", with: "", options: [.regularExpression, .caseInsensitive]
        )
        for (entity, character) in [
            ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // Collapse the blank-line runs left by adjacent block tags.
        text = text.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression
        )
        return text
    }

    // MARK: - Generic Osaurus import schema

    /// Minimal documented schema any tool (or an agent scraping a WebUI)
    /// can target:
    ///
    /// ```json
    /// {
    ///   "conversations": [
    ///     {
    ///       "id": "optional-stable-id",
    ///       "title": "optional title",
    ///       "createdAt": "2026-01-01T10:00:00Z",
    ///       "messages": [
    ///         {"role": "user", "content": "...", "timestamp": "2026-01-01T10:00:00Z"},
    ///         {"role": "assistant", "content": "..."}
    ///       ]
    ///     }
    ///   ]
    /// }
    /// ```
    ///
    /// A single top-level `{"messages": [...]}` object is also accepted.
    /// `role` is one of `system` / `user` / `assistant`; `timestamp`
    /// accepts ISO-8601 strings or epoch seconds.
    private static func parseGeneric(_ conversation: [String: Any]) -> ImportedConversation? {
        guard let messages = conversation["messages"] as? [[String: Any]] else { return nil }

        var turns: [ChatTurnData] = []
        for message in messages {
            guard
                let roleString = message["role"] as? String,
                let role = importedRole(from: roleString)
            else { continue }
            let content = genericText(from: message["content"])
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            turns.append(
                ChatTurnData(role: role, content: content, createdAt: flexibleDate(message["timestamp"]))
            )
        }
        guard turns.contains(where: { $0.role == .user }) else { return nil }

        return assemble(
            format: .generic,
            title: conversation["title"] as? String,
            externalId: conversation["id"] as? String,
            createdAt: flexibleDate(conversation["createdAt"]),
            updatedAt: flexibleDate(conversation["updatedAt"]),
            turns: turns
        )
    }

    /// Generic-schema `content` accepts a plain string, an array of
    /// strings (joined as paragraphs), or an array of typed text blocks
    /// (`{"type": "text", "text": …}`), since hand-rolled exports use
    /// all three shapes.
    private static func genericText(from content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [Any] {
            return parts
                .compactMap { part -> String? in
                    if let text = part as? String { return text }
                    if let block = part as? [String: Any] {
                        return block["text"] as? String
                    }
                    return nil
                }
                .joined(separator: "\n\n")
        }
        return ""
    }

    // MARK: - Shared assembly

    private static func assemble(
        format: SourceFormat,
        title: String?,
        externalId: String?,
        createdAt: Date?,
        updatedAt: Date?,
        turns: [ChatTurnData]
    ) -> ImportedConversation {
        let created = createdAt ?? turns.compactMap(\.createdAt).min() ?? Date()
        let updated = updatedAt ?? turns.compactMap(\.createdAt).max() ?? created
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = ChatSessionData(
            title: trimmedTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? ChatSessionData.generateTitle(from: turns),
            createdAt: created,
            updatedAt: updated,
            // Leave the model unset: the export's model id won't match a
            // configured Osaurus model, and nil falls back to the agent's
            // default on load.
            selectedModel: nil,
            turns: turns,
            source: .imported,
            externalSessionKey: externalId.map { "\(format.rawValue):\($0)" },
            capabilities: SessionCapability.derive(from: turns)
        )
        return ImportedConversation(session: session, format: format)
    }

    /// Roles that survive an import. Tool traffic from other assistants
    /// can't be replayed (no matching tool-call ids), so it is dropped.
    private static func importedRole(from raw: String) -> MessageRole? {
        switch raw {
        case "user": return .user
        case "assistant": return .assistant
        case "system": return .system
        default: return nil
        }
    }

    // MARK: - Date helpers

    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func flexibleDate(_ value: Any?) -> Date? {
        if let string = value as? String { return isoDate(string) }
        if let epoch = value as? Double { return Date(timeIntervalSince1970: epoch) }
        return nil
    }
}

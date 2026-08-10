//
//  AgentChannelReactionNormalizer.swift
//  osaurus
//
//  Provider-aware normalization for the cross-channel reaction tools.
//
//  Agents pass reactions in whatever form the model produced: a Unicode
//  emoji, a Slack-style alias (`:white_check_mark:`), a Discord custom emoji
//  (`name:id` or `<:name:id>`), or a Telegram custom emoji id. Each provider
//  API wants a different shape — Slack wants alias names without colons,
//  Discord wants the literal Unicode emoji or `name:id`, Telegram wants a
//  typed reaction object — so each service normalizes through here before
//  calling its API.
//

import Foundation

/// Typed Telegram `ReactionType` payload for `setMessageReaction`.
enum TelegramReactionPayload: Equatable, Sendable {
    case emoji(String)
    case customEmoji(String)

    var dictionary: [String: String] {
        switch self {
        case .emoji(let emoji):
            return ["type": "emoji", "emoji": emoji]
        case .customEmoji(let id):
            return ["type": "custom_emoji", "custom_emoji_id": id]
        }
    }

    var displayValue: String {
        switch self {
        case .emoji(let emoji):
            return emoji
        case .customEmoji(let id):
            return "custom_emoji:\(id)"
        }
    }
}

enum AgentChannelReactionNormalizer {
    /// Common alias → Unicode table (Slack/GitHub-style names). Kept small on
    /// purpose: it covers the reactions agents actually use; anything else is
    /// passed through when the provider can accept it and rejected otherwise.
    static let aliasToEmoji: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "thumbs_up": "👍",
        "-1": "👎", "thumbsdown": "👎", "thumbs_down": "👎",
        "heart": "❤️", "red_heart": "❤️",
        "smile": "😄",
        "grinning": "😀",
        "joy": "😂",
        "tada": "🎉", "party_popper": "🎉",
        "white_check_mark": "✅",
        "x": "❌",
        "eyes": "👀",
        "rocket": "🚀",
        "pray": "🙏",
        "fire": "🔥",
        "clap": "👏",
        "thinking_face": "🤔", "thinking": "🤔",
        "wave": "👋",
        "heavy_check_mark": "✔️",
        "cry": "😢",
        "open_mouth": "😮",
        "100": "💯",
        "zap": "⚡",
        "star": "⭐",
        "exclamation": "❗",
        "question": "❓",
        "ok_hand": "👌",
    ]

    /// Unicode → canonical Slack alias, derived from the table above. Emoji
    /// are indexed both with and without the variation selector (U+FE0F) so
    /// either presentation form resolves.
    static let emojiToAlias: [String: String] = {
        var result: [String: String] = [:]
        let canonical: [String: String] = [
            "👍": "+1", "👎": "-1", "❤️": "heart", "😄": "smile", "😀": "grinning",
            "😂": "joy", "🎉": "tada", "✅": "white_check_mark", "❌": "x",
            "👀": "eyes", "🚀": "rocket", "🙏": "pray", "🔥": "fire", "👏": "clap",
            "🤔": "thinking_face", "👋": "wave", "✔️": "heavy_check_mark",
            "😢": "cry", "😮": "open_mouth", "💯": "100", "⚡": "zap", "⭐": "star",
            "❗": "exclamation", "❓": "question", "👌": "ok_hand",
        ]
        for (emoji, alias) in canonical {
            result[emoji] = alias
            result[stripVariationSelectors(emoji)] = alias
        }
        return result
    }()

    // MARK: - Slack

    /// Slack `reactions.add` wants an alias name without colons
    /// (e.g. `white_check_mark`). Accepts `:alias:`, bare aliases, and any
    /// Unicode emoji the table can map back to a name. Returns nil when the
    /// reaction cannot be expressed as a Slack alias.
    static func slackName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return nil }
        if let alias = emojiToAlias[trimmed] ?? emojiToAlias[stripVariationSelectors(trimmed)] {
            return alias
        }
        // Bare alias: Slack has thousands of names beyond our table; pass
        // plausible names through and let Slack validate.
        if isPlausibleAliasName(trimmed) {
            return trimmed.lowercased()
        }
        return nil
    }

    // MARK: - Discord

    /// Discord's reaction endpoints want either the literal Unicode emoji or
    /// custom emoji as `name:id`. Accepts `<:name:id>` / `<a:name:id>` message
    /// markup, plain `name:id`, `:alias:` names, and Unicode. Returns nil for
    /// unresolvable ASCII names.
    static func discordReaction(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return nil }

        if let custom = parseDiscordCustomEmoji(trimmed) {
            return custom
        }
        let unColoned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if let emoji = aliasToEmoji[unColoned.lowercased()] {
            return emoji
        }
        if containsNonASCII(trimmed) {
            // Assume a literal Unicode emoji (Discord validates it).
            return trimmed
        }
        return nil
    }

    /// `<a:name:id>`, `<:name:id>`, and `name:id` all normalize to `name:id`.
    private static func parseDiscordCustomEmoji(_ value: String) -> String? {
        var body = value
        if body.hasPrefix("<") && body.hasSuffix(">") {
            body = String(body.dropFirst().dropLast())
            if body.hasPrefix("a:") {
                body = String(body.dropFirst(2))
            } else if body.hasPrefix(":") {
                body = String(body.dropFirst())
            }
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let name = String(parts[0])
        let id = String(parts[1])
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              !id.isEmpty,
              id.allSatisfy(\.isNumber)
        else { return nil }
        return "\(name):\(id)"
    }

    // MARK: - Telegram

    /// Telegram `setMessageReaction` wants a typed reaction object. Accepts
    /// Unicode emoji, `:alias:` names, numeric custom emoji ids, and
    /// `custom_emoji:<id>`. Variation selectors are stripped because
    /// Telegram's allowed-emoji list uses the bare code points (e.g. `❤`).
    static func telegramReaction(_ raw: String) -> TelegramReactionPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }

        if trimmed.lowercased().hasPrefix("custom_emoji:") {
            let id = String(trimmed.dropFirst("custom_emoji:".count))
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            return .customEmoji(id)
        }
        // Telegram custom emoji ids are long numeric document ids.
        if trimmed.count >= 8, trimmed.allSatisfy(\.isNumber) {
            return .customEmoji(trimmed)
        }
        let unColoned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        if let emoji = aliasToEmoji[unColoned.lowercased()] {
            return .emoji(stripVariationSelectors(emoji))
        }
        if containsNonASCII(trimmed) {
            return .emoji(stripVariationSelectors(trimmed))
        }
        return nil
    }

    // MARK: - iMessage

    /// The six canonical iMessage tapback kinds accepted by the pinned imsg
    /// helper (`--kind love|like|dislike|laugh|emphasize|question`). Custom
    /// emoji tapbacks can be read from history but cannot be sent.
    static let imessageTapbackKinds: Set<String> = [
        "love", "like", "dislike", "laugh", "emphasize", "question",
    ]

    /// Emoji / alias → canonical tapback kind. Indexed with and without the
    /// variation selector so either presentation form resolves.
    private static let imessageTapbackTable: [String: String] = {
        let canonical: [String: String] = [
            "❤️": "love", "❤": "love", "💗": "love", "😍": "love", "heart": "love",
            "love": "love", "heart_eyes": "love", "sparkling_heart": "love",
            "👍": "like", "+1": "like", "like": "like", "thumbsup": "like",
            "thumbs_up": "like", "ok_hand": "like", "👌": "like",
            "👎": "dislike", "-1": "dislike", "dislike": "dislike",
            "thumbsdown": "dislike", "thumbs_down": "dislike",
            "😂": "laugh", "😄": "laugh", "😆": "laugh", "🤣": "laugh",
            "haha": "laugh", "laugh": "laugh", "joy": "laugh", "smile": "laugh",
            "laughing": "laugh", "lol": "laugh",
            "‼️": "emphasize", "‼": "emphasize", "❗": "emphasize", "❗️": "emphasize",
            "💯": "emphasize", "emphasize": "emphasize", "emphasis": "emphasize",
            "exclamation": "emphasize", "bangbang": "emphasize", "100": "emphasize",
            "❓": "question", "❓️": "question", "?": "question",
            "question": "question", "question_mark": "question",
            "🤔": "question", "thinking_face": "question",
        ]
        var result: [String: String] = [:]
        for (key, kind) in canonical {
            result[key] = kind
            result[stripVariationSelectors(key)] = kind
        }
        return result
    }()

    /// The imsg `tapback` RPC wants one of the six canonical kind names.
    /// Accepts the kind names themselves, `:alias:` names, and the Unicode
    /// emoji Messages renders for each tapback. Returns nil when the reaction
    /// has no tapback equivalent (arbitrary emoji cannot be sent as tapbacks
    /// through the pinned helper).
    static func imessageTapbackKind(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let unColoned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
        if imessageTapbackKinds.contains(unColoned) { return unColoned }
        if let kind = imessageTapbackTable[unColoned]
            ?? imessageTapbackTable[stripVariationSelectors(trimmed)]
            ?? imessageTapbackTable[trimmed]
        {
            return kind
        }
        return nil
    }

    // MARK: - Helpers

    private static func isPlausibleAliasName(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber
                        || character == "_" || character == "-" || character == "+")
            }
    }

    private static func containsNonASCII(_ value: String) -> Bool {
        value.unicodeScalars.contains { !$0.isASCII }
    }

    private static func stripVariationSelectors(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value != 0xFE0F }))
    }
}

//
//  AgentChannelReactionNormalizerTests.swift
//  osaurusTests
//
//  Coverage for provider-aware emoji reaction normalization.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentChannelReactionNormalizerTests {

    // MARK: - Slack

    @Test func slackStripsColonsAndLowercasesAliases() {
        #expect(AgentChannelReactionNormalizer.slackName(":white_check_mark:") == "white_check_mark")
        #expect(AgentChannelReactionNormalizer.slackName("White_Check_Mark") == "white_check_mark")
        #expect(AgentChannelReactionNormalizer.slackName("+1") == "+1")
    }

    @Test func slackMapsUnicodeEmojiBackToAliases() {
        #expect(AgentChannelReactionNormalizer.slackName("✅") == "white_check_mark")
        #expect(AgentChannelReactionNormalizer.slackName("👍") == "+1")
        #expect(AgentChannelReactionNormalizer.slackName("🎉") == "tada")
        // With variation selector.
        #expect(AgentChannelReactionNormalizer.slackName("❤️") == "heart")
    }

    @Test func slackRejectsUnmappableInput() {
        #expect(AgentChannelReactionNormalizer.slackName("") == nil)
        #expect(AgentChannelReactionNormalizer.slackName("   ") == nil)
        #expect(AgentChannelReactionNormalizer.slackName("not a name!") == nil)
        #expect(AgentChannelReactionNormalizer.slackName(String(repeating: "a", count: 101)) == nil)
    }

    // MARK: - Discord

    @Test func discordPassesUnicodeEmojiThrough() {
        #expect(AgentChannelReactionNormalizer.discordReaction("🎉") == "🎉")
        #expect(AgentChannelReactionNormalizer.discordReaction("👍") == "👍")
    }

    @Test func discordMapsAliasesToUnicode() {
        #expect(AgentChannelReactionNormalizer.discordReaction(":tada:") == "🎉")
        #expect(AgentChannelReactionNormalizer.discordReaction("white_check_mark") == "✅")
    }

    @Test func discordNormalizesCustomEmojiForms() {
        #expect(AgentChannelReactionNormalizer.discordReaction("party_blob:123456789012345678")
            == "party_blob:123456789012345678")
        #expect(AgentChannelReactionNormalizer.discordReaction("<:party_blob:123456789012345678>")
            == "party_blob:123456789012345678")
        #expect(AgentChannelReactionNormalizer.discordReaction("<a:spinning:123456789012345678>")
            == "spinning:123456789012345678")
    }

    @Test func discordRejectsMalformedCustomEmoji() {
        #expect(AgentChannelReactionNormalizer.discordReaction("name:notanumber") == nil)
        #expect(AgentChannelReactionNormalizer.discordReaction("unknown_alias_zzz") == nil)
        #expect(AgentChannelReactionNormalizer.discordReaction("") == nil)
    }

    // MARK: - Telegram

    @Test func telegramProducesTypedEmojiPayloads() {
        #expect(AgentChannelReactionNormalizer.telegramReaction("👍") == .emoji("👍"))
        #expect(AgentChannelReactionNormalizer.telegramReaction(":fire:") == .emoji("🔥"))
    }

    @Test func telegramStripsVariationSelectorsForAllowedEmojiList() {
        // Telegram's allowed reaction list uses the bare heart (U+2764).
        #expect(AgentChannelReactionNormalizer.telegramReaction("❤️") == .emoji("❤"))
    }

    @Test func telegramDetectsCustomEmojiIds() {
        #expect(AgentChannelReactionNormalizer.telegramReaction("custom_emoji:5368324170671202286")
            == .customEmoji("5368324170671202286"))
        #expect(AgentChannelReactionNormalizer.telegramReaction("5368324170671202286")
            == .customEmoji("5368324170671202286"))
    }

    @Test func telegramRejectsPlainASCIIWords() {
        #expect(AgentChannelReactionNormalizer.telegramReaction("nope") == nil)
        #expect(AgentChannelReactionNormalizer.telegramReaction("custom_emoji:abc") == nil)
        #expect(AgentChannelReactionNormalizer.telegramReaction("") == nil)
    }

    @Test func telegramPayloadDictionariesMatchBotAPIShape() {
        #expect(TelegramReactionPayload.emoji("👍").dictionary == ["type": "emoji", "emoji": "👍"])
        #expect(TelegramReactionPayload.customEmoji("42").dictionary
            == ["type": "custom_emoji", "custom_emoji_id": "42"])
    }
}

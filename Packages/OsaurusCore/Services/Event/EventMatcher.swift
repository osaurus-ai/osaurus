//
//  EventMatcher.swift
//  osaurus
//
//  Pure matching: which events a channel message selects, and whether an
//  occurrence passes its event's filter.
//

import Foundation

enum EventMatcher {
    // MARK: - Channel selection

    struct ChannelMatch: Equatable, Sendable {
        let event: OsaurusEvent
        /// "alias:<alias>", "room:<roomId>", or "default" — for the ledger
        /// and the channel activity rows.
        let rule: String
        /// The message with a matched alias prefix removed.
        let content: String
    }

    /// Facts a platform reports about one inbound message, before events.
    struct ChannelFacts: Sendable {
        var kind: AgentChannelKind
        var connectionId: String
        var roomId: String
        var content: String
        /// nil when the platform cannot tell (no bot identity).
        var mentionsBot: Bool?
        /// The bot already posted in this room/thread.
        var hasPriorOutbound: Bool
    }

    /// The events a message fires, in three tiers: events whose alias leads
    /// the message (longest alias wins; room-scoped beats any-room), else
    /// events scoped to the message's room, else any-room events. Every
    /// event in the winning tier fires. Mention gating applies per event.
    static func rankChannelEvents(_ events: [OsaurusEvent], facts: ChannelFacts) -> [ChannelMatch] {
        let room = facts.roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = events.filter { event in
            guard event.isEnabled, let source = event.source.channelMessage else { return false }
            guard source.kind == facts.kind,
                AgentChannelConnection.normalizedId(source.connectionId)
                    == AgentChannelConnection.normalizedId(facts.connectionId)
            else { return false }
            guard source.roomIds.isEmpty || source.roomIds.contains(room) else { return false }
            return passesMentionGate(source, facts: facts)
        }

        var bestAlias: (alias: String, scoped: Bool)?
        var aliasMatches: [(event: OsaurusEvent, alias: String, scoped: Bool, remainder: String)] = []
        for event in candidates {
            guard let source = event.source.channelMessage else { continue }
            let scoped = !source.roomIds.isEmpty
            for alias in source.aliases {
                guard let remainder = stripLeadingAlias(alias, from: facts.content) else { continue }
                aliasMatches.append((event, alias, scoped, remainder))
                if let current = bestAlias {
                    let better =
                        (scoped && !current.scoped) || (scoped == current.scoped && alias.count > current.alias.count)
                    if better { bestAlias = (alias, scoped) }
                } else {
                    bestAlias = (alias, scoped)
                }
            }
        }
        if let bestAlias {
            var seen = Set<UUID>()
            return
                aliasMatches
                .filter {
                    $0.alias.lowercased() == bestAlias.alias.lowercased() && $0.scoped == bestAlias.scoped
                        && seen.insert($0.event.id).inserted
                }
                .map { ChannelMatch(event: $0.event, rule: "alias:\($0.alias)", content: $0.remainder) }
        }

        let unaliased = candidates.filter { ($0.source.channelMessage?.aliases ?? []).isEmpty }
        let roomScoped = unaliased.filter { !($0.source.channelMessage?.roomIds ?? []).isEmpty }
        if !roomScoped.isEmpty {
            return roomScoped.map { ChannelMatch(event: $0, rule: "room:\(room)", content: facts.content) }
        }
        return unaliased.map { ChannelMatch(event: $0, rule: "default", content: facts.content) }
    }

    static func passesMentionGate(_ source: ChannelMessageSourceConfig, facts: ChannelFacts) -> Bool {
        guard source.requireMention, ChannelMessageSourceConfig.supportsMentions(source.kind) else { return true }
        guard let mentioned = facts.mentionsBot else { return true }
        if mentioned { return true }
        return source.continueThreads && facts.hasPriorOutbound
    }

    /// Characters that may separate a leading alias from the message body.
    private static let aliasDelimiters = CharacterSet(charactersIn: ":,;-–—").union(.whitespacesAndNewlines)

    /// The message body with the leading alias and its delimiter removed
    /// when `content` starts with `alias` (case-insensitive, optional `@`)
    /// followed by a delimiter or end of message; nil otherwise.
    static func stripLeadingAlias(_ alias: String, from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, trimmed.count >= alias.count else { return nil }
        let working = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard working.lowercased().hasPrefix(alias.lowercased()) else { return nil }
        let afterAlias = working.dropFirst(alias.count)
        if afterAlias.isEmpty { return "" }
        guard let first = afterAlias.unicodeScalars.first, aliasDelimiters.contains(first) else { return nil }
        return String(
            afterAlias.drop(while: { char in
                char.unicodeScalars.allSatisfy { aliasDelimiters.contains($0) }
            }))
    }

    // MARK: - Filter

    /// nil when the occurrence passes, otherwise the reason it was
    /// filtered (`filtered:<clause>`).
    static func filterRejection(_ filter: EventFilter, payload: JSONValue) -> String? {
        guard !filter.isEmpty else { return nil }
        if !filter.senderAllowlist.isEmpty {
            let kind = payload.value(atPath: "event.source_kind")?.stringValue.flatMap(EventSourceKind.init(rawValue:))
            let paths = kind?.descriptor.senderPaths ?? EventSourceKind.channelMessage.descriptor.senderPaths
            let sender = paths.compactMap { payload.value(atPath: $0)?.stringValue?.lowercased() }
            let allowed = filter.senderAllowlist.map { $0.lowercased() }
            // For mail, `@example.com` allows a whole domain; channel handles
            // such as `@alice` stay exact.
            let domains = kind == .email
            let matches = sender.contains { value in
                allowed.contains { $0 == value || (domains && $0.hasPrefix("@") && value.hasSuffix($0)) }
            }
            guard matches else { return "filtered:sender" }
        }
        let text = (payload.value(atPath: "text")?.stringValue ?? "").lowercased()
        if !filter.keywordsAny.isEmpty, !filter.keywordsAny.contains(where: { text.contains($0.lowercased()) }) {
            return "filtered:keywords_any"
        }
        if !filter.keywordsAll.isEmpty, !filter.keywordsAll.allSatisfy({ text.contains($0.lowercased()) }) {
            return "filtered:keywords_all"
        }
        if !filter.pathGlobs.isEmpty {
            let paths = (payload.value(atPath: "folder.changed_paths")?.arrayValue ?? []).compactMap(\.stringValue)
            // A run with no diff (first pass, Fire now) still runs: the
            // agent inspects the whole folder.
            if !paths.isEmpty, !paths.contains(where: { matchesAnyGlob($0, filter.pathGlobs) }) {
                return "filtered:path_globs"
            }
        }
        for condition in filter.conditions {
            let actual = EventTemplate.text(of: payload.value(atPath: condition.path))
            guard actual.caseInsensitiveCompare(condition.equals.trimmingCharacters(in: .whitespaces)) == .orderedSame
            else { return "filtered:condition:\(condition.path)" }
        }
        return nil
    }

    static func matchesAnyGlob(_ path: String, _ globs: [String]) -> Bool {
        let cleaned = path.hasSuffix(" (removed)") ? String(path.dropLast(" (removed)".count)) : path
        let name = (cleaned as NSString).lastPathComponent
        return globs.contains { glob in
            fnmatch(glob, name, 0) == 0 || fnmatch(glob, cleaned, 0) == 0
        }
    }
}

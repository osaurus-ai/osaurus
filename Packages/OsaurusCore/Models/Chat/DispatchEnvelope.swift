//
//  DispatchEnvelope.swift
//  osaurus
//
//  Display-time parser for the machine-generated envelopes that background
//  dispatch paths write into a user turn's `content`: the untrusted channel
//  wrapper, the delegated-task delivery contract, the self-scheduled-run
//  preamble, the watcher-run framing, and the folder-unreadable preamble.
//
//  The stored turn and the model request are never touched — this only
//  recovers the human-authored text (plus a little provenance) so the chat
//  can render a message instead of a template. Every producer exposes its
//  fixed fragments as shared constants, and the round-trip tests pin them,
//  so the producer and this parser cannot drift apart.
//
//  Performance contract: no regular expressions; every kind is gated by a
//  `hasPrefix` / `hasSuffix` check before any `range(of:)` scan, so a normal
//  typed message costs a handful of comparisons and returns nil.
//

import Foundation

// MARK: - Channel envelope

/// Parsed provenance label of a channel message, e.g.
/// `"n8n connection n8n-clippy, conversation demo-helpdesk, sender workflow"`
/// → provider `n8n`, parts `[connection: n8n-clippy, conversation: demo-helpdesk, sender: workflow]`.
struct ChannelMessageSource: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        let label: String
        let value: String
    }

    /// Provider name as the adapter spelled it ("n8n", "Slack", "Discord",
    /// "Telegram", "WhatsApp", "iMessage").
    let provider: String
    let parts: [Part]
    /// The verbatim label, for tooltips.
    let raw: String

    /// First part whose label matches any of the given names, in order.
    func value(forAny labels: [String]) -> String? {
        for label in labels {
            if let part = parts.first(where: { $0.label == label }) { return part.value }
        }
        return nil
    }

    /// Where the message came from within the provider (conversation,
    /// channel, chat, or room), whichever the adapter supplied.
    var conversation: String? {
        value(forAny: ["conversation", "channel", "chat", "room"])
    }

    var sender: String? { value(forAny: ["sender"]) }

    /// Every adapter emits `"<Provider> <label> <value>, <label> <value>, …"`.
    /// Segments without a label/value pair are kept as unlabeled values so
    /// nothing the adapter wrote is silently dropped.
    static func parse(_ label: String) -> ChannelMessageSource {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.components(separatedBy: ", ")
        var provider = ""
        var parts: [Part] = []
        for (index, segment) in segments.enumerated() {
            let tokens = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if index == 0 {
                guard let first = tokens.first else { continue }
                provider = first
                if tokens.count >= 3 {
                    parts.append(Part(label: tokens[1], value: tokens.dropFirst(2).joined(separator: " ")))
                } else if tokens.count == 2 {
                    parts.append(Part(label: "", value: tokens[1]))
                }
            } else if tokens.count >= 2 {
                parts.append(Part(label: tokens[0], value: tokens.dropFirst().joined(separator: " ")))
            } else if let only = tokens.first {
                parts.append(Part(label: "", value: only))
            }
        }
        return ChannelMessageSource(provider: provider, parts: parts, raw: trimmed)
    }
}

/// The `[Untrusted external channel message] … [/Untrusted external channel message]`
/// block produced by `ChannelRemoteSafetyGate.wrapUntrustedContent`, decoded.
struct ChannelMessageEnvelope: Equatable, Sendable {
    let source: ChannelMessageSource
    let risk: ChannelRemoteContentRisk
    let signals: [ChannelRemoteContentSignal]
    /// The channel text itself, with the attachment trailer split off.
    let content: String
    /// One entry per attachment line of the trailer (leading `- ` removed).
    let attachmentLines: [String]
    let contentCharacterCount: Int
    let emittedCharacterCount: Int
    let truncated: Bool

    var isSuspicious: Bool { risk == .suspicious }

    /// Strict parse: the whole (whitespace-trimmed) text must be one envelope
    /// with decodable `source_json` and `content_json` lines. Anything else
    /// returns nil so ordinary user messages are never reinterpreted.
    static func parse(_ text: String) -> ChannelMessageEnvelope? {
        let open = ChannelRemoteSafetyGate.untrustedEnvelopeOpen
        let close = ChannelRemoteSafetyGate.untrustedEnvelopeClose
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(open), trimmed.hasSuffix(close) else { return nil }
        let innerStart = trimmed.index(trimmed.startIndex, offsetBy: open.count)
        let innerEnd = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
        guard innerStart <= innerEnd else { return nil }
        let inner = trimmed[innerStart..<innerEnd]

        var fields: [String: String] = [:]
        for rawLine in inner.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[..<colon].trimmingCharacters(in: .whitespaces)
            var value = rawLine[rawLine.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
            // First occurrence wins: a forged duplicate key inside the payload
            // cannot land here because the payload is a single JSON line.
            if fields[key] == nil { fields[key] = String(value) }
        }

        guard let sourceJSON = fields["source_json"],
            let source = decodeJSONString(sourceJSON),
            let contentJSON = fields["content_json"],
            let fullContent = decodeJSONString(contentJSON)
        else { return nil }

        let risk = fields["risk"].flatMap(ChannelRemoteContentRisk.init(rawValue:)) ?? .ordinary
        let signals: [ChannelRemoteContentSignal] = {
            guard let line = fields["signals"], line != "none" else { return [] }
            return line.components(separatedBy: ",")
                .compactMap { ChannelRemoteContentSignal(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        }()
        let originalCount = fields["content_character_count"].flatMap(Int.init) ?? fullContent.count
        let emittedCount = fields["emitted_content_character_count"].flatMap(Int.init) ?? fullContent.count
        let truncated = fields["content_truncated"] == "true" || emittedCount < originalCount

        let (content, attachmentLines) = splitAttachmentTrailer(fullContent)

        return ChannelMessageEnvelope(
            source: ChannelMessageSource.parse(source),
            risk: risk,
            signals: signals,
            content: content,
            attachmentLines: attachmentLines,
            contentCharacterCount: originalCount,
            emittedCharacterCount: emittedCount,
            truncated: truncated
        )
    }

    /// Splits off the `Attachments supplied by the channel (untrusted metadata):`
    /// trailer that `AgentChannelInboundRelay` appends after the text.
    private static func splitAttachmentTrailer(_ content: String) -> (String, [String]) {
        let marker = "\n\n" + AgentChannelInboundRelay.attachmentContextHeader + "\n"
        guard let range = content.range(of: marker, options: .backwards) else {
            return (content, [])
        }
        let body = String(content[..<range.lowerBound])
        let lines = content[range.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                let s = String(line)
                return s.hasPrefix("- ") ? String(s.dropFirst(2)) : s
            }
        return (body, lines)
    }

    private static func decodeJSONString(_ literal: String) -> String? {
        guard let data = literal.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
}

extension ChannelRemoteContentSignal {
    /// Plain-language name for the badge tooltip.
    var displayName: String {
        switch self {
        case .systemInstructionOverride: return L("Tries to override instructions")
        case .toolPolicyOverride: return L("Tries to change tool permissions")
        case .computerUseApproval: return L("Asks to approve Computer Use")
        case .credentialExfiltration: return L("Asks for credentials or tokens")
        case .channelPolicyMutation: return L("Tries to change channel policy")
        case .hiddenPromptMarker: return L("Contains hidden prompt markers")
        }
    }
}

// MARK: - Dispatch envelope

/// A user turn whose stored content is a machine-generated dispatch envelope,
/// reduced to the human-authored text plus provenance for the badge row.
struct DispatchEnvelope: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case channel(ChannelMessageEnvelope)
        case delegatedTask(resuming: Bool)
        case selfScheduledRun(scheduledBy: String?, scheduledAt: String?, previousRun: String?)
        case watcherRun(watchedFolder: String?, changedPaths: [String], overflowCount: Int, iteration: Int?)
    }

    /// Nil when only the folder-unreadable preamble matched.
    let kind: Kind?
    /// Path named by the folder-unreadable preamble, when present.
    let folderUnreadablePath: String?
    /// What the bubble should show in place of the raw content.
    let displayText: String

    /// Recover the display text from an envelope. Returns nil when the content
    /// is not an envelope (or reduces to nothing), so the caller falls back to
    /// rendering the raw text.
    ///
    /// The watcher framing has no markers of its own, so it is only tried for
    /// `.watcher` sessions; every other kind is self-identifying.
    static func parse(_ content: String, sessionSource: SessionSource) -> DispatchEnvelope? {
        var text = content
        var folderPath: String?
        if let stripped = stripFolderPreamble(text) {
            folderPath = stripped.path
            text = stripped.remainder
        }

        var kind: Kind?
        var display = text
        if let channel = parseChannel(text) {
            kind = .channel(channel)
            display = channel.content
        } else if let delegated = parseDelegation(text) {
            kind = .delegatedTask(resuming: delegated.resuming)
            display = delegated.input
        } else if let scheduled = parseSelfScheduled(text) {
            kind = scheduled.kind
            display = scheduled.instructions
        } else if sessionSource == .watcher, let watcher = parseWatcher(text) {
            kind = watcher.kind
            display = watcher.instructions
        }

        guard kind != nil || folderPath != nil else { return nil }
        let trimmedDisplay = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplay.isEmpty else { return nil }
        return DispatchEnvelope(kind: kind, folderUnreadablePath: folderPath, displayText: trimmedDisplay)
    }

    // MARK: Folder preamble

    private static func stripFolderPreamble(_ text: String) -> (path: String, remainder: String)? {
        let prefix = ExecutionContext.folderUnreadablePreamblePrefix
        guard text.hasPrefix(prefix) else { return nil }
        let afterPrefix = text.index(text.startIndex, offsetBy: prefix.count)
        let suffix = ExecutionContext.folderUnreadablePreambleSuffix
        guard let suffixRange = text.range(of: suffix, range: afterPrefix..<text.endIndex) else { return nil }
        let path = String(text[afterPrefix..<suffixRange.lowerBound])
        var remainder = text[suffixRange.upperBound...]
        if remainder.hasPrefix("\n\n") { remainder = remainder.dropFirst(2) }
        return (path, String(remainder))
    }

    // MARK: Channel

    private static func parseChannel(_ text: String) -> ChannelMessageEnvelope? {
        // Cheap gate before the full parse trims and scans.
        guard text.hasPrefix(ChannelRemoteSafetyGate.untrustedEnvelopeOpen) else { return nil }
        return ChannelMessageEnvelope.parse(text)
    }

    // MARK: Delegation

    private static func parseDelegation(_ text: String) -> (input: String, resuming: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [(open: String, close: String, resuming: Bool)] = [
            (AgentDelegationDispatcher.delegatedTaskOpen, AgentDelegationDispatcher.delegatedTaskClose, false),
            (AgentDelegationDispatcher.delegatedFollowUpOpen, AgentDelegationDispatcher.delegatedFollowUpClose, true),
        ]
        for candidate in candidates where trimmed.hasSuffix(candidate.close) {
            // The contract is appended as "\n\n[Open]\n…"; the LAST opener is
            // the real one even if the task text quotes the marker.
            let marker = "\n\n" + candidate.open + "\n"
            guard let range = trimmed.range(of: marker, options: .backwards) else { return nil }
            return (String(trimmed[..<range.lowerBound]), candidate.resuming)
        }
        return nil
    }

    // MARK: Self-scheduled run

    private static func parseSelfScheduled(_ text: String) -> (kind: Kind, instructions: String)? {
        guard text.hasPrefix(NextRunScheduler.selfScheduledRunPrefix) else { return nil }
        let header = "\n" + NextRunScheduler.instructionsHeader + "\n"
        guard let range = text.range(of: header) else { return nil }
        let preamble = text[..<range.lowerBound]
        var scheduledBy: String?
        var scheduledAt: String?
        var previousRun: String?
        for line in preamble.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if s.hasPrefix(NextRunScheduler.scheduledByLinePrefix) {
                // "Scheduled by: <who>, for <when>."
                var rest = String(s.dropFirst(NextRunScheduler.scheduledByLinePrefix.count))
                if rest.hasSuffix(".") { rest.removeLast() }
                if let split = rest.range(of: ", for ") {
                    scheduledBy = String(rest[..<split.lowerBound])
                    scheduledAt = String(rest[split.upperBound...])
                } else {
                    scheduledBy = rest
                }
            } else if s.hasPrefix(NextRunScheduler.previousRunLinePrefix) {
                previousRun = s
            }
        }
        let instructions = String(text[range.upperBound...])
        return (
            .selfScheduledRun(scheduledBy: scheduledBy, scheduledAt: scheduledAt, previousRun: previousRun),
            instructions
        )
    }

    // MARK: Watcher run

    private static func parseWatcher(_ text: String) -> (kind: Kind, instructions: String)? {
        // Peel the fixed guidance paragraphs off the end, innermost last.
        var body = Substring(text)
        let organized = "\n" + WatcherManager.alreadyOrganizedGuidance + "\n"
        guard body.hasSuffix(organized) else { return nil }
        body = body.dropLast(organized.count)

        var iteration: Int?
        let first = "\n" + WatcherManager.firstIterationGuidance + "\n"
        let followUp = "\n" + WatcherManager.followUpIterationGuidance + "\n"
        if body.hasSuffix(first) {
            body = body.dropLast(first.count)
            iteration = 1
        } else if body.hasSuffix(followUp) {
            body = body.dropLast(followUp.count)
            iteration = 2
        } else {
            return nil
        }

        // Optional changed-path block: header line, "- `path`" lines, and an
        // overflow line. It always follows the folder line / instructions.
        var changedPaths: [String] = []
        var overflow = 0
        let changedMarker = "\n" + WatcherManager.changedSinceHeader + "\n"
        if let range = body.range(of: changedMarker, options: .backwards) {
            for line in body[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                if s.hasPrefix("- `"), s.hasSuffix("`") {
                    changedPaths.append(String(s.dropFirst(3).dropLast()))
                } else if s.hasPrefix(WatcherManager.changedPathOverflowPrefix),
                    s.hasSuffix(WatcherManager.changedPathOverflowSuffix)
                {
                    let digits = s.dropFirst(WatcherManager.changedPathOverflowPrefix.count)
                        .dropLast(WatcherManager.changedPathOverflowSuffix.count)
                    overflow = Int(digits) ?? 0
                }
            }
            // Keep the newline that separated instructions from the block; it
            // is peeled below with the folder line / bare separator.
            body = body[..<range.lowerBound] + "\n"
        }

        // Folder line ("\n\n<prefix><path>\n") or the bare "\n" separator.
        var watchedFolder: String?
        let folderMarker = "\n\n" + WatcherManager.watchedFolderLinePrefix
        if let range = body.range(of: folderMarker, options: .backwards) {
            let after = body[range.upperBound...]
            if let lineEnd = after.firstIndex(of: "\n") {
                watchedFolder = String(after[..<lineEnd])
            } else {
                watchedFolder = String(after)
            }
            body = body[..<range.lowerBound]
        } else if body.hasSuffix("\n") {
            body = body.dropLast()
        }

        return (
            .watcherRun(
                watchedFolder: watchedFolder,
                changedPaths: changedPaths,
                overflowCount: overflow,
                iteration: iteration
            ),
            String(body)
        )
    }
}

// MARK: - Badge presentation

extension DispatchEnvelope {
    /// One chip in the provenance badge row.
    struct Badge: Equatable, Sendable {
        enum Tone: Equatable, Sendable {
            case neutral
            case warning
            case error
        }

        let symbol: String
        let label: String
        let tooltip: String?
        let tone: Tone

        init(symbol: String, label: String, tooltip: String? = nil, tone: Tone = .neutral) {
            self.symbol = symbol
            self.label = label
            self.tooltip = tooltip
            self.tone = tone
        }
    }

    /// Provider-specific glyph for the channel chip.
    static func providerSymbol(_ provider: String) -> String {
        switch provider.lowercased() {
        case "n8n": return "arrow.triangle.branch"
        case "slack": return "number"
        case "discord": return "bubble.left.and.bubble.right"
        case "telegram": return "paperplane"
        case "whatsapp": return "phone.bubble"
        case "imessage": return "message"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Badges in display order: provenance first, then context, then any
    /// warnings. The renderer caps the visible count and folds the rest into
    /// a "+N" chip, so order here is also priority.
    var badges: [Badge] {
        var out: [Badge] = []
        if let path = folderUnreadablePath {
            out.append(
                Badge(
                    symbol: "exclamationmark.triangle.fill",
                    label: L("Folder unreadable"),
                    tooltip: ExecutionContext.folderUnreadablePreamble(path: path),
                    tone: .error
                )
            )
        }
        switch kind {
        case let .channel(channel):
            let provider = channel.source.provider
            out.append(
                Badge(
                    symbol: Self.providerSymbol(provider),
                    label: provider.isEmpty ? L("via channel") : L("via \(provider)"),
                    tooltip: channel.source.raw
                )
            )
            if let conversation = channel.source.conversation {
                out.append(Badge(symbol: "bubble.left.and.text.bubble.right", label: conversation, tooltip: L("Conversation")))
            }
            if let sender = channel.source.sender {
                out.append(Badge(symbol: "person", label: sender, tooltip: L("Sender")))
            }
            if !channel.attachmentLines.isEmpty {
                let n = channel.attachmentLines.count
                out.append(
                    Badge(
                        symbol: "paperclip",
                        label: n == 1 ? L("1 attachment") : L("\(n) attachments"),
                        tooltip: channel.attachmentLines.joined(separator: "\n")
                    )
                )
            }
            if channel.truncated {
                out.append(
                    Badge(
                        symbol: "scissors",
                        label: L("Trimmed"),
                        tooltip: L(
                            "Showing \(channel.emittedCharacterCount) of \(channel.contentCharacterCount) characters"
                        ),
                        tone: .warning
                    )
                )
            }
            if channel.isSuspicious {
                let names = channel.signals.map(\.displayName)
                out.append(
                    Badge(
                        symbol: "exclamationmark.shield.fill",
                        label: L("Flagged"),
                        tooltip: names.isEmpty
                            ? L("This message was flagged as suspicious.")
                            : names.joined(separator: "\n"),
                        tone: .warning
                    )
                )
            }

        case let .delegatedTask(resuming):
            out.append(
                Badge(
                    symbol: "arrow.turn.down.right",
                    label: resuming ? L("Follow-up") : L("Delegated task"),
                    tooltip: resuming
                        ? L("Continuation of a task delegated by another agent")
                        : L("Task delegated by another agent")
                )
            )

        case let .selfScheduledRun(scheduledBy, scheduledAt, previousRun):
            var tooltipLines: [String] = []
            if let scheduledBy { tooltipLines.append(L("Scheduled by \(scheduledBy)")) }
            if let previousRun { tooltipLines.append(previousRun) }
            out.append(
                Badge(
                    symbol: "alarm",
                    label: L("Self-scheduled"),
                    tooltip: tooltipLines.isEmpty ? nil : tooltipLines.joined(separator: "\n")
                )
            )
            if let scheduledAt {
                out.append(Badge(symbol: "clock", label: scheduledAt, tooltip: L("Scheduled for")))
            }

        case let .watcherRun(watchedFolder, changedPaths, overflowCount, iteration):
            out.append(
                Badge(
                    symbol: "folder.badge.gearshape",
                    label: L("Watcher run"),
                    tooltip: iteration.map { $0 == 1 ? L("First pass") : L("Follow-up pass") }
                )
            )
            if let watchedFolder {
                let name = (watchedFolder as NSString).lastPathComponent
                out.append(
                    Badge(
                        symbol: "folder",
                        label: name.isEmpty ? watchedFolder : name,
                        tooltip: watchedFolder
                    )
                )
            }
            let total = changedPaths.count + overflowCount
            if total > 0 {
                var lines = changedPaths
                if overflowCount > 0 { lines.append(L("…and \(overflowCount) more")) }
                out.append(
                    Badge(
                        symbol: "doc.badge.clock",
                        label: total == 1 ? L("1 changed") : L("\(total) changed"),
                        tooltip: lines.joined(separator: "\n")
                    )
                )
            }

        case nil:
            break
        }
        return out
    }
}

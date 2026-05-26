//
//  ChatSessionExporter.swift
//  osaurus
//
//  Serializes `ChatSessionData` to Markdown / PDF / Zip for the sidebar
//  Actions menu.
//

import AppKit
import Foundation

@MainActor
public enum ChatSessionExporter {
    public enum ExportError: Error, LocalizedError {
        case sessionMissing
        case pdfRenderFailed
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sessionMissing: return "Chat session could not be loaded for export."
            case .pdfRenderFailed: return "Could not render the chat as a PDF."
            case .writeFailed(let m): return "Export write failed: \(m)"
            }
        }
    }

    // MARK: - Markdown

    /// Each turn becomes an H2 with role label, content, attachments, tool calls.
    /// When `options` enables any timing flag, the header line gains a
    /// suffix like ` — 14:02:18 (+1m23s, 312 tok, 28.4 tok/s)` with each
    /// piece guarded by both the flag and presence of the underlying data.
    public static func markdown(for session: ChatSessionData, options: ChatExportOptions = ChatExportOptions())
        -> String
    {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        var meta: [String] = []
        meta.append("Created: \(formatDate(session.createdAt))")
        meta.append("Updated: \(formatDate(session.updatedAt))")
        if let model = session.selectedModel, !model.isEmpty {
            meta.append("Model: \(model)")
        }
        meta.append("Source: \(session.source.rawValue)")
        if !session.capabilities.isEmpty {
            let caps = SessionCapability.allCases
                .filter { session.capabilities.contains($0) }
                .map(\.label)
                .joined(separator: ", ")
            meta.append("Capabilities: \(caps)")
        }
        lines.append("> " + meta.joined(separator: " · "))
        lines.append("")

        let agentLabel = assistantLabel(for: session)
        var previousTurnAnchor: Date? = nil
        for (idx, turn) in session.turns.enumerated() {
            let role = roleLabel(for: turn, assistantLabel: agentLabel)
            let suffix = timingSuffix(for: turn, options: options, previousAnchor: previousTurnAnchor)
            lines.append("## \(role) — turn \(idx + 1)\(suffix)")
            lines.append("")
            previousTurnAnchor = turn.createdAt ?? previousTurnAnchor
            let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append(trimmed)
                lines.append("")
            }
            if !turn.attachments.isEmpty {
                lines.append("**Attachments**")
                for att in turn.attachments {
                    lines.append("- \(describe(att))")
                }
                lines.append("")
            }
            if let calls = turn.toolCalls, !calls.isEmpty {
                lines.append("**Tool calls**")
                for call in calls {
                    lines.append("- `\(call.function.name)` — `\(call.function.arguments)`")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func writeMarkdown(
        session: ChatSessionData,
        options: ChatExportOptions = ChatExportOptions(),
        to url: URL
    ) throws {
        let text = markdown(for: session, options: options)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - PDF

    /// `NSPrintOperation` save-to-file gives page-broken output instead of
    /// the single tall page `NSView.dataWithPDF` would produce.
    public static func writePDF(session: ChatSessionData, options: ChatExportOptions = ChatExportOptions(), to url: URL)
        throws
    {
        let attributed = attributedMarkdown(for: session, options: options)
        let contentWidth: CGFloat = 540  // letter width minus 72pt margins
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 720))
        textView.textStorage?.setAttributedString(attributed)
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.sizeToFit()

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54

        let op = NSPrintOperation(view: textView, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() {
            throw ExportError.pdfRenderFailed
        }
    }

    // MARK: - Zip bundle

    /// Bundles `chat.md` plus hydrated attachments under `attachments/`.
    /// Unresolvable attachment bytes are skipped.
    public static func writeZip(session: ChatSessionData, options: ChatExportOptions = ChatExportOptions(), to url: URL)
        async throws
    {
        let fm = FileManager.default
        let bundleName = sanitizeFilename(session.title.isEmpty ? "chat" : session.title)
        let workRoot = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-export-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundleDir = workRoot.appendingPathComponent(bundleName, isDirectory: true)
        let attachmentsDir = bundleDir.appendingPathComponent("attachments", isDirectory: true)
        defer { try? fm.removeItem(at: workRoot) }

        do {
            try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
            let mdURL = bundleDir.appendingPathComponent("chat.md")
            try markdown(for: session, options: options).data(using: .utf8)?.write(to: mdURL, options: .atomic)

            var writtenNames = Set<String>()
            for (turnIdx, turn) in session.turns.enumerated() {
                for (attIdx, att) in turn.attachments.enumerated() {
                    guard let bytes = bytes(for: att) else { continue }
                    let base = att.filename ?? "turn\(turnIdx)-att\(attIdx)"
                    let name = uniqueFilename(base, taken: &writtenNames)
                    try bytes.write(to: attachmentsDir.appendingPathComponent(name), options: .atomic)
                }
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }

        let tempZip = workRoot.appendingPathComponent("\(bundleName).zip")
        do {
            try await fm.zipItem(at: bundleDir, to: tempZip)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.moveItem(at: tempZip, to: url)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func bytes(for attachment: Attachment) -> Data? {
        if let data = attachment.loadImageData() { return data }
        if let data = attachment.loadAudioData() { return data }
        if let data = attachment.loadVideoData() { return data }
        return nil
    }

    private static func describe(_ att: Attachment) -> String {
        if att.isImage { return "image: \(att.filename ?? "untitled")" }
        if att.isAudio { return "audio: \(att.filename ?? "untitled")" }
        if att.isDocument { return "document: \(att.filename ?? "untitled")" }
        return att.filename ?? "attachment"
    }

    /// Resolves the session's agent name for assistant role labels. Returns
    /// nil for the default (built-in) agent so the export stays "Assistant"
    /// instead of adding a noisy suffix.
    private static func assistantLabel(for session: ChatSessionData) -> String? {
        guard let agentId = session.agentId,
            agentId != Agent.defaultId,
            let agent = AgentManager.shared.agent(for: agentId),
            !agent.isBuiltIn
        else { return nil }
        let name = agent.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Builds the timing suffix appended to a turn header. Each piece
    /// is gated on the corresponding flag and the underlying data being
    /// present, so legacy turns (no timing fields) just contribute "".
    private static func timingSuffix(
        for turn: ChatTurnData,
        options: ChatExportOptions,
        previousAnchor: Date?
    ) -> String {
        guard options.hasAnyFlag else { return "" }
        var head: String? = nil
        if options.includeTimestamps, let created = turn.createdAt {
            head = formatTime(created)
        }
        var parens: [String] = []
        if options.includeDeltas,
            let created = turn.createdAt,
            let previous = previousAnchor
        {
            let delta = created.timeIntervalSince(previous)
            if delta >= 0 {
                parens.append("+\(formatDuration(delta))")
            }
        }
        if options.includeTokenUsage {
            if let tokens = turn.generationTokenCount {
                parens.append("\(tokens) tok")
            }
            if let created = turn.createdAt,
                let completed = turn.completedAt
            {
                let dur = completed.timeIntervalSince(created)
                if dur > 0, let tokens = turn.generationTokenCount, tokens > 0 {
                    let tps = Double(tokens) / dur
                    parens.append(String(format: "%.1f tok/s", tps))
                }
            }
        }
        let parenStr = parens.isEmpty ? "" : " (\(parens.joined(separator: ", ")))"
        if let head {
            return " — \(head)\(parenStr)"
        }
        return parens.isEmpty ? "" : " —\(parenStr)"
    }

    /// HH:MM:SS for the timestamp head.
    private static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// Compact "1m23s" / "12s" / "1h05m" — keeps the header short.
    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        if m < 60 { return "\(m)m\(String(format: "%02d", s))s" }
        let h = m / 60
        let mm = m % 60
        return "\(h)h\(String(format: "%02d", mm))m"
    }

    private static func roleLabel(for turn: ChatTurnData, assistantLabel: String?) -> String {
        let base = turn.role.rawValue.capitalized
        if turn.role == .assistant, let label = assistantLabel {
            return "\(base) (\(label))"
        }
        return base
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Strip filesystem-hostile characters.
    private static func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "chat" : String(cleaned.prefix(60))
    }

    /// Append `-2`, `-3`, ... on collision.
    private static func uniqueFilename(_ base: String, taken: inout Set<String>) -> String {
        let safe = sanitizeFilename(base)
        if !taken.contains(safe) {
            taken.insert(safe)
            return safe
        }
        let url = URL(fileURLWithPath: safe)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            n += 1
        }
    }

    /// PDF body: title bold, meta secondary, tool calls monospace.
    private static func attributedMarkdown(for session: ChatSessionData, options: ChatExportOptions)
        -> NSAttributedString
    {
        let body = NSMutableAttributedString()
        let titleFont = NSFont.boldSystemFont(ofSize: 18)
        let metaFont = NSFont.systemFont(ofSize: 10)
        let roleFont = NSFont.boldSystemFont(ofSize: 13)
        let textFont = NSFont.systemFont(ofSize: 11)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let secondary = NSColor.secondaryLabelColor

        body.append(NSAttributedString(string: session.title + "\n", attributes: [.font: titleFont]))
        var meta: [String] = ["Created: \(formatDate(session.createdAt))"]
        if let model = session.selectedModel, !model.isEmpty {
            meta.append("Model: \(model)")
        }
        meta.append("Source: \(session.source.rawValue)")
        body.append(
            NSAttributedString(
                string: meta.joined(separator: " · ") + "\n\n",
                attributes: [.font: metaFont, .foregroundColor: secondary]
            )
        )

        let agentLabel = assistantLabel(for: session)
        var previousTurnAnchor: Date? = nil
        for (idx, turn) in session.turns.enumerated() {
            let role = roleLabel(for: turn, assistantLabel: agentLabel)
            let suffix = timingSuffix(for: turn, options: options, previousAnchor: previousTurnAnchor)
            body.append(
                NSAttributedString(
                    string: "\(role) — turn \(idx + 1)\(suffix)\n",
                    attributes: [.font: roleFont]
                )
            )
            previousTurnAnchor = turn.createdAt ?? previousTurnAnchor
            let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                body.append(NSAttributedString(string: trimmed + "\n", attributes: [.font: textFont]))
            }
            if !turn.attachments.isEmpty {
                let listing = turn.attachments.map { "  - \(describe($0))" }.joined(separator: "\n")
                body.append(
                    NSAttributedString(
                        string: "Attachments\n\(listing)\n",
                        attributes: [.font: metaFont, .foregroundColor: secondary]
                    )
                )
            }
            if let calls = turn.toolCalls, !calls.isEmpty {
                let listing = calls.map { "  - \($0.function.name)(\($0.function.arguments))" }
                    .joined(separator: "\n")
                body.append(
                    NSAttributedString(
                        string: "Tool calls\n\(listing)\n",
                        attributes: [.font: monoFont, .foregroundColor: secondary]
                    )
                )
            }
            body.append(NSAttributedString(string: "\n", attributes: [.font: textFont]))
        }
        return body
    }
}

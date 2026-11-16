//
//  ChatImportVerifier.swift
//  osaurus
//
//  The code half of "the model reads, code checks". Turns the reader's
//  manifest into card rows, keeping only what the sources back up:
//  URLs, commands, args, env and header names must appear verbatim;
//  document references must resolve and bodies come from the documents;
//  capabilities come from a fixed list; models must exist; secrets
//  become setup slots; duplicates merge into the fast-path rows.
//

import Foundation

enum ChatImportVerifier {
    struct Outcome: Sendable {
        var items: [ChatImportItem] = []
        /// Fixed-wording notes about dropped values, shown on the card.
        var notes: [String] = []
    }

    static let maxInstructionChars = 60_000
    static let maxManualSteps = 8

    static func verify(
        manifest: ChatImportManifest,
        bundle: ChatImportBundle,
        fastPathItems: [ChatImportItem],
        consumedDocumentIds: Set<String> = []
    ) -> Outcome {
        var outcome = Outcome()
        var ids = ChatImportItemIds()
        for item in fastPathItems { ids.reserve(item.id) }
        let grounding = Grounding(bundle.groundingText)
        var dropped = 0

        for skill in manifest.skills {
            guard let body = body(doc: skill.doc, section: skill.section, bundle: bundle, consumed: consumedDocumentIds) else {
                if bundle.document(skill.doc) == nil { dropped += 1 }
                continue
            }
            let name = ChatImportFastPaths.cleanName(body.name ?? skill.name)
            guard !name.isEmpty, !hasInstructions(named: name, in: fastPathItems + outcome.items) else { continue }
            let description = clip(body.description ?? skill.description, 200)
            let spec = ChatImportInstructionsSpec(name: name, description: description, instructions: body.text)
            outcome.items.append(
                ChatImportItem(
                    id: ids.make("skill", name), kind: .skill, name: name, detail: description,
                    origin: body.origin, payload: .instructions(spec), contentHash: ChatImportHash.of(body.text)))
        }

        for agent in manifest.agents {
            guard let body = body(doc: agent.doc, section: agent.section, bundle: bundle, consumed: consumedDocumentIds)
            else {
                if bundle.document(agent.doc) == nil { dropped += 1 }
                continue
            }
            let name = ChatImportFastPaths.cleanName(agent.name)
            guard !name.isEmpty, !hasInstructions(named: name, in: fastPathItems + outcome.items) else { continue }
            let description = clip(agent.description, 200)
            let denies = Set(agent.denies.map { $0.lowercased() })
            let capabilities = agent.capabilities.map { $0.lowercased() }.filter(ChatImportCapabilities.keys.contains)
            let spec = ChatImportInstructionsSpec(
                name: name, description: description, instructions: body.text,
                model: agent.model.flatMap { grounding.contains($0) ? $0 : nil },
                capabilities: Array(Set(capabilities)).sorted(),
                deniesShell: denies.contains("shell"), deniesNetwork: denies.contains("network"))
            outcome.items.append(
                ChatImportItem(
                    id: ids.make("agent", name), kind: .agent, name: name, detail: description,
                    origin: body.origin, payload: .instructions(spec), contentHash: ChatImportHash.of(body.text)))
        }

        for command in manifest.commands {
            guard let body = body(doc: command.doc, section: command.section, bundle: bundle, consumed: consumedDocumentIds)
            else {
                if bundle.document(command.doc) == nil { dropped += 1 }
                continue
            }
            let name = ChatImportFastPaths.commandName(command.name)
            guard !name.isEmpty,
                !(fastPathItems + outcome.items).contains(where: { $0.kind == .command && $0.name == "/\(name)" })
            else { continue }
            var entry = CommandEntry(name: name)
            let description = clip(command.description, 200)
            entry.description = description.isEmpty ? nil : description
            entry.template = body.text
            entry.icon = "text.bubble"
            outcome.items.append(
                ChatImportItem(
                    id: ids.make("command", name), kind: .command, name: "/\(name)", detail: description,
                    origin: body.origin, payload: .command(entry), contentHash: ChatImportHash.of(body.text)))
        }

        var ungrounded = 0
        for server in manifest.mcpServers {
            guard let input = groundedServer(server, grounding: grounding) else {
                ungrounded += 1
                continue
            }
            let existing = fastPathItems + outcome.items
            guard !existing.contains(where: { sameServer($0, input) }) else { continue }
            outcome.items.append(ChatImportMCPBuilder.item(from: input, origin: originFor(input, bundle), ids: &ids))
        }

        var ungroundedSteps = 0
        for step in manifest.manualSteps.prefix(maxManualSteps) {
            let text = clip(step, 200)
            guard !text.isEmpty else { continue }
            guard isGroundedStep(text, grounding: grounding) else {
                ungroundedSteps += 1
                continue
            }
            outcome.items.append(
                ChatImportItem(
                    id: ids.make("step", text), kind: .manualStep, name: text, detail: "", origin: "",
                    payload: .manualStep(text), included: false))
        }

        if dropped > 0 {
            outcome.notes.append(L("Skipped \(dropped) item(s) that pointed at text Osaurus didn't download."))
        }
        if ungrounded > 0 {
            outcome.notes.append(
                L("Skipped \(ungrounded) MCP server(s) whose address or command isn't written in the source."))
        }
        if ungroundedSteps > 0 {
            outcome.notes.append(
                L("Skipped \(ungroundedSteps) step(s) that name an address or command the source doesn't."))
        }
        return outcome
    }

    // MARK: - Manual steps

    /// A step may name a site, address, or command only as the sources
    /// write it; the reader can't introduce one.
    static func isGroundedStep(_ text: String, grounding: Grounding) -> Bool {
        let addresses = matches(of: addressPattern, in: text).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
        }
        let code = matches(of: codeSpanPattern, in: text).map { String($0.dropFirst().dropLast()) }
        return (addresses + code).allSatisfy { grounding.containsURL($0) }
    }

    // swiftlint:disable:next force_try
    private static let addressPattern = try! NSRegularExpression(
        pattern: #"(?:[a-z][a-z0-9+.-]*://)?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?::\d+)?(?:/[^\s)`'"]*)?"#)
    // swiftlint:disable:next force_try
    private static let codeSpanPattern = try! NSRegularExpression(pattern: "`[^`\n]+`")

    private static func matches(of regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: - Saved text

    /// Cleans text that gets saved (a skill, agent, or command body):
    /// HTML comments, which a rendered page never shows the user, are
    /// removed, and key values (`SOME_API_KEY=value`, `Bearer value`,
    /// well-known key prefixes) become placeholders so a sample or pasted
    /// key never lands in a file. Returns card notes for what changed.
    static func cleanSavedText(_ items: inout [ChatImportItem]) -> [String] {
        var replaced = 0
        var hidden = 0
        func clean(_ text: String) -> String {
            let (visible, comments) = withoutComments(text)
            let (out, keys) = scrubbed(visible)
            hidden += comments
            replaced += keys
            return out
        }
        for index in items.indices {
            switch items[index].payload {
            case .instructions(var spec):
                spec.instructions = clean(spec.instructions)
                items[index].payload = .instructions(spec)
            case .command(var entry):
                guard let template = entry.template else { continue }
                entry.template = clean(template)
                items[index].payload = .command(entry)
            default:
                continue
            }
        }
        var notes: [String] = []
        if hidden > 0 { notes.append(L("Left out \(hidden) hidden comment(s) from the page text.")) }
        if replaced > 0 { notes.append(L("Replaced \(replaced) key value(s) in the imported text with a placeholder.")) }
        return notes
    }

    static func withoutComments(_ text: String) -> (String, Int) {
        let range = NSRange(text.startIndex..., in: text)
        let count = commentPattern.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        let out = commentPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), count)
    }

    // swiftlint:disable:next force_try
    private static let commentPattern = try! NSRegularExpression(
        pattern: "<!--.*?(?:-->|$)", options: [.dotMatchesLineSeparators])

    static func scrubbed(_ text: String) -> (String, Int) {
        var out = text
        var count = 0
        for (regex, template) in secretPatterns {
            let range = NSRange(out.startIndex..., in: out)
            let hits = regex.numberOfMatches(in: out, range: range)
            guard hits > 0 else { continue }
            count += hits
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return (out, count)
    }

    /// Values must carry a digit so placeholders like `your-api-key-here`
    /// stay readable.
    private static let secretPatterns: [(NSRegularExpression, String)] = [
        (
            // swiftlint:disable:next force_try
            try! NSRegularExpression(
                pattern: #"\b([A-Za-z][A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)[A-Za-z0-9_]*)(\s*[=:]\s*["']?)(?=[^\s"'`<>$]*\d)[^\s"'`<>$]{12,}"#,
                options: [.caseInsensitive]),
            "$1$2<$1>"
        ),
        (
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: #"\b(Bearer\s+)(?=[A-Za-z0-9._~+/-]*\d)[A-Za-z0-9._~+/-]{16,}=*"#),
            "$1<token>"
        ),
        (
            // swiftlint:disable:next force_try
            try! NSRegularExpression(
                pattern: #"\b(?:sk-|sk_live_|sk_test_|ghp_|gho_|ghs_|github_pat_|xoxb-|xoxp-|AKIA)[A-Za-z0-9_-]{12,}"#),
            "<key>"
        ),
    ]

    /// Checks every instructions row's model against what is installed or
    /// connected. A model that isn't available is dropped with a warning,
    /// so the agent uses the default.
    static func groundModels(_ items: inout [ChatImportItem], catalog: ConfigModelReference.Catalog) {
        for index in items.indices {
            guard case .instructions(var spec) = items[index].payload, let raw = spec.model else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "inherit" {
                spec.model = nil
            } else if case .resolved(let id) = ConfigModelReference.resolve(trimmed, catalog: catalog), !id.isEmpty {
                spec.model = id
            } else {
                spec.model = nil
                items[index].warnings.append(L("Model \(trimmed) isn't available here; the agent uses the default model."))
            }
            items[index].payload = .instructions(spec)
        }
    }

    /// When the reader fails, the readable page itself can still be saved
    /// as a skill.
    static func pageAsSkill(_ bundle: ChatImportBundle) -> ChatImportItem? {
        guard let document = bundle.documents.first(where: { $0.origin.hasPrefix("https://") }) else { return nil }
        let text = String(document.text.prefix(maxInstructionChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 80 else { return nil }
        let name = ChatImportFastPaths.cleanName(title(of: text) ?? URL(string: document.origin)?.host ?? "Imported page")
        let spec = ChatImportInstructionsSpec(name: name, description: "", instructions: text)
        var ids = ChatImportItemIds()
        var item = ChatImportItem(
            id: ids.make("skill", name), kind: .skill, name: name, detail: document.origin, origin: document.label,
            payload: .instructions(spec), contentHash: ChatImportHash.of(text))
        item.warnings.append(L("Osaurus couldn't tell what this page sets up, so it can save the page as a skill."))
        return item
    }

    // MARK: - Bodies

    struct Body {
        var text: String
        var origin: String
        var name: String?
        var description: String?
    }

    /// The instructions for a reference: the whole document, or the
    /// section under a heading when one is named and found. Frontmatter
    /// supplies the name and description when present.
    static func body(
        doc: String, section: String?, bundle: ChatImportBundle, consumed: Set<String> = []
    ) -> Body? {
        guard let document = bundle.document(doc), !consumed.contains(document.id) else { return nil }
        var text = document.text
        var name: String?
        var description: String?
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") {
            let (frontmatter, rest) = ClaudeMarkdownParser.extract(text)
            name = frontmatter["name"].flatMap { $0.isEmpty ? nil : $0 }
            description = frontmatter["description"].flatMap { $0.isEmpty ? nil : $0 }
            text = rest
        }
        if let section, let slice = self.section(section, in: text) {
            text = slice
            name = nil
        }
        text = String(text.prefix(maxInstructionChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Body(text: text, origin: document.label, name: name, description: description)
    }

    /// The text under the first markdown heading containing `title`, up to
    /// the next heading at the same or a higher level.
    static func section(_ title: String, in text: String) -> String? {
        let wanted = title.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard !wanted.isEmpty else { return nil }
        let lines = text.components(separatedBy: "\n")
        var start: Int?
        var level = 0
        var inFence = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            guard !inFence, let (headingLevel, heading) = headingInfo(line) else { continue }
            if let start {
                if headingLevel <= level {
                    return lines[start ..< index].joined(separator: "\n")
                }
            } else if heading.lowercased().contains(wanted) {
                start = index
                level = headingLevel
            }
        }
        return start.map { lines[$0...].joined(separator: "\n") }
    }

    private static func headingInfo(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func title(of text: String) -> String? {
        for line in text.components(separatedBy: "\n").prefix(40) {
            if let (_, heading) = headingInfo(line), !heading.isEmpty { return heading }
        }
        return nil
    }

    // MARK: - MCP servers

    /// The server only when its address or command, every argument, and
    /// every env/header name appear verbatim in the sources. Unwritten
    /// env/header names are dropped; anything else drops the server.
    static func groundedServer(_ server: ChatImportManifest.MCPServer, grounding: Grounding) -> ChatImportMCPBuilder.Input? {
        var input = ChatImportMCPBuilder.Input(name: server.name)
        if let url = server.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            guard grounding.containsURL(url), isAllowedServerURL(url) else { return nil }
            input.url = url
            input.headerNames = server.headers.filter { grounding.contains($0) }
            input.auth = server.auth
        } else if let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            var command = command
            var args = server.args
            // `npx -y pkg` reported as one command string.
            if args.isEmpty, command.contains(" ") {
                let parts = command.split(separator: " ").map(String.init)
                command = parts[0]
                args = Array(parts.dropFirst())
            }
            guard grounding.contains(command), args.allSatisfy({ grounding.contains($0) }) else { return nil }
            input.command = command
            input.args = args
            input.envNames = server.env.filter { grounding.contains($0) && isEnvName($0) }
        } else {
            return nil
        }
        return input
    }

    static func isAllowedServerURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    private static func isEnvName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    private static func sameServer(_ item: ChatImportItem, _ input: ChatImportMCPBuilder.Input) -> Bool {
        guard case .mcpServer(let spec) = item.payload else { return false }
        if spec.entry.name.caseInsensitiveCompare(input.name) == .orderedSame { return true }
        if let url = input.url, let existing = spec.entry.url { return trimSlash(url) == trimSlash(existing) }
        if let command = input.command, spec.entry.command == command { return (spec.entry.args ?? []) == input.args }
        return false
    }

    private static func originFor(_ input: ChatImportMCPBuilder.Input, _ bundle: ChatImportBundle) -> String {
        let needle = input.url ?? ([input.command ?? ""] + input.args).joined(separator: " ")
        let token = input.url ?? input.args.last ?? input.command ?? ""
        let match = bundle.documents.first { $0.text.contains(needle) } ?? bundle.documents.first { $0.text.contains(token) }
        return match?.label ?? L("your message")
    }

    // MARK: - Helpers

    private static func hasInstructions(named name: String, in items: [ChatImportItem]) -> Bool {
        items.contains { item in
            guard case .instructions = item.payload else { return false }
            return item.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.prefix(limit))
    }

    private static func trimSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// Verbatim matching against everything Osaurus downloaded plus the
    /// user's message.
    struct Grounding: Sendable {
        let text: String

        init(_ text: String) { self.text = text }

        func contains(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return text.contains(trimmed)
        }

        /// URLs also match without a trailing slash, since pages write
        /// both forms.
        func containsURL(_ value: String) -> Bool {
            contains(value) || (value.hasSuffix("/") && contains(String(value.dropLast())))
        }
    }
}

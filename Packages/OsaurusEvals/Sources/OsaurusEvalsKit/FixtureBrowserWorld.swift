//
//  FixtureBrowserWorld.swift
//  OsaurusEvalsKit
//
//  A deterministic, in-memory "web" for the `browser_use` eval lane — the
//  browser counterpart of `ScriptedCUDriver`. The child model drives the REAL
//  `BrowserUseKind` host, but every `browser_*` call lands here instead of
//  WebKit: pages are fixture data, snapshots use the production
//  `BrowserSnapshotFormatter` (so the model sees the exact ref grammar it sees
//  in production), and the world records what happened (typed values, clicked
//  ids, verb trace) for the case's substantive read-back checks.
//
//  Determinism contract: same pages + same tool calls ⇒ same envelopes. A
//  failing case therefore attributes to the model's planning / tool use, not
//  network, rendering, or timing flake.
//

import Foundation
import OsaurusCore

/// In-memory browser world serving `EvalCase.BrowserFixturePage`s.
actor FixtureBrowserWorld {
    private let pages: [EvalCase.BrowserFixturePage]

    /// Current page (nil until the first successful navigate).
    private var currentURL: String?
    private var history: [String] = []
    /// Element values by element id (seeded from fixtures, mutated by type/select).
    private var values: [String: String] = [:]
    /// Element ids clicked at least once.
    private var clicked: Set<String> = []
    /// Executed verb trace (`navigate`, `click`, `type`, …) in order.
    private var verbs: [String] = []
    /// Hosts the user "signed in to" via browser_open_login.
    private var loggedInHosts: Set<String> = []
    /// Snapshot ref → element id for the CURRENT page. Refs regenerate per
    /// page, so a ref from a previous page is stale — same contract as the
    /// live session.
    private var refs: [String: String] = [:]
    private var refCounter = 0

    init(pages: [EvalCase.BrowserFixturePage], startURL: String? = nil) {
        self.pages = pages
        for page in pages {
            for element in page.elements ?? [] where element.value != nil {
                values[element.id] = element.value
            }
        }
        if let startURL, Self.match(url: startURL, in: pages) != nil {
            currentURL = startURL
        }
    }

    // MARK: - Read-back for scoring

    func finalValues() -> [String: String] { values }
    func wasClicked(_ id: String) -> Bool { clicked.contains(id) }
    func verbTrace() -> [String] { verbs }

    // MARK: - Tool dispatch

    func execute(name: String, argumentsJSON: String) -> String {
        let args = Self.parseArgs(argumentsJSON)
        switch name {
        case "browser_navigate": return navigate(args)
        case "browser_navigate_back": return navigateBack(args)
        case "browser_snapshot": return snapshotEnvelope(tool: "browser_snapshot", prefix: nil, args: args)
        case "browser_read_page": return readPage(args)
        case "browser_click": return click(args)
        case "browser_type": return type(args)
        case "browser_select": return select(args)
        case "browser_hover": return recordOnly("hover", tool: "browser_hover", args: args)
        case "browser_scroll": return recordOnly("scroll", tool: "browser_scroll", args: args)
        case "browser_press_key": return pressKey(args)
        case "browser_wait_for":
            verbs.append("wait_for")
            return ToolEnvelope.success(tool: "browser_wait_for", text: "Wait condition met")
        case "browser_do": return batchDo(args)
        case "browser_open_login": return openLogin(args)
        case "browser_handle_dialog":
            return ToolEnvelope.success(
                tool: "browser_handle_dialog", text: "Next dialog will be accepted.")
        case "browser_console_messages":
            return ToolEnvelope.success(
                tool: "browser_console_messages", result: ["count": 0, "messages": [] as [String]])
        case "browser_network_requests":
            return ToolEnvelope.success(
                tool: "browser_network_requests", result: ["count": 0, "requests": [] as [String]])
        case "browser_cookies":
            return ToolEnvelope.success(
                tool: "browser_cookies",
                result: ["count": 0, "cookies": [] as [String]])
        case "browser_screenshot":
            return ToolEnvelope.success(
                tool: "browser_screenshot", result: ["path": "/dev/null", "size": 0])
        case "browser_execute_script", "browser_reset_session":
            return ToolEnvelope.failure(
                kind: .rejected,
                message: "\(name) is not available in the fixture world.",
                tool: name, retryable: false)
        default:
            return ToolEnvelope.failure(
                kind: .toolNotFound, message: "Unknown browser tool '\(name)'.", tool: name)
        }
    }

    // MARK: - Tools

    private func navigate(_ args: [String: Any]) -> String {
        guard let url = args["url"] as? String, !url.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`url` is required.", field: "url",
                tool: "browser_navigate")
        }
        verbs.append("navigate")
        guard let page = Self.match(url: url, in: pages) else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not load \(url): no such page.",
                tool: "browser_navigate")
        }
        let host = URL(string: page.url)?.host ?? page.url
        if page.loginRequired == true, !loggedInHosts.contains(host) {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Navigation landed on a login page (\(host)).",
                tool: "browser_navigate",
                retryable: true,
                metadata: [
                    "code": "LOGIN_REQUIRED",
                    "domain": host,
                    "url": page.url,
                    "hint":
                        "Call browser_open_login with this URL so the user can sign in, then retry "
                        + "the original navigation.",
                ]
            )
        }
        setCurrentPage(page.url)
        return snapshotEnvelope(
            tool: "browser_navigate",
            prefix: "Action: navigate to \(url) succeeded",
            args: args)
    }

    private func navigateBack(_ args: [String: Any]) -> String {
        verbs.append("back")
        guard history.count >= 2 else {
            return ToolEnvelope.failure(
                kind: .executionError, message: "No back history in this session.",
                tool: "browser_navigate_back")
        }
        history.removeLast()
        currentURL = history.last
        regenerateRefs()
        return snapshotEnvelope(
            tool: "browser_navigate_back",
            prefix: "Action: navigate back succeeded",
            args: args)
    }

    private func readPage(_ args: [String: Any]) -> String {
        verbs.append("read_page")
        guard let page = currentPage() else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "No page loaded. Call browser_navigate first.",
                tool: "browser_read_page")
        }
        let text = page.bodyText ?? ""
        let offset = max(0, (args["offset"] as? Int) ?? 0)
        let maxChars = min(40_000, max(500, (args["max_chars"] as? Int) ?? 20_000))
        let slice: String
        if offset < text.count {
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: min(maxChars, text.count - offset))
            slice = String(text[start..<end])
        } else {
            slice = ""
        }
        return ToolEnvelope.success(
            tool: "browser_read_page",
            result: [
                "url": page.url,
                "title": page.title ?? "",
                "text": slice,
                "total_chars": text.count,
                "offset": offset,
                "has_more": offset + slice.count < text.count,
            ])
    }

    private func click(_ args: [String: Any]) -> String {
        verbs.append("click")
        guard let element = resolveElement(args) else {
            return staleOrMissing(tool: "browser_click", args: args)
        }
        clicked.insert(element.id)
        if let destination = element.goto, let page = Self.match(url: destination, in: pages) {
            setCurrentPage(page.url)
        }
        return snapshotEnvelope(
            tool: "browser_click", prefix: "Action: click succeeded", args: args)
    }

    private func type(_ args: [String: Any]) -> String {
        verbs.append("type")
        guard let text = args["text"] as? String else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`text` is required.", field: "text",
                tool: "browser_type")
        }
        guard let element = resolveElement(args) else {
            return staleOrMissing(tool: "browser_type", args: args)
        }
        let clear = (args["clear"] as? Bool) ?? true
        values[element.id] = clear ? text : (values[element.id] ?? "") + text
        if (args["submit"] as? Bool) == true,
            let destination = element.goto,
            let page = Self.match(url: destination, in: pages)
        {
            setCurrentPage(page.url)
        }
        return snapshotEnvelope(
            tool: "browser_type", prefix: "Action: type succeeded", args: args)
    }

    private func select(_ args: [String: Any]) -> String {
        verbs.append("select")
        guard let selected = args["values"] as? [String], !selected.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`values` is required.", field: "values",
                tool: "browser_select")
        }
        guard let element = resolveElement(args) else {
            return staleOrMissing(tool: "browser_select", args: args)
        }
        values[element.id] = selected.joined(separator: ",")
        return snapshotEnvelope(
            tool: "browser_select", prefix: "Action: select succeeded", args: args)
    }

    private func pressKey(_ args: [String: Any]) -> String {
        verbs.append("press_key")
        let key = (args["key"] as? String) ?? ""
        return ToolEnvelope.success(
            tool: "browser_press_key", text: "Action: press \(key) succeeded")
    }

    private func recordOnly(_ verb: String, tool: String, args: [String: Any]) -> String {
        verbs.append(verb)
        return snapshotEnvelope(tool: tool, prefix: "Action: \(verb) succeeded", args: args)
    }

    private func batchDo(_ args: [String: Any]) -> String {
        guard let actions = args["actions"] as? [[String: Any]] else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`actions` is required.", field: "actions",
                tool: "browser_do")
        }
        for (index, item) in actions.enumerated() {
            guard let action = item["action"] as? String else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Action \(index) is missing the required `action` field.",
                    field: "actions", tool: "browser_do")
            }
            let result: String
            switch action {
            case "click": result = click(item)
            case "type": result = type(item)
            case "select": result = select(item)
            case "hover": result = recordOnly("hover", tool: "browser_do", args: item)
            case "scroll": result = recordOnly("scroll", tool: "browser_do", args: item)
            case "press_key": result = pressKey(item)
            case "wait_for":
                verbs.append("wait_for")
                result = ToolEnvelope.success(tool: "browser_do", text: "Wait condition met")
            default:
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Action \(index) (\(action)) failed: unknown action type",
                    tool: "browser_do")
            }
            if !ToolEnvelope.isSuccess(result) { return result }
        }
        return snapshotEnvelope(
            tool: "browser_do",
            prefix: "Action: browser_do completed (\(actions.count) actions)",
            args: args)
    }

    private func openLogin(_ args: [String: Any]) -> String {
        verbs.append("open_login")
        let raw = (args["url"] as? String) ?? currentURL ?? ""
        let host = URL(string: raw.contains("://") ? raw : "https://" + raw)?.host ?? raw
        loggedInHosts.insert(host)
        return ToolEnvelope.success(
            tool: "browser_open_login",
            result: [
                "closed_at": ISO8601DateFormatter().string(from: Date()),
                "timed_out": false,
                "final_url": raw,
            ])
    }

    // MARK: - Page / element resolution

    private func currentPage() -> EvalCase.BrowserFixturePage? {
        guard let currentURL else { return nil }
        return Self.match(url: currentURL, in: pages)
    }

    private static func match(
        url: String, in pages: [EvalCase.BrowserFixturePage]
    ) -> EvalCase.BrowserFixturePage? {
        let normalized = url.hasSuffix("/") ? String(url.dropLast()) : url
        // Exact match wins; otherwise the LONGEST matching prefix. First-match
        // prefix scanning would send "/wizard/step2" to "/wizard" whenever the
        // parent page is listed first.
        var best: (page: EvalCase.BrowserFixturePage, length: Int)?
        for candidate in pages {
            let page = candidate.url.hasSuffix("/") ? String(candidate.url.dropLast()) : candidate.url
            if page == normalized { return candidate }
            if normalized.hasPrefix(page), (best?.length ?? -1) < page.count {
                best = (candidate, page.count)
            }
        }
        return best?.page
    }

    private func setCurrentPage(_ url: String) {
        currentURL = url
        history.append(url)
        regenerateRefs()
    }

    /// Regenerate the ref map for the current page — refs from a previous
    /// page become stale, same as the live session's snapshot generation.
    private func regenerateRefs() {
        refs.removeAll()
        guard let page = currentPage() else { return }
        for element in page.elements ?? [] {
            refCounter += 1
            refs["E\(refCounter)"] = element.id
        }
    }

    private func resolveElement(_ args: [String: Any]) -> EvalCase.BrowserFixtureElement? {
        guard let page = currentPage() else { return nil }
        let elements = page.elements ?? []
        if let ref = args["ref"] as? String {
            guard let id = refs[ref] else { return nil }
            return elements.first { $0.id == id }
        }
        if let selector = args["selector"] as? String {
            // Fixture selectors are `#id` or the bare element id.
            let id = selector.hasPrefix("#") ? String(selector.dropFirst()) : selector
            return elements.first { $0.id == id }
        }
        return nil
    }

    private func staleOrMissing(tool: String, args: [String: Any]) -> String {
        let target = (args["ref"] as? String) ?? (args["selector"] as? String) ?? "?"
        return ToolEnvelope.failure(
            kind: .executionError,
            message:
                "Element '\(target)' not found. Snapshot is stale. Call browser_snapshot again.",
            tool: tool)
    }

    // MARK: - Snapshots

    private func snapshotEnvelope(tool: String, prefix: String?, args: [String: Any]) -> String {
        guard let page = currentPage() else {
            if let prefix {
                return ToolEnvelope.success(tool: tool, text: prefix)
            }
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "No page loaded. Call browser_navigate first to load a page.",
                tool: tool)
        }
        let detail = BrowserDetailLevel.parse(args["detail"] as? String, default: .standard)
        let refsForPage = refs.sorted { lhs, rhs in
            (Int(lhs.key.dropFirst()) ?? 0) < (Int(rhs.key.dropFirst()) ?? 0)
        }
        var elements: [[String: Any]] = []
        for (ref, id) in refsForPage {
            guard let element = (page.elements ?? []).first(where: { $0.id == id }) else { continue }
            var info: [String: Any] = ["ref": ref, "type": element.type]
            info["text"] = element.text ?? ""
            if let placeholder = element.placeholder { info["placeholder"] = placeholder }
            if let value = values[element.id] { info["value"] = value }
            if let destination = element.goto, element.type == "link" {
                info["href"] = destination
            }
            elements.append(info)
        }
        let data: [String: Any] = [
            "title": page.title ?? "",
            "url": page.url,
            "hasMore": false,
            "elements": elements,
            "bodyText": String((page.bodyText ?? "").prefix(500)),
        ]
        let snapshot = BrowserSnapshotFormatter.format(data, detail: detail)
        let text = [prefix, snapshot.isEmpty ? nil : snapshot]
            .compactMap { $0 }
            .joined(separator: "\n")
        return ToolEnvelope.success(tool: tool, text: text.isEmpty ? "OK" : text)
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return obj
    }
}

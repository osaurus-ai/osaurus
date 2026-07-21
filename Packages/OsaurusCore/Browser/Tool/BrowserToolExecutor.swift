//
//  BrowserToolExecutor.swift
//  OsaurusCore — Native Browser Use
//
//  Executes the PRIVATE `browser_*` primitives inside a `browser_use` run.
//  These tools are never registered in `ToolRegistry` and never appear in the
//  parent schema — the nested runner's toolset dispatches straight here.
//
//  Every action flows through the shared autonomy gate before it touches the
//  page: reads run freely, ordinary navigation follows the Computer Use
//  policy, typing/state mutation is `edit`, and submit / auth / session-reset
//  / arbitrary-script actions are conservatively `consequential`. Confirms
//  reuse `ComputerUsePromptQueue`, so the approval card the user already
//  knows serves both features.
//

import Foundation

/// Policy-backed gate for browser actions. Same `AutonomyPolicy` +
/// per-agent ceiling as Computer Use, minus the macOS app allowlist (that
/// list names desktop apps, not web hosts). Pure — unit-testable.
public struct BrowserGate: Sendable {
    public let policy: AutonomyPolicy
    public let ceiling: AutonomyCeiling?

    public init(policy: AutonomyPolicy, ceiling: AutonomyCeiling? = nil) {
        self.policy = policy
        self.ceiling = ceiling
    }

    /// Decide one browser action. `host` renders on the confirm card (and
    /// keys "approve remaining"); it is NOT allowlist-checked.
    public func evaluate(
        effect: EffectClass,
        actionLabel: String,
        host: String?,
        targetLabel: String?,
        typedText: String? = nil
    ) -> GateDecision {
        switch policy.disposition(for: effect, app: nil, ceiling: ceiling) {
        case .allow:
            return .run
        case .confirm:
            return .confirm(
                ActionPreview(
                    appName: host,
                    actionLabel: actionLabel,
                    targetLabel: targetLabel,
                    effect: effect,
                    note: nil,
                    typedText: typedText
                )
            )
        case .deny:
            return .reject(
                reason:
                    "The current autonomy policy blocks \(effect.displayLabel.lowercased()) actions in the browser. "
                    + "Raise the policy in Settings → Computer Use to allow it, or take a different action."
            )
        }
    }
}

/// One `browser_use` run's private tool dispatcher. MainActor because every
/// call ends in WebKit.
@MainActor
final class BrowserToolExecutor {
    private let agentId: UUID
    private let toolCallId: String
    private let gate: BrowserGate
    /// Confirm seam — production wires `ComputerUsePromptQueue`; tests inject.
    private let confirm: @MainActor (ActionPreview) async -> Bool

    init(
        agentId: UUID,
        toolCallId: String,
        gate: BrowserGate,
        confirm: (@MainActor (ActionPreview) async -> Bool)? = nil
    ) {
        self.agentId = agentId
        self.toolCallId = toolCallId
        self.gate = gate
        let capturedToolCallId = toolCallId
        self.confirm =
            confirm
            ?? { preview in
                await ComputerUsePromptQueue.shared.requestConfirmation(
                    preview, toolCallId: capturedToolCallId)
            }
    }

    private var session: BrowserSession {
        BrowserSessionManager.shared.session(for: agentId)
    }

    private var currentHost: String? {
        session.currentURL.flatMap { URL(string: $0)?.host }
    }

    // MARK: - Entry point

    func execute(name: String, argumentsJSON: String) async -> String {
        let args = Self.parseArgs(argumentsJSON)
        switch name {
        case "browser_navigate": return await navigate(args)
        case "browser_navigate_back": return await navigateBack(args)
        case "browser_read_page": return await readPage(args)
        case "browser_snapshot": return await snapshot(args)
        case "browser_click": return await click(args)
        case "browser_type": return await type(args)
        case "browser_select": return await select(args)
        case "browser_hover": return await hover(args)
        case "browser_scroll": return await scroll(args)
        case "browser_press_key": return await pressKey(args)
        case "browser_wait_for": return await waitFor(args)
        case "browser_do": return await batchDo(args)
        case "browser_screenshot": return await screenshot(args)
        case "browser_execute_script": return await executeScript(args)
        case "browser_console_messages": return await consoleMessages(args)
        case "browser_network_requests": return await networkRequests(args)
        case "browser_handle_dialog": return await handleDialog(args)
        case "browser_cookies": return await cookies(args)
        case "browser_open_login": return await openLogin(args)
        case "browser_reset_session": return await resetSession(args)
        default:
            return ToolEnvelope.failure(
                kind: .toolNotFound,
                message: "Unknown browser tool '\(name)'.",
                tool: name
            )
        }
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return obj
    }

    // MARK: - Gating

    /// Gate one action; nil means "go ahead", otherwise the failure envelope
    /// to return verbatim.
    private func gateAction(
        _ action: String,
        tool: String,
        actionLabel: String,
        host: String? = nil,
        targetLabel: String? = nil,
        typedText: String? = nil,
        submit: Bool = false
    ) async -> String? {
        let effect = BrowserEffectClassifier.classify(
            action: action, target: targetLabel, submit: submit)
        switch gate.evaluate(
            effect: effect,
            actionLabel: actionLabel,
            host: host ?? currentHost,
            targetLabel: targetLabel,
            typedText: typedText
        ) {
        case .run:
            return nil
        case .confirm(let preview):
            if await confirm(preview) { return nil }
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "The user declined: \(preview.summary). Ask how to proceed or try a different approach.",
                tool: tool,
                retryable: false
            )
        case .reject(let reason):
            return ToolEnvelope.failure(
                kind: .rejected, message: reason, tool: tool, retryable: false)
        }
    }

    // MARK: - Shared result shaping

    private func detail(_ args: [String: Any], default def: BrowserDetailLevel = .compact)
        -> BrowserDetailLevel
    {
        BrowserDetailLevel.parse(args["detail"] as? String, default: def)
    }

    /// The plugin's auto-snapshot contract: action confirmation line + a fresh
    /// snapshot at the requested verbosity, wrapped in a success envelope.
    private func actionResult(
        tool: String,
        prefix: String,
        detail: BrowserDetailLevel
    ) async -> String {
        recordCurrentPage()
        if detail == .none {
            return ToolEnvelope.success(tool: tool, text: prefix)
        }
        let snapshot = await session.takeSnapshot(detail: detail)
        return ToolEnvelope.success(tool: tool, text: prefix + "\n" + snapshot)
    }

    private func recordCurrentPage() {
        BrowserSessionManager.shared.recordNavigation(
            agentId: agentId,
            url: session.currentURL,
            title: session.currentTitle
        )
    }

    // MARK: - Tools

    private func navigate(_ args: [String: Any]) async -> String {
        guard let url = args["url"] as? String, !url.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`url` is required.", field: "url",
                expected: "URL to navigate to", tool: "browser_navigate")
        }
        // Scheme policy at the tool boundary — a clear invalidArgs beats a
        // policy trap deep in WebKit. decidePolicyFor still backstops
        // redirects and JS-driven loads.
        if let refusal = BrowserSession.navigationRefusalReason(for: URL(string: url)) {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: refusal, field: "url",
                expected: "an http:// or https:// URL", tool: "browser_navigate",
                retryable: false)
        }
        let targetHost = URL(string: url)?.host
        if let denial = await gateAction(
            "navigate", tool: "browser_navigate", actionLabel: "Navigate",
            host: targetHost, targetLabel: url)
        {
            return denial
        }
        let waitUntil = BrowserSession.WaitUntil(rawValue: args["wait_until"] as? String ?? "load") ?? .load
        let timeout = (args["timeout"] as? Double) ?? 30
        let result = await session.navigate(to: url, timeout: timeout, waitUntil: waitUntil)
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Navigation failed.",
                tool: "browser_navigate")
        }
        recordCurrentPage()
        // Landed on a login page → structured LOGIN_REQUIRED so the agent
        // calls browser_open_login instead of asking for credentials in chat.
        let finalURL = session.currentURL ?? url
        if let host = BrowserLoginDetector.loginHost(
            finalURL: finalURL, title: session.currentTitle ?? "")
        {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "Navigation landed on a login page (\(host)).",
                tool: "browser_navigate",
                retryable: true,
                metadata: [
                    "code": "LOGIN_REQUIRED",
                    "domain": host,
                    "url": finalURL,
                    "hint":
                        "Call browser_open_login with this URL so the user can sign in, then retry "
                        + "the original navigation. Do not ask the user for credentials in chat — the "
                        + "helper window handles authentication, including 2FA.",
                ]
            )
        }
        return await actionResult(
            tool: "browser_navigate",
            prefix: "Action: navigate to \(url) succeeded",
            detail: detail(args)
        )
    }

    private func navigateBack(_ args: [String: Any]) async -> String {
        if let denial = await gateAction(
            "back", tool: "browser_navigate_back", actionLabel: "Go back",
            targetLabel: "browser history")
        {
            return denial
        }
        let result = await session.goBack()
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Back navigation failed.",
                tool: "browser_navigate_back")
        }
        return await actionResult(
            tool: "browser_navigate_back",
            prefix: "Action: navigate back succeeded",
            detail: detail(args)
        )
    }

    private func readPage(_ args: [String: Any]) async -> String {
        let offset = max(0, (args["offset"] as? Int) ?? 0)
        let maxChars = min(40_000, max(500, (args["max_chars"] as? Int) ?? 20_000))
        let result = await session.readPageText()
        if let error = result.error {
            return ToolEnvelope.failure(
                kind: .executionError, message: error, tool: "browser_read_page")
        }
        let text = result.text ?? ""
        let total = text.count
        guard offset < total || total == 0 else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`offset` \(offset) is beyond the page text (\(total) characters).",
                field: "offset", expected: "0..<\(total)", tool: "browser_read_page",
                retryable: false)
        }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(maxChars, total - offset))
        let slice = String(text[start..<end])
        let hasMore = offset + slice.count < total
        var payload: [String: Any] = [
            "url": session.currentURL ?? "",
            "title": session.currentTitle ?? "",
            "text": slice,
            "total_chars": total,
            "offset": offset,
            "has_more": hasMore,
        ]
        if hasMore {
            payload["next_offset"] = offset + slice.count
        }
        return ToolEnvelope.success(tool: "browser_read_page", result: payload)
    }

    private func snapshot(_ args: [String: Any]) async -> String {
        var options = BrowserSession.SnapshotOptions()
        if let filter = args["filter"] as? String { options.filter = filter }
        if let maxElements = args["max_elements"] as? Int { options.maxElements = maxElements }
        if let visibleOnly = args["visible_only"] as? Bool { options.visibleOnly = visibleOnly }
        let text = await session.takeSnapshot(options: options, detail: detail(args, default: .standard))
        if text.hasPrefix("Error:") {
            return ToolEnvelope.failure(
                kind: .executionError, message: text, tool: "browser_snapshot")
        }
        return ToolEnvelope.success(tool: "browser_snapshot", text: text)
    }

    private func click(_ args: [String: Any]) async -> String {
        let ref = args["ref"] as? String
        let selector = args["selector"] as? String
        let label = await session.elementLabel(ref: ref, selector: selector)
        if let denial = await gateAction(
            "click", tool: "browser_click", actionLabel: "Click",
            targetLabel: label ?? ref ?? selector)
        {
            return denial
        }
        let result = await session.clickElement(ref: ref, selector: selector)
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Click failed.",
                tool: "browser_click")
        }
        // Brief settle for click-triggered DOM changes (plugin parity).
        try? await Task.sleep(nanoseconds: 200_000_000)
        return await actionResult(
            tool: "browser_click", prefix: "Action: click succeeded", detail: detail(args))
    }

    private func type(_ args: [String: Any]) async -> String {
        guard let text = args["text"] as? String else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`text` is required.", field: "text",
                expected: "text to type", tool: "browser_type")
        }
        let ref = args["ref"] as? String
        let selector = args["selector"] as? String
        let submit = (args["submit"] as? Bool) ?? false
        let label = await session.elementLabel(ref: ref, selector: selector)
        if let denial = await gateAction(
            "type", tool: "browser_type", actionLabel: submit ? "Type + submit" : "Type",
            targetLabel: label ?? ref ?? selector, typedText: text, submit: submit)
        {
            return denial
        }
        let result = await session.typeText(
            ref: ref, selector: selector, text: text,
            clear: (args["clear"] as? Bool) ?? true, submit: submit)
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Type failed.",
                tool: "browser_type")
        }
        return await actionResult(
            tool: "browser_type", prefix: "Action: type succeeded", detail: detail(args))
    }

    private func select(_ args: [String: Any]) async -> String {
        guard let values = args["values"] as? [String], !values.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`values` is required.", field: "values",
                expected: "array of option values or labels", tool: "browser_select")
        }
        let ref = args["ref"] as? String
        let selector = args["selector"] as? String
        if let denial = await gateAction(
            "select", tool: "browser_select", actionLabel: "Select",
            targetLabel: values.joined(separator: ", "))
        {
            return denial
        }
        let result = await session.selectOption(ref: ref, selector: selector, values: values)
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Select failed.",
                tool: "browser_select")
        }
        return await actionResult(
            tool: "browser_select", prefix: "Action: select succeeded", detail: detail(args))
    }

    private func hover(_ args: [String: Any]) async -> String {
        let ref = args["ref"] as? String
        let selector = args["selector"] as? String
        if let denial = await gateAction(
            "hover", tool: "browser_hover", actionLabel: "Hover", targetLabel: ref ?? selector)
        {
            return denial
        }
        let result = await session.hoverElement(ref: ref, selector: selector)
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Hover failed.",
                tool: "browser_hover")
        }
        return await actionResult(
            tool: "browser_hover", prefix: "Action: hover succeeded", detail: detail(args))
    }

    private func scroll(_ args: [String: Any]) async -> String {
        if let denial = await gateAction(
            "scroll", tool: "browser_scroll", actionLabel: "Scroll",
            targetLabel: args["direction"] as? String)
        {
            return denial
        }
        let result = await session.scroll(
            direction: args["direction"] as? String,
            ref: args["ref"] as? String,
            x: args["x"] as? Int,
            y: args["y"] as? Int
        )
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Scroll failed.",
                tool: "browser_scroll")
        }
        return await actionResult(
            tool: "browser_scroll", prefix: "Action: scroll succeeded", detail: detail(args))
    }

    private func pressKey(_ args: [String: Any]) async -> String {
        guard let key = args["key"] as? String, !key.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`key` is required.", field: "key",
                expected: "key name (Enter, Escape, Tab, …)", tool: "browser_press_key")
        }
        let isSubmitKey = key.lowercased() == "enter"
        if let denial = await gateAction(
            "press_key", tool: "browser_press_key", actionLabel: "Press key",
            targetLabel: key, submit: isSubmitKey)
        {
            return denial
        }
        let result = await session.pressKey(
            key: key, modifiers: (args["modifiers"] as? [String]) ?? [])
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .executionError, message: result.error ?? "Key press failed.",
                tool: "browser_press_key")
        }
        return ToolEnvelope.success(tool: "browser_press_key", text: "Action: press \(key) succeeded")
    }

    private func waitFor(_ args: [String: Any]) async -> String {
        let result = await session.waitFor(
            text: args["text"] as? String,
            textGone: args["text_gone"] as? String,
            time: args["time"] as? Double,
            timeout: (args["timeout"] as? Double) ?? 10
        )
        guard result.success else {
            return ToolEnvelope.failure(
                kind: .timeout, message: result.error ?? "Wait failed.", tool: "browser_wait_for")
        }
        return ToolEnvelope.success(tool: "browser_wait_for", text: "Wait condition met")
    }

    private func batchDo(_ args: [String: Any]) async -> String {
        guard let actions = args["actions"] as? [[String: Any]] else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`actions` is required.", field: "actions",
                expected: "array of action objects", tool: "browser_do")
        }
        let detail = detail(args)
        if actions.isEmpty {
            return await actionResult(
                tool: "browser_do", prefix: "Action: browser_do completed (0 actions)",
                detail: detail)
        }

        for (index, item) in actions.enumerated() {
            guard let action = item["action"] as? String else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Action \(index) is missing the required `action` field.",
                    field: "actions", tool: "browser_do")
            }
            let ref = item["ref"] as? String
            let selector = item["selector"] as? String
            let submit = (item["submit"] as? Bool) ?? false

            // Gate EVERY sub-action individually — batching must not smuggle a
            // consequential step past the policy.
            let gateLabel: String?
            switch action {
            case "click", "type":
                gateLabel = await session.elementLabel(ref: ref, selector: selector) ?? ref ?? selector
            case "press_key":
                gateLabel = item["key"] as? String
            default:
                gateLabel = ref ?? selector
            }
            let isSubmit =
                submit || (action == "press_key" && (item["key"] as? String)?.lowercased() == "enter")
            if let denial = await gateAction(
                action, tool: "browser_do",
                actionLabel: "\(action) (batch step \(index + 1)/\(actions.count))",
                targetLabel: gateLabel,
                typedText: action == "type" ? item["text"] as? String : nil,
                submit: isSubmit)
            {
                return denial
            }

            let result: (success: Bool, error: String?)
            switch action {
            case "click":
                result = await session.clickElement(ref: ref, selector: selector)
            case "type":
                guard let text = item["text"] as? String else {
                    return await batchFailure(index: index, action: action,
                        error: "missing required 'text' parameter", detail: detail)
                }
                result = await session.typeText(
                    ref: ref, selector: selector, text: text,
                    clear: (item["clear"] as? Bool) ?? true, submit: submit)
            case "select":
                guard let values = item["values"] as? [String] else {
                    return await batchFailure(index: index, action: action,
                        error: "missing required 'values' parameter", detail: detail)
                }
                result = await session.selectOption(ref: ref, selector: selector, values: values)
            case "hover":
                result = await session.hoverElement(ref: ref, selector: selector)
            case "scroll":
                result = await session.scroll(
                    direction: item["direction"] as? String, ref: ref,
                    x: item["x"] as? Int, y: item["y"] as? Int)
            case "press_key":
                guard let key = item["key"] as? String else {
                    return await batchFailure(index: index, action: action,
                        error: "missing required 'key' parameter", detail: detail)
                }
                result = await session.pressKey(
                    key: key, modifiers: (item["modifiers"] as? [String]) ?? [])
            case "wait_for":
                result = await session.waitFor(
                    text: item["text"] as? String,
                    textGone: item["text_gone"] as? String,
                    time: item["time"] as? Double,
                    timeout: (item["timeout"] as? Double) ?? 10)
            default:
                return await batchFailure(index: index, action: action,
                    error: "unknown action type", detail: detail)
            }
            if !result.success {
                return await batchFailure(index: index, action: action,
                    error: result.error ?? "Unknown error", detail: detail)
            }
        }

        switch args["wait_after"] as? String {
        case "domstable": await session.waitForDOMStable(timeout: 10)
        case "networkidle": await session.waitForNetworkIdle(timeout: 10)
        default: break
        }
        return await actionResult(
            tool: "browser_do",
            prefix: "Action: browser_do completed (\(actions.count) actions)",
            detail: detail
        )
    }

    /// Batched-action failure with a fresh snapshot so the agent can recover
    /// without an extra call (plugin parity).
    private func batchFailure(
        index: Int, action: String, error: String, detail: BrowserDetailLevel
    ) async -> String {
        let snapshot = await session.takeSnapshot(
            detail: detail == .none ? .compact : detail)
        return ToolEnvelope.failure(
            kind: .executionError,
            message: "Action \(index) (\(action)) failed: \(error)",
            tool: "browser_do",
            metadata: ["failed_index": index, "snapshot": snapshot]
        )
    }

    private func screenshot(_ args: [String: Any]) async -> String {
        // Path confinement: `path` is model-controlled. Writes stay inside
        // ~/Downloads, never overwrite, and traversal out is invalidArgs.
        guard let destination = BrowserScreenshotPath.resolve(custom: args["path"] as? String)
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Screenshot paths must stay inside ~/Downloads. Pass a bare file name (or omit `path` for an auto-generated one).",
                field: "path",
                expected: "a file name inside ~/Downloads",
                tool: "browser_screenshot",
                retryable: false)
        }
        guard let imageData = await session.takeScreenshot(fullPage: (args["full_page"] as? Bool) ?? false)
        else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to capture screenshot. Make sure a page is loaded with browser_navigate first.",
                tool: "browser_screenshot")
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try imageData.write(to: destination)
            return ToolEnvelope.success(
                tool: "browser_screenshot",
                result: ["path": destination.path, "size": imageData.count])
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to save screenshot: \(error.localizedDescription)",
                tool: "browser_screenshot")
        }
    }

    private func executeScript(_ args: [String: Any]) async -> String {
        guard let script = args["script"] as? String, !script.isEmpty else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`script` is required.", field: "script",
                expected: "JavaScript code to execute", tool: "browser_execute_script")
        }
        if let denial = await gateAction(
            "execute_script", tool: "browser_execute_script", actionLabel: "Run JavaScript",
            typedText: script)
        {
            return denial
        }
        let result = await session.executeScript(script)
        if let error = result.error {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "JavaScript execution failed: \(error)",
                tool: "browser_execute_script")
        }
        return ToolEnvelope.success(tool: "browser_execute_script", result: jsonSafe(result.result))
    }

    private func consoleMessages(_ args: [String: Any]) async -> String {
        let messages = await session.consoleMessages(
            level: args["level"] as? String,
            since: args["since"] as? Double,
            clear: (args["clear"] as? Bool) ?? false
        )
        return ToolEnvelope.success(
            tool: "browser_console_messages",
            result: ["count": messages.count, "messages": messages])
    }

    private func networkRequests(_ args: [String: Any]) async -> String {
        let requests = await session.networkRequests(
            failedOnly: (args["failed_only"] as? Bool) ?? false,
            methodFilter: args["method"] as? String,
            urlContains: args["url_contains"] as? String,
            clear: (args["clear"] as? Bool) ?? false
        )
        return ToolEnvelope.success(
            tool: "browser_network_requests",
            result: ["count": requests.count, "requests": requests])
    }

    private func handleDialog(_ args: [String: Any]) async -> String {
        let action = (args["action"] as? String) ?? "accept"
        switch action {
        case "status":
            return ToolEnvelope.success(
                tool: "browser_handle_dialog",
                result: ["last_dialog": session.lastDialog.map(jsonSafe) ?? NSNull()])
        case "accept", "dismiss":
            if let denial = await gateAction(
                "handle_dialog", tool: "browser_handle_dialog",
                actionLabel: "Set dialog policy", targetLabel: action)
            {
                return denial
            }
            session.setDialogPolicy(
                accept: action == "accept",
                promptText: args["prompt_text"] as? String
            )
            return ToolEnvelope.success(
                tool: "browser_handle_dialog",
                text: "Next dialog will be \(action == "accept" ? "accepted" : "dismissed").")
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`action` must be one of accept, dismiss, status.",
                field: "action", tool: "browser_handle_dialog")
        }
    }

    private func cookies(_ args: [String: Any]) async -> String {
        let action = (args["action"] as? String) ?? "get"
        let domain = args["domain"] as? String
        switch action {
        case "get":
            // Cookie VALUES are session tokens — they'd flow verbatim into the
            // child transcript (and to whatever provider serves the run).
            // Redacted by default; include_values requires a user confirm.
            let includeValues = (args["include_values"] as? Bool) ?? false
            if includeValues {
                if let denial = await gateAction(
                    "read_cookie_values", tool: "browser_cookies",
                    actionLabel: "Read cookie values",
                    targetLabel: domain ?? "all domains")
                {
                    return denial
                }
            }
            var cookies = await session.getCookies(domain: domain)
            if !includeValues {
                cookies = cookies.map { cookie in
                    var redacted = cookie
                    redacted["value"] = "<redacted>"
                    return redacted
                }
            }
            var payload: [String: Any] = ["count": cookies.count, "cookies": cookies]
            if !includeValues {
                payload["note"] =
                    "Cookie values are redacted by default. Pass include_values=true (requires user approval) if a value is genuinely needed."
            }
            return ToolEnvelope.success(tool: "browser_cookies", result: payload)
        case "set":
            guard let cookie = args["cookie"] as? [String: Any] else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`cookie` object is required for action='set'.",
                    field: "cookie", tool: "browser_cookies")
            }
            if let denial = await gateAction(
                "set_cookie", tool: "browser_cookies", actionLabel: "Set cookie",
                targetLabel: cookie["name"] as? String)
            {
                return denial
            }
            let result = await session.setCookie(cookie)
            guard result.ok else {
                return ToolEnvelope.failure(
                    kind: .executionError, message: result.error ?? "Failed to set cookie.",
                    tool: "browser_cookies")
            }
            return ToolEnvelope.success(tool: "browser_cookies", text: "Cookie set.")
        case "clear":
            if let denial = await gateAction(
                "clear_cookies", tool: "browser_cookies", actionLabel: "Clear cookies",
                targetLabel: domain ?? "all domains")
            {
                return denial
            }
            await session.clearCookies(domain: domain)
            return ToolEnvelope.success(
                tool: "browser_cookies",
                text: "Cookies cleared" + (domain.map { " for \($0)" } ?? "") + ".")
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`action` must be one of get, set, clear.",
                field: "action", tool: "browser_cookies")
        }
    }

    private func openLogin(_ args: [String: Any]) async -> String {
        let rawURL = args["url"] as? String
        let initialURL: URL?
        if let rawURL, !rawURL.isEmpty {
            initialURL = URL(string: rawURL.contains("://") ? rawURL : "https://" + rawURL)
        } else {
            initialURL = nil
        }
        if let denial = await gateAction(
            "open_login", tool: "browser_open_login", actionLabel: "Open sign-in window",
            host: initialURL?.host, targetLabel: initialURL?.absoluteString)
        {
            return denial
        }
        let timeoutSeconds = TimeInterval(max(1000, (args["timeout_ms"] as? Int) ?? 300_000)) / 1000.0
        let result = await BrowserSessionManager.shared.presentLoginWindow(
            agentId: agentId, initialURL: initialURL, timeoutSeconds: timeoutSeconds)
        var payload: [String: Any] = [
            "closed_at": ISO8601DateFormatter().string(from: result.closedAt),
            "timed_out": result.timedOut,
        ]
        if let url = result.finalURL { payload["final_url"] = url }
        return ToolEnvelope.success(tool: "browser_open_login", result: payload)
    }

    private func resetSession(_ args: [String: Any]) async -> String {
        if let denial = await gateAction(
            "reset_session", tool: "browser_reset_session", actionLabel: "Reset browser session",
            targetLabel: "wipe cookies, storage, and sign-ins for this agent")
        {
            return denial
        }
        await BrowserSessionManager.shared.resetSession(for: agentId)
        return ToolEnvelope.success(
            tool: "browser_reset_session",
            text: "Session cleared. The next browser_navigate starts a fresh logged-out profile.")
    }

    /// Coerce a JS evaluation result into a JSON-serialisable value.
    private func jsonSafe(_ value: Any?) -> Any {
        guard let value, !(value is NSNull) else { return NSNull() }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }
}

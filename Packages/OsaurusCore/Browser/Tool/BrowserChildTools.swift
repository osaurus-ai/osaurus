//
//  BrowserChildTools.swift
//  OsaurusCore — Native Browser Use
//
//  The PRIVATE tool schemas a `browser_use` child sees. Ported from the
//  plugin's manifest (same names, same argument contracts, so the operating
//  instructions transfer 1:1), but never registered in `ToolRegistry` — only
//  the nested runner's toolset carries them, keeping the parent schema at one
//  tool (`browser_use`) instead of the plugin's eighteen.
//

import Foundation

enum BrowserChildTools {
    static let detailProperty: JSONValue = .object([
        "type": .string("string"),
        "enum": .array([.string("none"), .string("compact"), .string("standard"), .string("full")]),
        "description": .string(
            "Snapshot verbosity: none (action result only), compact (single-line refs, default), "
                + "standard (multi-line with attributes), full (all attributes + page text)"),
    ])

    static var all: [Tool] {
        [
            tool(
                "browser_navigate",
                "Navigate to a URL and return a page snapshot with element refs. Use "
                    + "wait_until='networkidle' for SPAs. Use detail to control snapshot verbosity.",
                properties: [
                    "url": string("URL to navigate to (http/https only)"),
                    "wait_until": enumString(
                        ["load", "networkidle", "domstable"], "When to consider navigation done"),
                    "timeout": number("Timeout in seconds (default 30)"),
                    "detail": detailProperty,
                ],
                required: ["url"]
            ),
            tool(
                "browser_navigate_back",
                "Go back one step in this session's browser history (like the Back button) and "
                    + "return a page snapshot.",
                properties: ["detail": detailProperty]
            ),
            tool(
                "browser_read_page",
                "Read the main text content of the current page (articles, docs, search results, "
                    + "prices). Returns readable text with pagination — snapshots only show "
                    + "interactive elements; use this to actually read a page.",
                properties: [
                    "offset": number("Character offset to continue reading from (default 0)"),
                    "max_chars": number("Max characters to return (default 20000, max 40000)"),
                ]
            ),
            tool(
                "browser_snapshot",
                "Get a structured snapshot of interactive elements. Usually not needed since action "
                    + "tools return snapshots automatically. Use when you need to re-inspect without acting.",
                properties: [
                    "filter": enumString(
                        ["all", "inputs", "buttons", "links", "forms"],
                        "Filter element types (default: all)"),
                    "max_elements": number("Max elements to return (default: 100)"),
                    "visible_only": bool("Only visible elements (default: true)"),
                    "detail": detailProperty,
                ]
            ),
            tool(
                "browser_click",
                "Click an element and return updated page snapshot.",
                properties: [
                    "ref": string("Element ref from snapshot (e.g., 'E5')"),
                    "selector": string("CSS selector (fallback if ref not available)"),
                    "detail": detailProperty,
                ]
            ),
            tool(
                "browser_type",
                "Type text into an input element and return updated page snapshot. Use submit=true "
                    + "to press Enter after typing.",
                properties: [
                    "ref": string("Element ref from snapshot"),
                    "selector": string("CSS selector (fallback)"),
                    "text": string("Text to type"),
                    "clear": bool("Clear existing text first (default: true)"),
                    "submit": bool("Press Enter after typing (default: false)"),
                    "detail": detailProperty,
                ],
                required: ["text"]
            ),
            tool(
                "browser_select",
                "Select option(s) in a dropdown and return updated page snapshot.",
                properties: [
                    "ref": string("Element ref from snapshot"),
                    "selector": string("CSS selector (fallback)"),
                    "values": stringArray("Values or text to select"),
                    "detail": detailProperty,
                ],
                required: ["values"]
            ),
            tool(
                "browser_hover",
                "Hover over an element and return updated page snapshot.",
                properties: [
                    "ref": string("Element ref from snapshot"),
                    "selector": string("CSS selector (fallback)"),
                    "detail": detailProperty,
                ]
            ),
            tool(
                "browser_scroll",
                "Scroll the page and return updated page snapshot.",
                properties: [
                    "direction": enumString(["up", "down", "left", "right"], "Scroll direction"),
                    "ref": string("Scroll to bring this element into view"),
                    "x": number("X coordinate to scroll to"),
                    "y": number("Y coordinate to scroll to"),
                    "detail": detailProperty,
                ]
            ),
            tool(
                "browser_do",
                "Execute multiple browser actions in sequence and return a single snapshot at the "
                    + "end. Use to batch interactions (type, click, select, etc.) in one call. All refs "
                    + "from the previous snapshot remain valid throughout the batch. If any action "
                    + "fails, execution stops and returns the error with a snapshot.",
                properties: [
                    "actions": .object([
                        "type": .string("array"),
                        "description": .string("Ordered list of actions to execute"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "action": enumString(
                                    ["click", "type", "select", "hover", "scroll", "press_key", "wait_for"],
                                    "Action type"),
                                "ref": string("Element ref from snapshot"),
                                "selector": string("CSS selector (fallback)"),
                                "text": string("Text for type action, or text to wait for in wait_for"),
                                "values": stringArray("Values for select action"),
                                "key": string("Key for press_key action"),
                                "modifiers": stringArray("Modifier keys for press_key"),
                                "direction": string("Direction for scroll"),
                                "clear": bool("Clear before typing (default: true)"),
                                "submit": bool("Submit after typing"),
                                "time": number("Wait time in seconds"),
                                "timeout": number("Wait timeout in seconds"),
                                "text_gone": string("Wait for text to disappear"),
                            ]),
                            "required": .array([.string("action")]),
                        ]),
                    ]),
                    "detail": detailProperty,
                    "wait_after": enumString(
                        ["none", "domstable", "networkidle"],
                        "Wait condition after last action before snapshotting"),
                ],
                required: ["actions"]
            ),
            tool(
                "browser_press_key",
                "Press a keyboard key. Useful for Enter, Escape, Tab, arrow keys, or shortcuts.",
                properties: [
                    "key": string("Key name (Enter, Escape, Tab, ArrowUp, ArrowDown, etc.) or character"),
                    "modifiers": stringArray("Modifier keys: ctrl, shift, alt, meta/cmd"),
                ],
                required: ["key"]
            ),
            tool(
                "browser_wait_for",
                "Wait for text to appear, disappear, or for a specified time.",
                properties: [
                    "text": string("Wait for this text to appear"),
                    "text_gone": string("Wait for this text to disappear"),
                    "time": number("Wait for this many seconds"),
                    "timeout": number("Max time to wait (default: 10s)"),
                ]
            ),
            tool(
                "browser_screenshot",
                "Take a screenshot for visual debugging. Use full_page=true for entire page.",
                properties: [
                    "path": string(
                        "File name inside ~/Downloads (default: screenshot_<timestamp>.png). "
                            + "Paths outside ~/Downloads are rejected; existing files are never overwritten."),
                    "full_page": bool("Capture full scrollable page"),
                ]
            ),
            tool(
                "browser_execute_script",
                "Execute arbitrary JavaScript. Use as escape hatch for edge cases not covered by "
                    + "other tools.",
                properties: ["script": string("JavaScript code to execute")],
                required: ["script"]
            ),
            tool(
                "browser_console_messages",
                "Read JavaScript console output captured since the page loaded (or since the last "
                    + "clear). Returns level, message, and timestamp (ms epoch) for each entry.",
                properties: [
                    "level": enumString(
                        ["all", "log", "info", "warn", "error", "debug"],
                        "Filter by level. Default 'all'."),
                    "since": number("Unix seconds. Only return messages at or after this time."),
                    "clear": bool("Clear the buffer after returning. Default false."),
                ]
            ),
            tool(
                "browser_network_requests",
                "List fetch/XHR requests made by the page. Includes method, url, status, ok, duration_ms.",
                properties: [
                    "failed_only": bool("Only return requests with status 0 or 4xx/5xx."),
                    "method": string("Filter by HTTP method (GET, POST, etc.)."),
                    "url_contains": string("Filter by substring in URL."),
                    "clear": bool("Clear the buffer after returning. Default false."),
                ]
            ),
            tool(
                "browser_handle_dialog",
                "Pre-register a policy for the next JavaScript dialog (alert/confirm/prompt). Call "
                    + "BEFORE the action that triggers the dialog. Default policy is 'accept'.",
                properties: [
                    "action": enumString(
                        ["accept", "dismiss", "status"],
                        "accept=OK/Yes/use prompt_text; dismiss=Cancel/No/null; status=read last dialog."),
                    "prompt_text": string(
                        "Text to fill into a window.prompt() dialog when action='accept'."),
                ]
            ),
            tool(
                "browser_cookies",
                "Inspect, set, or clear cookies in this agent's browser cookie store.",
                properties: [
                    "action": enumString(["get", "set", "clear"], "Default 'get'."),
                    "domain": string("Filter (get/clear) by domain substring."),
                    "include_values": bool(
                        "For action='get': include raw cookie values (redacted by default; "
                            + "requires user approval). Only use when a value is genuinely needed."),
                    "cookie": .object([
                        "type": .string("object"),
                        "description": .string(
                            "For action='set': {name, value, domain, path?, secure?, expires?(unix seconds)}."),
                    ]),
                ]
            ),
            tool(
                "browser_open_login",
                "Opens a visible browser window so the user can sign in to a website. Cookies "
                    + "persist per-agent — once signed in, subsequent browser_navigate calls run "
                    + "logged-in. Call this when you receive a LOGIN_REQUIRED error from "
                    + "browser_navigate, or when the user explicitly asks to sign in. NEVER ask the "
                    + "user for passwords or 2FA codes in chat — this tool handles authentication via "
                    + "the helper window.",
                properties: [
                    "url": string(
                        "Optional URL to open in the helper window. If omitted, the window opens "
                            + "with a small prompt that lets the user enter any URL."),
                    "timeout_ms": number(
                        "Maximum time to wait for the user to close the window, in milliseconds. "
                            + "Default 300000 (5 minutes)."),
                ]
            ),
            tool(
                "browser_reset_session",
                "Wipes this agent's persistent browser session — closes the browser and removes its "
                    + "on-disk data store (cookies, localStorage, IndexedDB, cache). The next "
                    + "browser_navigate starts a fresh logged-out profile. Use this when the user asks "
                    + "to 'sign out of everything' or when authentication state is corrupted. "
                    + "Destructive — the user is asked to approve.",
                properties: [:]
            ),
        ]
    }

    /// Names of every private child tool (for visibility tests / exclusions).
    static var names: [String] { all.map { $0.function.name } }

    // MARK: - Schema helpers

    private static func tool(
        _ name: String, _ description: String,
        properties: [String: JSONValue],
        required: [String] = []
    ) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: name,
                description: description,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "required": .array(required.map { .string($0) }),
                ])
            )
        )
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    private static func bool(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    private static func enumString(_ values: [String], _ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description),
        ])
    }
}

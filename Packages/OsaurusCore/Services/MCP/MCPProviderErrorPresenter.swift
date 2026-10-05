//
//  MCPProviderErrorPresenter.swift
//  osaurus
//
//  Turns transport / JSON-RPC / HTTP failures recorded in
//  `MCPProviderState.lastError` into a short plain-language message with a
//  next step. The raw text stays available as `details` for a disclosure.
//

import Foundation

public struct MCPProviderErrorPresentation: Equatable, Sendable {
    public let message: String
    /// The original error text when `message` rewrote it; nil when the raw
    /// text was already readable and is shown as-is.
    public let details: String?
}

public enum MCPProviderErrorPresenter {
    public static func present(_ raw: String, providerName: String) -> MCPProviderErrorPresentation {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Stdio "command not found" already reads as a fix-it and the card
        // pairs it with an Edit button.
        if MCPStdioTransportError.isCommandNotFoundMessage(text) {
            return MCPProviderErrorPresentation(message: text, details: nil)
        }
        let name = providerName.isEmpty ? L("This service") : providerName
        guard let message = friendlyMessage(for: text.lowercased(), name: name) else {
            return MCPProviderErrorPresentation(message: text, details: nil)
        }
        return MCPProviderErrorPresentation(message: message, details: message == text ? nil : text)
    }

    static func friendlyMessage(for lower: String, name: String) -> String? {
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }

        if has("insufficient_scope", "http 403", "status 403", "forbidden") {
            return L("\(name) didn't allow this. Your account may not have access, or you may need to sign in again.")
        }
        if has("invalid_token", "http 401", "status 401", "unauthorized", "session expired",
            "authentication required", "requires sign in", "requires an api token", "rejected the saved api token")
        {
            return L("\(name) needs you to sign in again.")
        }
        if has("http 402", "status 402", "payment required", "subscription", "upgrade your plan") {
            return L("\(name) says your account doesn't include this. It may need a paid plan.")
        }
        if has("timed out", "timeout", "deadline") {
            return L("\(name) took too long to respond. Try again in a moment.")
        }
        if has("not connected to the internet", "network connection was lost", "could not connect",
            "cannot connect", "hostname could not be found", "cannot find host", "offline",
            "dns", "nsurlerrordomain")
        {
            return L("Couldn't reach \(name). Check your internet connection and try again.")
        }
        if has("client disconnected", "connection not initialized", "connection reset", "broken pipe") {
            return L("The connection to \(name) dropped. Click Retry to reconnect.")
        }
        if has("http 404", "status 404", "404 not found") {
            return L("\(name) didn't answer at this address. The service may have moved; check the URL.")
        }
        if lower.range(of: #"(http|status)[ :]*5\d\d"#, options: .regularExpression) != nil
            || has("bad gateway", "service unavailable", "internal server error", "gateway timeout")
        {
            return L("\(name) is having problems right now. Try again later.")
        }
        if has("subprocess exited") {
            return L("The local \(name) server stopped unexpectedly.")
        }
        // Only rewrite text that looks like a protocol dump; readable
        // messages (step-up prompts, sign-in failures) pass through.
        if has("[-32", "error domain=", "code=", "jsonrpc", "decodingerror") {
            return L("Something went wrong talking to \(name). Click Retry, or open Details for more.")
        }
        return nil
    }
}

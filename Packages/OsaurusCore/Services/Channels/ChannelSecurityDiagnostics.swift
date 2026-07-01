//
//  ChannelSecurityDiagnostics.swift
//  osaurus
//
//  Redaction and operator-facing explanations for channel security decisions.
//

import Foundation

enum ChannelSecurityDiagnostics {
    static let replyTokenMarker = "[REDACTED:CHANNEL_REPLY_TOKEN]"
    static let credentialMarker = "[REDACTED:CHANNEL_CREDENTIAL]"

    static func message(for reason: ChannelSecurityDiagnosticReason) -> String {
        switch reason {
        case .allowed:
            return "Allowed by channel security policy."
        case .disabled:
            return "Denied: the global remote/channel write kill switch is disabled."
        case .invalidIdentity:
            return "Denied: channel identity is missing a required installation or sender id."
        case .senderDenied:
            return "Denied: sender is not allowlisted for this channel."
        case .groupDenied:
            return "Denied: group is not allowlisted for this channel."
        case .threadDenied:
            return "Denied: thread is not allowlisted for this channel."
        case .trustDenied:
            return "Denied: sender trust level is below the channel policy minimum."
        case .writeDisabled:
            return "Denied: channel write permission is disabled."
        case .writeSenderDenied:
            return "Denied: sender is not allowlisted for channel writes."
        case .writeGroupDenied:
            return "Denied: group is not allowlisted for channel writes."
        case .writeThreadDenied:
            return "Denied: thread is not allowlisted for channel writes."
        case .expired:
            return "Denied: reply token expired."
        case .replayed:
            return "Denied: reply token nonce was already used."
        case .revoked:
            return "Denied: reply token was revoked or predates the current write gate generation."
        case .tokenInvalid:
            return "Denied: reply token is malformed or has an invalid signature."
        case .identityMismatch:
            return "Denied: reply token is bound to a different channel identity."
        case .purposeMismatch:
            return "Denied: reply token purpose does not match the requested action."
        case .actionMismatch:
            return "Denied: reply token action does not match the requested action."
        case .notYetValid:
            return "Denied: reply token was issued in the future beyond allowed clock skew."
        case .storeUnavailable:
            return "Denied: channel replay store is unavailable, so the request failed closed."
        }
    }

    static func redact(
        _ text: String,
        credentials: [String] = [],
        tokens: [String] = []
    ) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        let exactCredentials =
            credentials
            .filter { $0.count >= SecretScrubber.minimumValueLength }
            .sorted { $0.count > $1.count }
        for credential in exactCredentials where result.contains(credential) {
            result = result.replacingOccurrences(of: credential, with: credentialMarker)
        }

        let exactTokens =
            tokens
            .filter { $0.count >= SecretScrubber.minimumValueLength }
            .sorted { $0.count > $1.count }
        for token in exactTokens where result.contains(token) {
            result = result.replacingOccurrences(of: token, with: replyTokenMarker)
        }

        result = replacingMatches(
            in: result,
            pattern: #"osaurus_channel_reply_v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
            replacement: replyTokenMarker
        )
        result = replacingMatches(
            in: result,
            pattern: #"(?i)\b(token|secret|api[_-]?key|authorization)\s*[:=]\s*[A-Za-z0-9._~+/=-]{6,}"#,
            replacement: "$1=\(credentialMarker)"
        )
        return result
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}

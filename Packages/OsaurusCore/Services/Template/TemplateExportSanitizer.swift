//
//  TemplateExportSanitizer.swift
//  osaurus
//
//  What leaves the Mac in an exported template file, and what an imported
//  one may carry in. Secret values and folder bookmarks are never part of
//  a `Template`, so they cannot leak by construction; this pass removes the
//  remaining machine-local details a payload can hold: absolute paths, and
//  credentials an MCP server hint's endpoint or arguments can carry.
//
//  A signed template is the signer's exact content: export sanitizes
//  before signing, so an honest file is already clean, and changing one
//  here would only break (or silently drop) its signature. Signed
//  templates pass through unchanged; the import review shows them as
//  they are and the store refuses one whose signature does not match.
//

import Foundation

public enum TemplateExportSanitizer {

    public static func sanitized(_ template: Template) -> Template {
        if template.author?.isSigned == true { return template }
        var copy = template
        switch template.payload {
        case .agent:
            if let hint = copy.requirements.workingFolder {
                copy.requirements.workingFolder = PathHint(path: portablePath(hint.path), label: hint.label)
            }
            if let path = copy.agent.workingFolder.valueOrNil {
                copy.agent.workingFolder = .value(portablePath(path))
            }
        }
        copy.serverHints = copy.serverHints.map(sanitized)
        copy.bundled = copy.bundled.map(sanitized)
        return copy.contentHash == copy.computedContentHash() ? copy : copy.sealed()
    }

    /// A hint's shape already holds no header or env values; this drops
    /// credentials an endpoint or argument can still carry and makes paths
    /// portable.
    static func sanitized(_ hint: MCPServerHint) -> MCPServerHint {
        var copy = hint
        copy.url = hint.url.map(portableURL)
        copy.args = portableArgs(hint.args)
        copy.workingDirectory = hint.workingDirectory.map(portablePath)
        if let command = hint.command, command.hasPrefix("/") { copy.command = portablePath(command) }
        return copy
    }

    /// Stands in for a value that looked like a credential.
    static let redacted = "YOUR_KEY"

    private static let secretWords = ["key", "token", "secret", "password", "passwd", "auth", "signature", "sig"]

    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return secretWords.contains { lower.contains($0) }
    }

    /// Long letter-and-digit runs with no word structure: API keys, path
    /// tokens (`/s/9f2c…/mcp`), bearer strings.
    static func looksLikeCredential(_ value: String) -> Bool {
        guard value.count >= 20, !value.contains("."), !value.contains("/") else { return false }
        let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return letters > 0 && digits >= 3
    }

    /// The URL without user info, credential-named query items, or path
    /// segments that look like a credential.
    static func portableURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.user = nil
        components.password = nil
        if let items = components.queryItems {
            let kept = items.filter { !isSecretName($0.name) && !looksLikeCredential($0.value ?? "") }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if segments.contains(where: looksLikeCredential) {
            components.path = segments.map { looksLikeCredential($0) ? redacted : $0 }.joined(separator: "/")
        }
        return components.string ?? raw
    }

    /// Paths made portable; the value after a credential-named flag
    /// (`--api-key x`, `--token=x`) and credential-looking values redacted.
    static func portableArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var redactNext = false
        for arg in args {
            if redactNext {
                out.append(redacted)
                redactNext = false
                continue
            }
            if arg.hasPrefix("-") {
                if let eq = arg.firstIndex(of: "=") {
                    let flag = String(arg[..<eq])
                    let value = String(arg[arg.index(after: eq)...])
                    out.append(isSecretName(flag) || looksLikeCredential(value) ? flag + "=" + redacted : arg)
                } else {
                    out.append(arg)
                    redactNext = isSecretName(arg)
                }
                continue
            }
            if arg.hasPrefix("/") {
                out.append(portablePath(arg))
            } else {
                out.append(looksLikeCredential(arg) ? redacted : arg)
            }
        }
        return out
    }

    /// Paths under the home folder become `~/…`; anything else keeps only its
    /// last component, so no other volume or user name travels.
    static func portablePath(_ path: String) -> String {
        if path.hasPrefix("~") { return path }
        let abbreviated = Template.abbreviateHome(path)
        if abbreviated.hasPrefix("~") { return abbreviated }
        return (path as NSString).lastPathComponent
    }
}

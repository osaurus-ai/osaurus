//
//  TemplateExportSanitizer.swift
//  osaurus
//
//  What leaves the Mac in an exported template file, and what an imported
//  one may carry in. Saved dialog answers, secret values, install bindings,
//  and run history are never part of a `Template`, so they cannot leak by
//  construction; this pass removes the remaining machine-local details a
//  payload can hold: absolute paths, and secret-looking values in examples
//  and dialog defaults.
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
        case .workflow(var def):
            let secretKeys = secretFieldKeys(def)
            def.examples = def.examples.map { ex in
                WorkflowExample(name: ex.name, input: strip(ex.input, keys: secretKeys))
            }
            def.nodes = def.nodes.map { node in
                if case .agent(let spec) = node.kind {
                    var n = node
                    n.kind = .agent(portable(spec))
                    return n
                }
                guard case .dialog(var spec) = node.kind else { return node }
                spec.fields = spec.fields.map { field in
                    var f = field
                    if f.type == .secret || f.type == .file || f.type == .folder { f.defaultValue = nil }
                    return f
                }
                var n = node
                n.kind = .dialog(spec)
                return n
            }
            copy.payload = .workflow(def)
        }
        copy.serverHints = copy.serverHints.map(sanitized)
        copy.bundled = copy.bundled.map(sanitized)
        return copy.contentHash == copy.computedContentHash() ? copy : copy.sealed()
    }

    /// An agent step names its agent by display name and, for a shared one,
    /// by workspace and address: never by this Mac's agent id. A ref
    /// without a real address is dropped, leaving the name.
    static func portable(_ spec: AgentNodeSpec) -> AgentNodeSpec {
        let ref = spec.workspace.flatMap { ref -> WorkspaceAgentRef? in
            let workspace = ref.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workspace.isEmpty, WorkspaceAgentRef.looksLikeAddress(ref.agentAddress) else { return nil }
            return WorkspaceAgentRef(workspaceId: workspace, agentAddress: ref.agentAddress)
        }
        return AgentNodeSpec(
            agent: spec.agent.trimmingCharacters(in: .whitespacesAndNewlines), workspace: ref, task: spec.task)
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

    /// Dialog secret fields and code-node secret keys. Example inputs never
    /// carry values for them.
    static func secretFieldKeys(_ def: WorkflowDefinition) -> Set<String> {
        var keys = Set(def.secrets.map(\.key))
        for node in def.nodes {
            switch node.kind {
            case .dialog(let spec):
                for f in spec.fields where f.type == .secret { keys.insert(f.key) }
            case .code(let spec):
                keys.formUnion(spec.secrets)
            default:
                break
            }
        }
        return keys
    }

    static func strip(_ value: JSONValue, keys: Set<String>) -> JSONValue {
        switch value {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o where !keys.contains(k) { out[k] = strip(v, keys: keys) }
            return .object(out)
        case .array(let list):
            return .array(list.map { strip($0, keys: keys) })
        case .string(let s) where s.hasPrefix("/"):
            return .string(portablePath(s))
        default:
            return value
        }
    }
}

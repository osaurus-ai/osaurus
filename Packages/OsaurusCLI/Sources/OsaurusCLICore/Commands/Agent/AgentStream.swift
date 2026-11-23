//
//  AgentStream.swift
//  OsaurusCLICore
//
//  Reading the `POST /agents/{id}/run` event stream, and the transcripts
//  `osaurus agent run --session` keeps between runs.
//

import Foundation

/// One installed agent from `GET /agents`.
public struct AgentSummary: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let model: String?
    public let isBuiltIn: Bool

    init?(_ object: [String: Any]) {
        guard let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
        self.id = id
        self.name = name
        let description = (object["description"] as? String) ?? (object["generated_description"] as? String)
        self.description = description?.isEmpty == false ? description : nil
        self.model = (object["effective_model"] as? String) ?? (object["default_model"] as? String)
        self.isBuiltIn = object["is_built_in"] as? Bool ?? false
    }

    public enum Resolution: Equatable {
        case found(AgentSummary)
        case notFound
        case ambiguous([AgentSummary])
    }

    /// By id, `default` (the built-in agent), or name ignoring case and
    /// punctuation.
    public static func resolve(_ query: String, in agents: [AgentSummary]) -> Resolution {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = agents.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame }) {
            return .found(exact)
        }
        if key.lowercased() == "default", let builtIn = agents.first(where: \.isBuiltIn) {
            return .found(builtIn)
        }
        let named = agents.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        if named.count == 1 { return .found(named[0]) }
        if named.count > 1 { return .ambiguous(named) }
        let slug = WorkflowClient.slug(key)
        let slugged = agents.filter { !slug.isEmpty && WorkflowClient.slug($0.name) == slug }
        if slugged.count == 1 { return .found(slugged[0]) }
        return slugged.isEmpty ? .notFound : .ambiguous(slugged)
    }
}

/// What one `data:` line of an agent run says.
enum AgentStreamEvent: Equatable {
    case text(String)
    case toolStarted(name: String, label: String?)
    case toolFinished(name: String, label: String?, isError: Bool, result: String?)
    case modelLoad(state: String, model: String?)
    case error(String)
    case done
}

enum AgentStreamParser {
    /// Nil for blank lines, SSE comments (keepalives) and chunks with
    /// nothing to show (role, finish, reasoning, usage).
    static func parse(line: String) -> [AgentStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [.done] }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            return []
        }
        if let error = object["error"] as? [String: Any] {
            return [.error(error["message"] as? String ?? "The run failed.")]
        }
        if let error = object["error"] as? String { return [.error(error)] }
        var events: [AgentStreamEvent] = []
        if let tool = object["osaurus_agent_tool"] as? [String: Any], let name = tool["name"] as? String {
            let label = tool["label"] as? String
            if tool["phase"] as? String == "started" {
                events.append(.toolStarted(name: name, label: label))
            } else {
                events.append(
                    .toolFinished(
                        name: name, label: label, isError: tool["is_error"] as? Bool ?? false,
                        result: tool["result"] as? String))
            }
        }
        if let load = object["osaurus_model_load"] as? [String: Any], let state = load["state"] as? String {
            events.append(.modelLoad(state: state, model: load["model"] as? String))
        }
        for choice in object["choices"] as? [[String: Any]] ?? [] {
            if let content = (choice["delta"] as? [String: Any])?["content"] as? String, !content.isEmpty {
                events.append(.text(content))
            }
        }
        return events
    }

    /// Osaurus refused an Ask tool because nobody could approve it.
    static func isApprovalRefusal(_ result: String?) -> Bool {
        result?.contains("requires interactive approval") == true
    }

    /// The readable part of a tool's error result (an envelope or text).
    static func errorMessage(_ result: String?) -> String? {
        guard let result, !result.isEmpty else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = object["error"] as? String { return error }
        }
        let firstLine = result.split(separator: "\n").first.map(String.init) ?? result
        return firstLine.count > 200 ? String(firstLine.prefix(200)) + "…" : firstLine
    }
}

/// Transcripts for `osaurus agent run --session ID`, so a later run can pick
/// the conversation up. The server keeps no history for a local run; the
/// CLI replays it.
struct AgentSessionStore {
    let directory: URL

    static var live: AgentSessionStore {
        AgentSessionStore(directory: Configuration.root().appendingPathComponent("cli/sessions", isDirectory: true))
    }

    struct Transcript: Codable, Equatable {
        var agent: String
        var messages: [Message]

        struct Message: Codable, Equatable {
            let role: String
            let content: String
        }
    }

    static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count)
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            && !id.hasPrefix(".")
    }

    func url(for id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    func load(_ id: String) -> Transcript? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    func save(_ transcript: Transcript, as id: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(transcript)
        try data.write(to: url(for: id), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: id).path)
    }
}

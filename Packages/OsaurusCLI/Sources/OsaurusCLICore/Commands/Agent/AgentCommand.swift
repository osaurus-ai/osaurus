//
//  AgentCommand.swift
//  OsaurusCLICore
//
//  `osaurus agent list | run`: run an Osaurus agent headless, with its own
//  model, prompt, memory and tools, over `POST /agents/{id}/run`. The
//  answer streams to stdout and tool activity to stderr, so the command
//  composes in pipes:
//
//    git diff | osaurus agent run "Code Reviewer" -p "Review this change"
//

import Darwin
import Foundation

public struct AgentCommand: Command {
    public static let name = "agent"

    static let usage = """
        Usage:
          osaurus agent list [--json]
          osaurus agent run <name|id|default> [-p PROMPT] [--session ID] [--json]

        run sends PROMPT (and anything piped on stdin, appended after it) to the
        agent and streams the answer to stdout; tool activity goes to stderr.
        --session ID keeps the conversation under that name, so the next run
        with the same ID continues it. --json prints one object at the end
        instead of streaming.

        Tools set to Ask: in a terminal, Osaurus shows the approval card on the
        Mac and asks here too; answer in either place. Without a terminal they
        are declined, and the run lists which. Tools that write files, run
        commands or use your Mac's apps only run from the Osaurus app.

        All subcommands accept --access-key KEY.

          osaurus agent run default -p "Explain what a KV cache is in two sentences"
          cat notes.txt | osaurus agent run Writer -p "Tighten this" --session notes
        """

    struct RunOptions: Equatable {
        var agent: String
        var prompt: String?
        var session: String?
        var json = false
    }

    enum Invocation: Equatable {
        case list(json: Bool)
        case run(RunOptions)
        case help
    }

    struct UsageError: Error, Equatable {
        let message: String
    }

    public static func execute(args: [String]) async {
        let invocation: Invocation
        do {
            invocation = try parse(AccessKeyResolver.removingAccessKeyOptions(from: args))
        } catch let error as UsageError {
            fputs("osaurus agent: \(error.message)\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            exit(EXIT_FAILURE)
        }
        guard invocation != .help else {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        let server = await LocalServerClient.connect(command: "agent", args: args)
        do {
            switch invocation {
            case .help:
                exit(EXIT_SUCCESS)
            case .list(let json):
                let agents = try await list(server)
                if json {
                    printJSON(["agents": agents.map(agentJSON)])
                } else {
                    let defaultID = agents.first(where: \.isBuiltIn)?.id
                    for agent in agents { print(describe(agent, isDefault: agent.id == defaultID)) }
                }
                exit(EXIT_SUCCESS)
            case .run(var options):
                if isatty(STDIN_FILENO) == 0 {
                    let piped = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    options.prompt = combinedPrompt(options.prompt, piped: piped)
                }
                guard let prompt = options.prompt, !prompt.isEmpty else {
                    fputs("osaurus agent: give a prompt with -p, or pipe one in.\n", stderr)
                    exit(EXIT_FAILURE)
                }
                options.prompt = prompt
                exit(try await run(options, server: server))
            }
        } catch let error as UsageError {
            fputs("\(error.message)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            fputs("Could not reach Osaurus: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - Parsing

    static func parse(_ args: [String]) throws -> Invocation {
        guard let sub = args.first else { throw UsageError(message: "missing subcommand") }
        let rest = Array(args.dropFirst())
        if rest.contains("--help") || rest.contains("-h") { return .help }
        var json = false
        var prompt: String?
        var session: String?
        var positionals: [String] = []
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < rest.count else { throw UsageError(message: "\(flag) needs a value") }
            return rest[index]
        }
        while index < rest.count {
            let arg = rest[index]
            switch arg {
            case "--json": json = true
            case "-p" where sub == "run", "--prompt" where sub == "run": prompt = try value(arg)
            case "--session" where sub == "run":
                let id = try value(arg)
                guard AgentSessionStore.isValidID(id) else {
                    throw UsageError(message: "--session takes letters, numbers, '-', '_' or '.' (up to 64)")
                }
                session = id
            default:
                if arg.hasPrefix("-") { throw UsageError(message: "unknown option `\(arg)`") }
                positionals.append(arg)
            }
            index += 1
        }
        switch sub {
        case "list", "ls":
            guard positionals.isEmpty else { throw UsageError(message: "unexpected `\(positionals[0])`") }
            return .list(json: json)
        case "run":
            guard let agent = positionals.first else { throw UsageError(message: "missing agent name or id") }
            guard positionals.count == 1 else {
                throw UsageError(message: "unexpected `\(positionals[1])` (quote the prompt and pass it with -p)")
            }
            return .run(RunOptions(agent: agent, prompt: prompt, session: session, json: json))
        case "help", "-h", "--help":
            return .help
        default:
            throw UsageError(message: "unknown subcommand `\(sub)`")
        }
    }

    /// The prompt with piped input appended after a blank line.
    static func combinedPrompt(_ prompt: String?, piped: String) -> String? {
        let input = piped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return prompt }
        guard let prompt, !prompt.isEmpty else { return input }
        return prompt + "\n\n" + input
    }

    // MARK: - Listing

    static func list(_ server: LocalServerClient) async throws -> [AgentSummary] {
        let (data, response) = try await server.data(for: server.request("/agents", timeout: 15))
        if response.statusCode == 401 { throw UsageError(message: server.unauthorizedHint) }
        guard response.statusCode == 200,
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw UsageError(message: "Osaurus could not list agents (HTTP \(response.statusCode)).") }
        return (object["agents"] as? [[String: Any]] ?? []).compactMap(AgentSummary.init)
    }

    /// `isDefault` marks the agent that `agent run default` picks.
    static func describe(_ agent: AgentSummary, isDefault: Bool) -> String {
        var line = agent.name + (isDefault ? "  (default)" : agent.isBuiltIn ? "  (built-in)" : "")
        if let model = agent.model { line += "  [\(model)]" }
        if let description = agent.description { line += "  — \(description)" }
        return line
    }

    static func agentJSON(_ agent: AgentSummary) -> [String: Any] {
        var object: [String: Any] = ["id": agent.id, "name": agent.name, "built_in": agent.isBuiltIn]
        if let model = agent.model { object["model"] = model }
        if let description = agent.description { object["description"] = description }
        return object
    }

    // MARK: - Running

    struct Outcome {
        var text = ""
        var tools: [(name: String, error: String?)] = []
        var declined: [String] = []
        var error: String?
    }

    static func run(
        _ options: RunOptions,
        server: LocalServerClient,
        sessions: AgentSessionStore = .live
    ) async throws -> Int32 {
        let agents = try await list(server)
        let agent: AgentSummary
        switch AgentSummary.resolve(options.agent, in: agents) {
        case .found(let match): agent = match
        case .ambiguous(let matches):
            throw UsageError(
                message: "More than one agent matches `\(options.agent)`: "
                    + matches.map { "\($0.name) (\($0.id))" }.joined(separator: ", ") + ". Use the id.")
        case .notFound:
            throw UsageError(
                message: "No agent is named `\(options.agent)`. Agents: "
                    + agents.map(\.name).joined(separator: ", "))
        }

        var transcript = options.session.flatMap { sessions.load($0) }
            ?? AgentSessionStore.Transcript(agent: agent.id, messages: [])
        if transcript.agent != agent.id, !transcript.messages.isEmpty {
            throw UsageError(
                message: "Session `\(options.session ?? "")` belongs to another agent. Use a new --session ID.")
        }
        transcript.agent = agent.id
        let prompt = options.prompt ?? ""
        transcript.messages.append(.init(role: "user", content: prompt))

        // Answering approvals needs a terminal, and an approved CLI: the
        // server ignores the session header without the token.
        var approvalSession: String?
        var tty: Int32?
        if isatty(STDERR_FILENO) != 0, let terminal = TerminalApprovals.openTerminal() {
            if await server.requireToken() {
                approvalSession = TerminalApprovals.newSession()
                tty = terminal
            } else {
                close(terminal)
            }
        }
        defer { if let tty { close(tty) } }

        var body: [String: Any] = [
            "messages": transcript.messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
        ]
        if let session = options.session { body["session_id"] = "cli-\(session)" }
        var request = server.jsonRequest("/agents/\(agent.id)/run", body: body, timeout: 3600)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let approvalSession {
            request.setValue(approvalSession, forHTTPHeaderField: approvalSessionHeader)
        }

        let watcher: Task<Void, Never>? = approvalSession.map { session in
            let approvals = TerminalApprovals(server: server, session: session)
            let asker = TerminalApprovals.terminalAsker(tty: tty!)
            return Task { await approvals.watch(ask: asker, note: { fputs("  \($0)\n", stderr) }) }
        }
        defer { watcher?.cancel() }

        let outcome = try await stream(request, server: server, echo: !options.json)
        watcher?.cancel()

        if let session = options.session, outcome.error == nil, !outcome.text.isEmpty {
            transcript.messages.append(.init(role: "assistant", content: outcome.text))
            try? sessions.save(transcript, as: session)
        }

        if options.json {
            var object: [String: Any] = ["agent": agent.name, "agent_id": agent.id, "text": outcome.text]
            object["tools"] = outcome.tools.map { tool -> [String: Any] in
                var entry: [String: Any] = ["name": tool.name]
                if let error = tool.error { entry["error"] = error }
                return entry
            }
            if !outcome.declined.isEmpty { object["declined"] = outcome.declined }
            if let session = options.session { object["session"] = session }
            if let error = outcome.error { object["error"] = error }
            printJSON(object)
        }
        if !outcome.declined.isEmpty {
            fputs(declinedNote(outcome.declined), stderr)
        }
        if let error = outcome.error {
            if !options.json { fputs("\(error)\n", stderr) }
            return EXIT_FAILURE
        }
        return EXIT_SUCCESS
    }

    static let approvalSessionHeader = "X-Osaurus-CLI-Approval-Session"

    static func declinedNote(_ tools: [String]) -> String {
        let names = Array(Set(tools)).sorted().joined(separator: ", ")
        return "Declined without a terminal to approve them: \(names). Run this in a terminal to approve them, "
            + "or set them to Auto in Osaurus (Tools & MCP → All Tools, or the agent's Tools tab).\n"
    }

    /// Reads the run's events, echoing the answer to stdout and tool
    /// activity to stderr when `echo`.
    static func stream(_ request: URLRequest, server: LocalServerClient, echo: Bool) async throws -> Outcome {
        let (bytes, response) = try await server.bytes(for: request)
        if response.statusCode == 401 { throw UsageError(message: server.unauthorizedHint) }
        guard response.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message =
                (object?["message"] as? String)
                ?? ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data, as: UTF8.self)
            throw UsageError(message: "The run was refused (HTTP \(response.statusCode)): \(message)")
        }
        var outcome = Outcome()
        let stdoutIsTerminal = isatty(STDOUT_FILENO) != 0
        var midLine = false
        func activity(_ text: String) {
            guard echo else { return }
            if midLine, stdoutIsTerminal {
                print("")
                midLine = false
            }
            fputs(text + "\n", stderr)
        }
        lines: for try await line in bytes.lines {
            for event in AgentStreamParser.parse(line: line) {
                switch event {
                case .text(let text):
                    outcome.text += text
                    if echo {
                        print(text, terminator: "")
                        fflush(stdout)
                        midLine = !text.hasSuffix("\n")
                    }
                case .toolStarted(let name, let label):
                    activity("  → \(label ?? name)")
                case .toolFinished(let name, _, let isError, let result):
                    let message = isError ? AgentStreamParser.errorMessage(result) ?? "failed" : nil
                    outcome.tools.append((name, message))
                    if isError, AgentStreamParser.isApprovalRefusal(result) {
                        outcome.declined.append(name)
                        activity("  ✗ \(name): declined (needs approval)")
                    } else if let message {
                        activity("  ✗ \(name): \(message)")
                    }
                case .modelLoad(let state, let model):
                    if state == "loading" { activity("  Loading \(model ?? "the model")…") }
                case .error(let message):
                    outcome.error = message
                case .done:
                    break lines
                }
            }
        }
        if echo, midLine { print("") }
        return outcome
    }

    static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}

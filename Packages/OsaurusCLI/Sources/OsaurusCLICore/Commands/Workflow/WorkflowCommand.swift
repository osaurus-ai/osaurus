//
//  WorkflowCommand.swift
//  osaurus
//
//  `osaurus workflow list | run | status | runs | cancel`: run the owner's
//  workflows from Terminal. A run that stops for a form is answered here
//  when stdin is a terminal; otherwise the command exits 3 and the form
//  waits in Osaurus.
//

import Darwin
import Foundation

public struct WorkflowCommand: Command {
    public static let name = "workflow"

    /// A run is waiting on a form nobody here can answer.
    static let exitAwaitingInput: Int32 = 3

    static let usage = """
        Usage:
          osaurus workflow list [--json]
          osaurus workflow run <name|id> [--input key=value ...] [--input-json file|-] [--text TEXT]
                                         [--no-wait] [--json]
          osaurus workflow status <run_id> [--json]
          osaurus workflow runs [<name|id>] [--limit N] [--json]
          osaurus workflow cancel <run_id>

        run starts the workflow and waits for it. A form the run asks for is answered
        in the terminal (secret fields are not echoed); without a terminal, or with
        --no-wait, the form waits in Osaurus. --input values are read as the input
        field's type (numbers, true/false, JSON for lists and objects). --text gives
        free text to the field an automation's {{text}} would fill.

        Exit codes (run, status): 0 = completed (or started, with --no-wait);
        1 = failed, cancelled or needs setup; 3 = waiting for a form in Osaurus.
        Ctrl-C stops waiting; the run keeps going (stop it with `cancel`).

        All subcommands accept --access-key KEY.
        """

    struct RunOptions: Equatable {
        var workflow: String
        var inputs: [String] = []
        var inputJSON: String?
        var text: String?
        var wait = true
        var json = false
    }

    enum Invocation: Equatable {
        case list(json: Bool)
        case run(RunOptions)
        case status(runID: String, json: Bool)
        case runs(workflow: String?, limit: Int?, json: Bool)
        case cancel(runID: String)
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
            fputs("osaurus workflow: \(error.message)\n\n\(usage)\n", stderr)
            exit(EXIT_FAILURE)
        } catch {
            exit(EXIT_FAILURE)
        }
        if invocation == .help {
            print(usage)
            exit(EXIT_SUCCESS)
        }
        let server = await LocalServerClient.connect(command: "workflow", args: args)
        let client = WorkflowClient(server: server)
        do {
            exit(try await run(invocation, client: client))
        } catch let error as WorkflowClientError {
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
        var positionals: [String] = []
        var run = RunOptions(workflow: "")
        var limit: Int?
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
            case "--no-wait" where sub == "run": run.wait = false
            case "--input" where sub == "run", "-i" where sub == "run": run.inputs.append(try value(arg))
            case "--input-json" where sub == "run": run.inputJSON = try value(arg)
            case "--text" where sub == "run": run.text = try value(arg)
            case "--limit" where sub == "runs":
                guard let n = Int(try value(arg)), n > 0 else { throw UsageError(message: "--limit needs a positive number") }
                limit = n
            default:
                if arg.hasPrefix("-"), arg != "-" { throw UsageError(message: "unknown option `\(arg)`") }
                positionals.append(arg)
            }
            index += 1
        }
        switch sub {
        case "list", "ls":
            guard positionals.isEmpty else { throw UsageError(message: "unexpected `\(positionals[0])`") }
            return .list(json: json)
        case "run":
            guard positionals.count == 1 else {
                throw UsageError(message: positionals.isEmpty ? "missing workflow name or id" : "unexpected `\(positionals[1])`")
            }
            if run.text != nil, !run.inputs.isEmpty || run.inputJSON != nil {
                throw UsageError(message: "--text cannot be combined with --input or --input-json")
            }
            run.workflow = positionals[0]
            run.json = json
            return .run(run)
        case "status":
            guard positionals.count == 1 else { throw UsageError(message: "missing run id") }
            return .status(runID: positionals[0], json: json)
        case "runs", "history":
            guard positionals.count <= 1 else { throw UsageError(message: "unexpected `\(positionals[1])`") }
            return .runs(workflow: positionals.first, limit: limit, json: json)
        case "cancel", "stop":
            guard positionals.count == 1 else { throw UsageError(message: "missing run id") }
            return .cancel(runID: positionals[0])
        case "help", "-h", "--help":
            return .help
        default:
            throw UsageError(message: "unknown subcommand `\(sub)`")
        }
    }

    /// `key=value` pairs read as the type the input schema gives the key.
    static func inputValues(_ pairs: [String], schema: [String: Any]) throws -> [String: Any] {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        var values: [String: Any] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                throw UsageError(message: "--input needs key=value, got `\(pair)`")
            }
            let key = String(pair[..<equals])
            let raw = String(pair[pair.index(after: equals)...])
            values[key] = try typedValue(raw, schema: properties[key], key: key)
        }
        return values
    }

    static func typedValue(_ raw: String, schema: [String: Any]?, key: String) throws -> Any {
        let type = (schema?["type"] as? String) ?? ((schema?["type"] as? [String])?.first { $0 != "null" })
        switch type {
        case "number":
            guard let n = Double(raw) else { throw UsageError(message: "`\(key)` needs a number, got `\(raw)`") }
            return n
        case "integer":
            guard let n = Int(raw) else { throw UsageError(message: "`\(key)` needs a whole number, got `\(raw)`") }
            return n
        case "boolean":
            switch raw.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: throw UsageError(message: "`\(key)` needs true or false, got `\(raw)`")
            }
        case "array", "object":
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
            else { throw UsageError(message: "`\(key)` needs JSON (\(type ?? "")), got `\(raw)`") }
            return parsed
        default:
            return raw
        }
    }

    static func readInputJSON(_ source: String) throws -> [String: Any] {
        let data: Data
        if source == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            guard let contents = FileManager.default.contents(atPath: source) else {
                throw UsageError(message: "cannot read `\(source)`")
            }
            data = contents
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError(message: "--input-json must be a JSON object")
        }
        return object
    }

    // MARK: - Running

    static func run(_ invocation: Invocation, client: WorkflowClient) async throws -> Int32 {
        switch invocation {
        case .help:
            print(usage)
            return EXIT_SUCCESS
        case .list(let json):
            let workflows = try await client.list()
            if json {
                printJSON(["workflows": workflows.map(listJSON)])
            } else if workflows.isEmpty {
                print("(no workflows installed)")
            } else {
                for workflow in workflows {
                    var line = workflow.name
                    if workflow.needsSetup { line += "  [needs setup]" }
                    if let summary = workflow.summary { line += "  — \(summary)" }
                    print(line)
                    let inputs = describeInputs(workflow)
                    if !inputs.isEmpty { print("    inputs: \(inputs)") }
                }
            }
            return EXIT_SUCCESS
        case .run(let options):
            return try await start(options, client: client)
        case .status(let runID, let json):
            let run = try await client.run(runID)
            if json { printJSON(run) } else { printRun(run) }
            return exitCode(for: run)
        case .runs(let workflow, let limit, let json):
            let runs = try await client.runs(workflow: workflow, limit: limit)
            if json {
                printJSON(["runs": runs])
            } else if runs.isEmpty {
                print("(no runs)")
            } else {
                for run in runs {
                    let started = run["started_at"] as? String ?? ""
                    let status = run["status"] as? String ?? "?"
                    let name = run["workflow_name"] as? String ?? ""
                    let id = run["run_id"] as? String ?? ""
                    var line = "\(started)  \(status.padding(toLength: 13, withPad: " ", startingAt: 0)) \(name)  \(id)"
                    if let error = run["error"] as? String { line += "\n    \(error)" }
                    print(line)
                }
            }
            return EXIT_SUCCESS
        case .cancel(let runID):
            try await client.cancel(runID)
            print("Cancelled \(runID).")
            return EXIT_SUCCESS
        }
    }

    private static func start(_ options: RunOptions, client: WorkflowClient) async throws -> Int32 {
        let workflow = try await client.find(options.workflow)
        if workflow.needsSetup {
            throw WorkflowClientError(
                "Set up \(workflow.name) in Osaurus first"
                    + (workflow.setupSummary.map { ": \($0)" } ?? "."))
        }
        var input: [String: Any]?
        if let source = options.inputJSON { input = try readInputJSON(source) }
        if !options.inputs.isEmpty {
            input = (input ?? [:]).merging(try inputValues(options.inputs, schema: workflow.inputSchema)) { _, new in new }
        }
        let runID = try await client.start(workflowID: workflow.id, input: input, text: options.text)
        guard options.wait else {
            if options.json { printJSON(["run_id": runID, "status": "running"]) } else { print(runID) }
            return EXIT_SUCCESS
        }
        if !options.json { fputs("Running \(workflow.name) (\(runID))…\n", stderr) }
        let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDERR_FILENO) != 0
        let run = try await wait(for: runID, client: client, answerForms: interactive)
        if options.json { printJSON(run) } else { printRun(run) }
        return exitCode(for: run)
    }

    /// Polls until the run ends, answering forms in the terminal when
    /// `answerForms`; otherwise returns as soon as it waits on one. Past
    /// `deadline` it returns the run as it stands, still running.
    static func wait(
        for runID: String,
        client: WorkflowClient,
        answerForms: Bool,
        waitThroughForms: Bool = false,
        io: WorkflowFormPrompt.IO = .terminal,
        poll: Duration = .milliseconds(750),
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> [String: Any] {
        var lastAnswered: String?
        while true {
            let run = try await client.run(runID)
            let status = run["status"] as? String ?? ""
            if status == "awaiting_user" {
                guard answerForms || waitThroughForms else { return run }
                guard answerForms else {
                    if let deadline, ContinuousClock.now >= deadline { return run }
                    try await Task.sleep(for: poll)
                    continue
                }
                let dialog = run["pending_dialog"] as? [String: Any] ?? [:]
                let dialogID = dialog["id"] as? String
                if dialogID != nil, dialog["current"] as? Bool != false, dialogID != lastAnswered,
                    let nodeID = dialog["node_id"] as? String
                {
                    var issues: [String] = []
                    while true {
                        let values = WorkflowFormPrompt.ask(dialog, issues: issues, io: io)
                        switch try await client.answer(runID: runID, nodeID: nodeID, values: values) {
                        case .accepted, .gone, .queued:
                            issues = []
                        case .invalid(let problems):
                            issues = problems.isEmpty ? ["Osaurus did not accept those answers."] : problems
                        }
                        if issues.isEmpty { break }
                    }
                    lastAnswered = dialogID
                    continue
                }
            } else if status != "running" {
                return run
            }
            if let deadline, ContinuousClock.now >= deadline { return run }
            try await Task.sleep(for: poll)
        }
    }

    static func exitCode(for run: [String: Any]) -> Int32 {
        switch run["status"] as? String {
        case "completed": return EXIT_SUCCESS
        case "running": return EXIT_SUCCESS
        case "awaiting_user": return exitAwaitingInput
        default: return EXIT_FAILURE
        }
    }

    // MARK: - Output

    static func listJSON(_ workflow: WorkflowSummary) -> [String: Any] {
        var object: [String: Any] = [
            "id": workflow.id, "name": workflow.name, "tool_name": workflow.toolName,
            "input_schema": workflow.inputSchema, "needs_setup": workflow.needsSetup,
        ]
        if let summary = workflow.summary { object["summary"] = summary }
        if let setup = workflow.setupSummary { object["setup_summary"] = setup }
        return object
    }

    static func describeInputs(_ workflow: WorkflowSummary) -> String {
        let required = Set(workflow.requiredInputs)
        return workflow.inputProperties.keys.sorted { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }
            .map { key in
                let type = workflow.inputProperties[key]?["type"] as? String ?? "value"
                return required.contains(key) ? "\(key) (\(type))" : "[\(key) (\(type))]"
            }
            .joined(separator: ", ")
    }

    static func printRun(_ run: [String: Any]) {
        let status = run["status"] as? String ?? "unknown"
        let id = run["run_id"] as? String ?? ""
        switch status {
        case "completed":
            if let output = run["output"], !(output is NSNull) { print(render(output)) }
        case "awaiting_user":
            let title = (run["pending_dialog"] as? [String: Any])?["title"] as? String
            fputs(
                "Waiting for input\(title.map { " (\($0))" } ?? ""). Answer it in Osaurus, or run "
                    + "`osaurus workflow status \(id)` later.\n", stderr)
        case "running":
            print("Running. Check with `osaurus workflow status \(id)`.")
        default:
            var message = "Run \(status)"
            if let error = run["error"] as? [String: Any], let reason = error["reason"] as? String {
                message += ": \(reason)"
            } else if let error = run["error"] as? String {
                message += ": \(error)"
            }
            if let reasons = run["reasons"] as? [String], !reasons.isEmpty {
                message += "\n" + reasons.map { "  • \($0)" }.joined(separator: "\n")
            }
            fputs(message + "\n", stderr)
        }
    }

    /// A string output prints as text; anything else as pretty JSON.
    static func render(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let object = value as? [String: Any], object.count == 1, let text = object.values.first as? String {
            return text
        }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    static func printJSON(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}

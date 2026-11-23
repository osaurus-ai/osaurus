//
//  PythonCodeNodeExecutor.swift
//  osaurus
//
//  Python code steps. The source defines `def run(input, ctx)`; it runs
//  through `shell_run` inside the workflow's sandbox environment, where
//  the pip dependencies the workflow declares are installed, so there is
//  no Python runtime of Osaurus's own to keep in step. The step writes a
//  small bundle into the run workspace (which the host and the sandbox
//  share): the source, the input and the run context, runs a launcher
//  that imports the source, calls `run`, and writes the returned value to
//  `output.json`. The declared secrets ride in the exec environment, never
//  in the shared workspace, and the step reaches only the hosts it
//  declares (`SandboxStepScope`). The bundle is removed when the step
//  ends, whatever happened. Everything the code prints becomes the step's
//  log, with secret values scrubbed.
//

import Foundation

enum PythonCodeNodeExecutor {

    /// Where one attempt's files live, under the run workspace.
    static func bundleDirectory(workspace: URL, nodeID: String, attempt: Int) -> URL {
        workspace
            .appendingPathComponent(".osaurus", isDirectory: true)
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("\(Self.safe(nodeID))-\(attempt)", isDirectory: true)
    }

    private static func safe(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// The launcher: loads the bundle, exposes `ctx`, calls `run`, and
    /// writes the result. `print` goes to stderr so it lands in the log.
    static let launcher = """
        import asyncio, inspect, json, os, sys, importlib.util

        _dir = os.path.dirname(os.path.abspath(__file__))
        sys.path.insert(0, _dir)

        def _load(name, default=None):
            path = os.path.join(_dir, name)
            if not os.path.exists(path):
                return default
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)

        _input = _load("input.json", {})
        _ctx = _load("ctx.json", {})
        _secrets = json.loads(os.environ.pop("OSAURUS_STEP_SECRETS", "") or "{}")

        class _Secrets:
            def get(self, key):
                return _secrets.get(key)

        class _Ctx:
            def __init__(self, data):
                self.run = data.get("run") or {}
                self.caller = data.get("caller") or {}
                self.secrets = _Secrets()
                self.workspace = (self.run or {}).get("workspace")
            def log(self, *args):
                print(*args, file=sys.stderr)

        _stdout = sys.stdout
        sys.stdout = sys.stderr

        _spec = importlib.util.spec_from_file_location("osaurus_step", os.path.join(_dir, "step.py"))
        _module = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_module)
        if not hasattr(_module, "run"):
            print("step.py does not define run(input, ctx)", file=sys.stderr)
            sys.exit(3)

        _result = _module.run(_input, _Ctx(_ctx))
        if inspect.iscoroutine(_result):
            _result = asyncio.run(_result)
        if _result is None:
            _result = {}
        with open(os.path.join(_dir, "output.json"), "w", encoding="utf-8") as f:
            json.dump(_result, f, ensure_ascii=False)
        """

    static func run(spec: CodeSpec, context: WorkflowNodeContext) async throws -> WorkflowNodeOutcome {
        try await run(spec: spec, context: context, runtime: .live)
    }

    static func run(spec: CodeSpec, context: WorkflowNodeContext, runtime: ToolNodeExecutor.Runtime) async throws
        -> WorkflowNodeOutcome
    {
        let fm = FileManager.default
        let dir = bundleDirectory(workspace: context.workspace, nodeID: context.node.id, attempt: context.attempt)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func write(_ name: String, _ text: String) throws {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("step.py", spec.source)
        try write("main.py", launcher)
        try write("input.json", context.input.compactJSONString)
        try write(
            "ctx.json",
            JSONValue.object(["run": context.bindings.run, "caller": context.bindings.caller]).compactJSONString)
        let secrets = context.secrets.filter { spec.secrets.contains($0.key) }

        let timeout = min(spec.timeout, context.timeout).clampedInt(.up, in: 1...Int.max)
        let command = Self.guestCommand(
            main: dir.appendingPathComponent("main.py").path, timeoutSeconds: timeout,
            memoryLimitMB: spec.memoryLimitMB ?? Self.defaultMemoryLimitMB)
        let started = Date()
        let arguments: JSONValue = .object([
            "command": .string(command),
            "timeout": .number(Double(max(1, timeout))),
        ])
        let shell = WorkflowNode(
            id: context.node.id, name: context.node.name,
            kind: .tool(ToolNodeSpec(tool: ToolRef(name: "shell_run"))),
            input: .object(["command": command, "timeout": String(max(1, timeout))]), outputSchema: .object([:]))
        let shellContext = WorkflowNodeContext(
            runID: context.runID, workflowID: context.workflowID, workflowName: context.workflowName, node: shell,
            input: arguments, bindings: context.bindings, model: nil, secretAccounts: context.secretAccounts,
            caller: context.caller, workspace: context.workspace, folderRoot: context.folderRoot,
            sandbox: context.sandbox, grantedPaths: context.grantedPaths, writableRoots: context.writableRoots,
            hostFiles: context.hostFiles, permissionScope: context.permissionScope,
            requestFolderGrant: context.requestFolderGrant, attempt: context.attempt, timeout: context.timeout)
        let outcome: WorkflowNodeOutcome
        do {
            outcome = try await SandboxStepScope.$hosts.withValue(spec.network) {
                try await SandboxStepScope.$secrets.withValue(secrets) {
                    try await ToolNodeExecutor.run(
                        spec: ToolNodeSpec(tool: ToolRef(name: "shell_run")), context: shellContext, runtime: runtime)
                }
            }
        } catch let recorded as RecordedNodeFailure {
            // Non-zero exits come back as a success envelope; a failure
            // envelope here is the shell tool itself refusing or missing.
            throw recorded
        }

        let result = outcome.output.objectValue ?? [:]
        let stdout = result["stdout"]?.stringValue ?? ""
        let stderr = result["stderr"]?.stringValue ?? ""
        let exit = result["exit_code"]?.numberValue.map(Int.init) ?? 0
        var logs = Self.lines(stderr) + Self.lines(stdout)
        if Self.killedByTimeLimit(exitCode: exit), Date().timeIntervalSince(started) >= Double(timeout) - 0.5 {
            throw RecordedNodeFailure(
                underlying: CodeNodeError.scriptError(
                    message: L("Python ran past the step's \(timeout)-second limit and was stopped."), stack: stderr),
                toolCallRecords: outcome.toolCallRecords)
        }
        if exit != 0 {
            let last = logs.last ?? L("exit code \(exit)")
            throw RecordedNodeFailure(
                underlying: CodeNodeError.scriptError(message: L("Python exited with \(exit): \(last)"), stack: stderr),
                toolCallRecords: outcome.toolCallRecords)
        }
        let outputURL = dir.appendingPathComponent("output.json")
        guard let data = fm.contents(atPath: outputURL.path), let text = String(data: data, encoding: .utf8),
            let output = JSONValue.parse(text)
        else {
            throw RecordedNodeFailure(
                underlying: CodeNodeError.scriptError(
                    message: L("run() must return a JSON-serializable value; no output was written."), stack: stderr),
                toolCallRecords: outcome.toolCallRecords)
        }
        if logs.count > 200 {
            logs = Array(logs.prefix(100)) + [L("… \(logs.count - 200) lines omitted …")] + Array(logs.suffix(100))
        }
        return WorkflowNodeOutcome(
            output: Self.objectified(output), logs: logs, toolCalls: outcome.toolCalls,
            toolCallRecords: outcome.toolCallRecords)
    }

    /// Later nodes bind into the output by field, so scalars get one.
    static func objectified(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object, .array: return value
        case .null: return .object([:])
        case .string: return .object(["text": value])
        default: return .object(["value": value])
        }
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Address-space cap when the step sets none. Virtual, not resident:
    /// numeric libraries reserve far more than they touch, so this sits
    /// well above the JavaScript footprint default.
    static let defaultMemoryLimitMB = 2048

    /// Runs the launcher under the step's limits: an address-space cap,
    /// so a runaway step gets `MemoryError` instead of exhausting the VM
    /// every other agent shares, and a wall clock that kills it outright.
    /// The guest has `timeout`; on the macOS host `ulimit -v` is refused
    /// (and ignored) and `perl` arms the alarm.
    static func guestCommand(main: String, timeoutSeconds: Int, memoryLimitMB: Int) -> String {
        let python = "python3 " + quoted(main)
        return "ulimit -v \(max(16, memoryLimitMB) * 1024) 2>/dev/null; "
            + "if command -v timeout >/dev/null 2>&1; then exec timeout -s KILL \(timeoutSeconds) \(python); "
            + "elif command -v perl >/dev/null 2>&1; then exec perl -e 'alarm shift; exec @ARGV' \(timeoutSeconds) \(python); "
            + "else exec \(python); fi"
    }

    /// SIGKILL from `timeout -s KILL`, or SIGALRM from the perl alarm.
    static func killedByTimeLimit(exitCode: Int) -> Bool {
        exitCode == 128 + 9 || exitCode == 128 + 14 || exitCode == -9 || exitCode == -14
    }

    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

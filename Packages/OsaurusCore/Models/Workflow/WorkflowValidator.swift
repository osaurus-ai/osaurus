//
//  WorkflowValidator.swift
//  osaurus
//
//  Graph, schema, and binding checks for a workflow definition. A saved
//  template must pass with no issues; a draft may still carry planned
//  placeholders (`allowPlaceholders`), and must pass the strict check
//  (`workflow_draft` `get`) before it may test.
//
//  Rules:
//   - node ids are unique slugs; edges name existing nodes; no self-loops;
//   - the graph is acyclic (V1 allows no cycles);
//   - a binding may reference `input` and nodes upstream of its node; the
//     workflow output may reference any node;
//   - every schema is well-formed; every node kind's spec is complete.
//

import Foundation

public struct WorkflowIssue: Equatable, Sendable, Codable {
    public var nodeID: String?
    public var message: String

    public init(nodeID: String? = nil, _ message: String) {
        self.nodeID = nodeID
        self.message = nodeID.map { "\($0): \(message)" } ?? message
    }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case message
    }
}

public enum WorkflowValidator {

    private static let idAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Things that do not block a save but change how the workflow
    /// behaves: a `reply` inside a `map` posts once per item, up to the
    /// per-run reply cap. With `toolOutputSchema` (the schema a tool
    /// publishes, by name), also the tool steps whose output later steps
    /// read without knowing its shape, or by a field it does not have.
    public static func warnings(
        _ def: WorkflowDefinition, toolOutputSchema: ((String) -> JSONValue?)? = nil
    ) -> [WorkflowIssue] {
        let toolOutputs = toolOutputSchema.map { toolOutputWarnings(def, published: $0) } ?? []
        let mapReplies: [WorkflowIssue] = def.nodes.compactMap { node in
            guard case .map(let spec) = node.kind, spec.stepDecodingIssue() == nil,
                case .reply = spec.body(parentID: node.id).kind
            else { return nil }
            return WorkflowIssue(
                nodeID: node.id,
                "map step replies once per item; a run posts at most \(ReplySpec.maximumRepliesPerRun) replies, "
                    + "after which a reply is skipped with `reason: reply_cap`. Reply once after the map to post "
                    + "everything together.")
        }
        let bypassed: [WorkflowIssue] = def.nodes.compactMap { node in
            guard node.mode == .bypass else { return nil }
            if node.bypassPassesData {
                return WorkflowIssue(nodeID: node.id, "is bypassed: it does not run and hands its input on unchanged")
            }
            return WorkflowIssue(
                nodeID: node.id,
                "is bypassed and has nothing to hand on, so steps that bind its output get empty values; "
                    + "remove `mode: \"bypass\"` or bypass the steps after it too")
        }
        return mapReplies + bypassed + toolOutputs
    }

    private static func toolOutputWarnings(
        _ def: WorkflowDefinition, published: (String) -> JSONValue?
    ) -> [WorkflowIssue] {
        let readers = outputReaders(def)
        var out: [WorkflowIssue] = []
        for node in def.nodes {
            guard let tool = node.toolRef?.name, let reads = readers[node.id], let first = reads.first else { continue }
            let publishedSchema = published(tool)
            if node.outputSchema.isEmptySchema, publishedSchema?.isEmptySchema ?? true {
                out.append(
                    WorkflowIssue(
                        nodeID: node.id,
                        "`\(tool)` publishes no output schema and this step's `output_schema` is {}, so nothing "
                            + "checks the fields later steps read (\(first.reader) reads `{{\(first.ref)}}`). Test "
                            + "the step, then declare the fields it really returns in `output_schema`"))
                continue
            }
            let schema = node.effectiveOutputSchema(toolOutputSchema: publishedSchema)
            var reported = Set<String>()
            for read in reads where reported.insert(read.ref).inserted {
                guard let miss = missingField(read.path, in: schema) else { continue }
                let known = miss.known.prefix(8).joined(separator: ", ") + (miss.known.count > 8 ? ", …" : "")
                out.append(
                    WorkflowIssue(
                        nodeID: node.id,
                        "\(read.reader) reads `{{\(read.ref)}}`, but `\(tool)` returns no `\(miss.field)` field "
                            + "there (it has: \(known)), so the binding is empty"))
            }
        }
        return out
    }

    private struct OutputRead {
        var reader: String
        var ref: String
        var path: [String]
    }

    /// Every `{{nodes.<id>.output…}}` read, by the node read, with who reads it.
    private static func outputReaders(_ def: WorkflowDefinition) -> [String: [OutputRead]] {
        var readers: [String: [OutputRead]] = [:]
        func collect(_ value: JSONValue?, reader: String) {
            for ref in bindingStrings(in: value).flatMap(BindingRenderer.references(in:)) {
                guard case .node(let id, let path)? = BindingRenderer.parse(reference: ref) else { continue }
                let segments = path.split(separator: ".").map(String.init)
                readers[id, default: []].append(OutputRead(reader: reader, ref: ref, path: segments))
            }
        }
        for node in def.nodes { collect(encoded(node), reader: "`\(node.id)`") }
        for edge in def.edges { collect(encoded(edge), reader: "the edge \(edge.from) -> \(edge.to)") }
        collect(encoded(def.output), reader: "the workflow output")
        return readers
    }

    private static func encoded<T: Encodable>(_ value: T) -> JSONValue? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }.flatMap(JSONValue.parse)
    }

    /// The strings a binding may sit in; schemas are skipped.
    private static func bindingStrings(in value: JSONValue?) -> [String] {
        switch value {
        case .string(let s)?: return [s]
        case .array(let items)?: return items.flatMap { bindingStrings(in: $0) }
        case .object(let fields)?:
            return fields.filter { $0.key != "output_schema" }.values.flatMap { bindingStrings(in: $0) }
        default: return []
        }
    }

    /// The first segment of `path` that `schema` lists no field for, with
    /// the fields it does list. Nil when the path is there or the schema
    /// leaves that level open.
    private static func missingField(_ path: [String], in schema: JSONValue) -> (field: String, known: [String])? {
        var current = schema
        for segment in path {
            let o = current.objectValue
            if let properties = o?["properties"]?.objectValue, !properties.isEmpty {
                guard let next = properties[segment] else { return (segment, properties.keys.sorted()) }
                current = next
            } else if o?["type"]?.stringValue == "array", Int(segment) != nil, let items = o?["items"] {
                current = items
            } else {
                return nil
            }
        }
        return nil
    }

    /// `checkSandboxCommands` adds the shell-command checks of
    /// `sandboxCommandIssues`. Runs and imports pass false: a saved command
    /// that uses a macOS program still runs on a Mac whose sandbox is
    /// Seatbelt, so only drafts are held to the Linux sandbox.
    public static func validate(
        _ def: WorkflowDefinition, allowPlaceholders: Bool, checkSandboxCommands: Bool = true
    ) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []

        issues += JSONSchemaValidator.schemaIssues(def.inputSchema).map { WorkflowIssue("input_schema \($0)") }
        issues += JSONSchemaValidator.schemaIssues(def.outputSchema).map { WorkflowIssue("output_schema \($0)") }

        var seen = Set<String>()
        for node in def.nodes {
            if node.id.isEmpty || node.id.unicodeScalars.contains(where: { !idAllowed.contains($0) }) {
                issues.append(WorkflowIssue(nodeID: node.id, "id must be a lowercase slug (a-z, 0-9, _ or -)"))
            }
            if !seen.insert(node.id).inserted {
                issues.append(WorkflowIssue(nodeID: node.id, "duplicate node id"))
            }
        }
        if def.nodes.isEmpty {
            issues.append(WorkflowIssue("the workflow has no nodes"))
        }

        let ids = Set(def.nodes.map(\.id))
        var edgeSet = Set<String>()
        for edge in def.edges {
            if !ids.contains(edge.from) { issues.append(WorkflowIssue("edge from unknown node `\(edge.from)`")) }
            if !ids.contains(edge.to) { issues.append(WorkflowIssue("edge to unknown node `\(edge.to)`")) }
            if edge.from == edge.to { issues.append(WorkflowIssue(nodeID: edge.from, "edge to itself")) }
            if !edgeSet.insert("\(edge.from)->\(edge.to)").inserted {
                issues.append(WorkflowIssue("duplicate edge \(edge.from) -> \(edge.to)"))
            }
            if let when = edge.when {
                issues += when.issues.map { WorkflowIssue("edge \(edge.from) -> \(edge.to) `when`: \($0)") }
            }
            if edge.on == .error, let from = def.node(edge.from), from.onError != .continue {
                issues.append(
                    WorkflowIssue(
                        nodeID: edge.from,
                        "has an edge with `on: \"error\"` to `\(edge.to)`, so its `on_error` must be \"continue\""))
            }
        }

        // Graph order is undefined while ids repeat; upstream checks wait
        // until the ids are fixed.
        let uniqueIDs = ids.count == def.nodes.count
        let order = uniqueIDs ? topologicalOrder(def) : nil
        if uniqueIDs, order == nil {
            issues.append(WorkflowIssue("the graph has a cycle; workflows must be acyclic"))
        }
        let ancestors = order == nil ? nil : ancestorMap(def)

        for node in def.nodes {
            issues += validateNode(
                node, def: def, ancestors: ancestors.map { $0[node.id] ?? [] }, allowPlaceholders: allowPlaceholders)
        }

        for ref in def.output.references {
            switch BindingRenderer.parse(reference: ref) {
            case .input?, .run?, .caller?:
                break
            case .item?, .index?:
                issues.append(WorkflowIssue("output references `{{\(ref)}}`, which only a map step's item may use"))
            case .folder(let key)?:
                if !def.folders.contains(where: { $0.key == key }) {
                    issues.append(WorkflowIssue("output references folder `\(key)`, which is not declared"))
                }
            case .node(let id, _)?:
                if !ids.contains(id) { issues.append(WorkflowIssue("output references unknown node `\(id)`")) }
            case nil:
                issues.append(WorkflowIssue("output has an invalid reference `{{\(ref)}}`"))
            }
        }
        issues += dependencyIssues(def, allowPlaceholders: allowPlaceholders)
        if checkSandboxCommands { issues += sandboxCommandIssues(def) }
        issues += folderIssues(def)
        issues += secretIssues(def)
        issues += def.modelSlots.compactMap { slot in
            guard slot.strictness == .always, slot.requiredModel == nil else { return nil }
            return WorkflowIssue(
                "slot `\(slot.slot)` is `always` but names no `preferred` model; name the model it requires, or make it `preferred`")
        }
        return issues
    }

    private static func secretIssues(_ def: WorkflowDefinition) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []
        var keys = Set<String>()
        for secret in def.secrets {
            if secret.key.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(WorkflowIssue("a declared secret has no key"))
                continue
            }
            if !keys.insert(secret.key).inserted {
                issues.append(WorkflowIssue("secrets list `\(secret.key)` more than once; declare each secret once"))
            }
            if let oauth2 = secret.oauth2 {
                issues += oauth2.problems.map { WorkflowIssue("secret `\(secret.key)` oauth2: \($0)") }
            }
        }
        return issues
    }

    private static func folderIssues(_ def: WorkflowDefinition) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []
        var keys = Set<String>()
        for folder in def.folders {
            if !keys.insert(folder.key).inserted {
                issues.append(WorkflowIssue("folders list `\(folder.key)` more than once; declare each folder once"))
            }
            issues += folder.issues.map { WorkflowIssue($0) }
        }
        return issues
    }

    /// A path on the author's Mac written into a step: it will not exist
    /// on another Mac and is outside the run's folders on this one.
    static func isMachinePathLiteral(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/Users/") || trimmed == "~" || trimmed.hasPrefix("~/")
    }

    /// Install commands a shell step must not carry: the package belongs
    /// in `declare_dependency`, where setup installs it once and verifies it.
    static let installCommandPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"(?:^|[\s;&|(])(?:pip3?\s+install|python3?\s+-m\s+pip\s+install|npm\s+(?:install|i|add)|yarn\s+add|pnpm\s+add|apk\s+add|brew\s+install|apt(?:-get)?\s+install|uv\s+pip\s+install)\b"#
    )

    static func containsInstallCommand(_ command: String) -> Bool {
        installCommandPattern.firstMatch(
            in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    /// Programs only macOS has. Shell steps run in the workflow's Linux
    /// sandbox, where none of them exist.
    static let macOnlyPrograms = [
        "qlmanage", "sips", "osascript", "textutil", "mdfind", "mdls", "pbcopy", "pbpaste", "screencapture",
        "afconvert", "afplay", "plutil", "defaults", "diskutil", "launchctl", "open",
    ]

    /// One of `macOnlyPrograms` where a command starts: the start of a line,
    /// after `;`, `&`, `|`, `(`, `$(` or a backtick, or after a word that
    /// runs the next one (`do`, `then`, `xargs`, `-exec` …).
    static let macOnlyProgramPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"(?:^|[;&|(`]|\b(?:do|then|else|xargs|exec|env|sudo|nohup|time)\s|-exec\s)\s*"#
            + #"(?:/usr/bin/|/usr/sbin/|/bin/|/sbin/)?("# + macOnlyPrograms.joined(separator: "|")
            + #")(?=$|[\s;&|)`])"#,
        options: [.anchorsMatchLines]
    )

    /// The macOS-only program `command` runs, if any.
    static func macOnlyProgram(in command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        guard let match = macOnlyProgramPattern.firstMatch(in: command, range: range),
            let program = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[program])
    }

    /// A folder on this Mac spelled out in a command (`/Users/…`,
    /// `/Volumes/…`). `~` is left alone: in the sandbox it is the
    /// workflow's own home.
    static let machinePathInCommandPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"(?:^|[\s"'=:(])((?:/Users|/Volumes)/[^\s"';|&)]*)"#,
        options: [.anchorsMatchLines]
    )

    static func machinePath(inCommand command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        guard let match = machinePathInCommandPattern.firstMatch(in: command, range: range),
            let path = Range(match.range(at: 1), in: command)
        else { return nil }
        return String(command[path])
    }

    /// Shell commands that cannot work in the workflow's Linux sandbox: a
    /// macOS program, a folder on this Mac, or a folder the person picks
    /// or binds, none of which the sandbox can see.
    static func sandboxCommandIssues(_ def: WorkflowDefinition) -> [WorkflowIssue] {
        let pathFields = Set(
            WorkflowFormFields.fields(fromInputSchema: def.inputSchema)
                .filter { $0.type == .folder || $0.type == .file }.map(\.key))
        var issues: [WorkflowIssue] = []
        for (node, command) in def.shellSteps {
            guard let command else { continue }
            if let program = macOnlyProgram(in: command) {
                issues.append(
                    WorkflowIssue(
                        nodeID: node.id,
                        "runs `\(program)`, a macOS program, but shell steps run in the workflow's Linux sandbox, "
                            + "where it does not exist; use a Linux program and declare it with `declare_dependency`"))
            }
            if let path = machinePath(inCommand: command) {
                issues.append(
                    WorkflowIssue(
                        nodeID: node.id,
                        "names a folder on this Mac in its command (`\(path)`), which the sandbox cannot see; ask "
                            + "for the folder with a `folder` input field or `declare_folder`, copy its files into "
                            + "the run workspace with `file_copy`, and use relative paths in the command"))
            }
            let hostRefs = BindingRenderer.references(in: command).filter { ref in
                switch BindingRenderer.parse(reference: ref) {
                case .folder?: return true
                case .input(let path)?:
                    return path.split(separator: ".").first.map { pathFields.contains(String($0)) } ?? false
                default: return false
                }
            }
            if let ref = hostRefs.first {
                issues.append(
                    WorkflowIssue(
                        nodeID: node.id,
                        "passes `{{\(ref)}}` to its command, but the command runs in the workflow's sandbox, which "
                            + "sees only the run workspace (`{{run.workspace}}`), not folders on this Mac; copy the "
                            + "files into the run workspace first (a `file_search` step, then a `map` of "
                            + "`file_copy`), use relative paths in the command, and copy results back with "
                            + "`file_copy`"))
            }
        }
        return issues
    }

    private static func dependencyIssues(_ def: WorkflowDefinition, allowPlaceholders: Bool) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []
        var managers = Set<WorkflowDependency.Manager>()
        for dep in def.dependencies {
            if !managers.insert(dep.manager).inserted {
                issues.append(WorkflowIssue("dependencies list `\(dep.manager.rawValue)` more than once; declare each manager once"))
            }
            issues += dep.issues.map { WorkflowIssue($0) }
        }
        let shellSteps = def.shellSteps
        // While drafting the step may simply not be written yet.
        if !def.dependencies.isEmpty, shellSteps.isEmpty, !def.nodes.contains(where: \.needsSandbox),
            !allowPlaceholders
        {
            issues.append(
                WorkflowIssue(
                    "dependencies are declared but no step calls `shell_run` or runs Python; only those use them"))
        }
        for (node, command) in shellSteps {
            if let command, containsInstallCommand(command) {
                issues.append(
                    WorkflowIssue(
                        nodeID: node.id,
                        "installs a package in its command; declare it with `declare_dependency` instead so setup "
                            + "installs it once into the workflow's sandbox"))
            }
        }
        return issues
    }

    private static func validateNode(
        _ node: WorkflowNode, def: WorkflowDefinition, ancestors: Set<String>?, allowPlaceholders: Bool,
        inMapBody: Bool = false
    ) -> [WorkflowIssue] {
        var issues: [WorkflowIssue] = []
        func add(_ message: String) { issues.append(WorkflowIssue(nodeID: node.id, message)) }

        var refs = node.input.references
        if !(node.timeout > 0) {
            add("timeout must be positive")
        } else if !node.timeout.isFinite {
            add("timeout must be a finite number")
        }
        if inMapBody {
            if node.onError != .fail { add("a map step's item uses `on_item_error` on the map, not `on_error`") }
            if node.join != .any { add("a map step's item has no incoming edges; drop `join`") }
        }

        switch node.kind {
        case nil:
            if inMapBody {
                add("map needs its `step` filled in")
            } else if !allowPlaceholders {
                add("is still a planned placeholder; fill it in before saving")
            }
            return issues
        case .wait(let spec):
            let hasSeconds = !(spec.seconds ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let hasUntil = !(spec.until ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            if hasSeconds == hasUntil { add("wait needs exactly one of `seconds` or `until`") }
            if let seconds = spec.seconds {
                refs += BindingRenderer.references(in: seconds)
                if BindingRenderer.references(in: seconds).isEmpty {
                    if let n = Double(seconds.trimmingCharacters(in: .whitespaces)), !n.isNaN {
                        if n < 0 { add("wait `seconds` must not be negative") }
                        if n > WaitSpec.maximumSeconds { add("wait `seconds` must be at most \(Int(WaitSpec.maximumSeconds))") }
                        if node.timeout > 0, node.timeout < n {
                            add("timeout (\(node.timeout.clampedInt())s) is shorter than the wait itself; raise it")
                        }
                    } else {
                        add("wait `seconds` must be a number or a binding")
                    }
                }
            }
            if let until = spec.until {
                refs += BindingRenderer.references(in: until)
                if BindingRenderer.references(in: until).isEmpty, WorkflowCondition.date(.string(until)) == nil {
                    add("wait `until` must be an ISO 8601 date-time such as 2026-03-01T09:00:00Z, or a binding")
                }
            }
        case .map(let spec):
            if spec.items.trimmingCharacters(in: .whitespaces).isEmpty { add("map needs `items`: a binding to a list") }
            refs += BindingRenderer.references(in: spec.items)
            if BindingRenderer.references(in: spec.items).isEmpty { add("map `items` must be a binding such as {{nodes.search.output.entries}}") }
            if spec.concurrency > MapSpec.maximumConcurrency { add("map `concurrency` must be at most \(MapSpec.maximumConcurrency)") }
            if let problem = spec.stepDecodingIssue() {
                add(problem)
            } else {
                let body = spec.body(parentID: node.id)
                if case .map = body.kind { add("a map step cannot contain another map; flatten the list first") }
                if case .dialog = body.kind { add("a map step cannot ask the person once per item; ask before the map instead") }
                if case .agent = body.kind {
                    add("a map step cannot hand each item to an agent; give the agent the whole list in one step instead")
                }
                var bodyIssues = validateNode(
                    body, def: def, ancestors: ancestors, allowPlaceholders: false, inMapBody: true)
                for i in bodyIssues.indices {
                    bodyIssues[i].nodeID = node.id
                    bodyIssues[i].message = bodyIssues[i].message.replacingOccurrences(of: "\(body.id): ", with: "\(node.id): step ")
                }
                issues += bodyIssues
            }
            issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
        case .workflow(let spec):
            if spec.workflow.trimmingCharacters(in: .whitespaces).isEmpty { add("workflow needs the name of an installed workflow") }
            issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
        case .agent(let spec):
            if spec.agent.trimmingCharacters(in: .whitespaces).isEmpty { add("agent needs the name of the agent to ask") }
            if spec.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("agent needs a `task`: what to ask it") }
            if let ref = spec.workspace {
                if ref.workspaceId.trimmingCharacters(in: .whitespaces).isEmpty {
                    add("agent `workspace.workspace_id` is empty")
                }
                if !WorkspaceAgentRef.looksLikeAddress(ref.agentAddress) {
                    add("agent `workspace.agent_address` must be the shared agent's 0x address")
                }
            }
            refs += BindingRenderer.references(in: spec.task)
            issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
        case .state(let spec):
            let needsKey: Bool
            switch spec.action {
            case .get, .set, .increment, .delete: needsKey = true
            case .list, .clear: needsKey = false
            }
            let key = (spec.key ?? "").trimmingCharacters(in: .whitespaces)
            if needsKey, key.isEmpty { add("state `\(spec.action.rawValue)` needs a `key`") }
            if !needsKey, !key.isEmpty { add("state `\(spec.action.rawValue)` works on a whole table; drop `key`") }
            if let table = spec.table {
                let t = table.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.count > WorkflowStateStore.maximumNameLength || t.contains("\n") {
                    add("state `table` must be 1 to \(WorkflowStateStore.maximumNameLength) characters on one line")
                }
                refs += BindingRenderer.references(in: table)
            }
            if key.count > WorkflowStateStore.maximumNameLength || key.contains("\n") {
                add("state `key` must be at most \(WorkflowStateStore.maximumNameLength) characters on one line")
            }
            refs += BindingRenderer.references(in: key)
            if spec.action == .set {
                if let value = spec.value {
                    refs += BindingRenderer.references(in: value)
                } else {
                    add("state `set` needs a `value`")
                }
            } else if spec.value != nil {
                add("state `\(spec.action.rawValue)` does not take a `value`")
            }
            if let by = spec.by {
                if spec.action != .increment { add("state `by` applies to `increment` only") }
                refs += BindingRenderer.references(in: by)
                if BindingRenderer.references(in: by).isEmpty, Double(by.trimmingCharacters(in: .whitespaces)) == nil {
                    add("state `by` must be a number or a binding")
                }
            }
            if let limit = spec.limit {
                if spec.action != .list { add("state `limit` applies to `list` only") }
                if limit < 1 || limit > StateSpec.maximumListLimit { add("state `limit` must be between 1 and \(StateSpec.maximumListLimit)") }
            }
        case .http(let spec):
            if !HTTPNodeExecutor.allowedMethods.contains(spec.method) {
                add("http `method` must be one of \(HTTPNodeExecutor.allowedMethods.sorted().joined(separator: ", "))")
            }
            let url = spec.url.trimmingCharacters(in: .whitespaces)
            if url.isEmpty {
                add("http needs a `url`")
            } else if !url.lowercased().hasPrefix("https://") && !url.lowercased().hasPrefix("http://") && !url.hasPrefix("{{") {
                add("http `url` must start with https:// (or http:// for localhost)")
            } else if spec.literalHost == nil, spec.allowedHosts.isEmpty {
                add("http `url` binds its host, so list the hosts it may reach in `allowed_hosts`")
            }
            if let host = spec.literalHost, url.lowercased().hasPrefix("http://"), host != "localhost", host != "127.0.0.1" {
                add("http uses plain http:// to `\(host)`; use https:// (plain http is for localhost only)")
            }
            for host in spec.allowedHosts where !isPlainHost(host) {
                add("`allowed_hosts` entry `\(host)` must be a bare host name, like api.example.com")
            }
            let literalHosts = [spec.literalHost].compactMap { $0 } + spec.allowedHosts
            for host in literalHosts where !HTTPNodeExecutor.localHosts.contains(host.lowercased()) {
                if let probe = URL(string: "https://\(host)/"), PluginHostContext.checkSSRF(url: probe) != nil {
                    add("http may not reach `\(host)`: private, link-local, and metadata addresses are blocked (localhost is allowed)")
                }
            }
            refs += BindingRenderer.references(in: spec.url)
            for (name, value) in spec.headers {
                let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
                if lowered.isEmpty { add("http has a header with no name") }
                refs += BindingRenderer.references(in: value)
                if HTTPSpec.credentialHeaderNames.contains(lowered) {
                    add(
                        "http sets the `\(name)` header directly; use `auth` instead so the value comes from a declared "
                            + "secret and never appears in the template or in run records")
                } else if HTTPSpec.looksLikePastedCredential(value) {
                    add(
                        "http header `\(name)` holds what looks like a pasted credential; declare a secret and use `auth` "
                            + "(or bind the value) instead of writing it into the workflow")
                }
            }
            for (name, value) in spec.query {
                if name.trimmingCharacters(in: .whitespaces).isEmpty { add("http has a query parameter with no name") }
                refs += BindingRenderer.references(in: value)
                if HTTPSpec.looksLikePastedCredential(value) {
                    add(
                        "http query parameter `\(name)` holds what looks like a pasted credential; declare a secret and use "
                            + "`auth: {type: \"query\", …}` instead")
                }
            }
            if let body = spec.body { refs += body.references }
            for key in spec.secretKeys where key.trimmingCharacters(in: .whitespaces).isEmpty {
                add("http `auth` names an empty secret key")
            }
            if let paginate = spec.paginate {
                for issue in paginate.issues { add("http \(issue)") }
                if spec.response == .text { add("http `paginate` needs a JSON response (`response: json`)") }
                if spec.method != "GET" && spec.method != "POST" { add("http `paginate` works with GET or POST") }
            }
            issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
        case .inference(let spec):
            if spec.modelSlot.trimmingCharacters(in: .whitespaces).isEmpty { add("inference needs a model_slot") }
            if spec.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("inference needs instructions") }
            refs += BindingRenderer.references(in: spec.instructions)
            switch spec.mode {
            case .generate:
                issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
            case .decide(let options):
                if options.isEmpty { add("decide needs at least one option") }
                if Set(options).count != options.count { add("decide options must be unique") }
                for edge in def.edges where edge.from == node.id {
                    if let when = edge.when, when.path == "choice", when.op == .equals,
                        let v = when.value?.stringValue, !options.contains(v)
                    {
                        issues.append(WorkflowIssue(nodeID: node.id, "edge to `\(edge.to)` branches on `\(v)`, which is not an option"))
                    }
                }
            case .agentic(let tools, let maxSteps):
                if tools.isEmpty { add("agentic needs at least one tool") }
                for tool in tools { if let issue = excludedToolIssue(tool.name) { add(issue) } }
                // The executor's ceiling is the bound: a larger value would
                // be accepted and then silently clamped.
                if maxSteps < 1 || maxSteps > AgenticNodeExecutor.stepCeiling {
                    add("agentic max_steps must be between 1 and \(AgenticNodeExecutor.stepCeiling)")
                }
                issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
            }
        case .dialog(let spec):
            if spec.fields.isEmpty { add("dialog needs at least one field") }
            var keys = Set<String>()
            for field in spec.fields {
                if field.key.isEmpty { add("dialog field needs a key") }
                if !keys.insert(field.key).inserted { add("duplicate dialog field `\(field.key)`") }
                if field.type == .choice, (field.options ?? []).isEmpty { add("choice field `\(field.key)` needs options") }
            }
            if let expiresAfter = spec.expiresAfter, !(expiresAfter > 0 && expiresAfter.isFinite) {
                add("dialog `expires_after` must be a positive number of seconds; leave it out to wait for an answer")
            }
            refs += BindingRenderer.references(in: spec.message)
            refs += BindingRenderer.references(in: spec.title)
        case .reply(let spec):
            if !spec.hasText && !spec.hasFile { add("reply needs `text`, a `file`, or both") }
            if spec.caption != nil && !spec.hasFile { add("reply `caption` goes with a `file`; put the words in `text`") }
            if let file = spec.file, isMachinePathLiteral(file) {
                add(
                    "reply `file` names a file on this Mac (`\(file)`); point it at a file the run wrote, such as "
                        + "{{nodes.<id>.output.path}}")
            }
            refs += BindingRenderer.references(in: spec.text)
            refs += BindingRenderer.references(in: spec.file ?? "")
            refs += BindingRenderer.references(in: spec.caption ?? "")
        case .media(let spec):
            for message in mediaIssues(spec, node: node, def: def) { add(message) }
            refs += spec.templates.flatMap(BindingRenderer.references(in:))
            issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
        case .code(let spec):
            switch spec.language {
            case .javascript:
                if !spec.source.contains("function run") { add("code must define `async function run(input, ctx)`") }
            case .python:
                if !spec.source.contains("def run") { add("python code must define `def run(input, ctx)`") }
                if !spec.network.isEmpty { add("python code reaches the network through the sandbox; `network` applies to JavaScript only") }
            }
            if !(spec.timeout > 0) {
                add("code timeout must be positive")
            } else if !spec.timeout.isFinite {
                add("code timeout must be a finite number")
            }
            if let mb = spec.memoryLimitMB, mb < 16 { add("code memory_limit_mb must be at least 16") }
            for host in spec.network where !isPlainHost(host) {
                add("network allowlist entry `\(host)` must be a bare host name, like api.example.com")
            }
            issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
        case .tool(let spec):
            let name = spec.tool.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                add("tool needs a tool name")
            } else if let issue = excludedToolIssue(name) {
                add(issue)
            }
            let literals: [(String, String)]
            switch node.input {
            case .template(let text): literals = [("input", text)]
            case .object, .values:
                let fields = node.input.fieldTemplates ?? [:]
                literals = fields.keys.sorted().map { ($0, fields[$0] ?? "") }
            }
            for (field, value) in literals where isMachinePathLiteral(value) {
                add(
                    "`\(field)` names a folder on this Mac (`\(value)`); declare it with `declare_folder` and use "
                        + "{{folders.<key>}}, or ask for it with a folder input field")
            }
            issues += JSONSchemaValidator.schemaIssues(node.outputSchema).map { WorkflowIssue(nodeID: node.id, "output_schema \($0)") }
        }

        for ref in refs {
            switch BindingRenderer.parse(reference: ref) {
            case .input?, .run?, .caller?:
                break
            case .item?, .index?:
                if !inMapBody { add("references `{{\(ref)}}`, which only a map step's item may use") }
            case .folder(let key)?:
                if !def.folders.contains(where: { $0.key == key }) {
                    add("references folder `\(key)`, which is not declared; declare it with `declare_folder`")
                }
            case .node(let id, _)?:
                // A map body is named `<parent>.item`; its parent is the node whose ancestors apply.
                let selfID = inMapBody ? String(node.id.dropLast(".item".count)) : node.id
                if id == selfID || id == node.id {
                    add("references its own output")
                } else if let ancestors, !ancestors.contains(id) {
                    add("references `\(id)`, which is not upstream of it")
                }
            case nil:
                add(
                    "invalid reference `{{\(ref)}}`; use {{input.x}}, {{nodes.<id>.output.x}}, {{run.id}}, "
                        + "{{run.workspace}}, {{caller.kind}}, {{caller.agent_id}}, {{caller.agent_name}}, "
                        + "{{folders.<key>}}, or inside a map step {{item}} and {{index}}")
            }
        }
        return issues
    }

    /// Workflow and Architect tools. V1 workflows cannot call workflows.
    static func isWorkflowTool(_ name: String) -> Bool {
        name.hasPrefix(WorkflowTool.namePrefix) || name == RunWorkflowTool.toolName
            || name == ArchitectHandoffTool.toolName || ToolRegistry.architectToolNames.contains(name)
    }

    /// Tools that steer an agent loop rather than compute from their
    /// arguments: they need a running chat turn to mean anything.
    static let agentLoopControlToolNames: Set<String> = [
        "todo", "complete", "clarify", "speak", "spawn_agent", PromptWorkingFolderTool.toolName,
    ]

    /// Tools no tool or agentic node may call: workflow and Architect tools
    /// (no recursion), capability loaders, and agent-loop control. Every
    /// other registered tool is a valid step.
    static func isExcludedFromWorkflows(_ name: String) -> Bool {
        isWorkflowTool(name) || ToolRegistry.capabilityToolNames.contains(name)
            || agentLoopControlToolNames.contains(name) || ToolRegistry.agentCreationToolNames.contains(name)
    }

    private static func excludedToolIssue(_ name: String) -> String? {
        if isWorkflowTool(name) {
            return "`\(name)` is a workflow tool; to run another workflow, use a `workflow` node with its name"
        }
        if isExcludedFromWorkflows(name) {
            return "`\(name)` steers an agent's chat turn and cannot run as a workflow step"
        }
        return nil
    }

    /// A media step's spec, checked against what the action can take.
    static func mediaIssues(_ spec: MediaSpec, node: WorkflowNode, def: WorkflowDefinition) -> [String] {
        var out: [String] = []
        let action = spec.action.rawValue
        let overrides: Set<String>
        switch node.input {
        case .object, .values:
            let keys = node.input.fieldNames
            overrides = keys
            for key in keys.sorted() where !MediaSpec.overridableKeys.contains(key) {
                out.append(
                    "media `input` key `\(key)` is not a media parameter; use one of "
                        + MediaSpec.overridableKeys.sorted().joined(separator: ", "))
            }
        case .template(let text):
            overrides = []
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("media `input` must be an object of parameter overrides, like {\"seed\": \"{{item}}\"}")
            }
        }

        if spec.action.usesPrompt, spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !overrides.contains("prompt")
        {
            out.append("media `\(action)` needs a `prompt`")
        }
        if spec.action.usesSources {
            if spec.sources.isEmpty, !overrides.contains("sources") {
                out.append("media `\(action)` needs `sources`: the image(s) to work on, e.g. {{nodes.gen.output.images}}")
            }
            if spec.action == .upscale, spec.sources.count > 1 { out.append("media `upscale` takes one source image") }
            if spec.sources.count > MediaSpec.maximumSources {
                out.append("media `edit` takes at most \(MediaSpec.maximumSources) source images")
            }
        } else if spec.action == .generate, !spec.sources.isEmpty {
            out.append("media `generate` makes a new image from the prompt; use `edit` to change source images")
        }
        if spec.action == .video, spec.sources.count > 1 { out.append("media `video` takes at most one source image") }
        for source in spec.sources {
            if isMachinePathLiteral(source) {
                out.append(
                    "media `sources` names a file on this Mac (`\(source)`); bind a file the run made or the "
                        + "person picked, such as {{nodes.<id>.output.images}} or {{input.photo}}")
                continue
            }
            let type = BindingTypeResolver.type(ofTemplate: source, in: def)
            if !type.canFeedImageSource {
                out.append("media `sources` binds `\(source.trimmingCharacters(in: .whitespaces))`, which is a \(type.rawValue), not an image")
            }
        }

        switch (spec.action, spec.model.locality) {
        case (.edit, .remote), (.upscale, .remote):
            out.append("media `\(action)` runs on this Mac; set the model's `locality` to \"local\" or \"any\"")
        default: break
        }

        func range<T: Comparable>(_ name: String, _ value: T?, _ bounds: ClosedRange<T>) {
            if let value, !bounds.contains(value) {
                out.append("media `\(name)` must be between \(bounds.lowerBound) and \(bounds.upperBound)")
            }
        }
        func only(_ name: String, _ present: Bool, _ actions: [MediaAction]) {
            if present, !actions.contains(spec.action) {
                out.append("media `\(name)` applies to \(actions.map { "`\($0.rawValue)`" }.joined(separator: " or ")) only")
            }
        }
        range("width", spec.width?.staticValue, 64...4096)
        range("height", spec.height?.staticValue, 64...4096)
        if spec.model.selectsQwen21 {
            for (name, value) in [("width", spec.width?.staticValue), ("height", spec.height?.staticValue)] {
                if let value, let fix = MediaSpec.qwen21SizeFix(value) {
                    out.append("media `\(name)` \(value) won't run on Qwen-Image 2.1, which takes steps of 32 up to 2048; use \(fix)")
                }
            }
        }
        range("steps", spec.steps?.staticValue, 1...200)
        range("guidance", spec.guidance?.staticValue, 0...30)
        range("strength", spec.strength?.staticValue, 0...1)
        range("count", spec.count?.staticValue, 1...MediaSpec.maximumCount)
        range("seed", spec.seed?.staticValue, 0...(1 << 53))
        if let scale = spec.scale?.staticValue, !MediaSpec.upscaleScales.contains(scale) {
            out.append("media `scale` must be \(MediaSpec.upscaleScales.map(String.init).joined(separator: " or "))")
        }
        only("count", spec.count != nil, [.generate])
        only("strength", spec.strength != nil, [.edit])
        only("scale", spec.scale != nil, [.upscale])
        range("batch_size", spec.batchSize?.staticValue, 1...MediaSpec.maximumCount)
        range("shift", spec.shift?.staticValue, 0...100)
        range("preview_interval", spec.previewInterval?.staticValue, 1...200)
        range("fps", spec.fps?.staticValue, 1...240)
        if let frames = spec.frameCount?.staticValue, frames < 1 || frames % 4 != 1 {
            out.append("media `frame_count` must be 4n+1 (49, 81, ...)")
        }
        only("width", spec.width != nil, [.generate, .edit, .video])
        only("height", spec.height != nil, [.generate, .edit, .video])
        only("batch_size", spec.batchSize != nil, [.generate])
        only("sampler", spec.sampler != nil, [.generate, .edit])
        only("scheduler", spec.scheduler != nil, [.generate, .edit])
        only("shift", spec.shift != nil, [.generate, .edit])
        only("preview_interval", spec.previewInterval != nil, [.generate, .edit])
        only("frame_count", spec.frameCount != nil, [.video])
        only("fps", spec.fps != nil, [.video])
        only("negative_prompt", spec.negativePrompt != nil, [.generate, .edit, .video])
        only("duration", spec.duration != nil, [.video])
        only("resolution", spec.resolution != nil, [.video, .generate])
        only("aspect_ratio", spec.aspectRatio != nil, [.video, .generate])
        only("audio", spec.audio != nil, [.video])
        let framesSetLength =
            (spec.frameCount != nil || overrides.contains("frame_count")) && (spec.fps != nil || overrides.contains("fps"))
        if spec.action == .video, spec.duration == nil, !overrides.contains("duration"), !framesSetLength {
            out.append(
                "media `video` needs a `duration` the model lists, e.g. \"5\", or a local model's `frame_count` and `fps`")
        }
        return out
    }

    static func isPlainHost(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !h.contains("/"), !h.contains(":"), !h.contains(" ") else { return false }
        return h.split(separator: ".").count >= 2 || h == "localhost"
    }

    /// Kahn's algorithm. nil when the graph has a cycle. Ties keep the
    /// declared node order so runs and the graph view are stable.
    public static func topologicalOrder(_ def: WorkflowDefinition) -> [String]? {
        let ids = def.nodes.map(\.id)
        guard Set(ids).count == ids.count else { return nil }
        var indegree: [String: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        var outgoing: [String: [String]] = [:]
        for edge in def.edges where indegree[edge.from] != nil && indegree[edge.to] != nil {
            indegree[edge.to, default: 0] += 1
            outgoing[edge.from, default: []].append(edge.to)
        }
        var ready = ids.filter { indegree[$0] == 0 }
        var order: [String] = []
        while !ready.isEmpty {
            let next = ready.removeFirst()
            order.append(next)
            for to in outgoing[next] ?? [] {
                indegree[to, default: 0] -= 1
                if indegree[to] == 0 {
                    let insertAt = ready.firstIndex { ids.firstIndex(of: $0)! > ids.firstIndex(of: to)! } ?? ready.endIndex
                    ready.insert(to, at: insertAt)
                }
            }
        }
        return order.count == ids.count ? order : nil
    }

    /// Transitive predecessors of every node.
    public static func ancestorMap(_ def: WorkflowDefinition) -> [String: Set<String>] {
        guard let order = topologicalOrder(def) else { return [:] }
        var incoming: [String: [String]] = [:]
        for edge in def.edges { incoming[edge.to, default: []].append(edge.from) }
        var out: [String: Set<String>] = [:]
        for id in order {
            var set = Set<String>()
            for parent in incoming[id] ?? [] {
                set.insert(parent)
                set.formUnion(out[parent] ?? [])
            }
            out[id] = set
        }
        return out
    }
}

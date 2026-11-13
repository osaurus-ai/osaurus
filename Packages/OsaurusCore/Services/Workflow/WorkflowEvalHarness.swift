//
//  WorkflowEvalHarness.swift
//  osaurus
//
//  Drives the real workflow surfaces for the OsaurusEvals `workflow` and
//  `architect` domains. `runTemplate` runs a template through the
//  production node executor with every model slot bound to the eval model;
//  `runArchitect` hands a brief to the Architect through the shared agent
//  loop and scores the draft it leaves behind. Forms are answered from the
//  case's scripted answers, standing in for the user.
//

import Combine
import Foundation

public enum WorkflowEvalHarness {

    public struct Outcome: Sendable {
        public let passed: Bool
        /// Set when the row cannot run on this model or host. Never a pass.
        public let blocked: String?
        public let checks: [String]
        /// Estimated for inference nodes (one-shot calls report no usage).
        public let outputTokens: Int
        public let generationMs: Double

        public init(passed: Bool, blocked: String?, checks: [String], outputTokens: Int, generationMs: Double) {
            self.passed = passed
            self.blocked = blocked
            self.checks = checks
            self.outputTokens = outputTokens
            self.generationMs = generationMs
        }

        public var tokensPerSecond: Double? {
            guard outputTokens > 0, generationMs > 0 else { return nil }
            return Double(outputTokens) / (generationMs / 1000)
        }
    }

    public struct TemplateCase: Sendable {
        public var definition: JSONValue
        public var input: JSONValue
        public var answers: [String: JSONValue]
        public var expectStatus: String
        public var nodeStatuses: [String: String]
        public var outputKeys: [String]
        public var outputValues: [String: [JSONValue]]
        /// Output path -> words the text there must (or must not) contain.
        public var outputContains: [String: [String]]
        public var outputExcludes: [String: [String]]
        /// Tool step id (a `map` body is `<map id>.item`) -> the `result` its
        /// tool returns. When set, every tool step runs on a fixture: the
        /// step's teammate is resolved and its arguments bound as in the app,
        /// and no app or file on this Mac is read. A step with no fixture
        /// fails.
        public var toolResults: [String: JSONValue]
        /// Tool step id -> argument -> the value it must be called with. A
        /// `{{date:…}}` token (`yesterday_start`, `today_start`, `today_end`,
        /// `tomorrow_start`, `tomorrow_end`, `week_end`, `now`, `days_ago:N`) is this Mac's
        /// calendar at run time, matched within a minute.
        public var toolArguments: [String: [String: JSONValue]]

        public init(
            definition: JSONValue, input: JSONValue, answers: [String: JSONValue] = [:],
            expectStatus: String = "completed", nodeStatuses: [String: String] = [:],
            outputKeys: [String] = [], outputValues: [String: [JSONValue]] = [:],
            outputContains: [String: [String]] = [:], outputExcludes: [String: [String]] = [:],
            toolResults: [String: JSONValue] = [:], toolArguments: [String: [String: JSONValue]] = [:]
        ) {
            self.definition = definition
            self.input = input
            self.answers = answers
            self.expectStatus = expectStatus
            self.nodeStatuses = nodeStatuses
            self.outputKeys = outputKeys
            self.outputValues = outputValues
            self.outputContains = outputContains
            self.outputExcludes = outputExcludes
            self.toolResults = toolResults
            self.toolArguments = toolArguments
        }
    }

    /// A bundled day-one workflow or prepared ask by resource name
    /// (`default-workflow-end-of-day`), so a case runs the shipped file.
    @MainActor
    public static func bundledDefinition(named name: String) -> JSONValue? {
        let exists =
            (Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Team")
            ?? Bundle.module.url(forResource: name, withExtension: "json")) != nil
        guard exists, let definition = TeamSeeder.loadBundled(name)?.workflow,
            let data = try? JSONEncoder().encode(definition)
        else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public struct ArchitectCase: Sendable {
        public var brief: String
        public var answers: [String: JSONValue]
        public var maxIterations: Int
        public var nodeKinds: [String]
        public var inputKeys: [String]
        public var outputKeys: [String]
        public var requireTestRun: Bool
        public var requireProposeSave: Bool
        /// The person's replies to `clarify`, in order.
        public var replies: [String]
        /// Values the person holds for declared secrets, by key (`"*"` for any).
        public var secrets: [String: String]
        /// A saved workflow the chat starts from.
        public var seed: Seed?
        /// Checks on the output of the latest completed test run.
        public var testOutputKeys: [String]
        public var testOutputValues: [String: [JSONValue]]
        /// Substrings (case-insensitive) the output at a path must contain.
        public var testOutputContains: [String: [String]]
        /// Runs of the finished draft, in order, after the Architect is done.
        public var postRuns: [PostRun]
        public var structure: Structure
        /// Tool calls that must appear: `name`, or `name.arg` for a call that
        /// passed `arg`.
        public var requiredCalls: [String]
        public var forbiddenCalls: [String]
        public var maxClarifications: Int?
        /// Question marks across every `clarify` question.
        public var maxQuestions: Int?
        /// Soft budgets: exceeding one is a warning, not a failure.
        public var maxToolCalls: Int?
        public var maxPromptTokens: Int?
        /// Blocked (not failed) when no image model is available.
        public var needsImageModel: Bool
        /// The folder the person picks for a folder field `answers` leaves out.
        public var pickedFolder: String?

        public struct Seed: Sendable {
            public var name: String
            public var definition: JSONValue
            /// Run once before the chat; the failed run becomes the chat's
            /// repair run, as with Fix with the Architect.
            public var failingInput: JSONValue?

            public init(name: String, definition: JSONValue, failingInput: JSONValue? = nil) {
                self.name = name
                self.definition = definition
                self.failingInput = failingInput
            }
        }

        public struct PostRun: Sendable {
            /// nil reuses the input of the latest completed test.
            public var input: JSONValue?
            public var expectStatus: String
            public var outputKeys: [String]
            public var outputValues: [String: [JSONValue]]
            public var outputContains: [String: [String]]
            public var outputExcludes: [String: [String]]

            public init(
                input: JSONValue? = nil, expectStatus: String = "completed", outputKeys: [String] = [],
                outputValues: [String: [JSONValue]] = [:], outputContains: [String: [String]] = [:],
                outputExcludes: [String: [String]] = [:]
            ) {
                self.input = input
                self.expectStatus = expectStatus
                self.outputKeys = outputKeys
                self.outputValues = outputValues
                self.outputContains = outputContains
                self.outputExcludes = outputExcludes
            }
        }

        public struct Structure: Sendable {
            public var conditionalEdges = 0
            public var errorHandling = false
            public var retries = false
            public var paginate = false
            public var secretAuth = false
            public var fileOutput = false
            public var minExamples = 0
            /// Every example was the input of a completed test.
            public var examplesTested = false
            /// Every input has a title, a description, and `x-order`.
            public var describedInputs = true
            public var noAbsolutePaths = true
            /// Steps of the seed that must still be there.
            public var keepsNodes: [String] = []
            /// The draft still edits the seeded saved workflow.
            public var editsSeed = false
            public var declaresFolder = false
            /// An input field is a folder picked on the run form.
            public var folderInput = false
            /// The draft has at most this many more steps than the seed.
            public var maxAddedNodes: Int?

            public init() {}
        }

        public init(
            brief: String, answers: [String: JSONValue] = [:], maxIterations: Int = 16, nodeKinds: [String] = [],
            inputKeys: [String] = [], outputKeys: [String] = [], requireTestRun: Bool = true,
            requireProposeSave: Bool = true, replies: [String] = [], secrets: [String: String] = [:],
            seed: Seed? = nil, testOutputKeys: [String] = [], testOutputValues: [String: [JSONValue]] = [:],
            testOutputContains: [String: [String]] = [:], postRuns: [PostRun] = [],
            structure: Structure = Structure(), requiredCalls: [String] = [], forbiddenCalls: [String] = [],
            maxClarifications: Int? = nil, maxQuestions: Int? = nil, maxToolCalls: Int? = nil,
            maxPromptTokens: Int? = nil, needsImageModel: Bool = false, pickedFolder: String? = nil
        ) {
            self.pickedFolder = pickedFolder
            self.maxQuestions = maxQuestions
            self.brief = brief
            self.answers = answers
            self.maxIterations = maxIterations
            self.nodeKinds = nodeKinds
            self.inputKeys = inputKeys
            self.outputKeys = outputKeys
            self.requireTestRun = requireTestRun
            self.requireProposeSave = requireProposeSave
            self.replies = replies
            self.secrets = secrets
            self.seed = seed
            self.testOutputKeys = testOutputKeys
            self.testOutputValues = testOutputValues
            self.testOutputContains = testOutputContains
            self.postRuns = postRuns
            self.structure = structure
            self.requiredCalls = requiredCalls
            self.forbiddenCalls = forbiddenCalls
            self.maxClarifications = maxClarifications
            self.maxToolCalls = maxToolCalls
            self.maxPromptTokens = maxPromptTokens
            self.needsImageModel = needsImageModel
        }
    }

    // MARK: - Template runs

    @MainActor
    public static func runTemplate(_ spec: TemplateCase, model: String) async -> Outcome {
        let definition: WorkflowDefinition
        do {
            definition = try JSONDecoder().decode(
                WorkflowDefinition.self, from: Data(spec.definition.compactJSONString.utf8))
        } catch {
            return Outcome(
                passed: false, blocked: nil, checks: ["definition does not decode: \(error)"], outputTokens: 0,
                generationMs: 0)
        }
        let issues = WorkflowValidator.validate(definition, allowPlaceholders: false)
        guard issues.isEmpty else {
            return Outcome(
                passed: false, blocked: nil,
                checks: issues.map { "invalid: \(($0.nodeID.map { "[\($0)] " } ?? "") + $0.message)" },
                outputTokens: 0, generationMs: 0)
        }
        await waitForLocalModel(model)
        if let blocked = blockedReason(definition, model: model) {
            return Outcome(passed: false, blocked: blocked, checks: [], outputTokens: 0, generationMs: 0)
        }

        let template = Template(name: "Eval Workflow", summary: "Eval", payload: .workflow(definition))
        let nodeSlots = definition.nodes.compactMap { node -> String? in
            if case .inference(let spec) = node.kind { return spec.modelSlot }
            return nil
        }
        let slots = Dictionary(
            (definition.modelSlots.map(\.slot) + nodeSlots).map { ($0, model) }, uniquingKeysWith: { a, _ in a })
        let request = WorkflowRunner.Request(
            workflowID: UUID(), workflowName: template.name, template: template, slotModels: slots,
            caller: WorkflowCaller(kind: .user), input: spec.input,
            workspace: FileManager.default.temporaryDirectory.appendingPathComponent("wf-eval-\(UUID().uuidString)"))

        let calls = FixtureCalls()
        let override: (@Sendable (WorkflowNodeContext) -> ToolNodeExecutor.Runtime)? =
            spec.toolResults.isEmpty ? nil : fixtureRuntime(results: spec.toolResults, calls: calls)
        let run = await ToolNodeExecutor.$runtimeOverride.withValue(override) {
            await withScriptedAnswers(spec.answers) {
                let runID = WorkflowRunService.shared.start(request)
                return await WorkflowRunService.shared.result(of: runID)
            }
        }
        guard let run else {
            return Outcome(passed: false, blocked: nil, checks: ["the run was lost"], outputTokens: 0, generationMs: 0)
        }
        return score(run, spec, calls: override == nil ? nil : calls.snapshot())
    }

    /// What each fixture tool step was called with, and as whom.
    final class FixtureCalls: @unchecked Sendable {
        struct Call: Sendable {
            let node: String
            let tool: String
            let arguments: JSONValue
            let teammate: Teammate?
            var at = Date()
        }
        private let lock = NSLock()
        private var calls: [Call] = []

        func record(_ call: Call) {
            lock.lock()
            calls.append(call)
            lock.unlock()
        }

        func snapshot() -> [Call] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// A tool step's real resolution, binding, and output handling, with
    /// the call itself answered from `results`. A step's `agent` resolves
    /// only to a teammate template id, as a teammate with every app on.
    static func fixtureRuntime(results: [String: JSONValue], calls: FixtureCalls)
        -> @Sendable (WorkflowNodeContext) -> ToolNodeExecutor.Runtime
    {
        { context in
            let node = context.node.id
            var reference: String?
            if case .tool(let spec) = context.node.kind { reference = spec.tool.agent }
            let teammate = reference.flatMap(UUID.init(uuidString:)).flatMap(Teammate.teammate(forTemplateID:))
            var runtime = ToolNodeExecutor.Runtime.live
            runtime.execute = { name, arguments, _ in
                calls.record(
                    .init(
                        node: node, tool: name, arguments: JSONValue.parse(arguments) ?? .null,
                        teammate: teammate))
                guard let result = results[node] else {
                    return ToolEnvelope.failure(
                        kind: .executionError, message: "no fixture for step \(node)", tool: name, retryable: false)
                }
                let dated = resolvingDateTokens(result, now: Date(), calendar: .current)
                let object = try? JSONSerialization.jsonObject(
                    with: Data(dated.compactJSONString.utf8), options: [.fragmentsAllowed])
                return ToolEnvelope.success(tool: name, result: object)
            }
            runtime.resolveAgent = { reference in
                guard let teammate = UUID(uuidString: reference).flatMap(Teammate.teammate(forTemplateID:)) else {
                    return nil
                }
                return WorkflowStepAgent.Match(
                    id: teammate.templateID, name: teammate.rawValue.capitalized,
                    enabledAppleApps: Set(AppleApp.allCases))
            }
            return runtime
        }
    }

    static func score(_ run: WorkflowRun, _ spec: TemplateCase, calls: [FixtureCalls.Call]? = nil) -> Outcome {
        var checks: [(Bool, String)] = []
        checks.append(
            (
                run.status.rawValue == spec.expectStatus,
                "status \(run.status.rawValue) (want \(spec.expectStatus))"
                    + (run.error.map { ": \($0.reason)" } ?? "")
            ))
        for (node, want) in spec.nodeStatuses.sorted(by: { $0.key < $1.key }) {
            let got = run.node(node)?.status.rawValue ?? "missing"
            checks.append((got == want, "node \(node): \(got) (want \(want))"))
        }
        for key in spec.outputKeys {
            let value = run.output?.value(atPath: key)
            checks.append((value != nil && value != .null, "output.\(key) present"))
        }
        for (key, allowed) in spec.outputValues.sorted(by: { $0.key < $1.key }) {
            let value = run.output?.value(atPath: key)
            checks.append(
                (
                    value.map(allowed.contains) ?? false,
                    "output.\(key) = \(value?.compactJSONString ?? "nil") in \(allowed.map(\.compactJSONString))"
                ))
        }
        checks += outputChecks(
            run.output, keys: [], values: [:], contains: spec.outputContains, excludes: spec.outputExcludes,
            label: "run")
        // The text itself, so a passing row can still be read.
        if case .object(let fields)? = run.output {
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                checks.append((true, "output.\(key): " + (value.stringValue ?? value.compactJSONString).prefix(1_200)))
            }
        }
        if let calls {
            checks += fixtureCallChecks(calls, expected: spec.toolArguments)
        }
        var tokens = 0
        var ms = 0.0
        for node in run.nodes {
            if let model = node.model {
                checks.append((true, "node \(node.nodeID) ran on \(model)"))
            }
            if let out = node.outputTokens, let duration = node.durationMs {
                tokens += out
                ms += Double(duration)
            }
            if let error = node.error { checks.append((true, "node \(node.nodeID) error: \(error)")) }
        }
        return Outcome(
            passed: checks.allSatisfy(\.0), blocked: nil,
            checks: checks.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 }, outputTokens: tokens, generationMs: ms)
    }

    /// Each fixture call ran under a teammate and with the arguments the
    /// case names; every call is listed with its arguments. A date token is
    /// read on the clock at the moment of the call, not at scoring, so a slow
    /// model load later in the run does not move it.
    static func fixtureCallChecks(
        _ calls: [FixtureCalls.Call], expected: [String: [String: JSONValue]],
        calendar: Calendar = .current
    ) -> [(Bool, String)] {
        var checks: [(Bool, String)] = []
        for call in calls {
            checks.append(
                (
                    call.teammate != nil,
                    "step \(call.node) called \(call.tool) as \(call.teammate?.rawValue ?? "no teammate") "
                        + call.arguments.compactJSONString.prefix(240)
                ))
        }
        for (node, arguments) in expected.sorted(by: { $0.key < $1.key }) {
            let made = calls.filter { $0.node == node }
            guard !made.isEmpty else {
                checks.append((false, "step \(node) made no call"))
                continue
            }
            for call in made {
                for (key, want) in arguments.sorted(by: { $0.key < $1.key }) {
                    let got = call.arguments.value(atPath: key)
                    let ok = argumentMatches(got, want, now: call.at, calendar: calendar)
                    let shown = got?.compactJSONString ?? "nil"
                    checks.append((ok, "step \(node) \(key) = \(shown) (want \(want.compactJSONString))"))
                }
            }
        }
        return checks
    }

    /// A fixture result with each `{{date:…}}` string replaced by that date
    /// in the local offset the Apple tools write, so an event "today" stays
    /// today on every run and reads as today to the model.
    static func resolvingDateTokens(_ value: JSONValue, now: Date, calendar: Calendar) -> JSONValue {
        switch value {
        case .string(let text):
            guard text.hasPrefix("{{date:"), text.hasSuffix("}}"),
                let date = dateToken(String(text.dropFirst(7).dropLast(2)), now: now, calendar: calendar)
            else { return value }
            return .string(AppleDateParsing.format(date, timeZone: calendar.timeZone))
        case .array(let items):
            return .array(items.map { resolvingDateTokens($0, now: now, calendar: calendar) })
        case .object(let fields):
            return .object(fields.mapValues { resolvingDateTokens($0, now: now, calendar: calendar) })
        default:
            return value
        }
    }

    static func argumentMatches(_ got: JSONValue?, _ want: JSONValue, now: Date, calendar: Calendar) -> Bool {
        guard let token = want.stringValue, token.hasPrefix("{{date:"), token.hasSuffix("}}") else {
            return got == want
        }
        let name = String(token.dropFirst(7).dropLast(2))
        guard let target = dateToken(name, now: now, calendar: calendar), let text = got?.stringValue else {
            return false
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return false }
        return abs(date.timeIntervalSince(target)) <= 60
    }

    /// This Mac's calendar, the way the bundled code steps compute it. A
    /// trailing offset (`today_start+16h`, `now-30m`, `today_start-3d`)
    /// moves the date.
    static func dateToken(_ name: String, now: Date, calendar: Calendar) -> Date? {
        if let match = name.wholeMatch(of: /(.+?)([+-]\d+)([mhd])/),
            let base = dateToken(String(match.1), now: now, calendar: calendar), let amount = Int(match.2)
        {
            let unit: Calendar.Component = match.3 == "m" ? .minute : match.3 == "h" ? .hour : .day
            return calendar.date(byAdding: unit, value: amount, to: base)
        }
        let start = calendar.startOfDay(for: now)
        func endOfDay(_ day: Date) -> Date? {
            calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day)
        }
        switch name {
        case "now": return now
        case "yesterday_start": return calendar.date(byAdding: .day, value: -1, to: start)
        case "today_start": return start
        case "today_end": return endOfDay(start)
        case "tomorrow_start": return calendar.date(byAdding: .day, value: 1, to: start)
        case "tomorrow_end": return calendar.date(byAdding: .day, value: 1, to: start).flatMap(endOfDay)
        case "week_end":
            let weekday = calendar.component(.weekday, from: now) - 1
            return calendar.date(byAdding: .day, value: (7 - weekday) % 7, to: start).flatMap(endOfDay)
        default:
            guard name.hasPrefix("days_ago:"), let days = Double(name.dropFirst(9)) else { return nil }
            return now.addingTimeInterval(-days * 86400)
        }
    }

    /// Local models join the catalog when the launch scan lands, off the
    /// main thread; an installed model is waited for rather than reported
    /// as missing.
    @MainActor
    static func waitForLocalModel(_ model: String) async {
        func listed() -> Bool {
            ModelManager.shared.availableModels.contains {
                $0.isDownloaded && $0.id.caseInsensitiveCompare(model) == .orderedSame
            }
        }
        guard !listed(),
            await ModelManager.discoverLocalModelsOffMain().contains(where: {
                $0.id.caseInsensitiveCompare(model) == .orderedSame
            })
        else { return }
        let deadline = ContinuousClock.now + .seconds(15)
        while !listed(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Inference nodes need native structured output; code nodes need the
    /// JavaScript helper. Either missing is a host/model limit, not a fail.
    @MainActor
    static func blockedReason(_ def: WorkflowDefinition, model: String) -> String? {
        let kinds = Set(
            def.nodes.flatMap { node -> [String] in
                guard case .map(let spec) = node.kind else { return [node.kindName] }
                return [node.kindName, spec.body(parentID: node.id).kindName]
            })
        if kinds.contains("inference"), case .unsupported(let reason) = StructuredOutputCapability.support(for: model) {
            return "structured output unsupported for \(model): \(reason)"
        }
        if kinds.contains("code"), JSHostLocator.executableURL() == nil {
            return "osaurus-js-host is not available to this process (set OSAURUS_JS_HOST_PATH)"
        }
        return nil
    }

    // MARK: - Architect

    @MainActor
    public static func runArchitect(
        _ spec: ArchitectCase, model: String?
    ) async -> (outcome: Outcome, transcript: AgentLoopTranscript) {
        let media = spec.needsImageModel ? await MediaModelResolver.loadedLiveCandidates() : []
        if spec.needsImageModel,
            !media.contains(where: { $0.supports(.generate) }) || !media.contains(where: { $0.supports(.upscale) })
        {
            return (
                Outcome(
                    passed: false, blocked: "no image model that can generate and one that can upscale",
                    checks: [], outputTokens: 0, generationMs: 0),
                emptyTranscript(exit: "blocked")
            )
        }
        let drafts = WorkflowDraftStore.shared
        let before = Set(drafts.drafts.keys)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "architect-eval-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Test runs bind unbound slots to the Architect's model, as when the
        // user picks it in Settings; point it at the eval model for the run.
        let savedConfiguration = ArchitectConfigurationStore.load()
        if let model {
            var configuration = savedConfiguration
            configuration.model = model
            ArchitectConfigurationStore.save(configuration)
        }
        defer { ArchitectConfigurationStore.save(savedConfiguration) }
        WorkflowSecretsKeychain.useInMemoryStore(values: spec.secrets)
        defer { WorkflowSecretsKeychain.useInMemoryStore(values: nil) }

        let sessionID = UUID().uuidString
        var brief = spec.brief
        var installed: InstalledWorkflow?
        var setupChecks: [String] = []
        if let seed = spec.seed {
            switch install(seed, model: model) {
            case .failure(let message):
                return (
                    Outcome(passed: false, blocked: nil, checks: ["FAIL seed: \(message)"], outputTokens: 0, generationMs: 0),
                    emptyTranscript(exit: "errored")
                )
            case .success(let workflow):
                installed = workflow
                ArchitectLauncher.seed(sessionID: sessionID, from: workflow.template)
                if let failingInput = seed.failingInput, let draft = drafts.draft(forSession: sessionID) {
                    let runID = WorkflowRunService.shared.start(
                        workflow, input: failingInput, caller: WorkflowCaller(kind: .user))
                    if let run = await WorkflowRunService.shared.result(of: runID) {
                        let failed = run.status.rawValue == "failed"
                        setupChecks.append((failed ? "PASS " : "FAIL ") + "seed run status \(run.status.rawValue)")
                        drafts.setRepairRun(draft.id, runID: run.id)
                        drafts.notePending(draft.id, WorkflowRepairBrief.note(run, workflow: workflow))
                        let message = WorkflowRepairBrief.message(run, definition: workflow.definition)
                        brief = brief.isEmpty ? message : message + "\n\n" + brief
                    }
                }
            }
        }
        defer { if let installed { InstalledWorkflowStore.shared.delete(id: installed.id) } }
        // The person finishes Set Up for each declared folder as soon as it
        // appears, picking a folder of their own.
        let picked = workspace.appendingPathComponent("Picked Folders", isDirectory: true)
        let folderSetup = drafts.$drafts.sink { _ in
            Task { @MainActor in pickFolders(sessionID: sessionID, under: picked) }
        }
        defer { folderSetup.cancel() }
        if let context = drafts.takeTurnContext(sessionID: sessionID) {
            brief = ChatSession.buildUserMessageText(
                content: brief,
                attachments: [.document(filename: "workflow-context.md", content: context, fileSize: context.utf8.count)])
        }

        let transcript = await withScriptedAnswers(spec.answers, folder: spec.pickedFolder) {
            await AgentLoopEvaluator.run(
                task: brief, workspace: workspace, agentId: Agent.architectId,
                maxIterations: spec.maxIterations, model: model, useHostFolder: false, sessionId: sessionID,
                clarifyReplies: spec.replies)
        }
        let draft =
            drafts.draft(forSession: sessionID)
            ?? drafts.drafts.values.filter { !before.contains($0.id) }.max { $0.updatedAt < $1.updatedAt }
        var outcome = scoreArchitect(spec, transcript: transcript, draft: draft, seed: installed)
        if let draft, !spec.postRuns.isEmpty {
            let post = await withScriptedAnswers(spec.answers, folder: spec.pickedFolder) {
                await postRunChecks(spec.postRuns, draftID: draft.id, sessionID: sessionID)
            }
            outcome = Outcome(
                passed: outcome.passed && !post.contains { $0.hasPrefix("FAIL") }, blocked: nil,
                checks: outcome.checks + post, outputTokens: outcome.outputTokens,
                generationMs: outcome.generationMs)
        }
        if !setupChecks.isEmpty {
            outcome = Outcome(
                passed: outcome.passed && !setupChecks.contains { $0.hasPrefix("FAIL") }, blocked: nil,
                checks: setupChecks + outcome.checks, outputTokens: outcome.outputTokens,
                generationMs: outcome.generationMs)
        }
        for draft in drafts.drafts.values where !before.contains(draft.id) {
            drafts.delete(draft.id)
        }
        return (outcome, transcript)
    }

    @MainActor
    static func pickFolders(sessionID: String, under root: URL) {
        let drafts = WorkflowDraftStore.shared
        guard let draft = drafts.draft(forSession: sessionID) else { return }
        var bindings = draft.bindings
        for folder in draft.definition.folders where bindings.folders[folder.key] == nil {
            let url = root.appendingPathComponent(folder.key, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            bindings.folders[folder.key] = url.path
        }
        if bindings != draft.bindings { drafts.setBindings(draft.id, bindings) }
    }

    static func emptyTranscript(exit: String) -> AgentLoopTranscript {
        AgentLoopTranscript(
            toolCalls: [], finalText: "", iterations: 0, exit: exit, systemPrompt: "", toolSchemaNames: [], error: nil)
    }

    struct SeedFailure: Error, CustomStringConvertible {
        var description: String
    }

    @MainActor
    static func install(_ seed: ArchitectCase.Seed, model: String?) -> Result<InstalledWorkflow, SeedFailure> {
        let definition: WorkflowDefinition
        do {
            definition = try JSONDecoder().decode(
                WorkflowDefinition.self, from: Data(seed.definition.compactJSONString.utf8))
        } catch {
            return .failure(SeedFailure(description: "definition does not decode: \(error)"))
        }
        let issues = WorkflowValidator.validate(definition, allowPlaceholders: false)
        guard issues.isEmpty else {
            return .failure(SeedFailure(description: issues.map(\.message).joined(separator: "; ")))
        }
        let template = Template(name: seed.name, summary: seed.name, payload: .workflow(definition))
        let nodeSlots = definition.nodes.compactMap { node -> String? in
            if case .inference(let spec) = node.kind { return spec.modelSlot }
            return nil
        }
        let models = Dictionary(
            definition.modelSlots.map { ($0.slot, $0.preferred ?? model ?? "") }
                + nodeSlots.map { ($0, model ?? "") },
            uniquingKeysWith: { a, _ in a })
        do {
            return .success(
                try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings(models: models)))
        } catch {
            return .failure(SeedFailure(description: "install failed: \(error)"))
        }
    }

    /// Runs the finished draft as the person would after saving it.
    @MainActor
    static func postRunChecks(_ runs: [ArchitectCase.PostRun], draftID: UUID, sessionID: String) async -> [String] {
        var checks: [String] = []
        let lastInput = WorkflowDraftStore.shared.draft(id: draftID)?.testRunIDs.reversed()
            .compactMap { WorkflowRunStore.shared.run(id: $0) }
            .first { $0.status == .completed }?.input
        for (index, post) in runs.enumerated() {
            let label = "post-run \(index + 1)"
            guard let input = post.input ?? lastInput else {
                checks.append("FAIL \(label): no completed test input to reuse")
                continue
            }
            switch WorkflowDraftTester.start(draftID: draftID, input: input, sessionID: sessionID) {
            case .failure(let refusal):
                checks.append("FAIL \(label) refused: \(refusal)")
            case .success(let runID):
                guard let run = await WorkflowRunService.shared.result(of: runID) else {
                    checks.append("FAIL \(label): the run was lost")
                    continue
                }
                checks.append(
                    (run.status.rawValue == post.expectStatus ? "PASS " : "FAIL ")
                        + "\(label) status \(run.status.rawValue) (want \(post.expectStatus))"
                        + (run.error.map { ": \($0.reason)" } ?? ""))
                checks += outputChecks(
                    run.output, keys: post.outputKeys, values: post.outputValues, contains: post.outputContains,
                    excludes: post.outputExcludes, files: run.artifacts, label: label
                ).map { ($0.0 ? "PASS " : "FAIL ") + $0.1 }
            }
        }
        return checks
    }

    /// `files` are the run's artifacts: a `format: "file"` output field
    /// whose value is a workspace-relative name is read through its
    /// artifact's resolved path.
    static func outputChecks(
        _ output: JSONValue?, keys: [String], values: [String: [JSONValue]], contains: [String: [String]],
        excludes: [String: [String]] = [:], files: [WorkflowArtifact] = [], label: String
    ) -> [(Bool, String)] {
        var checks: [(Bool, String)] = []
        for key in keys {
            let value = output?.value(atPath: key)
            checks.append((value != nil && value != .null, "\(label) output.\(key) present"))
        }
        for (key, allowed) in values.sorted(by: { $0.key < $1.key }) {
            let value = output?.value(atPath: key)
            checks.append(
                (
                    value.map(allowed.contains) ?? false,
                    "\(label) output.\(key) = \(value?.compactJSONString.prefix(200) ?? "nil") in \(allowed.map(\.compactJSONString))"
                ))
        }
        for (key, needles) in contains.sorted(by: { $0.key < $1.key }) {
            let text = readable(output, at: key, files: files)
            let missing = needles.filter { !(text ?? "").contains($0.lowercased()) }
            checks.append(
                (
                    text != nil && missing.isEmpty,
                    missing.isEmpty
                        ? "\(label) output.\(key) mentions \(needles)"
                        : "\(label) output.\(key) is missing \(missing): \((text ?? "nil").prefix(200))"
                ))
        }
        for (key, needles) in excludes.sorted(by: { $0.key < $1.key }) {
            let text = readable(output, at: key, files: files) ?? ""
            let present = needles.filter { text.contains($0.lowercased()) }
            checks.append(
                (
                    present.isEmpty,
                    present.isEmpty
                        ? "\(label) output.\(key) leaves out \(needles)"
                        : "\(label) output.\(key) still has \(present): \(text.prefix(200))"
                ))
        }
        return checks
    }

    /// The output at `path`, lowercased, with the contents of any file it
    /// names appended. `*` is the whole output.
    static func readable(_ output: JSONValue?, at path: String, files: [WorkflowArtifact] = []) -> String? {
        guard let value = path == "*" ? output : output?.value(atPath: path) else { return nil }
        var text = value.stringValue ?? value.compactJSONString
        let outputFiles = files.filter { file in
            guard file.source == .output, file.problem == nil, !file.isDirectory, let field = file.field else {
                return false
            }
            return path == "*" || path == field || path.hasPrefix(field + ".")
        }
        for candidate in strings(in: value).filter({ $0.hasPrefix("/") }) + outputFiles.map(\.path) {
            guard FileManager.default.fileExists(atPath: candidate),
                let contents = try? String(contentsOfFile: candidate, encoding: .utf8)
            else { continue }
            text += "\n" + contents.prefix(20_000)
        }
        return text.lowercased()
    }

    static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let s): return [s]
        case .array(let items): return items.flatMap(strings)
        case .object(let fields): return fields.values.flatMap(strings)
        default: return []
        }
    }

    @MainActor
    static func scoreArchitect(
        _ spec: ArchitectCase, transcript: AgentLoopTranscript, draft: WorkflowDraft?,
        seed: InstalledWorkflow? = nil
    ) -> Outcome {
        guard transcript.toolSchemaNames.contains(WorkflowDraftTool.toolName) else {
            // Small-context models (Foundation) run with tools auto-disabled.
            return Outcome(
                passed: false,
                blocked: "The Architect's draft tools were not in the schema for this model "
                    + "(tools are auto-disabled for small-context models); exit \(transcript.exit)",
                checks: [], outputTokens: 0, generationMs: 0)
        }
        var checks: [(Bool, String)] = []
        let calls = transcript.toolCalls.map(\.name)
        // Only a reply the Architect chose to end on is a finished turn; a
        // cap, an error, or an unanswered question is not.
        checks.append(
            (
                transcript.error == nil && transcript.exit == "finalResponse",
                "loop exit \(transcript.exit)" + (transcript.error.map { ": \($0)" } ?? "")
            ))
        checks.append((draft != nil, "a draft was created"))
        if let draft {
            let issues = WorkflowValidator.validate(draft.definition, allowPlaceholders: false)
            checks.append(
                (
                    issues.isEmpty,
                    issues.isEmpty
                        ? "draft validates"
                        : "draft issues: " + issues.map(\.message).joined(separator: "; ")
                ))
            let kinds = Set(
                draft.definition.nodes.flatMap { [$0.kindName] + ($0.mapBody.map { [$0.kindName] } ?? []) })
            for kind in spec.nodeKinds {
                checks.append((kinds.contains(kind), "has a \(kind) node (has \(kinds.sorted()))"))
            }
            let inputKeys = Set(draft.definition.inputSchema.objectValue?["properties"]?.objectValue?.keys ?? [:].keys)
            for key in spec.inputKeys {
                checks.append((inputKeys.contains(key), "input schema has \(key)"))
            }
            let outputKeys = Set(
                draft.definition.outputSchema.objectValue?["properties"]?.objectValue?.keys ?? [:].keys)
            for key in spec.outputKeys {
                checks.append((outputKeys.contains(key), "output schema has \(key)"))
            }
            checks += structureChecks(spec.structure, draft: draft, seed: seed)
        }
        let testRuns = (draft?.testRunIDs ?? []).compactMap { WorkflowRunStore.shared.run(id: $0) }
        if spec.requireTestRun {
            let statuses = testRuns.map(\.status.rawValue)
            checks.append(
                (statuses.contains("completed"), "a workflow_test run completed (test runs: \(statuses))"))
        }
        if !spec.testOutputKeys.isEmpty || !spec.testOutputValues.isEmpty || !spec.testOutputContains.isEmpty {
            // Any completed test may show it: a later test can differ only
            // because an earlier one changed the workflow's stored data.
            let candidates = testRuns.filter { $0.status == .completed }.reversed().map {
                outputChecks(
                    $0.output, keys: spec.testOutputKeys, values: spec.testOutputValues,
                    contains: spec.testOutputContains, files: $0.artifacts, label: "test")
            }
            checks += candidates.first { $0.allSatisfy(\.0) } ?? candidates.first
                ?? [(false, "test output: no completed test run")]
        }
        if spec.requireProposeSave {
            checks.append((calls.contains(WorkflowProposeSaveTool.toolName), "workflow_propose_save was called"))
        }
        for required in spec.requiredCalls {
            checks.append((madeCall(required, in: transcript), "called \(required)"))
        }
        for forbidden in spec.forbiddenCalls {
            checks.append((!madeCall(forbidden, in: transcript), "never called \(forbidden)"))
        }
        let clarifications = calls.filter { $0 == "clarify" }.count
        if let limit = spec.maxClarifications {
            checks.append((clarifications <= limit, "clarify called \(clarifications) time(s) (at most \(limit))"))
        }
        if let limit = spec.maxQuestions {
            let asked = transcript.toolCalls.filter { $0.name == "clarify" }
                .map { $0.arguments.filter { $0 == "?" }.count }.reduce(0, +)
            checks.append((asked <= limit, "\(asked) question(s) asked (at most \(limit))"))
        }
        let leaked = ["<tool_call>", "</tool_call>", "<|im_start|>", "<|channel|>", "<think>", "</think>"]
            .filter { transcript.finalText.contains($0) }
        checks.append((leaked.isEmpty, leaked.isEmpty ? "no protocol markers in the reply" : "leaked \(leaked)"))
        let schemaErrors = transcript.toolCalls.filter {
            $0.wasError && ["invalid_args", "invalidArgs", "parse"].contains(errorKind($0.resultPreview) ?? "")
        }
        checks.append(
            (
                schemaErrors.isEmpty,
                schemaErrors.isEmpty
                    ? "no malformed tool calls"
                    : "malformed tool calls: " + schemaErrors.map { "\($0.name): \($0.resultPreview.prefix(160))" }
                        .joined(separator: " | ")
            ))
        var lines = checks.map { ($0.0 ? "PASS " : "FAIL ") + $0.1 }
        lines += processMetrics(spec, transcript: transcript, testRuns: testRuns)
        let tokens = transcript.completionTokens ?? 0
        let tps = transcript.decodeTokensPerSecond
        return Outcome(
            passed: checks.allSatisfy(\.0), blocked: nil,
            checks: lines,
            outputTokens: tokens,
            generationMs: tps.map { $0 > 0 ? Double(tokens) / $0 * 1000 : 0 } ?? 0)
    }

    /// `name` or `name.arg`: a call to `name` (that passed `arg`).
    static func madeCall(_ pattern: String, in transcript: AgentLoopTranscript) -> Bool {
        let parts = pattern.split(separator: ".", maxSplits: 1).map(String.init)
        return transcript.toolCalls.contains { call in
            guard call.name == parts[0] else { return false }
            guard parts.count == 2 else { return true }
            guard let args = try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)),
                let value = args.objectValue?[parts[1]]
            else { return false }
            return value != .null
        }
    }

    static func errorKind(_ envelope: String) -> String? {
        guard let range = envelope.range(of: #""kind"\s*:\s*"([A-Za-z_]+)""#, options: .regularExpression) else {
            return nil
        }
        return envelope[range].split(separator: "\"").dropFirst(2).first.map(String.init)
    }

    /// What the run cost and how it went, as `INFO`/`WARN` lines.
    static func processMetrics(_ spec: ArchitectCase, transcript: AgentLoopTranscript, testRuns: [WorkflowRun])
        -> [String]
    {
        var lines: [String] = []
        var counts: [String: Int] = [:]
        for call in transcript.toolCalls { counts[call.name, default: 0] += 1 }
        lines.append(
            "INFO tool calls \(transcript.toolCalls.count): "
                + counts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
        let errors = transcript.toolCalls.filter(\.wasError)
        if !errors.isEmpty {
            lines.append(
                "INFO failed calls \(errors.count): "
                    + errors.map { "\($0.name)[\(errorKind($0.resultPreview) ?? "?")]" }.joined(separator: ", "))
        }
        lines.append("INFO test runs \(testRuns.count): \(testRuns.map(\.status.rawValue))")
        lines.append("INFO tools in order: \(transcript.toolCalls.map(\.name).joined(separator: " → "))")
        let largest = transcript.toolCalls.sorted { ($0.resultCharacters ?? 0) > ($1.resultCharacters ?? 0) }.prefix(3)
        if !largest.isEmpty {
            lines.append(
                "INFO largest results: "
                    + largest.map { "\($0.name) step \($0.step) ~\(($0.resultCharacters ?? 0) / 4) tok" }
                    .joined(separator: ", "))
        }
        if let attribution = transcript.contextAttribution {
            lines.append(
                "INFO context: system \(attribution.systemPromptTokens) tok, tools \(attribution.toolSchemaTokens) tok, "
                    + "top "
                    + attribution.topContributors(3).map { "\($0.name) \($0.tokens)" }.joined(separator: ", "))
            if let history = attribution.history {
                lines.append(
                    "INFO history: tool results \(history.toolResultTokens) tok over \(history.toolResultCount), "
                        + "assistant \(history.assistantTokens) tok, user \(history.userTokens) tok")
            }
        }
        if let prompt = transcript.promptTokensTotal {
            lines.append(
                "INFO prompt tokens \(prompt) over \(transcript.modelSteps ?? 0) steps, peak "
                    + "\(transcript.peakContextTokens ?? 0)")
        }
        if let limit = spec.maxToolCalls, transcript.toolCalls.count > limit {
            lines.append("WARN \(transcript.toolCalls.count) tool calls (budget \(limit))")
        }
        if let limit = spec.maxPromptTokens, let prompt = transcript.promptTokensTotal, prompt > limit {
            lines.append("WARN \(prompt) prompt tokens (budget \(limit))")
        }
        return lines
    }

    @MainActor
    static func structureChecks(_ want: ArchitectCase.Structure, draft: WorkflowDraft, seed: InstalledWorkflow?)
        -> [(Bool, String)]
    {
        let definition = draft.definition
        let encoded = (try? JSONEncoder().encode(definition)).flatMap {
            try? JSONDecoder().decode(JSONValue.self, from: $0)
        }
        let nodes = encoded?.objectValue?["nodes"]?.arrayValue ?? []
        let allNodes = flattenNodes(nodes)
        var checks: [(Bool, String)] = []
        if want.conditionalEdges > 0 {
            let count = definition.edges.filter { $0.when != nil }.count
            checks.append((count >= want.conditionalEdges, "\(count) conditional edge(s) (want ≥ \(want.conditionalEdges))"))
        }
        if want.errorHandling {
            let handles =
                definition.edges.contains { $0.on != .success }
                || definition.nodes.contains { $0.onError != .fail }
            checks.append((handles, "handles a failing step (on_error / error edge)"))
        }
        if want.retries {
            let retries = allNodes.contains {
                ($0.objectValue?["retry"]?.objectValue?["max_attempts"]?.numberValue ?? 1) > 1
            }
            checks.append((retries, "a step retries"))
        }
        if want.paginate {
            let pages = allNodes.contains { $0.objectValue?["http"]?.objectValue?["paginate"] != nil }
            checks.append((pages, "an http step follows pages"))
        }
        if want.secretAuth {
            let declared = Set(definition.secrets.map(\.key))
            let used = Set(
                definition.nodes.flatMap { node -> [String] in
                    [node, node.mapBody].compactMap { $0 }.flatMap { step -> [String] in
                        if case .http(let spec) = step.kind { return spec.secretKeys }
                        return []
                    }
                })
            checks.append(
                (
                    !declared.isEmpty && !used.isEmpty && used.isSubset(of: declared),
                    "secrets declared \(declared.sorted()) and read through auth \(used.sorted())"
                ))
        }
        if want.fileOutput {
            let props = definition.outputSchema.objectValue?["properties"]?.objectValue ?? [:]
            let hasFile = props.values.contains { prop in
                prop.objectValue?["format"]?.stringValue == "file"
                    || prop.objectValue?["items"]?.objectValue?["format"]?.stringValue == "file"
            }
            checks.append((hasFile, "the workflow outputs a file"))
        }
        if want.minExamples > 0 {
            checks.append(
                (
                    definition.examples.count >= want.minExamples,
                    "\(definition.examples.count) example(s) (want ≥ \(want.minExamples))"
                ))
        }
        if want.examplesTested {
            let tested = draft.testRunIDs.compactMap { WorkflowRunStore.shared.run(id: $0) }
                .filter { $0.status == .completed }.map(\.input)
            let untested = definition.examples.filter { !tested.contains($0.input) }.map(\.name)
            checks.append(
                (
                    !definition.examples.isEmpty && untested.isEmpty,
                    untested.isEmpty ? "every example was tested" : "examples never tested: \(untested)"
                ))
        }
        if want.describedInputs {
            let props = definition.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            let bare = props.filter { _, prop in
                let object = prop.objectValue ?? [:]
                return (object["title"]?.stringValue ?? "").isEmpty
                    || (object["description"]?.stringValue ?? "").isEmpty
            }.keys.sorted()
            checks.append(
                (bare.isEmpty, bare.isEmpty ? "inputs have a title and description" : "inputs missing labels: \(bare)"))
            if props.count > 1 {
                let order = definition.inputSchema.objectValue?["x-order"]?.arrayValue ?? []
                checks.append((!order.isEmpty, "the input schema sets x-order"))
            }
        }
        if want.noAbsolutePaths {
            // Examples carry the person's own sample inputs, paths included.
            var portable = encoded?.objectValue ?? [:]
            portable["examples"] = nil
            let text = JSONValue.object(portable).compactJSONString
            let paths = ["/Users/", "/private/", "/var/folders/", "~/"].filter { text.contains($0) }
            checks.append((paths.isEmpty, paths.isEmpty ? "no machine paths in the definition" : "machine paths \(paths)"))
        }
        if !want.keepsNodes.isEmpty {
            let ids = Set(definition.nodes.map(\.id))
            let lost = want.keepsNodes.filter { !ids.contains($0) }
            checks.append((lost.isEmpty, lost.isEmpty ? "kept steps \(want.keepsNodes)" : "lost steps \(lost)"))
        }
        if want.editsSeed {
            let same = seed.map { draft.templateID == $0.templateID } ?? false
            checks.append((same, "the draft still edits the saved workflow"))
        }
        if want.declaresFolder {
            checks.append((!definition.folders.isEmpty, "declares a folder (\(definition.folders.map(\.key)))"))
        }
        if want.folderInput {
            let keys = WorkflowFormFields.fields(fromInputSchema: definition.inputSchema)
                .filter { $0.type == .folder }.map(\.key)
            checks.append((!keys.isEmpty, "an input field picks a folder (\(keys))"))
        }
        if let limit = want.maxAddedNodes, let seed {
            let added = definition.nodes.count - seed.definition.nodes.count
            checks.append((added <= limit, "\(added) step(s) added (at most \(limit))"))
        }
        return checks
    }

    /// Nodes with the steps of map bodies inlined.
    static func flattenNodes(_ nodes: [JSONValue]) -> [JSONValue] {
        nodes.flatMap { node -> [JSONValue] in
            let body = node.objectValue?["map"]?.objectValue?["step"]
            return [node] + (body.map { flattenNodes([$0]) } ?? [])
        }
    }

    // MARK: - Scripted answers

    /// Answers every form with the case's values, falling back to the
    /// field default, then `folder` for a folder field, then a
    /// type-appropriate sample.
    @MainActor
    static func withScriptedAnswers<T>(
        _ answers: [String: JSONValue], folder: String? = nil, _ body: () async -> T
    ) async -> T {
        let previous = WorkflowDialogNotifier.onPresented
        WorkflowDialogNotifier.onPresented = { dialog in
            var values: [String: JSONValue] = [:]
            for field in dialog.fields {
                let picked = field.type == .folder ? folder.map(JSONValue.string) : nil
                values[field.key] =
                    answers[field.key] ?? dialog.prefill[field.key] ?? field.defaultValue ?? picked ?? sample(field)
            }
            Task { @MainActor in _ = DialogCoordinator.shared.answer(dialog.id, values: values) }
        }
        defer { WorkflowDialogNotifier.onPresented = previous }
        return await body()
    }

    static func sample(_ field: DialogField) -> JSONValue {
        switch field.type {
        case .number: return .number(1)
        case .bool: return .bool(true)
        case .date: return .string("2026-01-15")
        case .choice: return .string(field.options?.first ?? "")
        case .secret: return .string("eval-secret")
        default: return .string("Eval answer for \(field.label)")
        }
    }
}

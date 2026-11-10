//
//  OnboardingEvalHarness.swift
//  osaurus
//
//  The deterministic rows of the OsaurusEvals `onboarding` domain. Each
//  check drives the shipped first-run pieces (the opening, the plan, the
//  panel, the team templates, the bundled workflows, the walkthrough
//  prompt, discovery) with no model and returns one line per assertion.
//  The model rows (the prepared reads, the typed asks) live in the
//  Workflow suite.
//

import Foundation

@MainActor
public enum OnboardingEvalHarness {

    public static let checks = [
        "opening", "plan_from_state", "zero_model_run", "step_control", "no_self_completion", "team_settings",
        "tool_budget", "isolation", "bundled_references", "default_workflows", "prepared_reads", "held_on_bridge",
        "skip_setup", "seeded_state", "wording", "prompt_budget", "discovery", "bundled_contracts",
    ]

    @MainActor
    public static func run(_ check: String) async -> WorkflowEvalHarness.Outcome {
        var probe = Probe()
        switch check {
        case "opening": opening(&probe)
        case "plan_from_state": planFromState(&probe)
        case "zero_model_run": zeroModelRun(&probe)
        case "step_control": stepControl(&probe)
        case "no_self_completion": noSelfCompletion(&probe)
        case "team_settings": teamSettings(&probe)
        case "tool_budget": await toolBudget(&probe)
        case "isolation": await isolation(&probe)
        case "bundled_references": await bundledReferences(&probe)
        case "default_workflows": defaultWorkflows(&probe)
        case "prepared_reads": preparedReads(&probe)
        case "held_on_bridge": heldOnBridge(&probe)
        case "skip_setup": skipSetup(&probe)
        case "seeded_state": seededState(&probe)
        case "wording": wording(&probe)
        case "prompt_budget": promptBudget(&probe)
        case "discovery": discovery(&probe)
        case "bundled_contracts": bundledContracts(&probe)
        default: probe.expect(false, "unknown check `\(check)`; known: \(checks.joined(separator: ", "))")
        }
        return WorkflowEvalHarness.Outcome(
            passed: !probe.lines.isEmpty && probe.lines.allSatisfy { $0.hasPrefix("PASS") },
            blocked: nil,
            checks: probe.lines,
            outputTokens: 0,
            generationMs: 0
        )
    }

    struct Probe {
        var lines: [String] = []
        mutating func expect(_ ok: Bool, _ line: String) { lines.append((ok ? "PASS " : "FAIL ") + line) }
    }

    // MARK: - Fixtures

    static let team: [OnboardingOpening.Member] = [
        .init(teammate: .planner, name: "Planner"), .init(teammate: .courier, name: "Courier"),
        .init(teammate: .keeper, name: "Keeper"), .init(teammate: .scout, name: "Scout"),
    ]
    static let profile = MacProfile(modelName: "MacBook Air", chip: "M4", memoryGB: 16)
    static let brains: [OnboardingBrainState] = [
        .local(comfortable: true), .local(comfortable: false), .bridged, .downloadingLocked,
        .provider("Anthropic"), .none,
    ]

    static func advanced(_ plan: OnboardingPlan, _ brain: OnboardingBrainState = .local(comfortable: true))
        -> OnboardingPlan
    {
        var plan = plan
        plan.advance(OnboardingAppSnapshot(plan: plan, brain: brain))
        return plan
    }

    static func panel(_ plan: OnboardingPlan, _ brain: OnboardingBrainState = .local(comfortable: true))
        -> OnboardingPanel?
    {
        OnboardingPanel.make(plan: plan, brain: brain, team: team, sessionId: plan.sessionId ?? UUID())
    }

    static func asks(_ panel: OnboardingPanel?) -> [String] {
        panel?.buttons.compactMap { if case .ask(let id) = $0.action { return id } else { return nil } } ?? []
    }

    static func onPath(_ pathId: String, outcome: OnboardingPlan.RequestOutcome? = .granted) -> OnboardingPlan {
        var plan = OnboardingPlan(sessionId: UUID())
        plan.select(pathId: pathId)
        plan.requestOutcome = outcome
        return advanced(plan)
    }

    // MARK: - Opening and plan

    static func opening(_ probe: inout Probe) {
        var texts: Set<String> = []
        for brain in brains {
            let text = OnboardingOpening.text(profile: profile, brain: brain)
            texts.insert(text)
            probe.expect(text.hasPrefix("Hi, I am Osaurus,"), "\(brain): greets without guessing a name")
            probe.expect(text.contains(OnboardingOpening.introLine), "\(brain): says what Osaurus does")
            probe.expect(
                !text.contains("MacBook Air") && !text.contains("16 GB"),
                "\(brain): no hardware recital"
            )
            probe.expect(!team.contains { text.contains($0.name) }, "\(brain): the cards show the team, not the opening")
            probe.expect(text.contains(OnboardingOpening.whereLine(brain)), "\(brain): says where it runs")
        }
        let distinct = Set(brains.map(OnboardingOpening.whereLine)).count
        probe.expect(texts.count == distinct, "one variant per place it runs (\(texts.count)/\(distinct))")
    }

    static func planFromState(_ probe: inout Probe) {
        let local = advanced(OnboardingPlan(sessionId: UUID()))
        probe.expect(local.status(of: OnboardingSteps.brain) == .done, "a committed model hides the brain step")
        probe.expect(local.current?.id == OnboardingSteps.choice, "local: starts at the cards")
        let none = advanced(OnboardingPlan(sessionId: UUID()), .none)
        probe.expect(none.current?.id == OnboardingSteps.brain, "no model: starts at the brain step")
        let locked = advanced(OnboardingPlan(sessionId: UUID()), .downloadingLocked)
        probe.expect(locked.current?.id == OnboardingSteps.choice, "downloading: the cards still work")
        let builder = OnboardingPaths.available(teammates: [.planner, .courier, .keeper, .scout]).map(\.id)
        probe.expect(
            builder == ["planner", "courier", "keeper", "scout", "osaurus"], "cards follow the team, Osaurus last: \(builder)")
        let developer = OnboardingPaths.available(teammates: Set(Teammate.allCases)).map(\.id)
        probe.expect(developer.contains("builder"), "Builder's card only with Builder")
    }

    static func zeroModelRun(_ probe: inout Probe) {
        for path in OnboardingPaths.available(teammates: Set(Teammate.allCases)) {
            let plan = onPath(path.id)
            probe.expect(plan.current?.id == OnboardingSteps.firstTask, "\(path.id): buttons reach the first task")
            let shown = panel(plan)
            let fallback = OnboardingSteps.definition(id: OnboardingSteps.firstTask)?.fallbackLine ?? ""
            probe.expect(shown != nil && !fallback.isEmpty, "\(path.id): a panel and a fallback line, no generation")
        }
    }

    static func stepControl(_ probe: inout Probe) {
        let choice = advanced(OnboardingPlan(sessionId: UUID()))
        probe.expect(
            OnboardingTurnRouter.stepAction("Skip", plan: choice, team: team) == .dismissSetup, "skip on the cards"
        )
        probe.expect(
            OnboardingTurnRouter.stepAction("planner", plan: choice, team: team) == .selectPath("planner"),
            "a card's name selects it"
        )
        var plan = choice
        plan.select(pathId: "planner")
        plan = advanced(plan)
        probe.expect(plan.current?.id == OnboardingSteps.firstTask, "a tap moves to the first task")
        probe.expect(OnboardingTurnRouter.stepAction("go back", plan: plan, team: team) == .back, "back")
        probe.expect(OnboardingTurnRouter.stepAction("later", plan: plan, team: team) == .dismissSetup, "later")
        plan.back()
        plan = advanced(plan)
        probe.expect(plan.pathId == nil && plan.current?.id == OnboardingSteps.choice, "back returns to the cards")
    }

    static func noSelfCompletion(_ probe: inout Probe) {
        let plan = onPath("planner")
        for claim in ["Done, I connected your calendar.", "All set, the step is finished", "I turned it on for you"] {
            probe.expect(
                OnboardingTurnRouter.stepAction(claim, plan: plan, team: team) == nil,
                "\"\(claim)\" is no step"
            )
        }
        probe.expect(advanced(plan) == plan, "the plan moves only on the person's action")
    }

    // MARK: - Team

    static func entry(_ teammate: Teammate) -> AgentEntry? { TeamSeeder.template(for: teammate)?.agent }

    static func teamSettings(_ probe: inout Probe) {
        let apps: [Teammate: [String]] = [
            .planner: ["calendar", "reminders"], .courier: ["mail"], .keeper: ["notes"], .scout: [], .builder: [],
        ]
        for teammate in Teammate.allCases {
            guard let entry = entry(teammate), let caps = entry.capabilities else {
                probe.expect(false, "\(teammate): template loads")
                continue
            }
            probe.expect(caps.appleApps == apps[teammate], "\(teammate): apps \(caps.appleApps ?? [])")
            probe.expect(caps.webSearchEnabled == (teammate == .scout), "\(teammate): web search only for Scout")
            probe.expect(
                caps.memoryEnabled == (teammate == .planner || teammate == .builder),
                "\(teammate): memory switch"
            )
            probe.expect(caps.redactionToolsEnabled == false, "\(teammate): redaction off on day one")
            probe.expect(
                caps.relayEnabled == false && caps.selfSchedulingEnabled == false && caps.searchMemoryEnabled == false,
                "\(teammate): relay, self-scheduling, and memory search off"
            )
            probe.expect(
                caps.clarifyEnabled == true && entry.orchestratorSpawnable == true,
                "\(teammate): clarify, spawnable"
            )
            probe.expect(entry.subagents?.enabled == false, "\(teammate): no subagents")
            probe.expect(
                entry.description?.contains("Not for") == true,
                "\(teammate): description says what it is not for"
            )
            probe.expect(
                (TeamSeeder.template(for: teammate)?.quickActions?.count ?? 0) >= 3,
                "\(teammate): quick actions"
            )
        }
        probe.expect(entry(.keeper)?.workingFolderReadOnly == true, "Keeper's Downloads is read only")
        probe.expect(entry(.builder)?.sandbox?.networkEnabled == false, "Builder's sandbox has no network")
    }

    /// The schema a wrapper run sees: a `.delegation` session in the
    /// teammate's folder.
    @MainActor
    static func wrapperSchema(_ agent: Agent, folder: URL) -> Set<String> {
        let mode: ExecutionMode =
            agent.workingFolderPath == nil
            ? .none
            : .hostFolder(
                FolderContext(
                    rootPath: folder,
                    projectType: .unknown,
                    tree: "./\n",
                    manifest: nil,
                    gitStatus: nil,
                    isGitRepo: false
                )
            )
        return ChatExecutionContext.$currentSessionSource.withValue(.delegation) {
            Set(SystemPromptComposer.resolveTools(agentId: agent.id, executionMode: mode).map(\.function.name))
        }
    }

    /// Creates the team in this process's (isolated) store, hands it to
    /// `body`, and deletes it again.
    @MainActor
    static func withTeam(_ body: ([Teammate: Agent], URL) -> Void) async {
        FolderToolManager.shared.ensureFolderToolsRegistered()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "onboarding-eval-\(UUID().uuidString)"
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let created = await TeamSeeder.$workingFolderOverrideForTests.withValue(folder.path) {
            await TeamSeeder.create(Teammate.allCases)
        }
        let byTeammate = Dictionary(
            created.compactMap { agent in agent.teammate.map { ($0, agent) } },
            uniquingKeysWith: { a, _ in a }
        )
        body(byTeammate, folder)
        for agent in created { _ = await AgentManager.shared.delete(id: agent.id) }
        try? FileManager.default.removeItem(at: folder)
    }

    static let baseline: Set<String> = ["capabilities", "get_current_time"]

    @MainActor
    static func toolBudget(_ probe: inout Probe) async {
        var lines = Probe()
        await withTeam { agents, folder in
            let domain: [Teammate: Set<String>] = [
                .planner: AppleApp.toolNames(for: [.calendar, .reminders]),
                .courier: AppleApp.toolNames(for: [.mail]),
                .keeper: AppleApp.toolNames(for: [.notes]).union(["file_read", "file_search"]),
                .scout: ["web_search", "search_and_extract", "share_artifact"],
            ]
            for teammate in [Teammate.planner, .courier, .keeper, .scout] {
                guard let agent = agents[teammate] else {
                    lines.expect(false, "\(teammate) was created")
                    continue
                }
                let real = wrapperSchema(agent, folder: folder)
                let tools = real.subtracting(baseline)
                lines.expect(
                    tools == domain[teammate],
                    "\(teammate): \(tools.count) domain tools, \(real.count) in the real schema \(real.sorted())"
                )
                lines.expect(tools.count <= 13, "\(teammate): within the day-one budget of 13")
            }
            if var courier = agents[.courier] {
                courier.settings.enabledAppleApps = [.mail, .messages]
                AgentManager.shared.update(courier)
                let connected = wrapperSchema(courier, folder: folder).subtracting(baseline)
                lines.expect(connected.count == 14, "Courier with Messages connected: \(connected.count)")
            }
        }
        probe.lines += lines.lines
    }

    /// Private data, untrusted input, and a way out of the Mac: no teammate
    /// holds all three. Mail sends go through the approval card.
    @MainActor
    static func isolation(_ probe: inout Probe) async {
        var lines = Probe()
        await withTeam { agents, folder in
            let web: Set<String> = ["web_search", "search_and_extract"]
            for (teammate, agent) in agents.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let schema = wrapperSchema(agent, folder: folder)
                let privateData =
                    !schema.intersection(AppleApp.toolNames(for: Set(AppleApp.allCases))).isEmpty
                    || schema.contains("file_read") || agent.workingFolderPath != nil
                let outbound = !schema.isDisjoint(with: web)
                lines.expect(!(privateData && outbound), "\(teammate): private=\(privateData) outbound=\(outbound)")
            }
            if let scout = agents[.scout] {
                let schema = wrapperSchema(scout, folder: folder)
                let reach = schema.filter { AppleApp.app(forTool: $0) != nil || $0.hasPrefix("file_") }
                lines.expect(reach.isEmpty, "Scout holds no app or folder tool \(reach.sorted())")
                lines.expect(!schema.contains("search_memory"), "Scout holds no memory tool")
            }
            if let courier = agents[.courier] {
                let schema = wrapperSchema(courier, folder: folder).subtracting(baseline)
                lines.expect(schema == AppleApp.toolNames(for: [.mail]), "Courier holds the Mail tools only")
            }
        }
        probe.lines += lines.lines
    }

    // MARK: - Workflows

    static func bundledWorkflows() -> [Template] {
        TeamSeeder.bundledDefaultWorkflows() + PreparedAskCatalog.templates()
    }

    static func toolSteps(_ template: Template) -> [(node: WorkflowNode, spec: ToolNodeSpec)] {
        func steps(_ node: WorkflowNode) -> [(node: WorkflowNode, spec: ToolNodeSpec)] {
            switch node.kind {
            case .tool(let spec): return [(node, spec)]
            case .map(let spec): return steps(spec.body(parentID: node.id))
            default: return []
            }
        }
        return (template.workflow?.nodes ?? []).flatMap(steps)
    }

    @MainActor
    static func bundledReferences(_ probe: inout Probe) async {
        var agents: [Agent] = []
        var ids: [Teammate: UUID] = [:]
        for teammate in Teammate.allCases {
            var renamed = Agent(name: "My \(teammate.rawValue)", systemPrompt: "")
            renamed.sourceTemplateID = teammate.templateID
            ids[teammate] = renamed.id
            agents += [renamed, Agent(name: teammate.rawValue.capitalized, systemPrompt: "")]
        }
        for template in bundledWorkflows() {
            for (node, spec) in toolSteps(template) {
                let teammate = spec.tool.agent.flatMap(UUID.init(uuidString:)).flatMap(
                    Teammate.teammate(forTemplateID:)
                )
                probe.expect(teammate != nil, "\(template.name)/\(node.id): `agent` is a teammate UUID")
                let resolved = spec.tool.agent.flatMap { WorkflowStepAgent.resolve($0, in: agents) }
                probe.expect(
                    teammate != nil && resolved?.id == ids[teammate!],
                    "\(template.name)/\(node.id): after a rename, still runs as \(teammate?.rawValue ?? "?")"
                )
            }
        }
    }

    static let readOnlyTools: Set<String> = [
        "calendar_events", "reminders_fetch", "mail_list", "mail_read", "mail_search", "notes_search", "notes_list",
        "file_search", "file_read", "search_and_extract", "git_status", "git_diff", "git_log",
    ]

    static func defaultWorkflows(_ probe: inout Probe) {
        let all = TeamSeeder.bundledDefaultWorkflows()
        probe.expect(all.count == 7, "seven default workflows (\(all.count))")
        let plain = TeamSeeder.defaultWorkflowTemplates(.init(developerMac: false, brainIsLocal: true))
        probe.expect(plain.count == 6, "Repo Digest only on a developer Mac")
        for template in all {
            guard let def = template.workflow else {
                probe.expect(false, "\(template.name) is a workflow")
                continue
            }
            let required = def.inputSchema.objectValue?["required"]?.arrayValue ?? []
            probe.expect(
                required.isEmpty == (template.name != "Research Brief"),
                "\(template.name): needs no input except Research Brief's topic"
            )
            let calls = toolSteps(template).map(\.spec.tool.name)
            probe.expect(Set(calls).isSubset(of: readOnlyTools), "\(template.name): reads only \(calls)")
            probe.expect(def.nodes.count <= 6, "\(template.name): \(def.nodes.count) steps")
        }
    }

    /// Every bundled workflow and prepared ask passes the strict validator,
    /// and each tool step sends only the arguments its registered tool
    /// declares, with every required one.
    static func bundledContracts(_ probe: inout Probe) {
        FolderToolManager.shared.ensureFolderToolsRegistered()
        let prepared = (PreparedAskCatalog.resourceNames + PreparedAskCatalog.writeResourceNames)
            .compactMap(TeamSeeder.loadBundled)
        for template in TeamSeeder.bundledDefaultWorkflows() + prepared {
            guard let def = template.workflow else {
                probe.expect(false, "\(template.name) is a workflow")
                continue
            }
            let issues = WorkflowValidator.validate(def, allowPlaceholders: false)
            probe.expect(issues.isEmpty, "\(template.name): valid \(issues.map(\.message))")
            for (node, spec) in toolSteps(template) {
                guard let schema = ToolRegistry.shared.parametersForTool(name: spec.tool.name)?.objectValue else {
                    probe.expect(false, "\(template.name)/\(node.id): \(spec.tool.name) is a registered tool")
                    continue
                }
                let declared = Set(schema["properties"]?.objectValue?.keys.map { $0 } ?? [])
                let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
                let sent = node.input.fieldNames
                probe.expect(
                    sent.isSubset(of: declared) && required.isSubset(of: sent),
                    "\(template.name)/\(node.id): \(spec.tool.name) arguments \(sent.sorted()) match its schema"
                )
            }
        }
    }

    static func preparedReads(_ probe: inout Probe) {
        // Osaurus's own asks are ordinary messages to it, not prepared reads.
        for path in OnboardingPaths.all where path.teammate != nil {
            for ask in path.asks {
                guard let id = ask.workflowId else {
                    probe.expect(false, "\(ask.id): every card ask runs a workflow")
                    continue
                }
                let template =
                    PreparedAskCatalog.template(id: id)
                    ?? TeamSeeder.bundledDefaultWorkflows().first { $0.id == id }
                guard let template, let def = template.workflow else {
                    probe.expect(false, "\(ask.id): its workflow exists")
                    continue
                }
                let steps = toolSteps(template)
                let isPrepared = PreparedAskCatalog.template(id: id) != nil
                if isPrepared {
                    probe.expect(steps.count <= 2, "\(ask.id): \(steps.count) fixed read(s)")
                }
                probe.expect(
                    steps.allSatisfy { readOnlyTools.contains($0.spec.tool.name) && $0.spec.tool.agent != nil },
                    "\(ask.id): each read is a fixed call under a teammate"
                )
                let dated = steps.filter { step in
                    (try? JSONEncoder().encode(step.node.input)).map { String(decoding: $0, as: UTF8.self) }?.contains(
                        "nodes.range.output"
                    ) == true
                }
                let hasRange = def.nodes.contains { $0.id == "range" && $0.kindName == "code" }
                probe.expect(dated.isEmpty || hasRange, "\(ask.id): dates come from a code step")
                let call = OnboardingFirstRun.dispatch(for: ask)
                let args = call.flatMap { JSONValue.parse($0.jsonArguments)?.objectValue }
                probe.expect(
                    call?.toolName == RunWorkflowTool.toolName && args?["workflow"]?.stringValue == id.uuidString,
                    "\(ask.id): the button runs run_workflow by id"
                )
            }
        }
    }

    static func heldOnBridge(_ probe: inout Probe) {
        let bridged = panel(onPath("planner"), .bridged)
        probe.expect(asks(bridged).isEmpty, "on the bridge, personal asks wait")
        probe.expect(asks(panel(onPath("scout"), .bridged)).count == 2, "Scout's web asks stay on the bridge")
        let provider = panel(onPath("courier", outcome: nil), .provider("Anthropic"))
        probe.expect(provider?.note?.contains("Anthropic") == true, "on a provider, the request says where data goes")
        probe.expect(provider?.buttons.first?.action == .request, "the request comes before the dialog")
        let denied = panel(onPath("planner", outcome: .denied))
        probe.expect(
            denied?.buttons.contains { $0.action == .openSettings(.calendar) } == true,
            "a denial links Settings"
        )
        probe.expect(!asks(denied).isEmpty, "a denial leaves the other asks usable")
    }

    static func skipSetup(_ probe: inout Probe) {
        let starts: [(String, OnboardingPlan)] = [
            ("brain", advanced(OnboardingPlan(sessionId: UUID()), .none)),
            ("cards", advanced(OnboardingPlan(sessionId: UUID()))),
            ("first task", onPath("planner")),
        ]
        for (name, start) in starts {
            probe.expect(start.current != nil, "\(name): the walkthrough is on a step")
            var plan = start
            plan.dismiss()
            plan = advanced(plan)
            probe.expect(plan.finishReason == .dismissed && plan.isComplete, "\(name): Skip setup ends setup")
            probe.expect(panel(plan) == nil, "\(name): no panel after Skip setup")
        }
        var done = onPath("planner")
        done.finish(.firstTask, askId: "planner.today")
        done.firstTaskSucceeded = true
        done = advanced(done)
        probe.expect(done.isComplete && done.current == nil, "setup ends at the first task, with nothing after it")
        probe.expect(
            OnboardingSteps.all.map(\.id) == [OnboardingSteps.brain, OnboardingSteps.choice, OnboardingSteps.firstTask],
            "three walkthrough steps"
        )
        var stored = onPath("planner")
        stored.steps.append(.init(id: "keep", status: .pending))
        stored.finish(.firstTask)
        stored.dropRetiredSteps()
        probe.expect(advanced(stored).isComplete, "a stored plan with a retired step still settles")
    }

    static func seededState(_ probe: inout Probe) {
        var plan = onPath("planner", outcome: .denied)
        plan.finish(.firstTask)
        let facts = OnboardingFirstRun.handoverFacts(plan: plan, location: .thisMac, team: team)
        probe.expect(facts.contains("This chat runs: On this Mac."), "holds where the chat runs")
        probe.expect(facts.contains { $0.contains("Planner") }, "holds the path")
        probe.expect(facts.allSatisfy { $0.count <= SessionState.maxItemCharacters }, "each fact fits the state")
        let walkthrough = OnboardingOpening.text(profile: profile, brain: .local(comfortable: true))
        probe.expect(!facts.contains { walkthrough.contains($0) }, "the walkthrough is not carried over")
    }

    static func wording(_ probe: inout Probe) {
        let banned = ["run_workflow", "configurator_handoff", "Orchestrator", "Configurator", "subagent", "tool call"]
        var texts = brains.map { OnboardingOpening.text(profile: profile, brain: $0) }
        texts += OnboardingSteps.all.map(\.fallbackLine) + OnboardingSteps.all.map(\.card)
        texts += OnboardingPaths.all.flatMap { [$0.introLine, $0.job, $0.pitch] + $0.asks.map(\.label) }
        for text in texts {
            let hit = banned.filter { text.localizedCaseInsensitiveContains($0) }
            probe.expect(hit.isEmpty, "no tool or role names: \(text.prefix(60))")
            probe.expect(!text.localizedCaseInsensitiveContains("go offline"), "no request to go offline")
        }
        let questions = texts.prefix(brains.count).map { $0.filter { $0 == "?" }.count }
        probe.expect(questions.allSatisfy { $0 <= 1 }, "one question per opening")
    }

    static func promptBudget(_ probe: inout Probe) {
        var turns: [ChatTurn] = []
        var plan = onPath("planner")
        var worst = 0
        for turn in 0 ..< 20 {
            let message = "turn \(turn) " + String(repeating: "word ", count: 2000)
            let (system, prompt) = OnboardingSystemPromptBuilder.build(
                .init(plan: plan, location: .provider("Osaurus Cloud"), team: team, history: turns, message: message)
            )
            worst = max(
                worst,
                OnboardingSystemPromptBuilder.tokens(system) + OnboardingSystemPromptBuilder.tokens(prompt)
            )
            turns.append(ChatTurn(role: .user, content: message))
            turns.append(ChatTurn(role: .assistant, content: String(repeating: "reply ", count: 400)))
            if turn == 10 { plan.requestOutcome = .denied }
        }
        probe.expect(
            worst <= OnboardingSystemPromptBuilder.tokenBudget,
            "largest prompt over 20 turns: \(worst) of \(OnboardingSystemPromptBuilder.tokenBudget) tokens"
        )
    }

    static func discovery(_ probe: inout Probe) {
        var fresh = DiscoverySnapshot()
        fresh.keeperExists = true
        fresh.courierExists = true
        let order = DiscoveryCatalog.defaultOrder
        func isOpen(_ snapshot: DiscoverySnapshot) -> (DiscoveryItem) -> Bool {
            { DiscoveryCatalog.status($0, in: snapshot) == .open }
        }
        var state = DiscoveryState()
        let first = DiscoveryStore.pick(order: order, isOpen: isOpen(fresh), state: &state, today: "2026-11-04")
        let again = DiscoveryStore.pick(order: order, isOpen: isOpen(fresh), state: &state, today: "2026-11-04")
        probe.expect(first != nil && again == first, "one new card per day; the same card repeats that day")
        let next = DiscoveryStore.pick(order: order, isOpen: isOpen(fresh), state: &state, today: "2026-11-05")
        probe.expect(next != nil && next != first, "a new day brings one new card")
        if let first { state.retired.insert(first) }
        var picks: [DiscoveryItem] = []
        for day in 6 ... 9 {
            if let item = DiscoveryStore.pick(
                order: order,
                isOpen: isOpen(fresh),
                state: &state,
                today: "2026-11-0\(day)"
            ) {
                picks.append(item)
            }
        }
        probe.expect(!picks.contains { $0 == first }, "a dismissed item never returns")
        var done = fresh
        done.keeperRedactionOn = true
        probe.expect(DiscoveryCatalog.status(.keeperRedaction, in: done) == .done, "a completed item is done")
        var messages = fresh
        probe.expect(DiscoveryCatalog.status(.messages, in: messages) == .open, "Messages opens once Courier exists")
        messages.fullDiskAccess = true
        messages.courierHasMessages = true
        probe.expect(DiscoveryCatalog.status(.messages, in: messages) == .done, "Messages is done once connected")
    }
}

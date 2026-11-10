//
//  ConfigEventsRoundTripTests.swift
//  osaurusTests
//
//  The `events:` declarative section: export → build → export is the
//  identity for every source kind, absent keys patch over the stored event,
//  invalid entries fail with a pointed message, risky changes are flagged,
//  and legacy `schedules:` / `watchers:` / `channels.*.inbound_*` input is
//  translated (idempotently) with a deprecation note; retired email
//  automations are dropped with a note.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ConfigEventsRoundTripTests {
    static let agentName = "Helper"
    static let target = AgentDispatchTarget.local(UUID())

    static func resolveAgent(_ value: String) -> AgentDispatchTarget? {
        value.caseInsensitiveCompare(agentName) == .orderedSame ? target : nil
    }

    static func build(
        _ entry: EventEntry, existing: OsaurusEvent? = nil
    ) -> Result<ConfigEvents.BuildOutcome, ConfigEventError> {
        ConfigEvents.build(
            entry, existing: existing, resolveAgent: resolveAgent, resolveWorkflow: { _ in nil },
            mintBookmarks: false)
    }

    static func exported(_ event: OsaurusEvent) -> EventEntry {
        var entry = ConfigEvents.export(event)
        if event.action.agent != nil { entry.agent = agentName }
        return entry
    }

    static func agent(_ instructions: String = "Handle it") -> EventAction {
        .agent(AgentEventAction(target: target, instructions: instructions))
    }

    static func sampleEvents(folder: String) -> [OsaurusEvent] {
        [
            OsaurusEvent(
                name: "Weekly digest",
                source: .schedule(ScheduleSourceConfig(frequency: .weekly(dayOfWeek: 2, hour: 9, minute: 15))),
                action: agent("Write the digest"),
                delivery: EventDeliveryPolicy(mode: .serial, maxQueued: 0, missedFirePolicy: .skip)),
            OsaurusEvent(
                name: "Receipts",
                isEnabled: false,
                source: .folder(FolderSourceConfig(path: folder, recursive: true, responsiveness: .patient)),
                filter: EventFilter(pathGlobs: ["*.pdf"]),
                action: agent("File receipts")),
            OsaurusEvent(
                name: "GitHub pushes",
                source: .webhook(
                    WebhookSourceConfig(
                        verification: .hmacSHA256, signatureHeader: "X-Hub-Signature-256", maxBodyBytes: 65_536,
                        rateLimitPerMinute: 30)),
                filter: EventFilter(conditions: [EventCondition(path: "webhook.body.ref", equals: "refs/heads/main")]),
                action: agent("Summarize {{webhook.body.head_commit.message}}"),
                delivery: EventDeliveryPolicy(mode: .parallel, maxConcurrent: 3, maxQueued: 10, dedupeWindowSeconds: 900)),
            OsaurusEvent(
                name: "GitHub issues",
                source: .webhook(WebhookSourceConfig(provider: .github, sampleBody: #"{"action": "opened"}"#)),
                action: agent("Triage {{webhook.body.issue.title}}")),
            OsaurusEvent(
                name: "Release feed",
                source: .rss(
                    RSSSourceConfig(
                        url: "https://example.com/releases.xml", pollIntervalSeconds: 1800, catchUp: .sinceCursor,
                        maxItemsPerTick: 5)),
                filter: EventFilter(keywordsAny: ["swift"]),
                action: agent("Summarize {{feed.item.title}}")),
            OsaurusEvent(
                name: "Status stream",
                source: .sse(
                    SSESourceConfig(
                        url: "https://status.example.com/stream", headers: ["Accept-Language": "en"],
                        eventNames: ["incident"], heartbeatTimeoutSeconds: 120)),
                action: agent("Report {{sse.data.title}}")),
            OsaurusEvent(
                name: "Failures",
                source: .runFailed(RunFailedSourceConfig(includeAutomationRuns: true)),
                action: agent("Explain {{failure.error}}")),
            OsaurusEvent(
                name: "On launch",
                source: .app(AppEventsSourceConfig(reasons: [.appLaunched, .automationUpdated])),
                action: agent("Warm up")),
            OsaurusEvent(
                name: "Support room",
                source: .channelMessage(
                    ChannelMessageSourceConfig(
                        kind: .slack, roomIds: ["C123"], aliases: ["support"], requireMention: false,
                        continueThreads: false)),
                filter: EventFilter(senderAllowlist: ["U1"], keywordsAny: ["help"], keywordsAll: ["urgent"]),
                action: agent("Triage"),
                reply: EventReplyPolicy(autoReply: true)),
        ]
    }

    // MARK: - Round trip

    @Test func exportBuildExportIsTheIdentityForEverySourceKind() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-evt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for event in Self.sampleEvents(folder: folder.path) {
            let entry = Self.exported(event)
            let outcome = try Self.build(entry).get()
            #expect(Self.exported(outcome.event) == entry, "round trip changed \(event.name)")
            #expect(outcome.event.sourceKind == event.sourceKind)
            #expect(outcome.event.filter == event.filter)
            #expect(outcome.event.delivery == event.delivery)
            #expect(outcome.event.reply == event.reply)
            #expect(outcome.event.isEnabled == event.isEnabled)
            #expect(outcome.event.target == Self.target)

            let data = try JSONEncoder().encode(entry)
            #expect(try JSONDecoder().decode(EventEntry.self, from: data) == entry)
        }
    }

    @Test func webhookSampleBodyRoundTripsAndIsBoundedByTheBodyLimit() throws {
        var config = WebhookSourceConfig(verification: .hmacSHA256)
        config.sampleBody = #"{"issue":{"title":"Crash"}}"#
        let event = OsaurusEvent(name: "Issues", source: .webhook(config), action: Self.agent())
        let entry = Self.exported(event)
        #expect(entry.source?.sampleBody == config.sampleBody)
        #expect(try Self.build(entry).get().event.source.webhook?.sampleBody == config.sampleBody)

        var cleared = EventEntry(name: "Issues")
        cleared.source = EventSourceEntry(kind: "webhook")
        cleared.source?.sampleBody = "  "
        #expect(try Self.build(cleared, existing: event).get().event.source.webhook?.sampleBody == nil)

        var tooBig = cleared
        tooBig.source?.maxBodyBytes = 4
        tooBig.source?.sampleBody = "{\"a\": 1}"
        guard case .failure(let error) = Self.build(tooBig, existing: event) else {
            Issue.record("a sample longer than max_body_bytes must fail")
            return
        }
        #expect(error.message.contains("sample_body"))
    }

    @Test func newTriggerKindsBuildFromAMinimalDocument() throws {
        func entry(_ kind: String, _ configure: (inout EventSourceEntry) -> Void = { _ in }) -> EventEntry {
            var entry = EventEntry(name: kind)
            var source = EventSourceEntry(kind: kind)
            configure(&source)
            entry.source = source
            entry.agent = Self.agentName
            entry.instructions = "Go"
            return entry
        }
        let rss = try Self.build(entry("rss") { $0.url = "https://example.com/feed" }).get().event
        #expect(rss.source.rss == RSSSourceConfig(url: "https://example.com/feed"))
        #expect(rss.delivery.dedupe == .durable)
        let sse = try Self.build(entry("sse") { $0.url = "https://example.com/s"; $0.heartbeatTimeoutSeconds = 0 })
            .get().event
        #expect(sse.source.sse?.heartbeatTimeoutSeconds == nil)
        let failed = try Self.build(entry("run_failed")).get().event
        #expect(failed.source.runFailed == RunFailedSourceConfig())
        let app = try Self.build(entry("app") { $0.reasons = ["automation_enabled", "app_launched"] }).get().event
        #expect(app.source.app?.reasons == [.appLaunched, .automationEnabled])
        #expect(app.delivery.dedupe == .none)

        let workflowID = UUID()
        let named = ConfigEvents.build(
            entry("run_failed") { $0.workflows = ["Digest"] }, existing: nil, resolveAgent: Self.resolveAgent,
            resolveWorkflow: { $0 == "Digest" ? workflowID : nil }, mintBookmarks: false)
        #expect(try named.get().event.source.runFailed?.workflowIDs == [workflowID])
    }

    @Test func providerWebhooksValidateAndAskForThePastedSecret() throws {
        var entry = EventEntry(name: "Payments")
        entry.source = EventSourceEntry(kind: "webhook")
        entry.source?.provider = "stripe"
        entry.agent = Self.agentName
        entry.instructions = "Book it"
        let outcome = try Self.build(entry).get()
        #expect(outcome.event.source.webhook?.provider == .stripe)
        #expect(outcome.needsUserAction)
        #expect(outcome.notes.contains { $0.contains("signing secret") })
        #expect(Self.exported(outcome.event).source?.verification == nil, "a provider exports no verification keys")

        var github = entry
        github.source?.provider = "github"
        let gh = try Self.build(github).get()
        #expect(!gh.needsUserAction)
        #expect(gh.notes.contains { $0.contains("and secret") })

        var mixed = entry
        mixed.source?.verification = "hmac_sha256"
        guard case .failure(let error) = Self.build(mixed) else {
            Issue.record("a provider with verification keys must fail")
            return
        }
        #expect(error.message.contains("verification"))

        var unknown = entry
        unknown.source?.provider = "zapier"
        guard case .failure(let unknownError) = Self.build(unknown) else {
            Issue.record("an unknown provider must fail")
            return
        }
        #expect(unknownError.message.contains("source.provider"))
    }

    @Test func newTriggerKindsRejectBadValues() {
        func failure(_ kind: String, _ configure: (inout EventSourceEntry) -> Void) -> String? {
            var entry = EventEntry(name: "Bad")
            var source = EventSourceEntry(kind: kind)
            configure(&source)
            entry.source = source
            entry.agent = Self.agentName
            entry.instructions = "Go"
            if case .failure(let error) = Self.build(entry) { return error.message }
            return nil
        }
        #expect(failure("rss") { _ in }?.contains("`url` is required") == true)
        #expect(failure("rss") { $0.url = "ftp://x" }?.contains("source.url") == true)
        #expect(failure("rss") { $0.url = "https://x.com/f"; $0.pollIntervalSeconds = 5 }?.contains("poll_interval_seconds") == true)
        #expect(failure("rss") { $0.url = "https://x.com/f"; $0.maxItemsPerTick = 0 }?.contains("max_items_per_tick") == true)
        #expect(failure("rss") { $0.url = "https://x.com/f"; $0.catchUp = "all" }?.contains("catch_up") == true)
        #expect(failure("sse") { $0.url = "https://x.com/s"; $0.heartbeatTimeoutSeconds = 5 }?.contains("heartbeat") == true)
        #expect(failure("run_failed") { $0.workflows = ["Missing"] }?.contains("source.workflows") == true)
        #expect(failure("app") { $0.reasons = ["reboot"] }?.contains("source.reasons") == true)
        #expect(failure("app") { $0.reasons = [] }?.contains("at least one") == true)
    }

    @Test func emailAutomationsAreRetiredWithANoteAndLeftAlone() throws {
        let stored = OsaurusEvent(
            name: "Invoices", source: .email(EmailSourceConfig(connectionId: "c1")), action: Self.agent())
        #expect(ConfigEvents.export([stored]).isEmpty)
        #expect(!ConfigEventScope.automations.owns(stored))

        var entry = EventEntry(name: "Invoices")
        entry.agent = Self.agentName
        entry.instructions = "File it"
        entry.source = EventSourceEntry(kind: "email")
        entry.source?.connection = "Work"
        guard case .failure(let error) = Self.build(entry) else {
            Issue.record("an email automation must not build")
            return
        }
        #expect(error.message.contains("channels.email"))

        var document = OsaurusConfigDocument()
        var schedule = EventEntry(name: "Daily")
        schedule.source = EventSourceEntry(kind: "schedule")
        document.automations = [entry, schedule]
        let (translated, notes) = document.translatingLegacyEvents()
        #expect(translated.automations?.map(\.name) == ["Daily"])
        #expect(notes.contains { $0.contains("`Invoices`") && $0.contains("channels.email.sender_allowlist") })
        #expect(translated.translatingLegacyEvents().notes.isEmpty)
    }

    @Test func dedupeModeSurvivesADeliveryBlockAndOlderWindowOnlyDocuments() throws {
        var event = Self.sampleEvents(folder: "/tmp")[2]
        event.delivery.dedupe = .durable
        let entry = Self.exported(event)
        #expect(entry.delivery?.dedupe == "durable")
        #expect(entry.delivery?.dedupeWindowSeconds == nil)
        #expect(try Self.build(entry).get().event.delivery.dedupe == .durable)

        func dedupe(_ change: (inout EventDeliveryEntry) -> Void) throws -> EventDedupePolicy {
            var patch = EventEntry(name: event.name)
            var delivery = EventDeliveryEntry()
            change(&delivery)
            patch.delivery = delivery
            return try Self.build(patch, existing: event).get().event.delivery.dedupe
        }
        #expect(try dedupe { $0.maxQueued = 3 } == .durable)
        #expect(try dedupe { $0.dedupeWindowSeconds = 120 } == .window(120))
        #expect(try dedupe { $0.dedupeWindowSeconds = 0 } == .none)
        #expect(try dedupe { $0.dedupe = "window" } == .window(EventDedupePolicy.defaultWindowSeconds))
        #expect(try dedupe { $0.dedupe = "none" } == .none)

        var bad = EventEntry(name: event.name)
        bad.delivery = EventDeliveryEntry()
        bad.delivery?.dedupe = "durable"
        bad.delivery?.dedupeWindowSeconds = 60
        guard case .failure(let error) = Self.build(bad, existing: event) else {
            Issue.record("a window with a durable dedupe must fail")
            return
        }
        #expect(error.message.contains("dedupe_window_seconds"))
        bad.delivery?.dedupeWindowSeconds = nil
        bad.delivery?.dedupe = "forever"
        guard case .failure(let unknown) = Self.build(bad, existing: event) else {
            Issue.record("an unknown dedupe mode must fail")
            return
        }
        #expect(unknown.message.contains("delivery.dedupe"))
    }

    @Test func routingRepliesMapOntoTheActionsReplySwitch() throws {
        var rule = ChannelRoutingRuleEntry(name: "R")
        rule.agent = Self.agentName
        rule.replies = "automatic"
        let auto = try Self.build(rule.eventEntry(kind: .telegram, connection: nil)).get().event
        #expect(auto.reply.autoReply)
        rule.replies = "approval"
        #expect(try !Self.build(rule.eventEntry(kind: .telegram, connection: nil)).get().event.reply.autoReply)
        rule.replies = nil
        #expect(try !Self.build(rule.eventEntry(kind: .telegram, connection: nil)).get().event.reply.autoReply)
        rule.replies = "none"
        guard case .failure(let error) = Self.build(rule.eventEntry(kind: .telegram, connection: nil)) else {
            Issue.record("an agent rule cannot use replies: none")
            return
        }
        #expect(error.message.contains("replies"))
    }

    @Test func webhookExportNeverCarriesTheToken() throws {
        let webhook = WebhookSourceConfig(verification: .sharedSecretHeader)
        let event = OsaurusEvent(name: "Hook", source: .webhook(webhook), action: Self.agent())
        let json = String(decoding: try JSONEncoder().encode(ConfigEvents.export(event)), as: UTF8.self)
        #expect(!json.contains(webhook.token))
        let created = try Self.build(Self.exported(event)).get()
        #expect(created.notes.contains { $0.contains("webhook URL") })
        let patched = try Self.build(EventEntry(name: "Hook"), existing: event).get()
        #expect(patched.event.source.webhook?.token == webhook.token)
    }

    @Test func absentKeysKeepTheStoredValues() throws {
        let stored = Self.sampleEvents(folder: "/tmp")[2]
        var entry = EventEntry(name: stored.name)
        entry.enabled = false
        let patched = try Self.build(entry, existing: stored).get().event
        #expect(patched.id == stored.id)
        #expect(!patched.isEnabled)
        #expect(patched.source == stored.source)
        #expect(patched.filter == stored.filter)
        #expect(patched.delivery == stored.delivery)
        #expect(patched.action == stored.action)

        var newInstructions = EventEntry(name: stored.name)
        newInstructions.instructions = "Only failures"
        let changed = try Self.build(newInstructions, existing: stored).get().event
        #expect(changed.action.agent?.instructions == "Only failures")
        #expect(changed.action.agent?.target == Self.target)
    }

    @Test func changingTheSourceKindReplacesTheSource() throws {
        let stored = Self.sampleEvents(folder: "/tmp")[0]
        var entry = EventEntry(name: stored.name)
        entry.source = EventSourceEntry(kind: "webhook")
        let rebuilt = try Self.build(entry, existing: stored).get().event
        #expect(rebuilt.sourceKind == .webhook)
        #expect(rebuilt.source.webhook?.verification == .hmacSHA256)
    }

    // MARK: - Validation

    @Test func invalidEntriesFailWithAPointedMessage() {
        func message(_ entry: EventEntry, existing: OsaurusEvent? = nil) -> String? {
            if case .failure(let error) = Self.build(entry, existing: existing) { return error.message }
            return nil
        }
        var noKind = EventEntry(name: "New")
        noKind.agent = Self.agentName
        noKind.instructions = "x"
        #expect(message(noKind)?.contains("source.kind") == true)

        var badKind = noKind
        badKind.source = EventSourceEntry(kind: "form")
        #expect(message(badKind)?.contains("must be one of") == true)

        var both = noKind
        both.source = EventSourceEntry(kind: "webhook")
        both.workflow = "Anything"
        #expect(message(both)?.contains("not both") == true)

        var defaultAgent = noKind
        defaultAgent.source = EventSourceEntry(kind: "webhook")
        defaultAgent.agent = "default"
        #expect(message(defaultAgent)?.contains("Default agent") == true)

        var badMode = noKind
        badMode.source = EventSourceEntry(kind: "webhook")
        badMode.delivery = EventDeliveryEntry()
        badMode.delivery?.mode = "fifo"
        #expect(message(badMode)?.contains("delivery.mode") == true)

        var replyOnWebhook = noKind
        replyOnWebhook.source = EventSourceEntry(kind: "webhook")
        replyOnWebhook.reply = EventReplyEntry()
        replyOnWebhook.reply?.autoReply = true
        #expect(message(replyOnWebhook)?.contains("only channel_message automations reply") == true)

        var inputOnAgent = noKind
        inputOnAgent.source = EventSourceEntry(kind: "webhook")
        inputOnAgent.input = ["x": "{{text}}"]
        #expect(message(inputOnAgent)?.contains("only workflow automations take `input`") == true)

        var hugeBody = noKind
        hugeBody.source = EventSourceEntry(kind: "webhook")
        hugeBody.source?.maxBodyBytes = 50_000_000
        #expect(message(hugeBody)?.contains("max_body_bytes") == true)

        var missingFolder = noKind
        missingFolder.source = EventSourceEntry(kind: "folder")
        missingFolder.source?.path = "/definitely/not/here-\(UUID().uuidString)"
        #expect(message(missingFolder)?.contains("not an existing directory") == true)

        var unknownWorkflow = EventEntry(name: "WF")
        unknownWorkflow.source = EventSourceEntry(kind: "webhook")
        unknownWorkflow.workflow = "Nope"
        #expect(message(unknownWorkflow)?.contains("no installed workflow") == true)

        #expect(message(EventEntry(name: "  "))?.contains("non-empty name") == true)

        var noAction = EventEntry(name: "Nothing")
        noAction.source = EventSourceEntry(kind: "webhook")
        #expect(message(noAction) == "automations[Nothing]: \(ConfigEvents.actionRequiredMessage)")
    }

    // MARK: - Instructions alone

    static func promptEntry(
        _ instructions: String? = "Give me a short motivational quote.", model: String? = nil
    ) -> EventEntry {
        var entry = EventEntry(name: "Morning quote")
        var source = EventSourceEntry(kind: "schedule")
        source.frequency = "daily"
        source.frequencyTimeOfDay = "07:30"
        entry.source = source
        entry.instructions = instructions
        entry.model = model
        return entry
    }

    static func buildPrompt(
        _ entry: EventEntry, existing: OsaurusEvent? = nil
    ) -> Result<ConfigEvents.BuildOutcome, ConfigEventError> {
        ConfigEvents.build(
            entry, existing: existing, resolveAgent: resolveAgent, resolveWorkflow: { _ in nil },
            resolveModel: { $0 == "nope" ? .invalid("no model named `nope`") : .resolved($0.lowercased()) },
            mintBookmarks: false)
    }

    @Test func instructionsAloneAskAModelWithNoAgentAndRoundTrip() throws {
        let event = try Self.buildPrompt(Self.promptEntry(model: "Gemma-4")).get().event
        #expect(event.action.kind == .prompt)
        #expect(event.action.prompt == PromptEventAction(instructions: "Give me a short motivational quote.", model: "gemma-4"))
        #expect(event.agentId == nil)
        #expect(event.target == nil)

        let exported = ConfigEvents.export(event)
        #expect(exported.agent == nil)
        #expect(exported.workflow == nil)
        #expect(exported.model == "gemma-4")
        #expect(exported.instructions == "Give me a short motivational quote.")
        #expect(ConfigEvents.export(try Self.buildPrompt(exported).get().event) == exported)

        // No model means "the default model"; instructions alone are enough.
        let noModel = try Self.buildPrompt(Self.promptEntry()).get().event
        #expect(noModel.action.prompt?.model == nil)

        // A patch keeps the prompt; an empty model clears it.
        var patch = EventEntry(name: "Morning quote")
        patch.model = ""
        let cleared = try Self.buildPrompt(patch, existing: event).get().event
        #expect(cleared.action.prompt == PromptEventAction(instructions: event.action.prompt!.instructions, model: nil))
        var reword = EventEntry(name: "Morning quote")
        reword.instructions = "A haiku instead."
        #expect(try Self.buildPrompt(reword, existing: event).get().event.action.prompt?.instructions == "A haiku instead.")

        // Editing an agent automation's instructions keeps it an agent automation.
        let agentEvent = OsaurusEvent(
            name: "Agent one", source: .webhook(WebhookSourceConfig()), action: Self.agent("Old"))
        var agentPatch = EventEntry(name: "Agent one")
        agentPatch.instructions = "New"
        let kept = try Self.buildPrompt(agentPatch, existing: agentEvent).get().event
        #expect(kept.action.kind == .agent)
        #expect(kept.action.agent?.instructions == "New")

        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(OsaurusEvent.self, from: data).action == event.action)
    }

    @Test func instructionsAloneRejectAgentOnlyKeysAndChannelRules() {
        func message(_ entry: EventEntry) -> String? {
            if case .failure(let error) = Self.buildPrompt(entry) { return error.message }
            return nil
        }
        var withAgent = Self.promptEntry(model: "gemma-4")
        withAgent.agent = Self.agentName
        #expect(message(withAgent)?.contains("only an automation with `instructions` alone") == true)

        var withWorkflow = Self.promptEntry(model: "gemma-4")
        withWorkflow.workflow = "Anything"
        #expect(message(withWorkflow)?.contains("only an automation with `instructions` alone") == true)

        for (key, change) in [
            ("input", { (e: inout EventEntry) in e.input = ["x": "y"] }),
            ("working_folder", { (e: inout EventEntry) in e.workingFolder = "/tmp" }),
            ("fresh_session", { (e: inout EventEntry) in e.freshSession = true }),
        ] as [(String, (inout EventEntry) -> Void)] {
            var entry = Self.promptEntry()
            change(&entry)
            #expect(message(entry)?.contains(".\(key):") == true, "\(key) should be rejected")
        }

        var channel = Self.promptEntry()
        channel.source = EventSourceEntry(kind: "channel_message")
        channel.source?.platform = "telegram"
        #expect(message(channel)?.contains("a channel rule runs an agent or a workflow") == true)

        #expect(message(Self.promptEntry("   ", model: "gemma-4"))?.contains("`instructions` is required") == true)
        #expect(message(Self.promptEntry(model: "nope"))?.contains(".model: no model named `nope`") == true)
    }

    @Test func cronSchedulesMustBeRunnable() throws {
        func cron(_ expression: String) -> Result<ConfigEvents.BuildOutcome, ConfigEventError> {
            var entry = Self.promptEntry()
            entry.source?.frequency = "cron"
            entry.source?.frequencyTimeOfDay = nil
            entry.source?.frequencyValue = expression
            return Self.buildPrompt(entry)
        }
        let event = try cron("0 8 * * 1-5").get().event
        guard case .cron(let expression)? = event.source.schedule?.frequency else {
            Issue.record("expected a cron schedule")
            return
        }
        #expect(expression == "0 8 * * 1-5")
        for bad in ["61 8 * * *", "every weekday", "0 8 * *"] {
            guard case .failure(let error) = cron(bad) else {
                Issue.record("`\(bad)` should be rejected")
                continue
            }
            #expect(error.message.contains("five"), "\(bad): \(error.message)")
        }
    }

    @Test func newAgentEventsDefaultTheirChatContinuityPerSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-evt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func fresh(_ source: EventSourceEntry) throws -> Bool? {
            var entry = EventEntry(name: "E")
            entry.source = source
            entry.agent = Self.agentName
            entry.instructions = "x"
            return try Self.build(entry).get().event.action.agent?.freshSessionPerFire
        }
        var schedule = EventSourceEntry(kind: "schedule")
        schedule.frequency = "daily"
        schedule.frequencyTimeOfDay = "08:00"
        var folderSource = EventSourceEntry(kind: "folder")
        folderSource.path = folder.path
        var channel = EventSourceEntry(kind: "channel_message")
        channel.platform = "telegram"
        #expect(try fresh(schedule) == true)
        #expect(try fresh(EventSourceEntry(kind: "webhook")) == true)
        #expect(try fresh(folderSource) == false)
        #expect(try fresh(channel) == false)
    }

    @Test func planResolverOnlyKnowsAgentsThatSurviveTheApply() {
        let resolver = ConfigEvents.planAgentResolver(names: ["helper"])
        #expect(resolver("Helper") != nil)
        #expect(resolver("Gone") == nil)
    }

    // MARK: - Risks and diff

    @Test func risksFlagNewlyUnsignedWebhooksAndNewAutoReplies() {
        let unsigned = OsaurusEvent(
            name: "Open hook", source: .webhook(WebhookSourceConfig(verification: .none)), action: Self.agent())
        #expect(ConfigEvents.risks(for: unsigned, previous: nil).count == 1)
        #expect(ConfigEvents.risks(for: unsigned, previous: unsigned).isEmpty)

        let replying = try! #require(Self.sampleEvents(folder: "/tmp").first { $0.sourceKind == .channelMessage })
        #expect(ConfigEvents.risks(for: replying, previous: nil).count == 1)
        #expect(ConfigEvents.risks(for: replying, previous: replying).isEmpty)
        var quiet = replying
        quiet.reply = EventReplyPolicy(autoReply: false)
        #expect(ConfigEvents.risks(for: quiet, previous: nil).isEmpty)
    }

    @Test func diffLinesNameEachChangedKey() {
        var current = EventEntry(name: "E")
        current.enabled = true
        current.instructions = "old"
        var desired = current
        desired.enabled = false
        desired.instructions = "new"
        desired.delivery = EventDeliveryEntry()
        desired.delivery?.maxQueued = 5
        #expect(
            ConfigEvents.diffLines(current: current, desired: desired) == [
                "delivery.max_queued: (unset) -> 5", "enabled: true -> false", "instructions: old -> new",
            ])
        #expect(ConfigEvents.diffLines(current: current, desired: current).isEmpty)
    }

    // MARK: - Legacy translation

    @Test func legacySchedulesAndWatchersBecomeEventsOnce() {
        var schedule = ScheduleEntry(name: "Daily standup")
        schedule.agent = Self.agentName
        schedule.instructions = "Post the standup"
        schedule.frequency = "daily"
        schedule.frequencyTimeOfDay = "09:00"
        var watcher = WatcherEntry(name: "Downloads")
        watcher.agent = Self.agentName
        watcher.instructions = "Sort"
        watcher.path = "/tmp"
        watcher.responsiveness = "fast"
        var doc = OsaurusConfigDocument()
        doc.legacySchedules = [schedule]
        doc.legacyWatchers = [watcher]
        var existing = EventEntry(name: "downloads")
        existing.instructions = "Keep mine"
        doc.automations = [existing]
        #expect(doc.declaredSections.contains(.automations))

        let (translated, notes) = doc.translatingLegacyEvents()
        #expect(translated.legacySchedules == nil)
        #expect(translated.legacyWatchers == nil)
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { $0.contains("deprecated") })
        let events = translated.automations ?? []
        #expect(events.map(\.name) == ["downloads", "Daily standup"])
        #expect(events[0].instructions == "Keep mine")
        let standup = events[1]
        #expect(standup.source?.kind == "schedule")
        #expect(standup.source?.frequency == "daily")
        #expect(standup.source?.frequencyTimeOfDay == "09:00")
        #expect(standup.agent == Self.agentName)

        let (again, moreNotes) = translated.translatingLegacyEvents()
        #expect(again == translated)
        #expect(moreNotes.isEmpty)
    }

    @Test func preRenameEventsKeyDecodesIntoAutomationsAndExportsTheNewKey() throws {
        let document = try ConfigYAML.decode(
            """
            events:
              - name: Morning digest
                agent: \(Self.agentName)
                instructions: Summarize
                source:
                  kind: schedule
                  frequency: daily
            """)
        #expect(document.automations?.map(\.name) == ["Morning digest"])
        #expect(document.declaredSections == [.automations])
        #expect(ConfigSectionID.parse("events") == .automations)
        #expect(ConfigSectionID.parse("schedules") == .automations)

        let encoded = try ConfigYAML.encode(document)
        #expect(encoded.contains("automations:"))
        #expect(!encoded.contains("events:"))
    }

    @Test func legacyInboundKeysTranslateIntoThePlatformsDefaultEvent() {
        var section = ChannelPlatformSection()
        section.inboundAgent = .value(Self.agentName)
        section.requireMention = false
        section.autoReplyEnabled = true
        section.writeEnabled = true
        var channels = ChannelsSection()
        channels.whatsapp = section
        var doc = OsaurusConfigDocument()
        doc.channels = channels

        let (translated, notes) = doc.translatingLegacyEvents()
        let rule = translated.channels?.whatsapp?.routing?.first
        let entry = rule?.eventEntry(kind: .whatsapp, connection: nil)
        #expect(translated.automations == nil)
        #expect(entry?.source?.kind == "channel_message")
        #expect(entry?.source?.platform == "whatsapp")
        #expect(entry?.agent == Self.agentName)
        #expect(entry?.source?.requireMention == false)
        #expect(entry?.reply?.autoReply == true)
        let cleared = translated.channels?.whatsapp
        #expect(cleared?.hasLegacyInbound == false)
        #expect(cleared?.writeEnabled == true)
        #expect(notes.contains { $0.contains("channels.<platform>.inbound_*") })
    }

    @Test func aRequiredInputLeftOutOfTheDocumentTakesItsDefault() throws {
        var definition = WF.intake()
        definition.inputSchema = .object([
            "type": .string("object"),
            "properties": .object([
                "date": WF.string,
                "max_items": .object(["type": .string("integer"), "default": .number(5)]),
            ]),
            "required": .array([.string("date"), .string("max_items")]),
        ])
        let template = try TemplateStore.shared.save(
            WF.template(definition, name: "Defaults probe \(UUID().uuidString.prefix(6))"))
        let installed = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings())
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        func build(_ input: [String: String]) -> Result<ConfigEvents.BuildOutcome, ConfigEventError> {
            var entry = EventEntry(name: "Defaults")
            entry.source = EventSourceEntry(kind: "webhook")
            entry.workflow = installed.name
            entry.input = input
            return ConfigEvents.build(
                entry, existing: nil, resolveAgent: Self.resolveAgent,
                resolveWorkflow: { $0 == installed.name ? installed.id : nil }, mintBookmarks: false)
        }

        let built = try build(["date": "{{webhook.body.date}}"]).get().event
        #expect(built.action.workflow?.inputMapping == ["date": "{{webhook.body.date}}", "max_items": "5"])
        // A value in the document wins; an input with no default still has to be bound.
        #expect(try build(["date": "x", "max_items": "9"]).get().event.action.workflow?.inputMapping["max_items"] == "9")
        guard case .failure(let error) = build(["max_items": "9"]) else {
            Issue.record("expected a missing `date`")
            return
        }
        #expect(error.message.contains("`date`"))
    }
}

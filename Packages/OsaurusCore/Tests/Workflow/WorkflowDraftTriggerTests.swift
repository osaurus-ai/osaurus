//
//  WorkflowDraftTriggerTests.swift
//  OsaurusCoreTests
//
//  The trigger the Architect attaches to `workflow_propose_save`: checked
//  against the draft's input schema before the workflow is installed,
//  limited to workflow-only keys and trigger kinds, and created by the save
//  card as a workflow automation.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowDraftTriggerTests {
    private static func draft(name: String = "Morning Brief \(UUID().uuidString.prefix(6))") -> WorkflowDraft {
        var definition = WF.intake()
        definition.inputSchema = WF.object(["day": WF.string, "topic": WF.string], required: ["day"])
        return WorkflowDraft(name: name, definition: definition)
    }

    private static func trigger(_ json: String, draft: WorkflowDraft) -> Result<WorkflowDraftTrigger, ConfigEventError> {
        WorkflowDraftTrigger.parse(JSONValue.parse(json) ?? .null, draft: draft)
    }

    private static func message(_ json: String, draft: WorkflowDraft) -> String? {
        if case .failure(let error) = trigger(json, draft: draft) { return error.message }
        return nil
    }

    @Test func aScheduleBoundToTheDraftInputsIsAccepted() throws {
        let draft = Self.draft()
        let parsed = try Self.trigger(
            #"""
            {"source": {"kind": "schedule", "frequency": "cron", "frequency_value": "0 8 * * 1-5"},
             "input": {"day": "{{schedule.scheduled_for}}", "topic": "local AI news"}}
            """#, draft: draft
        ).get()
        #expect(parsed.entry.name == draft.name)
        #expect(parsed.entry.workflow == nil)
        #expect(parsed.entry.input == ["day": "{{schedule.scheduled_for}}", "topic": "local AI news"])
        #expect(parsed.summary.hasPrefix(EventSourceKind.schedule.displayName))

        // A `workflow` key is dropped: the trigger always runs this draft.
        let named = try Self.trigger(
            #"{"name": "Weekday brief", "workflow": "Something else", "source": {"kind": "webhook"}, "input": {"day": "{{webhook.body.day}}"}}"#,
            draft: draft
        ).get()
        #expect(named.entry.name == "Weekday brief")
        #expect(named.entry.workflow == nil)
    }

    @Test func triggersAreCheckedAgainstTheDraftBeforeItIsInstalled() {
        let draft = Self.draft()
        #expect(
            Self.message(#"{"source": {"kind": "webhook"}, "input": {"topic": "x"}}"#, draft: draft)?
                .contains("needs `day`") == true)
        #expect(
            Self.message(
                #"{"source": {"kind": "schedule", "frequency": "cron", "frequency_value": "61 8 * * *"}, "input": {"day": "x"}}"#,
                draft: draft)?.contains("five") == true)
        for key in ["agent", "instructions", "model", "working_folder", "fresh_session", "reply"] {
            #expect(
                Self.message(#"{"source": {"kind": "webhook"}, "\#(key)": "x"}"#, draft: draft)?
                    .contains("trigger.\(key)") == true, "\(key)")
        }
        #expect(
            Self.message(#"{"source": {"kind": "channel_message", "platform": "telegram"}}"#, draft: draft)?
                .contains("Channels → Routing") == true)
        #expect(Self.message(#"{"input": {"day": "x"}}"#, draft: draft)?.contains("trigger.source.kind") == true)
        #expect(Self.message(#""daily""#, draft: draft)?.contains("must be an object") == true)
    }

    @Test func aNameUsedByAnotherAutomationIsRefused() {
        let draft = Self.draft()
        let taken = EventManager.shared.create(
            OsaurusEvent(
                name: "Taken \(UUID().uuidString.prefix(6))", isEnabled: false,
                source: .webhook(WebhookSourceConfig()),
                action: .prompt(PromptEventAction(instructions: "Say hi."))))
        defer { _ = EventManager.shared.delete(id: taken.id) }
        #expect(
            Self.message(#"{"name": "\#(taken.name)", "source": {"kind": "webhook"}, "input": {"day": "x"}}"#, draft: draft)?
                .contains("runs something else") == true)
    }

    @Test func saveCreatesTheWorkflowAutomationAndASecondSaveUpdatesIt() throws {
        let draft = Self.draft()
        let parsed = try Self.trigger(
            #"{"enabled": false, "source": {"kind": "webhook"}, "input": {"day": "{{webhook.body.day}}"}}"#,
            draft: draft
        ).get()
        let template = try TemplateStore.shared.save(Template(name: draft.name, summary: "", payload: .workflow(draft.definition)))
        let installed = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings())
        defer {
            for event in EventManager.shared.events where event.name == draft.name {
                _ = EventManager.shared.delete(id: event.id)
            }
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }

        let result = try #require(parsed.apply(to: installed))
        #expect(result.status != .failed, "\(result.message ?? "")")
        let created = EventManager.shared.events.filter { $0.name == draft.name }
        #expect(created.count == 1)
        #expect(created.first?.action.workflow?.workflowID == installed.id)
        #expect(created.first?.action.workflow?.inputMapping["day"] == "{{webhook.body.day}}")
        #expect(created.first?.agentId == nil)

        // The next version's proposal recognizes its own automation, and
        // saving again updates it in place.
        var nextVersion = draft
        nextVersion.templateID = template.id
        let again = try Self.trigger(
            #"{"source": {"kind": "webhook"}, "input": {"day": "{{webhook.body.date}}"}}"#, draft: nextVersion
        ).get()
        _ = again.apply(to: installed)
        let updated = EventManager.shared.events.filter { $0.name == draft.name }
        #expect(updated.count == 1)
        #expect(updated.first?.action.workflow?.inputMapping["day"] == "{{webhook.body.date}}")
    }

    @Test func proposalsAreHeldPerDraftUntilTheCardReadsThem() throws {
        let id = UUID()
        let parsed = try Self.trigger(
            #"{"source": {"kind": "webhook"}, "input": {"day": "x"}}"#, draft: Self.draft()
        ).get()
        WorkflowDraftTrigger.setProposed(parsed, for: id)
        #expect(WorkflowDraftTrigger.proposed(for: id) == parsed)
        #expect(WorkflowDraftTrigger.proposed(for: UUID()) == nil)
        WorkflowDraftTrigger.setProposed(nil, for: id)
        #expect(WorkflowDraftTrigger.proposed(for: id) == nil)
    }
}

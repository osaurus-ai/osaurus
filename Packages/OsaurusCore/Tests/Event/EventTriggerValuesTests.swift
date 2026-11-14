//
//  EventTriggerValuesTests.swift
//  osaurusTests
//
//  The values a trigger exposes (with a webhook's sample body fields), and
//  how a workflow's inputs bind to them: kind of binding, prefill,
//  required-input check, and the preview a sample run produces.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct EventTriggerValuesTests {
    private func webhookEvent(sample: String?) -> OsaurusEvent {
        OsaurusEvent(
            name: "GitHub issues",
            source: .webhook(WebhookSourceConfig(token: "t", verification: .none, sampleBody: sample)),
            action: .workflow(WorkflowEventAction(workflowID: UUID())))
    }

    @Test func eachTriggerListsItsOwnValuesPlusTheCommonOnes() {
        let schedule = EventTriggerValues.catalog(for: .schedule).map(\.path)
        #expect(schedule == ["schedule.scheduled_for", "text", "fired_at", "event.name"])
        let folder = EventTriggerValues.catalog(for: .folder).map(\.path)
        #expect(folder.prefix(2) == ["folder.changed_paths", "folder.path"])
        let webhook = EventTriggerValues.catalog(for: .webhook).map(\.path)
        #expect(webhook.first == "webhook.body")
        #expect(webhook.contains("webhook.query"))
        #expect(EventTriggerValues.catalog(for: .webhook).first?.template == "{{webhook.body}}")
    }

    @Test func aSampleBodyExposesItsFieldsWithExamples() {
        let event = webhookEvent(sample: #"{"issue": {"title": "Login fails", "number": 42}, "action": "opened", "bad key": 1}"#)
        let sample = EventTriggerValues.samplePayload(for: event)
        let values = EventTriggerValues.catalog(for: .webhook, sample: sample)
        let paths = values.map(\.path)
        #expect(paths.contains("webhook.body.issue.title"))
        #expect(paths.contains("webhook.body.issue.number"))
        #expect(paths.contains("webhook.body.action"))
        // Keys the {{path}} grammar can't address are skipped.
        #expect(!paths.contains { $0.contains("bad key") })
        #expect(values.first { $0.path == "webhook.body.issue.title" }?.example == "Login fails")
        #expect(values.first { $0.path == "webhook.body.issue.number" }?.example == "42")
        #expect(values.first { $0.path == "webhook.body.issue.title" }?.label == "Body: issue.title")
    }

    @Test func aNonJSONSampleIsPassedAsOneValue() {
        let event = webhookEvent(sample: "hello there")
        let values = EventTriggerValues.catalog(for: .webhook, sample: EventTriggerValues.samplePayload(for: event))
        #expect(!values.contains { $0.path.hasPrefix("webhook.body.") })
        #expect(values.first { $0.path == "webhook.body" }?.example == "hello there")
        #expect(EventTriggerValues.parsedSampleBody("  ") == nil)
    }

    @Test func bindingKindsFollowTheTemplate() {
        #expect(WorkflowInputBinding.kind(of: nil) == .unset)
        #expect(WorkflowInputBinding.kind(of: "  ") == .unset)
        #expect(WorkflowInputBinding.kind(of: "{{webhook.body.title}}") == .triggerValue("webhook.body.title"))
        #expect(WorkflowInputBinding.kind(of: "New: {{webhook.body.title}}") == .template)
        #expect(WorkflowInputBinding.kind(of: "high") == .fixed)
        // Not a payload root: sent as written.
        #expect(WorkflowInputBinding.kind(of: "{{mustache}}") == .fixed)
    }

    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object(["type": .string("string"), "title": .string("Issue title")]),
            "priority": .object(["type": .string("string"), "default": .string("normal")]),
            "count": .object(["type": .string("integer")]),
            "notes": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("title"), .string("priority"), .string("count")]),
    ])

    @Test func prefillBindsTheNaturalValueAndRequiredDefaults() {
        let mapping = WorkflowInputBinding.prefill(schema: schema, sourceKind: .webhook)
        #expect(mapping["title"] == "{{text}}")
        #expect(mapping["priority"] == "normal")
        #expect(mapping["count"] == nil)
        #expect(mapping["notes"] == nil)
    }

    @Test func requiredDefaultsAreTheFixedValuesABindingCarries() {
        #expect(WorkflowInputBinding.requiredDefaults(schema: schema) == ["priority": "normal"])
    }

    @Test func requiredInputsWithNothingBoundAreReported() {
        let fields = WorkflowFormFields.fields(fromInputSchema: schema)
        let missing = WorkflowInputBinding.missingRequired(
            fields: fields, mapping: ["title": "{{webhook.body.title}}", "priority": "high"])
        #expect(missing.map(\.key) == ["count"])
        #expect(fields.first { $0.key == "title" }?.label == "Issue title")
    }

    @Test func previewRendersTheSampleRunAndCoercesTypes() {
        let event = webhookEvent(sample: #"{"title": "Login fails", "n": "7"}"#)
        let payload = EventTriggerValues.samplePayload(for: event)
        let mapping = ["title": "Bug: {{webhook.body.title}}", "count": "{{webhook.body.n}}", "priority": "high"]
        #expect(WorkflowInputBinding.preview(field: "title", mapping: mapping, payload: payload, schema: schema) == "Bug: Login fails")
        #expect(WorkflowInputBinding.preview(field: "count", mapping: mapping, payload: payload, schema: schema) == "7")
        #expect(WorkflowInputBinding.preview(field: "notes", mapping: mapping, payload: payload, schema: schema) == nil)
        #expect(WorkflowInputBinding.issues(mapping: mapping, payload: payload, schema: schema).isEmpty)
    }

    @Test func sampleBodyRoundTripsAndOldConfigsDecode() throws {
        let config = WebhookSourceConfig(token: "t", sampleBody: #"{"a":1}"#)
        let decoded = try JSONDecoder().decode(WebhookSourceConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.sampleBody == #"{"a":1}"#)
        let legacy = try JSONDecoder().decode(WebhookSourceConfig.self, from: Data(#"{"token":"t"}"#.utf8))
        #expect(legacy.sampleBody == nil)
    }

    @Test func testCommandSendsTheSampleBodySafely() {
        #expect(EventDetailView.shellQuotedBody(nil) == #"{"text":"Hello from curl"}"#)
        #expect(EventDetailView.shellQuotedBody(#"{ "a" : 1 }"#) == #"{"a":1}"#)
        #expect(EventDetailView.shellQuotedBody("it's") == #"it'\''s"#)
    }
}

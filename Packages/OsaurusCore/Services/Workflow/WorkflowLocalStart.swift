//
//  WorkflowLocalStart.swift
//  osaurus
//
//  Starts one of the owner's workflows for a caller on this Mac that is
//  not a window: the Run Workflow action in Shortcuts, through
//  `POST /workflows/{id}/run`. The run is a background user run, so its
//  forms park and post a notification. Input is either an object, taken
//  as given over the schema's defaults, or text, which goes to the field
//  an automation's `{{text}}` would.
//

import Foundation

@MainActor
enum WorkflowLocalStart {
    enum Failure: Error, Equatable {
        case notFound
        case needsSetup(String)
        case invalidInput(String)

        var status: Int {
            switch self {
            case .notFound: 404
            case .needsSetup: 409
            case .invalidInput: 400
            }
        }

        var code: String {
            switch self {
            case .notFound: "workflow_not_found"
            case .needsSetup: "needs_setup"
            case .invalidInput: "invalid_input"
            }
        }

        var message: String {
            switch self {
            case .notFound: L("No installed workflow has that id.")
            case .needsSetup(let summary): L("Set up this workflow in Osaurus first: \(summary)")
            case .invalidInput(let detail): L("The input does not fit the workflow: \(detail)")
            }
        }
    }

    static func start(
        workflowID: UUID,
        text: String?,
        values: JSONValue?,
        report: (InstalledWorkflow) -> SetupReport = { SetupChecker.check($0, secrets: .caller(nil), attended: false) },
        launch: (InstalledWorkflow, JSONValue, WorkflowCaller) -> UUID = {
            WorkflowRunService.shared.start($0, input: $1, caller: $2)
        }
    ) -> Result<UUID, Failure> {
        guard let workflow = InstalledWorkflowStore.shared.workflow(id: workflowID) else { return .failure(.notFound) }
        let setup = report(workflow)
        if setup.hasBlockers { return .failure(.needsSetup(setup.summary)) }
        switch input(schema: workflow.definition.inputSchema, text: text, values: values) {
        case .failure(let failure): return .failure(failure)
        case .success(let input):
            return .success(launch(workflow, input, WorkflowCaller(kind: .user, background: true)))
        }
    }

    static func input(schema: JSONValue, text: String?, values: JSONValue?) -> Result<JSONValue, Failure> {
        var given: [String: JSONValue] = [:]
        if let values {
            guard let object = values.objectValue else {
                return .failure(.invalidInput(L("`input` must be an object.")))
            }
            given = object
        } else if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let mapping = WorkflowInputMapper.suggestedMapping(schema: schema, sourceKind: nil)
            let mapped = WorkflowInputMapper.input(
                mapping: mapping,
                payload: .object(["text": .string(text)]),
                schema: schema
            )
            given = mapped.objectValue ?? [:]
        }
        var input: [String: JSONValue] = [:]
        for field in WorkflowFormFields.fields(fromInputSchema: schema) {
            if let value = field.defaultValue { input[field.key] = value }
        }
        input.merge(given) { _, new in new }
        let value = JSONValue.object(input)
        let issues = JSONSchemaValidator.validate(value, against: schema)
        guard issues.isEmpty else { return .failure(.invalidInput(issues.map(\.description).joined(separator: "; "))) }
        return .success(value)
    }
}

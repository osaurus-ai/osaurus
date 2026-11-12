//
//  PushTestWorkflow.swift
//  osaurus
//
//  Debug builds only. With `OSAURUS_PUSH_TEST_WORKFLOW=1` in the scheme, launch installs a
//  "Push Test" workflow if there isn't one: a few steps that each just wait 3 seconds, and one
//  that asks a yes/no question. It needs no model, tool or setup, so running it from the iPhone
//  or the Mac shows every workflow notification (started, waiting for an answer, finished) in
//  about 15 seconds. KEEP: how workflow push is tested on device.
//

#if DEBUG

    import Foundation
    import os

    @MainActor
    enum PushTestWorkflow {
        static let name = "Push Test"
        private static let log = Logger(subsystem: "ai.osaurus", category: "workflow.push-test")

        static func installIfAsked() {
            guard ProcessInfo.processInfo.environment["OSAURUS_PUSH_TEST_WORKFLOW"] == "1" else { return }
            guard !InstalledWorkflowStore.shared.workflows.contains(where: { $0.name == name }) else { return }
            do {
                let definition = try JSONDecoder().decode(WorkflowDefinition.self, from: Data(definitionJSON.utf8))
                let issues = WorkflowValidator.validate(definition, allowPlaceholders: false)
                guard issues.isEmpty else {
                    log.error("push test workflow invalid: \(issues.map(\.message).joined(separator: "; "))")
                    return
                }
                let template = Template(name: name, summary: "Steps that wait a few seconds, for testing notifications.",
                    payload: .workflow(definition))
                _ = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings(models: [:]))
                log.notice("installed the push test workflow")
            } catch {
                log.error("push test workflow not installed: \(String(describing: error))")
            }
        }

        private static let definitionJSON = """
            {
              "input_schema": {"type": "object", "properties": {}},
              "output_schema": {"type": "object", "properties": {}},
              "nodes": [
                {"id": "gather", "name": "Gathering", "kind": "wait", "wait": {"seconds": 3}},
                {"id": "think", "name": "Thinking", "kind": "wait", "wait": {"seconds": 3}},
                {
                  "id": "ask", "name": "Checking with you", "kind": "dialog",
                  "dialog": {
                    "title": "Keep going?",
                    "message": "A test question, to see the waiting notification and its clearing.",
                    "fields": [
                      {"key": "go", "label": "Keep going?", "type": "bool", "required": true,
                       "persistence": "always_ask"}
                    ]
                  }
                },
                {"id": "finish", "name": "Wrapping up", "kind": "wait", "wait": {"seconds": 3}}
              ],
              "edges": [
                {"from": "gather", "to": "think"},
                {"from": "think", "to": "ask"},
                {"from": "ask", "to": "finish"}
              ],
              "output": {}
            }
            """
    }

#endif

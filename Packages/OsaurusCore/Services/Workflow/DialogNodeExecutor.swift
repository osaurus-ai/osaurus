//
//  DialogNodeExecutor.swift
//  osaurus
//
//  Dialog nodes. A `remember` field uses its saved answer; a value the
//  caller passes under the field's key overrides it for this run only. An
//  `always_ask` field is asked every time, prefilled from the caller's
//  value, else (with `prefill_last`) the last answer, else its default.
//  When every field is remembered and known, the node completes without
//  showing anything. Answers given in the form are saved for `remember`
//  and `prefill_last` fields.
//

import Foundation

enum DialogNodeExecutor {

    struct Plan: Equatable {
        /// Values known without asking.
        var known: [String: JSONValue]
        /// Fields to show.
        var ask: [DialogField]
        var prefill: [String: JSONValue]
    }

    /// Pure: what to ask given saved answers and the caller's input.
    static func plan(spec: DialogSpec, callInput: JSONValue, saved: [String: JSONValue]) -> Plan {
        var plan = Plan(known: [:], ask: [], prefill: [:])
        let overrides = callInput.objectValue ?? [:]
        for field in spec.fields {
            let callValue = overrides[field.key].flatMap { $0 == .null ? nil : $0 }
            switch field.persistence {
            case .remember:
                if let value = callValue ?? saved[field.key] {
                    plan.known[field.key] = value
                } else {
                    plan.ask.append(field)
                    if let d = field.defaultValue { plan.prefill[field.key] = d }
                }
            case .alwaysAsk(let prefillLast):
                plan.ask.append(field)
                if let value = callValue ?? (prefillLast ? saved[field.key] : nil) ?? field.defaultValue {
                    plan.prefill[field.key] = value
                }
            }
        }
        return plan
    }

    static func run(
        spec: DialogSpec, context: WorkflowNodeContext, awaitingUser: WorkflowAwaitingUserHandler
    ) async throws -> WorkflowNodeOutcome {
        let workflowID = context.workflowID
        let nodeID = context.node.id
        let saved: [String: JSONValue] = await MainActor.run {
            var out: [String: JSONValue] = [:]
            for field in spec.fields {
                if let v = SavedAnswersStore.shared.value(workflowID: workflowID, nodeID: nodeID, fieldKey: field.key) {
                    out[field.key] = v
                }
            }
            return out
        }
        let plan = plan(spec: spec, callInput: context.bindings.input, saved: saved)
        guard !plan.ask.isEmpty else {
            return WorkflowNodeOutcome(output: .object(plan.known), logs: [L("All answers were remembered.")])
        }

        let dialog = PendingDialog(
            id: UUID(), runID: context.runID, workflowID: workflowID, workflowName: context.workflowName,
            nodeID: context.node.id,
            title: spec.title.isEmpty
                ? context.node.name : BindingRenderer.renderReadableText(spec.title, in: context.bindings),
            message: BindingRenderer.renderReadableText(spec.message, in: context.bindings),
            fields: plan.ask, prefill: plan.prefill, caller: context.caller, createdAt: Date())

        await awaitingUser(true)
        let answers: [String: JSONValue]
        do {
            answers = try await DialogCoordinator.shared.present(dialog)
        } catch {
            await awaitingUser(false)
            throw error
        }
        await awaitingUser(false)

        await MainActor.run {
            for field in plan.ask {
                guard let value = answers[field.key] else { continue }
                let keep: Bool = {
                    switch field.persistence {
                    case .remember: return true
                    case .alwaysAsk(let prefillLast): return prefillLast
                    }
                }()
                if keep { SavedAnswersStore.shared.save(workflowID: workflowID, nodeID: nodeID, field: field, value: value) }
            }
        }
        return WorkflowNodeOutcome(output: .object(plan.known.merging(answers) { _, new in new }))
    }
}

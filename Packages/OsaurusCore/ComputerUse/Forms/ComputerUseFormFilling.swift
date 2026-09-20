import Foundation

public struct ComputerUseFormFillResult: Sendable {
    public let attempted: Int
    public let completed: Int
    public let summary: String
    public let stoppedReason: String?

    public init(attempted: Int, completed: Int, summary: String, stoppedReason: String?) {
        self.attempted = attempted
        self.completed = completed
        self.summary = summary
        self.stoppedReason = stoppedReason
    }
}

/// Optional form-specialist attachment, separate from the loop's LLM planner.
/// Implementations must gate and verify every mutation using the supplied gate.
public protocol ComputerUseFormFilling: Sendable {
    func fill(
        snapshot: CUSnapshot,
        driver: any MacDriver,
        gate: any ComputerUseGating,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        isInterrupted: @escaping @Sendable () -> Bool,
        feed: SubagentFeed
    ) async -> ComputerUseFormFillResult
}

extension CUAFormsAgentRun: ComputerUseFormFilling {
    func fill(
        snapshot: CUSnapshot,
        driver: any MacDriver,
        gate: any ComputerUseGating,
        confirm: @escaping @Sendable (ActionPreview) async -> Bool,
        isInterrupted: @escaping @Sendable () -> Bool,
        feed: SubagentFeed
    ) async -> ComputerUseFormFillResult {
        var attempted = 0
        var completed = 0
        do {
            guard !isInterrupted() else { throw CancellationError() }
            try await validate()
            let windows = snapshot.windows.filter(\.focused)
            guard snapshot.tier == .ax, !snapshot.truncated, windows.count == 1,
                let windowID = windows.first?.id,
                let app = await driver.listApps().first(where: { $0.pid == snapshot.pid }),
                let window = await driver.listWindows(pid: app.pid).first(where: { $0.windowId == windowID })
            else {
                throw CUAFormsError.invalid(
                    "Open one identifiable form window with a complete accessibility tree first."
                )
            }
            let target = CUAFormTarget(app: app, window: window)
            let captured = try await CUAFormsPlanner.capture(target: target, driver: driver)
            let elements = captured.elements.filter {
                $0.windowId == windowID && CUAFormsPlanner.role($0.role) == "Edit"
                    && $0.enabled && !CUSecureFieldRole.contains($0.role)
            }
            let decisions = try await score(elements: elements, title: window.title ?? "", feed: feed)
            for decision in decisions {
                guard decision.canApply, case .fill(let entity) = decision.action,
                    decision.element.value != entity.value
                else { continue }
                guard !isInterrupted() else { throw CancellationError() }
                try await validate()
                let before = try await CUAFormsPlanner.capture(target: target, driver: driver)
                let field = try CUAFormsPlanner.matching(decision.element, in: before)
                guard field.value == decision.element.value else {
                    throw CUAFormsError.invalid("A field changed after scoring.")
                }
                let action = AgentAction(
                    verb: .setValue,
                    target: AgentTarget(describe: field.label),
                    text: entity.value
                )
                let effect = EffectClassifier.classify(
                    action: action,
                    resolvedRole: field.role,
                    resolvedLabel: field.label,
                    resolvedValue: field.value,
                    resolvedRoleDescription: field.roleDescription,
                    appName: app.name
                )
                switch await gate.evaluate(
                    action: action,
                    effect: .max(.edit, effect),
                    appName: app.name,
                    targetLabel: field.label
                ) {
                case .reject(let reason): throw CUAFormsError.invalid(reason)
                case .confirm(let preview):
                    guard await confirm(preview) else { throw CUAFormsError.invalid("The user declined form filling.") }
                case .run: break
                }
                // A prompt can remain open while the app/field/settings change.
                guard !isInterrupted() else { throw CancellationError() }
                try await validate()
                let fresh = try await CUAFormsPlanner.capture(target: target, driver: driver)
                let current = try CUAFormsPlanner.matching(field, in: fresh)
                guard current.value == field.value else {
                    throw CUAFormsError.invalid("A field changed while awaiting approval.")
                }
                guard !isInterrupted() else { throw CancellationError() }
                try Task.checkCancellation()
                attempted += 1
                let applied = await driver.perform(.setValue(id: current.id, value: entity.value))
                guard applied.success, !applied.stale, !applied.removed else {
                    throw CUAFormsError.invalid("Accessibility rejected the edit; no keyboard fallback was attempted.")
                }
                let after = try await CUAFormsPlanner.capture(target: target, driver: driver)
                guard try CUAFormsPlanner.matching(current, in: after).value == entity.value else {
                    throw CUAFormsError.invalid(
                        "The app did not retain the expected value. Inspect it before retrying."
                    )
                }
                completed += 1
                recordApplied()
                feed.emit(
                    SubagentActivityEvent(
                        kind: .verify,
                        title: "CUA S1 Forms: field verified",
                        detail: field.label,
                        success: true
                    )
                )
            }
            return ComputerUseFormFillResult(
                attempted: attempted,
                completed: completed,
                summary:
                    "CUA S1 Forms filled \(completed) verified text fields. No submission or checkbox action was performed.",
                stoppedReason: nil
            )
        } catch {
            let reason = "Form filling stopped after \(completed) verified fields: \(error.localizedDescription)"
            return ComputerUseFormFillResult(
                attempted: attempted,
                completed: completed,
                summary: reason,
                stoppedReason: reason
            )
        }
    }
}

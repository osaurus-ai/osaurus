import Foundation

struct CUAFormTarget: Equatable, Sendable {
    let app: CUAppListing
    let window: CUWindowInfo
}

enum CUAFormAction: Equatable, Sendable {
    case fill(CUAFormEntity)
    case check
    case click
    case skip
}

struct CUAFormDecision: Identifiable, Sendable {
    let id: UUID
    let element: CUElement
    let action: CUAFormAction
    let probability: Float

    var canApply: Bool {
        guard element.enabled, probability >= 0.5,
            !CUSecureFieldRole.contains(element.role)
        else { return false }
        switch action {
        case .fill: return CUAFormsPlanner.role(element.role) == "Edit"
        case .check: return CUAFormsPlanner.role(element.role) == "CheckBox" && Self.checked(element.value) == false
        case .click, .skip: return false
        }
    }

    static func checked(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "1", "true", "checked": return true
        case "0", "false", "unchecked": return false
        default: return nil
        }
    }
}

struct CUAFormPlan: Sendable {
    let id = UUID()
    let target: CUAFormTarget
    let profileName: String
    let decisions: [CUAFormDecision]
    let scoringSeconds: Double
}

enum CUAFormsPlanner {
    /// Normalize AX vocabulary to the upstream training schema. Unknown and
    /// secure roles are excluded, never silently treated as editable fields.
    static func role(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "axtextfield", "textfield", "axtextarea", "textarea", "edit": return "Edit"
        case "axcheckbox", "checkbox": return "CheckBox"
        case "axbutton", "button": return "Button"
        case "axcombobox", "combobox": return "ComboBox"
        default: return nil
        }
    }

    static func context(for element: CUElement, title: String) -> String {
        // Python [:n] slices Unicode scalar/code points, not Swift graphemes.
        func prefix(_ value: String, _ count: Int) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.prefix(count)))
        }
        let elementRole = role(element.role) ?? element.role
        let state: String
        if elementRole == "CheckBox" {
            state = CUAFormDecision.checked(element.value) == true ? "checked" : "unchecked"
        } else {
            state = "value=\"\(prefix(element.value ?? "", 48))\""
        }
        var result =
            "TASK fill the form from the document, then submit\nFORM \(prefix(title, 64))\n"
            + "ELEMENT \(elementRole) \"\(prefix(element.label ?? "", 72))\" \(state)"
        if let hint = element.placeholder, !hint.isEmpty { result += " hint=\"\(prefix(hint, 72))\"" }
        // The literal training context above is data, NOT permission to submit.
        return result
    }

    static func capture(target: CUAFormTarget, driver: any MacDriver) async throws -> CUSnapshot {
        try Task.checkCancellation()
        guard await driver.availability().accessibility else { throw MacDriverError.accessibilityNotGranted }
        let apps = await driver.listApps()
        guard
            apps.contains(where: {
                $0.pid == target.app.pid && $0.bundleId == target.app.bundleId && $0.name == target.app.name
            })
        else {
            throw CUAFormsError.invalid("The chosen app exited or changed. Select its window again.")
        }
        let snapshot = await driver.capture(
            pid: target.app.pid,
            tier: .ax,
            windowId: target.window.windowId,
            maxElements: 2000,
            focusedWindowOnly: false,
            interactiveOnly: true
        )
        // Native ax capture currently traverses all windows even when windowId
        // is supplied. Explicitly validate and filter; never use focusedWindow.
        guard snapshot.pid == target.app.pid, snapshot.tier == .ax, !snapshot.truncated,
            snapshot.windows.contains(where: { $0.id == target.window.windowId && $0.title == target.window.title })
        else {
            throw CUAFormsError.invalid(
                "The chosen window changed or its accessibility tree is incomplete. Preview again."
            )
        }
        try Task.checkCancellation()
        return snapshot
    }

    static func preview(
        profile: CUAFormProfile,
        target: CUAFormTarget,
        driver: any MacDriver,
        scorer: any CUAFormsScoring
    ) async throws -> CUAFormPlan {
        let entities = try profile.validatedEntities()
        let snapshot = try await capture(target: target, driver: driver)
        let elements = snapshot.elements.filter {
            $0.windowId == target.window.windowId && role($0.role) != nil && !CUSecureFieldRole.contains($0.role)
        }
        guard (1 ... 64).contains(elements.count) else {
            throw CUAFormsError.invalid("Choose a window with 1–64 accessible form elements.")
        }
        let options = entities.map(\.option) + ["check", "click", "skip"]
        let start = ContinuousClock.now
        let rows = try await scorer.probabilities(
            contexts: elements.map { context(for: $0, title: target.window.title ?? "") },
            options: options
        )
        let duration = start.duration(to: .now).components
        guard rows.count == elements.count else { throw CUAFormsError.invalid("Scorer omitted an element.") }
        let decisions = try zip(elements, rows).map { element, row -> CUAFormDecision in
            guard row.count == options.count, row.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }),
                abs(row.reduce(0, +) - 1) < 0.001,
                let index = row.indices.max(by: { row[$0] < row[$1] })
            else { throw CUAFormsError.invalid("Scorer returned an invalid option row.") }
            let action: CUAFormAction
            if index < entities.count {
                action = .fill(entities[index])
            } else {
                action = [.check, .click, .skip][index - entities.count]
            }
            return CUAFormDecision(id: UUID(), element: element, action: action, probability: row[index])
        }
        return CUAFormPlan(
            target: target,
            profileName: profile.name,
            decisions: decisions,
            scoringSeconds: Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        )
    }

    static func matching(_ original: CUElement, in snapshot: CUSnapshot) throws -> CUElement {
        let matches = snapshot.elements.filter {
            $0.windowId == original.windowId && $0.role == original.role
                && $0.label == original.label && $0.placeholder == original.placeholder
                && $0.path == original.path && $0.x == original.x && $0.y == original.y
                && $0.w == original.w && $0.h == original.h
        }
        guard matches.count == 1, let element = matches.first, element.enabled else {
            throw CUAFormsError.invalid(
                "An element moved, disappeared, became ambiguous, or is disabled. Preview again."
            )
        }
        return element
    }
}

struct CUAFormsApplyReport: Sendable {
    let completed: Int
    let requested: Int
    let stoppedReason: String?

    var summary: String {
        if let stoppedReason { return "Stopped after \(completed)/\(requested) confirmed changes: \(stoppedReason)" }
        return "Confirmed \(completed)/\(requested) changes. Nothing was submitted."
    }
}

enum CUAFormsExecutor {
    /// Explicit preview confirmation is required even under autonomous policy.
    /// This seam has no path to submission, coordinate input or typing fallback.
    static func apply(
        plan: CUAFormPlan,
        selected: Set<UUID>,
        confirmed: Bool,
        driver: any MacDriver,
        enabled: @Sendable () async -> Bool,
        policy: @Sendable () async -> AutonomyPolicy,
        progress: @Sendable (Int) async -> Void = { _ in }
    ) async -> CUAFormsApplyReport {
        var completed = 0
        do {
            let actions = plan.decisions.filter { selected.contains($0.id) }.sorted {
                if case .fill = $0.action, case .check = $1.action { return true }
                return false
            }
            guard confirmed, !selected.isEmpty, actions.count == selected.count,
                actions.allSatisfy(\.canApply)
            else { throw CUAFormsError.invalid("Confirm a nonempty selection of eligible previewed fields first.") }
            for decision in actions {
                try Task.checkCancellation()
                guard await enabled() else { throw CUAFormsError.invalid("Experimental forms is disabled.") }
                let snapshot = try await CUAFormsPlanner.capture(target: plan.target, driver: driver)
                let current = try CUAFormsPlanner.matching(decision.element, in: snapshot)
                guard current.value == decision.element.value else {
                    throw CUAFormsError.invalid(
                        "A field changed after preview. Nothing more will be overwritten; preview again."
                    )
                }
                let action: CUElementAction
                let gateAction: AgentAction
                let effect: EffectClass
                switch decision.action {
                case .fill(let entity):
                    action = .setValue(id: current.id, value: entity.value)
                    gateAction = AgentAction(
                        verb: .setValue,
                        target: AgentTarget(describe: current.label),
                        text: entity.value
                    )
                    effect = .edit
                case .check:
                    guard CUAFormDecision.checked(current.value) == false else {
                        throw CUAFormsError.invalid("Cannot verify an unchecked checkbox.")
                    }
                    action = .click(id: current.id)
                    gateAction = AgentAction(verb: .click, target: AgentTarget(describe: current.label))
                    // Checkboxes can be agreements; respect the stronger policy.
                    effect = .consequential
                case .click, .skip:
                    throw CUAFormsError.invalid("Submission and button clicks are not supported by this experiment.")
                }
                let gate = ComputerUseGate(policy: await policy())
                let classified = EffectClassifier.classify(
                    action: gateAction,
                    resolvedRole: current.role,
                    resolvedLabel: current.label,
                    resolvedValue: current.value,
                    resolvedRoleDescription: current.roleDescription,
                    appName: plan.target.app.name
                )
                let verdict = await gate.evaluate(
                    action: gateAction,
                    effect: .max(effect, classified),
                    appName: plan.target.app.name,
                    targetLabel: current.label
                )
                if case .reject(let reason) = verdict { throw CUAFormsError.invalid(reason) }
                // .confirm is satisfied ONLY by this exact reviewed selection's
                // affirmative UI confirmation, never by a model's decision.
                try Task.checkCancellation()
                guard await enabled() else { throw CUAFormsError.invalid("Experimental forms is disabled.") }
                let result = await driver.perform(action)
                guard result.success, !result.stale, !result.removed else {
                    throw CUAFormsError.invalid(
                        "The accessibility action was rejected. No keyboard fallback was attempted."
                    )
                }
                let after = try await CUAFormsPlanner.capture(target: plan.target, driver: driver)
                let observed = try CUAFormsPlanner.matching(current, in: after)
                let verified: Bool
                switch decision.action {
                case .fill(let entity): verified = observed.value == entity.value
                case .check: verified = CUAFormDecision.checked(observed.value) == true
                case .click, .skip: verified = false
                }
                guard verified else {
                    throw CUAFormsError.invalid(
                        "The app did not report the expected field value. Inspect the form before retrying."
                    )
                }
                completed += 1
                await progress(completed)
            }
            return CUAFormsApplyReport(completed: completed, requested: selected.count, stoppedReason: nil)
        } catch {
            let reason =
                error is CancellationError
                ? "Cancelled; inspect any already-applied changes." : error.localizedDescription
            return CUAFormsApplyReport(completed: completed, requested: selected.count, stoppedReason: reason)
        }
    }
}

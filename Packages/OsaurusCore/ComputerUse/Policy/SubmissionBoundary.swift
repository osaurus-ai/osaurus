//
//  SubmissionBoundary.swift
//  OsaurusCore - Computer Use
//
//  Run-level stop-before-submit policy. It is deliberately independent of the
//  configurable autonomy gate: even an autonomous run must stop at a browser
//  form boundary and obtain one exact, non-reusable approval.
//

import Foundation

/// The immutable action context shown to and approved by the user.
public struct SubmissionApprovalBinding: Sendable, Equatable {
    public let snapshotId: Int
    public let appName: String
    public let verb: AgentVerb
    public let targetLabel: String?
    public let actionLabel: String
    /// Internal-only fingerprints for post-approval freshness validation. They
    /// are intentionally not public evidence fields: raw form values and
    /// harness element identifiers are never retained in the approval object.
    let targetFingerprint: UInt64?
    let snapshotFingerprint: UInt64
    let targetIsSecure: Bool
    let actionFingerprint: UInt64
    let hadSubmissionSuccessSignal: Bool

    init(
        snapshotId: Int,
        appName: String,
        verb: AgentVerb,
        targetLabel: String?,
        actionLabel: String
    ) {
        self.snapshotId = snapshotId
        self.appName = appName
        self.verb = verb
        self.targetLabel = targetLabel
        self.actionLabel = actionLabel
        targetFingerprint = nil
        snapshotFingerprint = 0
        targetIsSecure = false
        actionFingerprint = 0
        hadSubmissionSuccessSignal = false
    }

    init(
        snapshotId: Int,
        appName: String,
        verb: AgentVerb,
        targetLabel: String?,
        actionLabel: String,
        targetFingerprint: UInt64?,
        snapshotFingerprint: UInt64,
        targetIsSecure: Bool,
        actionFingerprint: UInt64,
        hadSubmissionSuccessSignal: Bool
    ) {
        self.snapshotId = snapshotId
        self.appName = appName
        self.verb = verb
        self.targetLabel = targetLabel
        self.actionLabel = actionLabel
        self.targetFingerprint = targetFingerprint
        self.snapshotFingerprint = snapshotFingerprint
        self.targetIsSecure = targetIsSecure
        self.actionFingerprint = actionFingerprint
        self.hadSubmissionSuccessSignal = hadSubmissionSuccessSignal
    }
}

/// Structured, privacy-clean proof of how a run approached a submit boundary.
public struct ComputerUseFormEvidence: Sendable, Equatable {
    public enum PreparationState: String, Sendable, Equatable {
        case notStarted = "not_started"
        case filled
        case verified
        case readyForReview = "ready_for_review"
    }

    public enum SubmissionState: String, Sendable, Equatable {
        case notEncountered = "not_encountered"
        case readyForReview = "ready_for_review"
        case approved
        case acted
        case verified
        case actionExecutedUnverified = "action_executed_unverified"
    }

    /// Successful edit attempts observed before a submit boundary.
    public internal(set) var fillActions = 0
    /// Edit attempts whose post-action Accessibility view changed.
    public internal(set) var verifiedFillActions = 0
    public internal(set) var preparationState: PreparationState = .notStarted
    public internal(set) var submissionState: SubmissionState = .notEncountered
    public internal(set) var submissionBinding: SubmissionApprovalBinding?

    public init() {}
}

/// Conservative detection for actions that can submit a browser form.
/// False positives stop for review; false negatives could cross a trust
/// boundary, so uncertain Return/Enter actions in a browser are included.
public enum SubmissionBoundary {
    enum Revalidation {
        case valid(CUElement?)
        case invalid
    }

    static func canPerformSubmission(_ action: AgentAction) -> Bool {
        isActivation(action.verb)
            || (action.verb == .pressKey && isReturnOrEnter(action.key))
            || (action.verb == .pressKey && isSpace(action.key))
    }

    static func hasSubmitControl(in snapshot: CUSnapshot) -> Bool {
        guard isBrowser(snapshot.app) || hasBrowserAccessibilityContext(snapshot) else { return false }
        return snapshot.elements.contains { element in
            isSubmissionControlRole(element.role) && hasSubmitSignal(
                [element.label, element.roleDescription, element.value]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }
    }

    public static func binding(
        action: AgentAction,
        element: CUElement?,
        snapshot: CUSnapshot,
        appName: String?,
        effect: EffectClass
    ) -> SubmissionApprovalBinding? {
        let app = appName ?? snapshot.app
        guard isBrowser(app) || hasBrowserAccessibilityContext(snapshot) else { return nil }

        let targetHasSubmitSignal = hasSubmitSignal(
            [
                element?.label,
                element?.roleDescription,
                element.flatMap(safeElementValue),
                action.target?.describe,
                action.note,
            ]
                .compactMap { $0 }
                .joined(separator: " "),
            includeCommitmentOnlySignals: isSubmissionControlRole(element?.role)
        )
        let isSpaceControlActivation = action.verb == .pressKey
            && isSpace(action.key)
            && (
                isSubmissionControlRole(element?.role)
                    || isKeyboardControlRole(element?.role)
                    || targetHasSubmitSignal
            )
        let isSubmitActivation =
            (isActivation(action.verb) || isSpaceControlActivation)
            && !hasDismissalSignal(
                [element?.label, element?.roleDescription, action.target?.describe]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
            && (
                targetHasSubmitSignal
                    || (isSubmissionControlRole(element?.role) && isWithinForm(element))
                    || (
                        isSubmissionControlRole(element?.role)
                            && hasFormInputContext(snapshot)
                    )
                    || (
                        (isSubmissionControlRole(element?.role)
                            || isButtonRole(element?.roleDescription))
                            && effect >= .edit
                    )
            )
        let isReturnSubmission = action.verb == .pressKey && isReturnOrEnter(action.key)
        // Native AX value-setting does not activate a form, but `type` may
        // route through HID fallback. A newline then becomes a real Return
        // event, so treat it as a possible submit boundary in every browser.
        let isTypedNewlineSubmission = (action.verb == .type || action.verb == .setValue)
            && (action.text?.contains(where: { $0 == "\n" || $0 == "\r" }) ?? false)
        guard isSubmitActivation || isReturnSubmission || isTypedNewlineSubmission else { return nil }

        let targetIsSecure = element.map { CUSecureFieldRole.contains($0.role) } ?? false
        return SubmissionApprovalBinding(
            snapshotId: snapshot.snapshotId,
            appName: app,
            verb: action.verb,
            targetLabel: element.flatMap(displayLabel) ?? action.target?.describe,
            actionLabel: targetIsSecure ? "Enter protected text" : action.feedLabel,
            targetFingerprint: element.map(elementFingerprint),
            snapshotFingerprint: snapshotFingerprint(snapshot),
            targetIsSecure: targetIsSecure,
            actionFingerprint: processKeyedFingerprint([action.feedLabel]),
            hadSubmissionSuccessSignal: hasSubmissionSuccessSignal(snapshot)
        )
    }

    /// Revalidate an approved submission against a fresh AX capture. Returns
    /// the fresh target reference to execute, or nil when the app, form, action,
    /// or target changed while the user was reviewing the prompt.
    static func revalidation(
        for binding: SubmissionApprovalBinding,
        action: AgentAction,
        snapshot: CUSnapshot
    ) -> Revalidation {
        guard action.verb == binding.verb,
            processKeyedFingerprint([action.feedLabel]) == binding.actionFingerprint,
            snapshot.app.caseInsensitiveCompare(binding.appName) == .orderedSame,
            snapshotFingerprint(snapshot) == binding.snapshotFingerprint
        else { return .invalid }

        guard let targetFingerprint = binding.targetFingerprint else {
            return .valid(nil)
        }
        guard let element = snapshot.elements.first(where: {
            elementFingerprint($0) == targetFingerprint
        }) else {
            return .invalid
        }
        return .valid(element)
    }

    public static func revalidatedElement(
        for binding: SubmissionApprovalBinding,
        action: AgentAction,
        snapshot: CUSnapshot
    ) -> CUElement? {
        guard case .valid(let element) = revalidation(
            for: binding,
            action: action,
            snapshot: snapshot
        ) else {
            return nil
        }
        return element
    }

    static func verifiesSubmission(
        for binding: SubmissionApprovalBinding,
        action: AgentAction,
        snapshot: CUSnapshot
    ) -> Bool {
        if case .invalid = revalidation(for: binding, action: action, snapshot: snapshot) {
            return true
        }
        return !binding.hadSubmissionSuccessSignal && hasSubmissionSuccessSignal(snapshot)
    }

    private static func hasSubmissionSuccessSignal(_ snapshot: CUSnapshot) -> Bool {
        snapshot.elements.contains { element in
            let text = [element.label, safeElementValue(element), element.roleDescription]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            return submissionSuccessSignals.contains { signal in
                text.contains(signal)
            }
        }
    }

    public static func confirmationPreview(
        action: AgentAction,
        binding: SubmissionApprovalBinding,
        note: String?
    ) -> ActionPreview {
        ActionPreview(
            appName: binding.appName,
            actionLabel: binding.actionLabel,
            targetLabel: binding.targetLabel,
            effect: .consequential,
            note: binding.targetIsSecure
                ? "Protected input is ready. Approve only if you want to submit the form now."
                : (note ?? "The form is filled and ready for review. Approve only if you want to submit it now."),
            typedText: binding.targetIsSecure ? nil : action.typedTextForPreview,
            approvalScope: .oneShot(binding)
        )
    }

    private static func isActivation(_ verb: AgentVerb) -> Bool {
        verb == .click || verb == .doubleClick
    }

    private static func isSpace(_ key: String?) -> Bool {
        switch key?.lowercased() {
        case "space", "spacebar", " ": return true
        default: return false
        }
    }

    private static func isKeyboardControlRole(_ role: String?) -> Bool {
        guard let normalized = role?.lowercased() else { return false }
        return normalized.contains("checkbox") || normalized.contains("check box")
            || normalized.contains("radio") || normalized.contains("switch")
    }

    private static func isSubmissionControlRole(_ role: String?) -> Bool {
        guard let normalized = role?.lowercased() else { return false }
        return normalized.contains("button") || normalized.contains("link")
            || normalized.contains("menuitem") || normalized.contains("menu item")
    }

    private static func isButtonRole(_ role: String?) -> Bool {
        role?.lowercased().contains("button") == true
    }

    private static func isWithinForm(_ element: CUElement?) -> Bool {
        [element?.path, element?.roleDescription]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains("form")
    }

    private static func hasFormInputContext(_ snapshot: CUSnapshot) -> Bool {
        snapshot.elements.contains { element in
            let role = element.role.lowercased()
            return role.contains("textfield") || role.contains("text field")
                || role.contains("textarea") || role.contains("text area")
                || role.contains("securetext") || role.contains("secure text")
                || role.contains("combobox") || role.contains("combo box")
                || role.contains("checkbox") || role.contains("check box")
                || role.contains("radio")
        }
    }

    private static func isReturnOrEnter(_ key: String?) -> Bool {
        switch key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "return", "enter", "\r", "\n": return true
        default: return false
        }
    }

    private static func isBrowser(_ appName: String) -> Bool {
        let normalized = appName.lowercased()
        return browserNames.contains { normalized.contains($0) }
    }

    private static func hasBrowserAccessibilityContext(_ snapshot: CUSnapshot) -> Bool {
        snapshot.elements.contains { element in
            let context = [element.role, element.roleDescription, element.path]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            return context.contains("webarea") || context.contains("web area")
                || context.contains("web content") || context.contains("html")
        }
    }

    private static func hasSubmitSignal(
        _ text: String,
        includeCommitmentOnlySignals: Bool = true
    ) -> Bool {
        let normalized = text.lowercased()
        let tokens = Set(normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let signals = includeCommitmentOnlySignals
            ? submitSignals.union(commitmentOnlySignals)
            : submitSignals
        return signals.contains { signal in
            signal.contains(" ") ? normalized.contains(signal) : tokens.contains(signal)
        }
    }

    private static func hasDismissalSignal(_ text: String) -> Bool {
        let tokens = Set(
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )
        return !tokens.isDisjoint(with: dismissalSignals)
    }

    private static func displayLabel(_ element: CUElement) -> String? {
        var description = element.role
        if let label = element.label, !label.isEmpty {
            description += " \"\(label)\""
        } else if let roleDescription = element.roleDescription, !roleDescription.isEmpty {
            description += " \"\(roleDescription)\""
        }
        return description.isEmpty ? nil : description
    }

    private static func safeElementValue(_ element: CUElement) -> String? {
        CUSecureFieldRole.contains(element.role) ? nil : element.value
    }

    private static func snapshotFingerprint(_ snapshot: CUSnapshot) -> UInt64 {
        // Capture tier and focus flags are intentionally excluded: opening the
        // Osaurus approval card can change focus, and the freshness capture is
        // AX-only even when the prior resolution escalated to SoM. The actual
        // form controls, values, enabled state, app, and window must stay equal.
        // Unrelated page content is excluded so clocks, carousels, and ads do
        // not invalidate an otherwise exact approval.
        var fields = [snapshot.app, snapshot.focusedWindow ?? ""]
        let elementFields = snapshot.elements.filter(isFormStateElement).map { element in
            [
                element.path ?? "", element.role, element.roleDescription ?? "", element.label ?? "",
                element.value ?? "",
                element.placeholder ?? "", element.enabled ? "1" : "0",
            ]
        }.sorted { $0.lexicographicallyPrecedes($1) }
        fields.append(contentsOf: elementFields.flatMap { $0 })
        return processKeyedFingerprint(fields)
    }

    private static func isFormStateElement(_ element: CUElement) -> Bool {
        let role = element.role.lowercased()
        return role.contains("textfield") || role.contains("text field")
            || role.contains("textarea") || role.contains("text area")
            || role.contains("securetext") || role.contains("secure text")
            || role.contains("combobox") || role.contains("combo box")
            || role.contains("checkbox") || role.contains("check box")
            || role.contains("radio") || role.contains("button")
            || isWithinForm(element)
    }

    private static func elementFingerprint(_ element: CUElement) -> UInt64 {
        processKeyedFingerprint([
            element.path ?? "", element.role, element.roleDescription ?? "", element.label ?? "",
            element.placeholder ?? "", String(element.windowId ?? -1),
        ])
    }

    /// Approval exists only in this process. Swift's process-keyed Hasher keeps
    /// equality stable for the approval lifetime without producing a portable
    /// dictionary oracle for form values.
    private static func processKeyedFingerprint(_ fields: [String]) -> UInt64 {
        var hasher = Hasher()
        for field in fields {
            hasher.combine(field)
        }
        return UInt64(truncatingIfNeeded: hasher.finalize())
    }

    private static let browserNames = [
        "safari", "google chrome", "chrome", "chromium", "firefox", "arc", "brave", "edge", "opera", "vivaldi",
        "orion", "duckduckgo", "zen browser", "browser", "dia",
    ]

    private static let submitSignals: Set<String> = [
        "submit", "send", "continue", "confirm", "register", "checkout", "purchase", "pay", "book", "schedule",
        "post", "publish", "upload", "sign in", "sign up", "log in", "place order", "create account", "save changes",
        "next", "finish", "complete", "apply", "request access", "subscribe", "get started",
        "login", "signin", "signup", "signout", "go", "search", "join",
        "enviar", "envoyer", "senden", "continuar", "invia", "bestellen",
        "отправить", "продолжить", "войти", "заказать",
        "送信", "提交", "继续", "登录", "确认", "결제", "제출",
    ]

    // These labels are consequential on buttons/links, but commonly describe
    // reversible form controls such as "Agree to terms" checkboxes. Only use
    // them when accessibility identifies a submission-capable control role.
    private static let commitmentOnlySignals: Set<String> = [
        "authorize", "approve", "accept", "agree",
    ]

    private static let dismissalSignals: Set<String> = [
        "back", "cancel", "close", "dismiss", "later", "skip",
    ]

    private static let submissionSuccessSignals: Set<String> = [
        "submitted", "submission received", "success", "thank you",
        "request received", "order confirmed", "payment complete",
        "enviado", "envoyé", "gesendet", "отправлено", "已提交", "제출 완료",
    ]
}

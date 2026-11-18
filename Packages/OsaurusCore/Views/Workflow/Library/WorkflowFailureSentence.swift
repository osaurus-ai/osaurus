//
//  WorkflowFailureSentence.swift
//  osaurus
//
//  A failed run in plain words for Activity and Home: what Osaurus tried,
//  what stopped it, a short reason beside the failed step, and the one
//  thing to do about it when there is one. Built from the step's
//  `NodeRunFailure` classification; codes and stack text stay on the run
//  page (Technical details).
//

import Foundation

/// What to offer first for a failure.
enum WorkflowActivityRemedy: Equatable {
    case fix(WorkflowFailureRemedy)
    /// A connection asked to sign in again: Set Up has Sign In Again.
    case signInAgain

    var title: String {
        switch self {
        case .fix(let remedy): return remedy.title
        case .signInAgain: return L("Sign in again")
        }
    }
}

struct WorkflowFailureExplanation: Equatable {
    /// "Osaurus tried to run “Read mail”, but a connected account asked you to sign in again."
    let sentence: String
    /// The failed step's name, when a step failed.
    let failedStep: String?
    /// "sign-in expired", beside the failed step.
    let shortReason: String?
    let remedy: WorkflowActivityRemedy?
}

enum WorkflowFailureSentence {
    /// A run that failed or stopped for setup.
    static func explain(_ run: WorkflowRun, definition: WorkflowDefinition?) -> WorkflowFailureExplanation {
        let nodeID = run.error?.nodeID ?? run.nodes.last { $0.status == .failed }?.nodeID
        let node = nodeID.flatMap(run.node)
        let step = nodeID.map { definition?.node($0)?.name ?? $0 }
        let failure = run.error?.failure ?? node?.failure
        let message = run.error?.reason ?? node?.error
        if run.status == .needsSetup {
            return WorkflowFailureExplanation(
                sentence: L("\(run.workflowName) needs to be set up before it can run."),
                failedStep: step, shortReason: L("needs setup"), remedy: nil)
        }
        guard let failure else {
            let sentence = step.map { L("“\($0)” did not finish.") } ?? L("\(run.workflowName) did not finish.")
            return WorkflowFailureExplanation(
                sentence: append(message, to: sentence), failedStep: step, shortReason: nil, remedy: nil)
        }
        let remedy = remedy(for: failure, reason: message)
        return WorkflowFailureExplanation(
            sentence: sentence(kind: failure.kind, step: step ?? run.workflowName, remedy: remedy, message: message),
            failedStep: step, shortReason: shortReason(failure.kind), remedy: remedy)
    }

    /// An automation that could not start its workflow at all.
    static func explain(refused eventRun: EventRun, workflowName: String) -> WorkflowFailureExplanation {
        WorkflowFailureExplanation(
            sentence: append(eventRun.error, to: L("Osaurus could not start \(workflowName).")),
            failedStep: nil, shortReason: nil, remedy: nil)
    }

    static func remedy(for failure: NodeRunFailure, reason: String?) -> WorkflowActivityRemedy? {
        if failure.kind == "sign_in_needed" || failure.kind == "provider_auth" { return .signInAgain }
        return WorkflowFailureRemedy.from(failure: failure, reason: reason).map(WorkflowActivityRemedy.fix)
    }

    static func sentence(kind: String, step: String, remedy: WorkflowActivityRemedy?, message: String?) -> String {
        switch kind {
        case "sign_in_needed", "provider_auth":
            return L("Osaurus tried to run “\(step)”, but a connected account asked you to sign in again.")
        case "connection_missing":
            return L("Osaurus tried to run “\(step)”, but the account it signs in with is gone.")
        case "http_401", "http_403":
            return L("Osaurus tried to run “\(step)”, but the service turned down its sign-in.")
        case "permission_denied":
            return L("Osaurus tried to run “\(step)”, but macOS has not given it permission yet.")
        case "user_denied", "folder_denied":
            return L("“\(step)” stopped because the request to allow it was declined.")
        case "replace_denied":
            return L("“\(step)” stopped because replacing existing files was not allowed.")
        case "dialog_dismissed":
            return L("“\(step)” stopped because its form was closed without an answer.")
        case "form_expired":
            return L("“\(step)” stopped because nobody answered its form in time.")
        case "no_model", "model_unavailable", "unsupported_model", "no_media_model", "image_model_unavailable",
            "provider_model_unavailable":
            return L("Osaurus tried to run “\(step)”, but the model it uses is not available.")
        case "missing_key":
            return L("Osaurus tried to run “\(step)”, but a key it needs has not been added.")
        case "timed_out", "model_timed_out", "code_limit":
            return L("“\(step)” ran out of time before it finished.")
        case "timeout", "network_error", "provider_error", "http_429":
            return L("Osaurus tried to reach a service for “\(step)”, but it did not answer. Trying again may work.")
        case "model_busy", "model_residency", "insufficient_memory", "memory_admission":
            return L("“\(step)” could not start because other work was using the memory it needs.")
        case "insufficient_funds":
            return L("“\(step)” stopped because the provider account is out of credits.")
        case "unavailable":
            if case .fix(.chooseFolder)? = remedy {
                return L("“\(step)” needs a folder to work in, and none is chosen.")
            }
            return append(message, to: L("Something “\(step)” needs is not available on this Mac right now."))
        default:
            if kind.hasPrefix("http_5") {
                return L("Osaurus tried to reach a service for “\(step)”, but it did not answer. Trying again may work.")
            }
            return append(message, to: L("“\(step)” did not finish."))
        }
    }

    /// A few words beside the failed step.
    static func shortReason(_ kind: String) -> String? {
        switch kind {
        case "sign_in_needed", "provider_auth": return L("sign-in expired")
        case "connection_missing": return L("account removed")
        case "http_401", "http_403": return L("sign-in refused")
        case "permission_denied", "user_denied", "folder_denied", "replace_denied": return L("not allowed")
        case "dialog_dismissed", "form_expired": return L("no answer")
        case "no_model", "model_unavailable", "unsupported_model", "no_media_model", "image_model_unavailable",
            "provider_model_unavailable":
            return L("no model")
        case "missing_key": return L("missing key")
        case "timed_out", "model_timed_out", "code_limit", "timeout": return L("ran out of time")
        case "network_error", "provider_error", "http_429": return L("service did not answer")
        case "model_busy", "model_residency", "insufficient_memory", "memory_admission": return L("not enough memory")
        case "insufficient_funds": return L("out of credits")
        case "unavailable": return L("not available")
        default: return kind.hasPrefix("http_5") ? L("service did not answer") : nil
        }
    }

    private static func append(_ message: String?, to sentence: String) -> String {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return sentence
        }
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return sentence + " " + line
    }
}

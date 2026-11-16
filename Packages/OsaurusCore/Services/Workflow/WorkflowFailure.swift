//
//  WorkflowFailure.swift
//  osaurus
//
//  What a failed step tells the person and the Architect. `message` is the
//  error's own words: a Swift error without `LocalizedError` bridges to
//  "The operation couldn't be completed (X error N)", which says nothing,
//  so its description is used instead. `classify` says what kind of
//  failure it was, whether another attempt could help, and where the fix
//  belongs: the step, Set Up, an app setting, a retry, or the person.
//

import Foundation

/// A step stopped by an app setting rather than by anything in the step.
struct WorkflowSettingBlock: Error, LocalizedError, Equatable {
    var message: String
    /// The setting's on-screen title, as in `SettingsSearchIndex`.
    var setting: String
    var kind: String

    var errorDescription: String? { message }
}

enum WorkflowFailure {

    static func message(_ error: Error) -> String {
        if let recorded = error as? RecordedNodeFailure { return message(recorded.underlying) }
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return text
        }
        if isBridgedWithoutDescription(error) {
            if let described = error as? CustomStringConvertible { return described.description }
            return typeName(error) + "." + String(describing: error)
        }
        return error.localizedDescription
    }

    /// A Swift error bridged to `NSError` with nothing but its type and case
    /// number to show.
    static func isBridgedWithoutDescription(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == String(reflecting: type(of: error))
            && ns.userInfo[NSLocalizedDescriptionKey] == nil
    }

    static func typeName(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    static func classify(_ error: Error) -> NodeRunFailure {
        if let recorded = error as? RecordedNodeFailure { return classify(recorded.underlying) }
        let retryable = WorkflowNodeError.isRetryable(error)
        func make(_ kind: String, _ fixIn: NodeRunFailure.FixIn, _ hint: String? = nil, type: String? = nil)
            -> NodeRunFailure
        {
            NodeRunFailure(
                kind: kind, retryable: retryable, errorType: type ?? typeName(error), fixIn: fixIn, hint: hint)
        }

        switch error {
        case let node as WorkflowNodeError:
            let type = "WorkflowNodeError." + node.caseName
            switch node {
            case .placeholder:
                return make("placeholder", .workflow, L("Build this step: give it a kind and its settings."), type: type)
            case .noModel(let slot):
                return make(
                    "no_model", .setup, L("Bind a model to the slot \"\(slot)\" in Set Up, or give the step another slot."),
                    type: type)
            case .outputMismatch:
                return make(
                    "output_mismatch", .workflow,
                    L("Change the step's instructions or its output schema so what it returns matches."), type: type)
            case .timedOut:
                return make(
                    "timed_out", .workflow,
                    L("The step ran out of time. Raise its timeout or give it less to do; a first run may also be loading a model."),
                    type: type)
            case .dialogDismissed:
                return make("dialog_dismissed", .person, L("The form was closed without an answer. Run again and fill it in."), type: type)
            case .formExpired:
                return make(
                    "form_expired", .person,
                    L("Nobody answered the form in time. Run again and fill it in, or remove the form's `expires_after` so it waits for an answer."),
                    type: type)
            case .unsupported:
                return make("unsupported", .workflow, type: type)
            case .toolFailed(let tool, let kind, _, let toolRetryable):
                return toolFailure(tool: tool, kind: kind, retryable: toolRetryable, type: type)
            case .missingSecret(let key, let forAgent):
                return make(
                    "missing_key", .setup,
                    forAgent
                        ? L("Add \(key) in Settings → Vault, shared by all agents or as this agent's own value.")
                        : L("Add \(key) in Settings → Vault as a value shared by all agents; runs without an agent use only those."),
                    type: type)
            }
        case let block as WorkflowSettingBlock:
            return make(block.kind, .settings, L("Change \(block.setting), or change the step so it stays within it."))
        case let subagent as SubagentError:
            let type = "SubagentError." + subagent.kindName
            switch subagent {
            case .denied:
                return make(
                    "denied", .settings,
                    L("A permission or policy refuses this; the message names it. Workflow steps do not use agent settings: change the step, or the app setting the message names."),
                    type: type)
            case .userDenied:
                return make("user_denied", .person, L("The person declined. Run again and allow it, or change the step."), type: type)
            case .unavailable:
                return make(
                    "unavailable", .settings,
                    L("Something this step needs is not available on this Mac right now; the message names it. When another loaded model is in the way, see Agents → Delegation → Local Models & Memory → Swap Local Models for Subagents; when no model is set, see Model Defaults → Images & Video → Image Generation Model."),
                    type: type)
            case .invalidArgs:
                return make("invalid_args", .workflow, L("Fix the arguments the step passes."), type: type)
            case .timedOut:
                return make("timed_out", .retry, L("Retry from the failed step. If it times out again, raise the step's timeout."), type: type)
            case .iterationCap, .overBudget, .emptyExhausted, .toolRejected:
                return make(subagent.kindName, .workflow, L("Narrow the step's task or its tools so it can finish."), type: type)
            case .executionFailed(_, let canRetry):
                return canRetry
                    ? make("execution_failed", .retry, L("Retry from the failed step."), type: type)
                    : make("execution_failed", .workflow, type: type)
            }
        case let structured as StructuredOutputError:
            if case .unsupportedModel = structured {
                return make(
                    "unsupported_model", .setup,
                    L("Bind the step's model slot to a model that can follow a JSON schema."))
            }
            return make("output_mismatch", .workflow, L("Change the step's instructions or its output schema so what it returns matches."))
        case let core as CoreModelError:
            switch core {
            case .timedOut, .unresponsive, .circuitBreakerOpen:
                return make("model_timed_out", .retry, L("Retry from the failed step. If it repeats, raise the step's timeout."))
            case .modelUnavailable, .backgroundWouldEvictUserModel:
                return make("model_unavailable", .setup, L("Bind the step's model slot to a model that is installed or connected."))
            }
        case let code as CodeNodeError:
            switch code {
            case .runtimeMissing:
                return make("code_runtime_missing", .settings, L("This build is missing its JavaScript helper. Reinstall Osaurus."))
            case .launchFailed:
                return make("code_launch_failed", .retry, L("Retry from the failed step."))
            case .timedOut, .memoryLimit:
                return make("code_limit", .workflow, L("Make the code do less, or raise the step's timeout or memory limit."))
            case .scriptError, .crashed:
                return make("code_error", .workflow, L("Fix the step's code; the message and stack say where."))
            }
        case is DeadlineExceededError:
            return make("timed_out", .workflow, L("The step ran out of time. Raise its timeout or give it less to do."))
        case is MediaModelResolver.Failure:
            return make(
                "no_media_model", .setup,
                L("Install or connect a model that can do this, or change the step's model to one that is here."))
        case let handoff as ChatResidencyHandoff.HandoffError:
            switch handoff {
            case .chatBusy:
                return make("model_busy", .retry, L("Another model was still working. Retry from the failed step."))
            case .insufficientMemory:
                return make("insufficient_memory", .settings, L("Not enough memory. Close other models or apps, or change Server → Memory Safety."))
            default:
                return make(
                    "model_residency", .settings,
                    L("Another loaded model is in the way. Finish that work, or turn on Agents → Delegation → Local Models & Memory → Swap Local Models for Subagents."))
            }
        case let image as ImageGenerationError:
            switch image {
            case .modelNotFound, .modelIncomplete, .unknownModel, .wrongModelKind:
                return make("image_model_unavailable", .setup, L("Install the image model again, or pick another one in Model Defaults."))
            case .invalidRequest:
                return make("invalid_args", .workflow, L("Change the step's image settings; the message names the one refused."))
            case .engine:
                return make("image_engine", .retry, L("Retry from the failed step."))
            case .memoryAdmission:
                return make("memory_admission", .settings, L("Make fewer or smaller images, or change Server → Memory Safety."))
            }
        case let coordinator as NativeImageJobCoordinatorError:
            switch coordinator {
            case .noReadyModel, .selectedModelUnavailable, .selectedModelIncomplete, .selectedModelWrongKind:
                return make("image_model_unavailable", .setup, L("Install an image model, or pick another one in Model Defaults."))
            case .requestFailed:
                return make("image_job_failed", .retry, L("Retry from the failed step."))
            case .cancelled:
                return make("cancelled", .person)
            }
        case let media as MediaGenerationError:
            switch media {
            case .authenticationRequired:
                return make("provider_auth", .setup, L("Sign in to the provider again."))
            case .insufficientFunds:
                return make("insufficient_funds", .person, L("Add credits with the provider."))
            case .contentPolicy, .invalidRequest, .unsupported:
                return make("provider_refused", .workflow, L("Change the step's prompt or settings; the provider names what it refused."))
            case .modelUnavailable, .invalidTarget, .regionRestricted:
                return make("provider_model_unavailable", .setup, L("Pick a provider model that is available to you."))
            case .providerUnavailable, .transport, .invalidResponse, .queuedJobContinues, .server:
                return make("provider_error", .retry, L("Retry from the failed step."))
            }
        default:
            return make("error", retryable ? .retry : .workflow)
        }
    }

    /// A tool's failure envelope, by its kind.
    private static func toolFailure(tool: String, kind: String, retryable: Bool, type: String) -> NodeRunFailure {
        func make(_ fixIn: NodeRunFailure.FixIn, _ hint: String? = nil) -> NodeRunFailure {
            NodeRunFailure(kind: kind, retryable: retryable, errorType: type, fixIn: fixIn, hint: hint, tool: tool)
        }
        switch kind {
        case "user_denied", "folder_denied":
            return make(.person, L("The person declined. Run again and allow it, or change the step."))
        case "replace_denied":
            return make(
                .person,
                L("The person didn't allow replacing existing files. Run again and allow it, or save results to a new folder."))
        case "permission_denied":
            return make(.settings, L("Grant \(tool) its permission, or remove the step."))
        case "unavailable":
            return make(.settings, L("\(tool) cannot run on this Mac right now; the message says why."))
        case "command_not_found":
            return make(.setup, L("Declare the program as a dependency so Set Up installs it."))
        case "timeout", "network_error":
            return make(.retry, L("Retry from the failed step. If it repeats, add a retry policy or raise the timeout."))
        case "http_401", "http_403":
            return make(.setup, L("The service refused the credentials. Check the step's secret or connection in Set Up."))
        default:
            if kind.hasPrefix("http_5") || kind == "http_429" {
                return make(.retry, L("The service is failing or busy. Retry, or add a retry policy."))
            }
            return make(retryable ? .retry : .workflow)
        }
    }
}

extension WorkflowNodeError {
    var caseName: String {
        switch self {
        case .placeholder: return "placeholder"
        case .noModel: return "noModel"
        case .outputMismatch: return "outputMismatch"
        case .timedOut: return "timedOut"
        case .dialogDismissed: return "dialogDismissed"
        case .formExpired: return "formExpired"
        case .unsupported: return "unsupported"
        case .toolFailed: return "toolFailed"
        case .missingSecret: return "missingSecret"
        }
    }
}

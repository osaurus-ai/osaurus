//
//  SupportReportDraft.swift
//  osaurus
//
//  What the user has filled in on "Report a Problem" but not sent: the kind
//  of report, what it is about (picked from this Mac's own agents, workflows,
//  models, Osaurus Cloud models, paired phone and Store listings), the
//  description and any images.
//
//  Two things leave the Mac from here, and the review step shows both:
//  - `details`: the user's picks, by name. Small (the router caps it at 4 KB)
//    and always sent.
//  - `extras`: metadata about the picked item (a model's size, a workflow's
//    recent run outcomes). Only with "Share extra details" on, and placed
//    under `diagnostics.extras` so it reads alongside the rest of the bundle.
//

import Foundation

/// The kinds of report, in the order the form offers them. Raw values are
/// the router's `category` values.
enum SupportCategory: String, CaseIterable, Identifiable, Sendable {
    case bug
    case cloud
    case agent
    case workflow
    case ios
    case store
    case model

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: return L("Something Isn't Working")
        case .cloud: return L("Osaurus Cloud")
        case .agent: return L("Agent Problem")
        case .workflow: return L("Workflow Problem")
        case .ios: return L("iPhone App")
        case .store: return L("Store")
        case .model: return L("Model Trouble")
        }
    }

    var subtitle: String {
        switch self {
        case .bug: return L("Crashes, errors, or something that looks wrong.")
        case .cloud: return L("Cloud models fail, will not connect, or credits look wrong.")
        case .agent: return L("An agent gives wrong answers or misuses tools.")
        case .workflow: return L("A workflow fails, stalls, or does the wrong thing.")
        case .ios: return L("Pairing, syncing, or the Osaurus iPhone app.")
        case .store: return L("Publishing to or installing from the Store.")
        case .model: return L("A model will not download, load, or run well.")
        }
    }

    var symbol: String {
        switch self {
        case .bug: return "ladybug"
        case .cloud: return "cloud"
        case .agent: return "person.crop.circle"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .ios: return "iphone"
        case .store: return "bag"
        case .model: return "cpu"
        }
    }

    /// Short label for lists and the thread subtitle.
    var shortLabel: String {
        switch self {
        case .bug: return L("Bug")
        case .cloud: return L("Cloud")
        case .agent: return L("Agent")
        case .workflow: return L("Workflow")
        case .ios: return L("iPhone")
        case .store: return L("Store")
        case .model: return L("Model")
        }
    }

    /// The "what went wrong" choices. Ids are stable English keys sent in
    /// `details.problem`; titles are what the user reads.
    var problems: [SupportProblem] {
        switch self {
        case .bug:
            return [
                .init(id: "crash", title: L("Crashed or quit")),
                .init(id: "error", title: L("Showed an error")),
                .init(id: "wrong_display", title: L("Looks wrong")),
                .init(id: "slow", title: L("Slow or frozen")),
                .init(id: "other", title: L("Something else")),
            ]
        case .cloud:
            return [
                .init(id: "cannot_connect", title: L("Will not connect")),
                .init(id: "requests_fail", title: L("Requests fail")),
                .init(id: "slow", title: L("Slow or times out")),
                .init(id: "models_missing", title: L("Models are missing")),
                .init(id: "credits", title: L("Credits or billing")),
                .init(id: "other", title: L("Something else")),
            ]
        case .agent:
            return [
                .init(id: "wrong_answer", title: L("Wrong or made-up answers")),
                .init(id: "tool_misuse", title: L("Uses tools wrongly")),
                .init(id: "stuck", title: L("Gets stuck or loops")),
                .init(id: "ignores_instructions", title: L("Ignores its instructions")),
                .init(id: "other", title: L("Something else")),
            ]
        case .workflow:
            return [
                .init(id: "fails", title: L("Fails")),
                .init(id: "stalls", title: L("Stalls or never finishes")),
                .init(id: "wrong_output", title: L("Wrong result")),
                .init(id: "setup", title: L("Cannot set it up")),
                .init(id: "other", title: L("Something else")),
            ]
        case .ios:
            return [
                .init(id: "pairing", title: L("Cannot pair")),
                .init(id: "disconnects", title: L("Keeps disconnecting")),
                .init(id: "sync", title: L("Chats do not sync")),
                .init(id: "app_crash", title: L("The iPhone app crashes")),
                .init(id: "other", title: L("Something else")),
            ]
        case .store:
            return [
                .init(id: "publish_fails", title: L("Cannot publish")),
                .init(id: "install_fails", title: L("Cannot install")),
                .init(id: "listing_wrong", title: L("Listing looks wrong")),
                .init(id: "removed", title: L("Listing was removed")),
                .init(id: "other", title: L("Something else")),
            ]
        case .model:
            return [
                .init(id: "download", title: L("Will not download")),
                .init(id: "load", title: L("Will not load")),
                .init(id: "slow", title: L("Too slow")),
                .init(id: "bad_output", title: L("Garbled or repeating output")),
                .init(id: "memory", title: L("Uses too much memory")),
                .init(id: "other", title: L("Something else")),
            ]
        }
    }

    /// The "Share extra details" switch, or nil when the category has
    /// nothing beyond the standard diagnostics.
    var extrasTitle: String? {
        switch self {
        case .bug: return nil
        case .cloud: return L("Share the connection status")
        case .agent: return L("Share the agent's setup")
        case .workflow: return L("Share recent run results")
        case .ios: return L("Share pairing status")
        case .store: return L("Share the listing's status")
        case .model: return L("Share the model's details")
        }
    }

    var extrasDetail: String? {
        switch self {
        case .bug: return nil
        case .cloud:
            return L("Whether Osaurus Cloud is on and connected, when it last connected, and how many models it lists. Not your chats or balance.")
        case .agent: return L("Default model and whether it is locked. Not the agent's instructions.")
        case .workflow: return L("Status, timing, and the failed step of the last 5 runs. Not their inputs or outputs.")
        case .ios: return L("When the phone was paired and how it connects. Not your chats.")
        case .store: return L("The listing's id, version, and visibility.")
        case .model: return L("The model's type and size on disk.")
        }
    }
}

struct SupportDetailRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct SupportProblem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

/// Part of the app a general bug is about.
enum SupportAppArea: String, CaseIterable, Identifiable, Sendable {
    case chat
    case agents
    case workflows
    case models
    case settings
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return L("Chat")
        case .agents: return L("Agents")
        case .workflows: return L("Workflows")
        case .models: return L("Models")
        case .settings: return L("Settings")
        case .other: return L("Somewhere else")
        }
    }
}

/// Which way a Store problem goes.
enum SupportStoreDirection: String, CaseIterable, Identifiable, Sendable {
    case publishing
    case installing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .publishing: return L("Publishing")
        case .installing: return L("Installing")
        }
    }
}

/// One thing the user picked from this Mac. `id` finds it again for the
/// extras; only `name` goes into `details`.
struct SupportPick: Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

struct SupportReportDraft: Equatable, Sendable {
    var category: SupportCategory?
    var problemId: String?
    var area: SupportAppArea = .chat
    var cloudModel: SupportPick?
    var agent: SupportPick?
    var workflow: SupportPick?
    var model: SupportPick?
    var storeDirection: SupportStoreDirection = .publishing
    var storeListing: SupportPick?
    /// A Store link for an install problem, pasted by the user.
    var storeLink = ""
    var phoneModel = ""
    var phoneOSVersion = ""
    var phoneAppVersion = ""
    var shareExtras = true
    var description = ""
    var images: [SupportImageAttachment] = []

    var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSend: Bool { category != nil && !trimmedDescription.isEmpty }

    var problem: SupportProblem? {
        guard let category, let problemId else { return nil }
        return category.problems.first { $0.id == problemId }
    }

    /// Whether `extras` will be attached: the category has some and the
    /// switch is on.
    var sendsExtras: Bool { shareExtras && category?.extrasTitle != nil }

    /// Switching category drops the picks that belonged to the old one, so
    /// a hidden agent never rides along on a model report.
    mutating func select(category newValue: SupportCategory) {
        guard newValue != category else { return }
        let description = description
        let images = images
        self = SupportReportDraft()
        self.category = newValue
        self.description = description
        self.images = images
    }

    /// The labelled picks, in form order, for the review step. Empty values
    /// are left out.
    var detailRows: [SupportDetailRow] {
        guard let category else { return [] }
        var rows: [SupportDetailRow] = []
        func add(_ key: String, _ label: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { rows.append(SupportDetailRow(id: key, label: label, value: trimmed)) }
        }
        switch category {
        case .bug:
            add("area", L("Where"), area.title)
        case .cloud:
            add("model", L("Model"), cloudModel?.name)
        case .agent:
            add("agent", L("Agent"), agent?.name)
        case .workflow:
            add("workflow", L("Workflow"), workflow?.name)
        case .ios:
            add("phone_model", L("iPhone Model"), phoneModel)
            add("ios_version", L("iOS Version"), phoneOSVersion)
            add("app_version", L("App Version"), phoneAppVersion)
        case .store:
            add("direction", L("Problem With"), storeDirection.title)
            switch storeDirection {
            case .publishing: add("listing", L("Listing"), storeListing?.name)
            case .installing: add("link", L("Store Link"), storeLink)
            }
        case .model:
            add("model", L("Model"), model?.name)
        }
        add("problem", L("What Went Wrong"), problem?.title)
        return rows
    }

    /// `details` for the request: stable keys, with enum picks sent by id so
    /// they read the same whatever language the app is in. Nil when the
    /// user picked nothing.
    var details: JSONValue? {
        guard let category else { return nil }
        var object: [String: JSONValue] = [:]
        func put(_ key: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { object[key] = .string(String(trimmed.prefix(200))) }
        }
        switch category {
        case .bug:
            put("area", area.rawValue)
        case .cloud:
            put("model", cloudModel?.id)
        case .agent:
            put("agent", agent?.name)
        case .workflow:
            put("workflow", workflow?.name)
        case .ios:
            put("phone_model", phoneModel)
            put("ios_version", phoneOSVersion)
            put("app_version", phoneAppVersion)
        case .store:
            put("direction", storeDirection.rawValue)
            switch storeDirection {
            case .publishing: put("listing", storeListing?.name)
            case .installing: put("link", storeLink)
            }
        case .model:
            put("model", model?.id)
        }
        put("problem", problemId)
        return object.isEmpty ? nil : .object(object)
    }
}

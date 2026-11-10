//
//  WorkflowFailureRemedy.swift
//  osaurus
//
//  The one thing the person can do about a failed workflow call, shown as
//  a link on its chat card. Read from the call's result, so a reloaded
//  chat offers it too. Nil when the fix belongs in the workflow itself.
//

import AppKit
import Foundation

enum WorkflowFailureRemedy: Equatable, Sendable {
    /// Grant a macOS permission. The tool's declared requirements say which.
    case systemSettings(tool: String?)
    /// Give the step's agent a folder: none is set, or it is not a git repository.
    case chooseFolder(agent: String?)
    case searchSettings
    case chooseModel

    var title: String {
        switch self {
        case .systemSettings: return L("Open System Settings")
        case .chooseFolder: return L("Choose Folder")
        case .searchSettings: return L("Search settings")
        case .chooseModel: return L("Choose a Model")
        }
    }

    static func from(result: String) -> WorkflowFailureRemedy? {
        guard let object = JSONValue.parse(result)?.objectValue, object["ok"]?.boolValue == false else {
            return nil
        }
        if object["status"]?.stringValue == WorkflowCallResult.Status.needsSetup.rawValue {
            return object["no_model"]?.boolValue == true ? .chooseModel : nil
        }
        guard let error = object["error"]?.objectValue,
            let data = error["failure"].flatMap({ try? JSONEncoder().encode($0) }),
            let failure = try? JSONDecoder().decode(NodeRunFailure.self, from: data)
        else { return nil }
        return from(failure: failure, reason: error["reason"]?.stringValue)
    }

    static func from(failure: NodeRunFailure, reason: String?) -> WorkflowFailureRemedy? {
        switch failure.kind {
        case "no_model", "model_unavailable":
            return .chooseModel
        case "permission_denied":
            return .systemSettings(tool: failure.tool)
        default:
            break
        }
        guard let tool = failure.tool else { return nil }
        if ToolDisplayName.isSearchTool(tool) { return .searchSettings }
        let noFolder = failure.kind == "unavailable" && reason?.contains(FolderToolHelpers.noActiveFolderMessage) == true
        let notARepository =
            ToolRegistry.gitToolNames.contains(tool)
            && reason?.localizedCaseInsensitiveContains("not a git repository") == true
        return noFolder || notARepository ? .chooseFolder(agent: failure.agent) : nil
    }

    @MainActor
    func perform(over window: NSWindow?) {
        switch self {
        case .systemSettings(let tool):
            let info = tool.flatMap { ToolRegistry.shared.policyInfo(for: $0) }
            let needed = info?.systemPermissions ?? []
            if let permission = needed.first(where: { info?.systemPermissionStates[$0] != true }) ?? needed.first {
                SystemPermissionService.shared.openSystemSettings(for: permission)
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(url)
            }
        case .chooseFolder(let reference):
            guard let reference, let agent = WorkflowStepAgent.resolve(reference, in: AgentManager.shared.agents) else {
                AppDelegate.shared?.showManagementWindow(initialTab: .agents)
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = L("Choose")
            panel.message = L("Choose the folder \(agent.name) works in.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let bookmark = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            AgentManager.shared.updateWorkingFolder(for: agent.id, bookmark: bookmark, path: url.path)
        case .searchSettings:
            AppDelegate.shared?.showManagementWindow(initialTab: .search)
        case .chooseModel:
            BrainChooserSheet.present(over: window)
        }
    }
}

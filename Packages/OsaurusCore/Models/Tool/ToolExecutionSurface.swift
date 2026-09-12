//
//  ToolExecutionSurface.swift
//  osaurus
//
//  Where a tool call's side effects land. Shown on the approval card so
//  consent to "run this command" is informed by whether
//  it can touch this Mac or only the isolated VM (osaurus#2651).
//
//  The public workspace vocabulary (`shell_run`, `file_write`, …) keeps one
//  name in every execution mode and is routed to the VM at execution time
//  (`sandboxBridgeExec`, `combinedFileRoute`), so the tool name alone cannot
//  tell the user which machine a command will run on. The resolver here
//  mirrors that routing so the card can.
//

import Foundation

public enum ToolExecutionSurface: String, Sendable, Equatable, CaseIterable {
    /// Runs inside the isolated Linux sandbox VM; it cannot reach this Mac's
    /// files, processes, or apps.
    case sandboxVM
    /// Runs directly on this Mac with the user's normal access.
    case nativeHost
    /// Executes on a remote MCP server reached over the network — neither
    /// on this Mac nor in the sandbox.
    case remoteServer

    // MARK: - Resolution

    /// Surface of a tool registered from an MCP provider. HTTP providers
    /// run remotely; stdio providers run wherever `executionHost` placed
    /// the subprocess. An unresolvable provider is reported as the host —
    /// the conservative answer for a consent prompt.
    static func forMCPProvider(
        transport: MCPProviderTransport?,
        executionHost: MCPProviderExecutionHost?
    ) -> ToolExecutionSurface {
        switch transport {
        case .http:
            return .remoteServer
        case .stdio:
            return executionHost == .sandbox ? .sandboxVM : .nativeHost
        case nil:
            return .nativeHost
        }
    }

    /// Tool names whose backend is chosen per call from the execution
    /// context rather than fixed at registration: `ToolRegistry
    /// .coreWorkspaceToolNames` plus `file_copy`, which routes by path too.
    static let contextRoutedToolNames: Set<String> = [
        "file_read", "file_search", "file_write", "file_edit", "shell_run", "file_copy",
    ]

    /// Mirror of the execution-time routing in `ShellRunTool.execute` and
    /// `combinedFileRoute(path:)`, evaluated on the same inputs those read
    /// from `ChatExecutionContext`, so the card's answer and the tool
    /// body's route can never disagree.
    ///
    /// - `hasSandboxBridge`: the registry resolved a sandbox identity for
    ///   this call (`ToolRegistry.combinedSandboxReadBridge`), i.e. VM
    ///   execution is registered and the run is not a dispatched host folder.
    /// - `hasFolderRoot`: `ChatExecutionContext.currentFolderRoot` is bound.
    /// - `pathArgument`: the routed path argument (`path`, or `destination`
    ///   for `file_copy`), when the model supplied one.
    static func forContextRoutedTool(
        name: String,
        pathArgument: String?,
        hasSandboxBridge: Bool,
        hasFolderRoot: Bool
    ) -> ToolExecutionSurface {
        guard hasSandboxBridge else { return .nativeHost }
        // Pure VM mode: no host root, so every workspace tool serves the VM.
        guard hasFolderRoot else { return .sandboxVM }
        // `shell_run` only bridges into the VM when there is no host root.
        if name == "shell_run" { return .nativeHost }
        // File tools with a host root route an absolute `/workspace/...`
        // path into the VM and everything else to the host folder.
        return (pathArgument ?? "").hasPrefix("/workspace") ? .sandboxVM : .nativeHost
    }

    /// The argument that decides a context-routed file tool's filesystem.
    static func routedPathArgument(toolName: String, argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let key = toolName == "file_copy" ? "destination" : "path"
        return object[key] as? String
    }

    // MARK: - Presentation

    public var title: String {
        switch self {
        case .sandboxVM: L("Sandbox VM")
        case .nativeHost: L("Native · this Mac")
        case .remoteServer: L("Remote MCP server")
        }
    }

    /// One sentence a user can base an approval on.
    public var consentDetail: String {
        switch self {
        case .sandboxVM:
            L("Runs inside the isolated Linux sandbox. It cannot change files, processes, or apps on this Mac.")
        case .nativeHost:
            L("Runs directly on this Mac with your normal access. Approving can change files, processes, or apps on your host.")
        case .remoteServer:
            L("Runs on a remote MCP server over the network — not on this Mac and not in the sandbox.")
        }
    }

    public var symbolName: String {
        switch self {
        case .sandboxVM: "shippingbox.fill"
        case .nativeHost: "desktopcomputer"
        case .remoteServer: "network"
        }
    }
}

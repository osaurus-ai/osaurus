//
//  RoutableWorkflowCatalog.swift
//  osaurus
//
//  Everything `run_workflow` may run, in one list: installed workflows and
//  hosted links marked "Osaurus can run this for you", plus the one-node
//  wrapper for each agent. This is the only reader of the wrappers besides `run_workflow`:
//  the Workflows UI, `osaurus_config`, `osaurus_inspect`, the Architect,
//  pickers, and HTTP/MCP listings read the stores, which never hold one.
//

import Foundation

/// One workflow the Orchestrator may run, as `run_workflow` sees it.
public struct RoutableWorkflowDoc: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case installed
        case hosted
        case wrapper
    }

    public struct Input: Sendable, Hashable {
        public let name: String
        public let type: String
        public let required: Bool

        public init(name: String, type: String, required: Bool) {
            self.name = name
            self.type = type
            self.required = required
        }
    }

    /// Workflow id (UUID string).
    public let id: String
    /// The name `run_workflow` resolves.
    public let name: String
    public let summary: String
    public let inputs: [Input]
    public let kind: Kind

    public init(id: String, name: String, summary: String, inputs: [Input] = [], kind: Kind) {
        self.id = id
        self.name = name
        self.summary = summary
        self.inputs = inputs
        self.kind = kind
    }
}

@MainActor
public enum RoutableWorkflowCatalog {
    /// Installed and hosted workflows the Orchestrator may run, then
    /// wrappers.
    public static func docs() -> [RoutableWorkflowDoc] { listing().docs }

    /// `docs()` plus every wrapper left out because a custom agent or a
    /// workflow already uses its name.
    static func listing() -> (docs: [RoutableWorkflowDoc], shadowed: [AgentWrapperCatalog.Shadowed]) {
        var docs: [RoutableWorkflowDoc] = InstalledWorkflowStore.shared.orchestratorVisible.map { workflow in
            RoutableWorkflowDoc(
                id: workflow.id.uuidString,
                name: workflow.name,
                summary: workflow.summary ?? "",
                inputs: inputs(from: workflow.definition.inputSchema),
                kind: .installed)
        }
        docs += HostedWorkflowLinkStore.shared.orchestratorVisible.map { link in
            RoutableWorkflowDoc(
                id: link.id.uuidString,
                name: link.name,
                summary: link.summary ?? "",
                inputs: inputs(from: link.inputs),
                kind: .hosted)
        }
        let wrappers = wrapperListing()
        let taken = Set(docs.map { $0.name.lowercased() })
        var shadowed = wrappers.shadowed
        for wrapper in wrappers.wrappers {
            if taken.contains(wrapper.name.lowercased()) {
                shadowed.append(.init(name: wrapper.name, by: .workflow, worker: wrapper.worker))
            } else {
                docs.append(wrapper.doc)
            }
        }
        AgentWrapperCatalog.logNewShadows(shadowed)
        return (docs, shadowed)
    }

    /// Names `run_workflow` resolves, for `status` and refusal messages.
    public static func names() -> [String] { docs().map(\.name) }

    /// The live wrappers; a seam for tests.
    static var wrapperListing: @MainActor () -> AgentWrapperCatalog.Listing = { AgentWrapperCatalog.liveListing() }

    /// Top-level properties of an input schema, in declaration order when
    /// the schema keeps one (`required` first, then the rest by name).
    static func inputs(from schema: JSONValue) -> [RoutableWorkflowDoc.Input] {
        guard let object = schema.objectValue, let properties = object["properties"]?.objectValue else { return [] }
        let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let ordered =
            (object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            + properties.keys.sorted().filter { !required.contains($0) }
        return ordered.compactMap { name in
            guard let property = properties[name]?.objectValue else { return nil }
            return RoutableWorkflowDoc.Input(
                name: name, type: property["type"]?.stringValue ?? "string", required: required.contains(name))
        }
    }
}

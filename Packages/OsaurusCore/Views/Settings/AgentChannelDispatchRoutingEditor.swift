//
//  AgentChannelDispatchRoutingEditor.swift
//  osaurus
//
//  Shared inbound-routing editor for provider settings sheets: a default
//  agent plus per-room routing rules with optional name aliases, so several
//  agents can share one channel provider.
//

import SwiftUI

/// A room (Slack channel, Discord channel, Telegram chat) the editor can
/// offer in its room pickers. Providers map their discovery results into
/// this shape.
struct AgentChannelRoutableRoom: Identifiable, Equatable {
    let id: String
    let name: String
}

struct AgentChannelDispatchRoutingEditor: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var roster = WorkspaceRosterStore.shared

    /// Provider-appropriate noun for rooms ("channel" or "chat").
    let roomNoun: String
    /// Discovered rooms for the pickers; rules can still hold ids that are
    /// not in this list (they render as the raw id).
    let rooms: [AgentChannelRoutableRoom]
    /// Default reply target: a local agent or a teammate's shared workspace
    /// agent (which answers on the owner's Mac over the relay).
    @Binding var defaultTarget: AgentDispatchTarget?
    @Binding var routes: [AgentChannelDispatchRoute]

    /// Raw alias text per route id so typing commas/spaces is not fought
    /// by normalization; parsed into the route on every change.
    @State private var aliasDrafts: [UUID: String] = [:]

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var selectableAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    private var workspaceAgents: [WorkspaceAgentPickerOption] {
        WorkspaceAgentPickerOption.all(roster: roster)
    }

    private var hasAnyTarget: Bool {
        !selectableAgents.isEmpty || !workspaceAgents.isEmpty
    }

    private var firstAvailableTarget: AgentDispatchTarget {
        if let defaultTarget { return defaultTarget }
        if let local = selectableAgents.first { return .local(local.id) }
        if let shared = workspaceAgents.first { return .workspace(shared.ref) }
        return .local(UUID())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            defaultAgentPicker

            if !routes.isEmpty {
                Text(
                    "Rules run first: a leading name (\u{201C}sales: \u{2026}\u{201D}) picks its agent, then the \(roomNoun) rule, then the agent above.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach($routes) { $route in
                        routeRow($route)
                    }
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    let route = AgentChannelDispatchRoute(
                        roomId: rooms.first?.id,
                        target: firstAvailableTarget
                    )
                    routes.append(route)
                    aliasDrafts[route.id] = ""
                }
            } label: {
                Label {
                    Text("Add Rule", bundle: .module)
                } icon: {
                    Image(systemName: "plus.circle")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.accentColor)
            .disabled(!hasAnyTarget)

            if routes.isEmpty {
                Text(
                    "Optional: add rules to reply in different \(roomNoun)s with different agents, or let a name prefix pick an agent inside a shared \(roomNoun).",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            for route in routes where aliasDrafts[route.id] == nil {
                aliasDrafts[route.id] = route.nameAliases.joined(separator: ", ")
            }
            roster.beginObserving()
        }
        .onDisappear { roster.endObserving() }
    }

    private var defaultAgentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent that replies", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Picker("", selection: $defaultTarget) {
                Text(
                    routes.isEmpty ? L("Choose an agent") : L("None (reply only where a rule matches)")
                ).tag(AgentDispatchTarget?.none)
                ForEach(selectableAgents) { agent in
                    Text(agent.name).tag(Optional(AgentDispatchTarget.local(agent.id)))
                }
                if !workspaceAgents.isEmpty {
                    Section(header: Text("Workspace agents", bundle: .module)) {
                        ForEach(workspaceAgents) { option in
                            Text(workspaceLabel(option)).tag(Optional(AgentDispatchTarget.workspace(option.ref)))
                        }
                    }
                }
                if let current = defaultTarget, !isKnown(current) {
                    Text(missingLabel(current)).tag(Optional(current))
                }
            }
            .labelsHidden()
            Text(
                defaultTarget?.isWorkspace == true
                    ? L(
                        "Replies to every message no rule below claims. This shared agent runs on its owner's Mac; replies wait until it is online."
                    )
                    : L("Replies to every message no rule below claims.")
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isKnown(_ target: AgentDispatchTarget) -> Bool {
        switch target {
        case .local(let id): return selectableAgents.contains { $0.id == id }
        case .workspace(let ref): return workspaceAgents.contains { $0.ref == ref }
        }
    }

    private func missingLabel(_ target: AgentDispatchTarget) -> String {
        switch target {
        case .local: return L("Missing agent")
        case .workspace(let ref): return L("\(AgentTargetResolver.displayName(for: ref)) (unavailable)")
        }
    }

    /// "Name · Workspace" plus a presence glyph so the picker shows at a
    /// glance whether the teammate's Mac is currently reachable.
    private func workspaceLabel(_ option: WorkspaceAgentPickerOption) -> String {
        let glyph: String
        switch option.presence {
        case .online: glyph = "●"
        case .offline: glyph = "○"
        case .unknown: glyph = "◌"
        }
        return "\(glyph) \(option.name) · \(option.workspaceName)"
    }

    private func routeRow(_ route: Binding<AgentChannelDispatchRoute>) -> some View {
        let routeId = route.wrappedValue.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                roomPicker(route)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                agentPicker(route)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        routes.removeAll { $0.id == routeId }
                        aliasDrafts.removeValue(forKey: routeId)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.tertiaryText)
                .help(Text("Remove this rule", bundle: .module))
            }

            TextField(
                L("Optional names, comma-separated (e.g. sales, support)"),
                text: aliasBinding(for: routeId)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardBackground.opacity(0.5))
        )
    }

    private func roomPicker(_ route: Binding<AgentChannelDispatchRoute>) -> some View {
        Picker("", selection: route.roomId) {
            Text("Any \(roomNoun)", bundle: .module).tag(String?.none)
            ForEach(rooms) { room in
                Text(room.name).tag(Optional(room.id))
            }
            if let currentRoom = route.wrappedValue.roomId,
               !rooms.contains(where: { $0.id == currentRoom }) {
                Text(currentRoom).tag(Optional(currentRoom))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
    }

    private func agentPicker(_ route: Binding<AgentChannelDispatchRoute>) -> some View {
        Picker("", selection: route.target) {
            ForEach(selectableAgents) { agent in
                Text(agent.name).tag(AgentDispatchTarget.local(agent.id))
            }
            if !workspaceAgents.isEmpty {
                Section(header: Text("Workspace agents", bundle: .module)) {
                    ForEach(workspaceAgents) { option in
                        Text(workspaceLabel(option)).tag(AgentDispatchTarget.workspace(option.ref))
                    }
                }
            }
            if !isKnown(route.wrappedValue.target) {
                Text(missingLabel(route.wrappedValue.target)).tag(route.wrappedValue.target)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
    }

    private func aliasBinding(for routeId: UUID) -> Binding<String> {
        Binding(
            get: { aliasDrafts[routeId] ?? "" },
            set: { newValue in
                aliasDrafts[routeId] = newValue
                guard let index = routes.firstIndex(where: { $0.id == routeId }) else { return }
                routes[index].nameAliases = AgentChannelDispatchRoute.normalizedAliases(
                    newValue.split(separator: ",").map(String.init)
                )
            }
        )
    }
}

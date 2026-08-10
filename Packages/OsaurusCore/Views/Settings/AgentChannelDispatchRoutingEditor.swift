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

    /// Provider-appropriate noun for rooms ("channel" or "chat").
    let roomNoun: String
    /// Discovered rooms for the pickers; rules can still hold ids that are
    /// not in this list (they render as the raw id).
    let rooms: [AgentChannelRoutableRoom]
    @Binding var defaultAgentId: UUID?
    @Binding var routes: [AgentChannelDispatchRoute]

    /// Raw alias text per route id so typing commas/spaces is not fought
    /// by normalization; parsed into the route on every change.
    @State private var aliasDrafts: [UUID: String] = [:]

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var selectableAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
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
                        agentId: defaultAgentId ?? selectableAgents.first?.id ?? UUID()
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
            .disabled(selectableAgents.isEmpty)

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
        }
    }

    private var defaultAgentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent that replies", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            Picker("", selection: $defaultAgentId) {
                Text(
                    routes.isEmpty ? L("Choose an agent") : L("None (reply only where a rule matches)")
                ).tag(UUID?.none)
                ForEach(selectableAgents) { agent in
                    Text(agent.name).tag(Optional(agent.id))
                }
            }
            .labelsHidden()
            Text(
                "Replies to every message no rule below claims.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
        }
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
        Picker("", selection: route.agentId) {
            ForEach(selectableAgents) { agent in
                Text(agent.name).tag(agent.id)
            }
            if !selectableAgents.contains(where: { $0.id == route.wrappedValue.agentId }) {
                Text("Missing agent", bundle: .module).tag(route.wrappedValue.agentId)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
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

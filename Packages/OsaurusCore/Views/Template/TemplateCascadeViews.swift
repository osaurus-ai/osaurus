//
//  TemplateCascadeViews.swift
//  osaurus
//
//  The workflows an agent template brings, as the share sheet (before and
//  after publishing) and the agent's dashboard list them: one row each,
//  saying whether it has its own page and whether the agent's page links
//  to it.
//

import SwiftUI

/// One workflow an agent template brings.
struct CascadeWorkflowRow<Trailing: View>: View {
    @Environment(\.theme) private var theme

    let name: String
    let version: Int
    let chip: TemplateCascadeCopy.Chip
    let detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            Image(systemName: "flowchart")
                .glyphSize(13, weight: .medium)
                .foregroundColor(theme.text.secondary)
            VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: name)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    Text(verbatim: "v\(version)")
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                    StatusChip(chip.text, tone: chip.tone)
                }
                Text(verbatim: detail)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
    }
}

/// Rows in one card, divided.
struct CascadeWorkflowList<Item: Identifiable, Row: View>: View {
    @Environment(\.theme) private var theme

    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < items.count - 1 { Divider().opacity(0.4) }
            }
        }
        .settingsChrome(.card)
        .overlay(RoundedRectangle(cornerRadius: theme.radius.large).stroke(theme.border.default, lineWidth: theme.stroke.default))
    }
}

/// What the rows say. The registry links the agent's page to a workflow's
/// page only when visitors of the one may see the other: Public always,
/// Unlisted only from an agent that isn't Public, password-protected and
/// workspace listings never.
enum TemplateCascadeCopy {
    struct Chip: Equatable {
        let text: String
        let tone: StatusChip.Tone
    }

    static func agentLinks(to record: WorkflowRegistryRecord, agentVisibility: WorkflowVisibility) -> Bool {
        switch record.visibility {
        case .public: return true
        case .hidden: return agentVisibility != .public
        case .password, .workspace: return false
        }
    }

    static func chip(_ state: TemplateCascadePlan.State, agentVisibility: WorkflowVisibility) -> Chip {
        switch state {
        case .willPublish: return Chip(text: L("Publishes"), tone: .accent)
        case .alreadyPublished(let record):
            return agentLinks(to: record, agentVisibility: agentVisibility)
                ? Chip(text: L("Live"), tone: .success) : Chip(text: L("Not linked"), tone: .warning)
        case .linkedToAuthor: return Chip(text: L("Their page"), tone: .info)
        case .checksOnPublish: return Chip(text: L("Checked on publish"), tone: .neutral)
        case .bundledOnly: return Chip(text: L("Bundled only"), tone: .neutral)
        }
    }

    static func detail(
        _ row: TemplateCascadePlan.Row, agentVisibility: WorkflowVisibility, visibility: WorkflowVisibility?
    ) -> String {
        switch row.state {
        case .willPublish:
            if row.record != nil {
                return L("Publishes version \(row.template.version) on its page first.")
            }
            return L("Gets its own \((visibility ?? agentVisibility).title) page first, linked from the agent's.")
        case .alreadyPublished(let record):
            return live(record, agentVisibility: agentVisibility)
        case .linkedToAuthor(let address):
            return byAuthor(address)
        case .checksOnPublish(let address):
            return L("Its author is \(SharedAgentIdentity.shortAddress(address)). Publishing checks that against your Osaurus ID: if it's you, it gets its own page first; if not, the agent's page links to theirs.")
        case .bundledOnly(let reason):
            return bundledOnly(reason)
        }
    }

    static func chip(_ status: TemplateCascadeResult.Status, agentVisibility: WorkflowVisibility) -> Chip {
        switch status {
        case .published: return Chip(text: L("Published"), tone: .success)
        case .alreadyPublished(let record):
            return chip(TemplateCascadePlan.State.alreadyPublished(record), agentVisibility: agentVisibility)
        case .linkedToAuthor(let address): return chip(TemplateCascadePlan.State.linkedToAuthor(address: address), agentVisibility: agentVisibility)
        case .bundledOnly(let reason): return chip(TemplateCascadePlan.State.bundledOnly(reason), agentVisibility: agentVisibility)
        case .failed: return Chip(text: L("Didn't publish"), tone: .warning)
        }
    }

    static func detail(_ status: TemplateCascadeResult.Status, agentVisibility: WorkflowVisibility) -> String {
        switch status {
        case .published(let record), .alreadyPublished(let record):
            return live(record, agentVisibility: agentVisibility)
        case .linkedToAuthor(let address): return byAuthor(address)
        case .bundledOnly(let reason): return bundledOnly(reason)
        case .failed(let message): return L("\(message) The agent still carries it.")
        }
    }

    static func live(_ record: WorkflowRegistryRecord, agentVisibility: WorkflowVisibility) -> String {
        let version = record.registryLatestVersion ?? record.version
        if agentLinks(to: record, agentVisibility: agentVisibility) {
            return L("Live at version \(version), \(record.visibility.title). The agent's page links to it.")
        }
        if record.visibility == .password {
            return L("Live at version \(version), password-protected, so the agent's page doesn't link to it.")
        }
        if record.visibility == .workspace {
            return L("Live at version \(version), shared with workspaces, so the agent's page doesn't link to it.")
        }
        return L("Live at version \(version), Unlisted, so the agent's public page doesn't link to it.")
    }

    static func byAuthor(_ address: String) -> String {
        L("By \(SharedAgentIdentity.shortAddress(address)), so it isn't republished. The agent's page links to theirs when they published this exact version.")
    }

    static func bundledOnly(_ reason: TemplateCascadePlan.Reason) -> String {
        switch reason {
        case .passwordProtected:
            return L("Stays inside the agent: a password-protected agent's workflows don't get their own pages.")
        case .workspaceOnly:
            return L("Stays inside the agent: a workspace agent's workflows travel with it to its members.")
        case .builtIn: return L("Built into Osaurus, so it stays inside the agent.")
        case .takenDown: return L("You took its page down, so it stays inside the agent until you publish it again.")
        case .removedByAdmin: return L("The Osaurus team removed its page, so it stays inside the agent.")
        case .turnedOff: return L("Stays inside the agent this time.")
        }
    }
}

//
//  WorkflowCards.swift
//  osaurus
//
//  Cards for the Workflows screen: a workflow on this Mac and a template
//  that is not set up yet. Each reads at a glance (what it asks for, what
//  it gives back, where it runs, who uses it) and shares in one click;
//  a published one says so, with who can see it and how many installed
//  it, and opens its dashboard.
//

import SwiftUI
import AppKit

enum WorkflowShareCopy {
    static func takeDownTitle(_ kind: TemplateKind) -> String {
        kind == .agent ? L("Take Down Template") : L("Take Down Workflow")
    }

    static func unpublishMessage(_ name: String) -> String {
        L("Take \"\(name)\" down? Its page stops working for everyone. People who installed it keep their copy, and publishing it again brings it back at the same link.")
    }

    /// "Live · Public · 14 installs", "Live · Unlisted until approved ·
    /// In review", or the taken-down state.
    /// `includesReview: false` leaves the review state to a chip beside it.
    static func status(_ record: WorkflowRegistryRecord, includesReview: Bool = true) -> String {
        if record.removedByAdmin { return L("Removed") }
        if record.takenDown { return L("Taken down") }
        let review = PublishReviewState(record: record)
        var parts = [L("Live"), review.isUnlistedUntilApproved ? L("Unlisted until approved") : record.visibility.title]
        if includesReview, let chip = review.chipText {
            parts.append(chip)
        } else if let installs = record.installCount {
            parts.append(installs == 1 ? L("1 install") : L("\(installs) installs"))
        }
        return parts.joined(separator: " · ")
    }

    /// The glyph beside `status`.
    static func statusIcon(_ record: WorkflowRegistryRecord) -> String {
        guard record.isLive else { return "eye.slash" }
        let review = PublishReviewState(record: record)
        return review.chipText == nil ? record.visibility.symbol : review.chipIcon
    }

    /// What publishing `version` does: a Public listing goes to review
    /// ("Submit Version 3 for Review", or "Resubmit Version 3" after changes
    /// were requested); Unlisted and Password publish right away.
    static func publishLabel(
        version: Int?, record: WorkflowRegistryRecord?, visibility: WorkflowVisibility? = nil, short: Bool = false
    ) -> String {
        let shown = visibility ?? record?.visibility ?? .public
        guard shown == .public else {
            guard let version else { return L("Publish") }
            return short ? L("Publish v\(version)") : L("Publish Version \(version)")
        }
        guard let version else { return L("Submit for Review") }
        if record?.isLive == true, record?.review?.status == .rejected {
            return short ? L("Resubmit v\(version)") : L("Resubmit Version \(version)")
        }
        return short ? L("Submit v\(version) for Review") : L("Submit Version \(version) for Review")
    }
}

/// The "Live" badge for a workflow or agent template published to the
/// registry; opens its dashboard.
struct LiveBadge: View {
    @Environment(\.theme) private var theme
    let record: WorkflowRegistryRecord
    let action: () -> Void
    var body: some View {
        let review = PublishReviewState(record: record)
        Button(action: action) {
            if record.isLive, review.chipText != nil || review.unseen {
                PublishReviewChip(record: record)
            } else {
                StatusChip(
                    record.isLive ? L("Live") : L("Taken down"),
                    tint: record.isLive ? theme.statusInk(.success) : theme.text.tertiary
                )
            }
        }
        .buttonStyle(.plain)
        .help(help(review))
    }

    private func help(_ review: PublishReviewState) -> String {
        guard record.isLive else { return L("Taken down. Click to publish again.") }
        if review.chipText != nil || review.unseen { return L("\(review.detail()) Click to manage.") }
        return L("Published on \(record.url.host ?? "store.osaurus.ai"). Click to manage.")
    }
}

/// Publish actions in a card's menu.
struct PublishMenuItems: View {
    let record: WorkflowRegistryRecord?
    let version: Int
    let onPublish: () -> Void
    let onManage: () -> Void
    let onTakeDown: () -> Void

    var body: some View {
        if let record, record.isLive {
            Button(action: onManage) { Label(L("Manage Published…"), systemImage: "globe") }
            if (record.registryLatestVersion ?? record.version) < version {
                Button(action: onPublish) {
                    Label(
                        WorkflowShareCopy.publishLabel(version: version, record: record) + "…",
                        systemImage: "arrow.up.circle")
                }
            }
            Button {
                ShareLinkPasteboard.copy(record.url.absoluteString)
                _ = ToastManager.shared.success(L("Copied the link"))
            } label: {
                Label(L("Copy Link"), systemImage: "link")
            }
            Button {
                NSWorkspace.shared.open(record.url)
            } label: {
                Label(L("Open Page"), systemImage: "safari")
            }
            Button(action: onTakeDown) { Label(L("Take Down…"), systemImage: "eye.slash") }
        } else if let record, record.removedByAdmin {
            Button(action: onManage) { Label(L("Removed from Registry…"), systemImage: "exclamationmark.triangle") }
        } else if record != nil {
            Button(action: onManage) { Label(L("Publish Again…"), systemImage: "globe") }
        } else {
            Button(action: onPublish) { Label(L("Publish…"), systemImage: "globe") }
        }
    }
}

/// The card's footer button: Share before publishing; the live status
/// (opening the dashboard) after. Workflow and agent template cards share it.
struct ShareFooterButton: View {
    @Environment(\.theme) private var theme
    let record: WorkflowRegistryRecord?
    let onShare: () -> Void
    let onManage: () -> Void

    var body: some View {
        if let record {
            SettingsButton(
                .secondary, WorkflowShareCopy.status(record), icon: WorkflowShareCopy.statusIcon(record),
                size: .compact, verbatim: true, action: onManage
            )
            .help(help(record))
        } else {
            SettingsButton(.secondary, "Share", icon: "square.and.arrow.up", size: .compact, action: onShare)
                .help(L("Save a file or publish a page"))
        }
    }

    private func help(_ record: WorkflowRegistryRecord) -> String {
        guard record.isLive else { return L("Taken down. Click to publish again.") }
        let review = PublishReviewState(record: record)
        if review.chipText != nil { return L("\(review.detail()) Click to manage.") }
        if let agent = record.publishedWith.flatMap({ TemplateStore.shared.latest(id: $0)?.name }) {
            return L("Published with the \(agent) agent. Click to manage.")
        }
        return L("Published. Click to manage.")
    }
}

/// "Asks for" and "Gives back", one line each.
struct WorkflowDigestLines: View {
    @Environment(\.theme) private var theme
    let definition: WorkflowDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            let inputs = WorkflowSummary.inputs(definition)
            line(L("Asks for"), inputs.isEmpty ? L("Nothing, it runs as is") : WorkflowSummary.list(inputs))
            let outputs = WorkflowSummary.outputs(definition)
            if !outputs.isEmpty { line(L("Gives back"), WorkflowSummary.list(outputs)) }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Text(verbatim: label)
                .font(SettingsFont.chip)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 62, alignment: .leading)
            Text(verbatim: value)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(value)
        }
    }
}

/// The facts under a card, in the order a reader decides by.
@MainActor
enum WorkflowCardFacts {
    static func steps(_ definition: WorkflowDefinition) -> String {
        let count = definition.nodes.count
        return count == 1 ? L("1 step") : L("\(count) steps")
    }

    /// Where the template's model steps may run; nil when it uses no model.
    static func locality(_ template: Template) -> String? {
        let models = template.requirements.models
        guard !models.isEmpty else { return nil }
        let catalog = SetupChecker.Environment.live().modelCatalog
        return models.contains { SetupChecker.mayUseCloud($0, catalog: catalog) } ? L("May use the cloud") : L("Runs on this Mac")
    }

    static func agents(_ count: Int) -> String {
        switch count {
        case 0: return L("Not on an agent yet")
        case 1: return L("On 1 agent")
        default: return L("On \(count) agents")
        }
    }

    static func installed(_ workflow: InstalledWorkflow, agentCount: Int) -> [String] {
        let bound = workflow.template.requirements.models.compactMap { workflow.bindings.models[$0.slot] }
        let runsOn =
            bound.isEmpty
            ? locality(workflow.template)
            : L("Runs on \(WorkflowSummary.list(Array(Set(bound)).sorted().map(WorkflowModelChoices.displayName)))")
        return [steps(workflow.definition), runsOn, agents(agentCount)].compactMap { $0 }
    }

    static func template(_ template: Template) -> [String] {
        if template.kind == .agent { return agentTemplate(template) }
        let secrets = template.requirements.secrets.count
        return [
            steps(template.workflow ?? WorkflowDefinition()),
            locality(template),
            secrets == 0 ? nil : (secrets == 1 ? L("1 secret to enter") : L("\(secrets) secrets to enter")),
        ].compactMap { $0 }
    }

    /// The model it runs on, the workflows it brings, its quick actions.
    static func agentTemplate(_ template: Template) -> [String] {
        let model = template.agent.model.valueOrNil.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let workflows = template.bundled.count
        let actions = template.actions?.count ?? 0
        return [
            model.map { L("Runs on \($0)") } ?? L("Uses your default model"),
            workflows == 0 ? nil : (workflows == 1 ? L("Brings 1 workflow") : L("Brings \(workflows) workflows")),
            actions == 0 ? nil : (actions == 1 ? L("1 quick action") : L("\(actions) quick actions")),
        ].compactMap { $0 }
    }
}

/// What a template needs, as chips: where its models may run, code
/// steps, secrets, and MCP servers.
struct WorkflowRequirementChips: View {
    struct Item: Equatable {
        let icon: String
        let text: String
        let help: String
    }

    @Environment(\.theme) private var theme
    let template: Template

    static func items(for template: Template) -> [Item] {
        let reqs = template.requirements
        var items: [Item] = []
        if !reqs.models.isEmpty {
            items.append(
                reqs.models.allSatisfy { $0.locality == .localOnly }
                    ? Item(icon: "lock.laptopcomputer", text: L("Local only"), help: L("Every model step runs on this Mac."))
                    : Item(icon: "cloud", text: L("Cloud"), help: L("Some model steps may use a cloud provider.")))
        }
        let code = template.workflow?.codeNodes.count ?? 0
        if code > 0 {
            items.append(Item(icon: "chevron.left.forwardslash.chevron.right", text: L("\(code) code"), help: L("Code steps")))
        }
        if !reqs.secrets.isEmpty {
            let text = reqs.secrets.count == 1 ? L("1 secret") : L("\(reqs.secrets.count) secrets")
            items.append(Item(icon: "key", text: text, help: L("Secrets to enter at setup")))
        }
        if !reqs.mcpServers.isEmpty {
            items.append(
                Item(icon: "server.rack", text: reqs.mcpServers.joined(separator: ", "), help: L("MCP servers")))
        }
        let tools = template.workflow?.calledTools.count ?? 0
        if tools > 0 {
            items.append(
                Item(
                    icon: "wrench.and.screwdriver", text: tools == 1 ? L("1 tool") : L("\(tools) tools"),
                    help: L("Tools its steps call")))
        }
        return items
    }

    var body: some View {
        FlowLayout(spacing: theme.space.s6) {
            ForEach(Self.items(for: template), id: \.text) { item in
                StatusChip(item.text, tone: .neutral, icon: item.icon)
                    .help(item.help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Installed

struct InstalledWorkflowCard: View {
    @Environment(\.theme) private var theme

    let workflow: InstalledWorkflow
    let update: Template?
    let published: WorkflowRegistryRecord?
    let agentCount: Int
    let hasHistory: Bool
    let animationDelay: Double
    let hasAppeared: Bool
    var openHelp: String = "Show details"
    /// Draws the card as a Workflows row made of these parts,
    /// keeping its menu and confirmations.
    var row: WorkflowRowParts? = nil
    /// Reuse the card's actions and confirmation state as a lone ⋯ button
    /// (the workflow page header).
    var isDetailActionMenu = false
    var menuButtonSize: SettingsButtonSize = .standard
    var onDetails: (() -> Void)? = nil
    let onOpen: () -> Void
    let onRun: () -> Void
    let onSaveAsFile: () -> Void
    let onShare: () -> Void
    let onPublish: () -> Void
    let onManage: () -> Void
    let onTakeDown: () -> Void
    let onSetUp: () -> Void
    let onUpdate: () -> Void
    let onEdit: () -> Void
    let onVersionHistory: () -> Void
    let onToggleOrchestrator: () -> Void
    let onRename: () -> Void
    let onUninstall: () -> Void

    @State private var confirmUninstall = false
    @State private var confirmTakeDown = false

    private var detailedCard: some View {
        LibraryCard(
            title: workflow.name,
            minHeight: 168,
            help: openHelp == "Show details" ? L("Show details") : L("Open workflow"),
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onOpen
        ) {
            LibraryIcon(symbol: "flowchart", tint: theme.statusInk(.info))
        } badges: {
            StatusChip("v\(workflow.templateVersion)", tint: theme.text.tertiary)
            if workflow.needsSetup {
                StatusChip(L("Needs setup"), tone: .warning)
            } else if !WorkflowCredentials.missingKeys(workflow).isEmpty {
                StatusChip(
                    L("Keys missing"), tone: .warning, icon: "key.fill",
                    help: L("Add its keys in Settings → Vault. Runs without an agent stop until then."))
            }
            if let update { StatusChip(L("Update to v\(update.version)"), tone: .accent) }
            if let pinned = workflow.nameMismatch {
                StatusChip(L("Name differs"), tone: .accent)
                    .help(
                        L("Version \(workflow.templateVersion) is named “\(pinned)”; agents still call this “\(workflow.name)”. Open it to choose."))
            }
            if let published { LiveBadge(record: published, action: onManage) }
            if workflow.orchestratorVisible {
                Image(systemName: "sparkles")
                    .font(SettingsFont.glyphSmall)
                    .foregroundColor(theme.text.link)
                    .help(L("Osaurus can run this for you"))
            }
        } content: {
            LibraryCardPreview(text: workflow.summary ?? "")
            if !workflow.tags.isEmpty {
                FlowLayout(spacing: theme.space.s4) {
                    ForEach(workflow.tags.prefix(5), id: \.self) { tag in
                        StatusChip(tag, tone: .neutral)
                    }
                    if workflow.tags.count > 5 {
                        StatusChip("+\(workflow.tags.count - 5)", tint: theme.text.tertiary)
                    }
                }
            }
            WorkflowDigestLines(definition: workflow.definition)
        } footer: {
            LibraryCardFooter(facts: WorkflowCardFacts.installed(workflow, agentCount: agentCount)) {
                ShareFooterButton(record: published, onShare: onShare, onManage: onManage)
                if workflow.needsSetup {
                    SettingsButton(.primary, "Set Up…", size: .compact, action: onSetUp)
                } else {
                    SettingsButton(.primary, "Run…", icon: "play.fill", size: .compact, action: onRun)
                }
            }
        } menu: {
            menuItems
        }
    }

    var body: some View {
        Group {
            if isDetailActionMenu {
                SettingsActionMenu(accessibilityLabel: L("Workflow actions")) {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(SettingsIconButtonStyle(size: menuButtonSize, role: .tertiary))
                .fixedSize()
                .help(L("Workflow actions"))
            } else if let row {
                WorkflowHomepageRow(
                    title: workflow.name, summary: row.summary ?? workflow.summary ?? "",
                    isExpandable: row.isExpandable, isExpanded: row.isExpanded, isSelected: row.isSelected,
                    onOpen: onOpen,
                    leading: { row.leading }, meta: { row.meta }, accessory: { row.accessory },
                    actions: { menuItems }, expanded: { row.expanded }
                )
                .keyboard(row.keyboard)
            } else { detailedCard }
        }
        .themedAlert(
            L("Uninstall Workflow"),
            isPresented: $confirmUninstall,
            message: L("Uninstall \"\(workflow.name)\"? Its saved answers and run history on this Mac are deleted. The template stays in your library."),
            primaryButton: .destructive(L("Uninstall"), action: onUninstall),
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Take Down Workflow"),
            isPresented: $confirmTakeDown,
            message: WorkflowShareCopy.unpublishMessage(workflow.name),
            primaryButton: .destructive(L("Take Down"), action: onTakeDown),
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    /// Most used first: run and edit, then setup and naming, then sharing.
    @ViewBuilder
    private var menuItems: some View {
        Group {
            Button(action: onRun) { Label(L("Run…"), systemImage: "play") }
            Button(action: onEdit) { Label(L("Edit with the Architect"), systemImage: "pencil.and.outline") }
            if update != nil {
                Button(action: onUpdate) { Label(L("Update…"), systemImage: "arrow.up.circle") }
            }
            if let onDetails {
                Button(action: onDetails) { Label(L("Details & History"), systemImage: "info.circle") }
            }
            Divider()
            Button(action: onSetUp) { Label(L("Set Up…"), systemImage: "checklist") }
            Button(action: onRename) { Label(L("Rename…"), systemImage: "pencil") }
            if hasHistory {
                Button(action: onVersionHistory) { Label(L("Version History"), systemImage: "clock.arrow.circlepath") }
            }
            Button(action: onToggleOrchestrator) {
                Label(
                    workflow.orchestratorVisible ? L("Don't Let Osaurus Run This") : L("Let Osaurus Run This"),
                    systemImage: workflow.orchestratorVisible ? "eye.slash" : "eye")
            }
            Divider()
            Button(action: onSaveAsFile) { Label(L("Save as File…"), systemImage: "doc.badge.arrow.up") }
            PublishMenuItems(
                record: published, version: workflow.templateVersion, onPublish: onPublish, onManage: onManage,
                onTakeDown: { confirmTakeDown = true })
            Divider()
            Button(role: .destructive) { confirmUninstall = true } label: {
                Label(L("Uninstall"), systemImage: "trash")
            }
        }
    }
}

// MARK: - Not Set Up

struct WorkflowTemplateCard: View {
    @Environment(\.theme) private var theme

    let template: Template
    let isBuiltIn: Bool
    let published: WorkflowRegistryRecord?
    let animationDelay: Double
    let hasAppeared: Bool
    let onOpen: () -> Void
    let onAdd: () -> Void
    let onEdit: () -> Void
    let onSaveAsFile: () -> Void
    let onShare: () -> Void
    let onPublish: () -> Void
    let onManage: () -> Void
    let onTakeDown: () -> Void
    let onVersionHistory: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var isHomepageCard = false
    var homepageIcon = "flowchart"
    var isSelected = false

    @State private var confirmDelete = false
    @State private var confirmTakeDown = false

    private var detailedCard: some View {
        LibraryCard(
            title: template.name,
            minHeight: 168,
            help: L("Preview"),
            animationDelay: animationDelay,
            hasAppeared: hasAppeared,
            action: onOpen
        ) {
            LibraryIcon(symbol: "flowchart", tint: theme.statusInk(.info))
        } badges: {
            StatusChip("v\(template.version)", tint: theme.text.tertiary)
            if isBuiltIn { StatusChip(L("Built-in"), tint: theme.statusInk(.info)) }
            if let published { LiveBadge(record: published, action: onManage) }
            // The seal reflects a verified signature, never the
            // author block alone (anyone can write one).
            switch TemplateSigner.status(of: template) {
            case .signed(let address, let known):
                HStack(spacing: theme.space.s2) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(SettingsFont.glyphSmall)
                        .foregroundColor(known == nil ? theme.statusInk(.info) : theme.statusInk(.success))
                    Text(SharedAgentIdentity.shortAddress(address))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                }
                .help(L("Signed by \(address)"))
            case .invalid:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(SettingsFont.glyphSmall)
                    .foregroundColor(theme.statusInk(.warning))
                    .help(L("Signature does not match"))
            case .unsigned:
                EmptyView()
            }
        } content: {
            LibraryCardPreview(text: template.summary ?? "")
            if let def = template.workflow { WorkflowDigestLines(definition: def) }
        } footer: {
            LibraryCardFooter(facts: WorkflowCardFacts.template(template)) {
                ShareFooterButton(record: published, onShare: onShare, onManage: onManage)
                SettingsButton(.primary, "Add", icon: "plus", size: .compact, help: "Set it up on this Mac", action: onAdd)
            }
        } menu: {
            menuItems
        }
    }

    var body: some View {
        Group {
            if isHomepageCard {
                WorkflowStarterCard(title: template.name, icon: homepageIcon, detail: WorkflowStarterCard.detail(for: template),
                    isSelected: isSelected, minimumHeight: theme.space.s64 + theme.space.s48, action: onOpen)
                    .assignedContextMenu { menuItems }
            } else { detailedCard }
        }
        .themedAlert(
            L("Delete Template"),
            isPresented: $confirmDelete,
            message: L("Delete every version of \"\(template.name)\" from this Mac?"),
            primaryButton: .destructive(L("Delete"), action: onDelete),
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlert(
            L("Take Down Workflow"),
            isPresented: $confirmTakeDown,
            message: WorkflowShareCopy.unpublishMessage(template.name),
            primaryButton: .destructive(L("Take Down"), action: onTakeDown),
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    @ViewBuilder
    private var menuItems: some View {
        Group {
            Button(action: onAdd) { Label(L("Add…"), systemImage: "plus.circle") }
            Button(action: onEdit) { Label(L("Edit with the Architect"), systemImage: "pencil.and.outline") }
            Divider()
            if !isBuiltIn {
                Button(action: onRename) { Label(L("Rename…"), systemImage: "pencil") }
            }
            Button(action: onVersionHistory) { Label(L("Version History"), systemImage: "clock.arrow.circlepath") }
            Divider()
            Button(action: onSaveAsFile) { Label(L("Save as File…"), systemImage: "doc.badge.arrow.up") }
            PublishMenuItems(
                record: published, version: template.version, onPublish: onPublish, onManage: onManage,
                onTakeDown: { confirmTakeDown = true })
            if !isBuiltIn {
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
            }
        }
    }
}

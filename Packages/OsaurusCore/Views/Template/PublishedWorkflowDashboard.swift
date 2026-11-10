//
//  PublishedWorkflowDashboard.swift
//  osaurus
//
//  One published workflow or agent template, as its owner sees it: the page (its card,
//  status, link, and the ways to pass it on), the numbers the registry
//  keeps (installs, versions, since when), each published version beside
//  the version on this Mac with a Publish button when the library is
//  ahead, who can see it (with the password when that's the answer), for
//  an agent the workflows it brings and their own pages, and, last and
//  quiet, taking it down. A workflow whose page came with an agent says so.
//
//  The numbers the library cached show at once; opening the dashboard
//  reads the registry with the owner's signature (so a password-protected
//  or taken-down workflow answers too) and, while it has the key, lists
//  everything this Osaurus ID has published and brings the local records
//  in line. Hosted by `ShareWorkflowSheet`, which owns the footer.
//

import SwiftUI

struct PublishedWorkflowDashboard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var registryRecords = WorkflowRegistryRecordStore.shared
    @ObservedObject private var templates = TemplateStore.shared
    @ObservedObject private var osaurusID = OsaurusIDService.shared

    let template: Template
    /// Publish the library's latest version (or publish again after a
    /// take-down); the sheet runs the publish flow.
    let onPublish: (Template) -> Void
    let onSaveAsFile: () -> Void
    /// The sheet owns the confirmation so it overlays the whole sheet.
    @Binding var confirmTakeDown: Bool
    var isTakingDown = false
    /// Take down one of an agent's workflows; the sheet confirms it.
    var onTakeDownWorkflow: (Template) -> Void = { _ in }
    var takingDownWorkflowID: UUID?
    /// Revise with Architect after changes were requested; nil hides it.
    var onRevise: (() -> Void)?

    @State private var detail: WorkflowsRegistryDetail?
    @State private var isLoading = false
    @State private var loadFailed = false
    /// The owner read needs the Osaurus ID; without one (or when its
    /// authentication was declined) the numbers are the last fetched.
    @State private var needsIdentity = false
    @State private var banned = false
    @State private var selectedVisibility: WorkflowVisibility?
    @State private var password = ""
    @State private var workspaceIDs: Set<String> = []
    /// The registry has said which workspaces a Workspace listing is
    /// shared with; until then Save could write a stale list over it.
    @State private var sharedWorkspacesLoaded = false
    @State private var isSavingVisibility = false
    @State private var visibilitySaved = false
    @State private var visibilityError: String?
    /// An agent's workflow pages follow its new visibility.
    @State private var workflowsFollow = true
    @State private var shareCard: NSImage?
    @State private var linkCopied = false

    /// The listing as the registry last showed it, and the edits on top.
    @State private var shownListing = ShownListing()
    @State private var listingName = ""
    @State private var listingSummary = ""
    @State private var topics: [ListingTopic] = []
    @State private var examples: [ListingExampleDraft] = []
    /// Examples are a whole set, so they change only once the registry's
    /// current ones are known.
    @State private var examplesLoaded = false
    @State private var isSavingListing = false
    @State private var listingSaved = false
    @State private var listingResult: ListingEditsResult?
    @State private var confirmExamples = false
    /// Opened on an unopened approval: the Review panel shows it this once.
    @State private var openedOnApproval = false

    private struct ShownListing: Equatable {
        var name = ""
        var summary = ""
        var edited = false
        var topics: [ListingTopic] = []
        var examples: [ListingExampleDraft] = []
    }

    private var record: WorkflowRegistryRecord? { registryRecords.record(for: template.id) }
    private var isAgent: Bool { template.kind == .agent }

    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 22) {
                    page(record)
                    if showsReview(record) {
                        PublishReviewPanel(
                            record: record, localAhead: localAhead(record), banned: banned, onRevise: onRevise,
                            onResubmit: onPublish)
                    }
                    stats(record)
                    versions(record)
                    // Visibility only applies to a live page; Publish Again asks for it.
                    if record.isLive { whoCanSeeIt(record) }
                    if !record.removedByAdmin { listing(record) }
                    if isAgent { bundledWorkflows(record) }
                    bottomActions(record)
                }
                .padding(theme.space.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    Spacer().frame(height: 60)
                    Text("This template isn't published.", bundle: .module)
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            selectedVisibility = record?.visibility
            workspaceIDs = Set(record?.workspaceIDs ?? [])
            if let record { showListing(fromRecord: record) }
            openedOnApproval = record.map { $0.hasUnseenDecision && $0.review?.status == .approved } ?? false
            registryRecords.markReviewSeen(templateID: template.id)
            refresh()
            renderShareCard()
        }
        .onChange(of: record?.review) { _, review in
            // A decision that lands while the dashboard is open is seen here.
            if review?.status == .approved { openedOnApproval = true }
            registryRecords.markReviewSeen(templateID: template.id)
        }
        // `.contained`: the central alert host sits behind this sheet's window.
        .themedAlert(
            ListingCopy.consentTitle(examples.filter(\.isNew).count),
            isPresented: $confirmExamples,
            message: ListingCopy.consentMessage(
                images: examples.filter(\.isNew).reduce(0) { $0 + $1.includedImages.filter { $0.uploaded == nil }.count },
                visibility: record?.visibility ?? .public),
            primaryButton: .primary(L("Share"), action: saveListing),
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
    }

    // MARK: - Review

    private func showsReview(_ record: WorkflowRegistryRecord) -> Bool {
        let state = PublishReviewState(record: record)
        return state.isUnderReview || (state.phase == .listed && openedOnApproval)
    }

    /// The library's latest version when it's ahead of the registry's.
    private func localAhead(_ record: WorkflowRegistryRecord) -> Template? {
        let publishedLatest = detail?.latestVersion ?? record.registryLatestVersion ?? record.version
        guard let local = templates.latest(id: template.id), local.version > publishedLatest else { return nil }
        return local
    }

    /// The review chip a version row carries: Listed, In review, Changes
    /// requested, or Not reviewed for an upload a newer one replaced.
    private func reviewChip(version: Int, record: WorkflowRegistryRecord) -> StatusChip? {
        guard record.isLive, record.visibility == .public, let review = record.review else { return nil }
        let state = PublishReviewState(record: record)
        if version == review.version {
            switch review.status {
            case .pending: return StatusChip(L("In review"), tone: .info, icon: "clock")
            case .rejected: return StatusChip(L("Changes requested"), tone: .warning, icon: "exclamationmark.bubble")
            case .approved: return StatusChip(L("In the store"), tone: .success, icon: "checkmark")
            case .superseded, .withdrawn: break
            }
        }
        if version == state.listedVersion { return StatusChip(L("In the store"), tone: .success, icon: "checkmark") }
        if let listed = state.listedVersion, version > listed { return StatusChip(L("Not reviewed"), tone: .neutral) }
        return nil
    }

    // MARK: - Page

    /// `@handle` wherever one is known: the registry's, else the claimed
    /// Osaurus ID; the short address only as a last resort.
    private func handle(_ record: WorkflowRegistryRecord) -> String {
        let fromRegistry = detail?.author.handle ?? record.authorHandle
        if let fromRegistry, fromRegistry.hasPrefix("@") { return fromRegistry }
        if let claimed = osaurusID.claimedHandle { return "@" + claimed }
        return fromRegistry ?? SharedAgentIdentity.shortAddress(record.address)
    }

    /// The page as it stands: its card, status, link, and the ways to pass
    /// it on. Taken down or removed, the card and link give way to why.
    private func page(_ record: WorkflowRegistryRecord) -> some View {
        HStack(alignment: .top, spacing: 16) {
            if record.isLive { thumbnail }
            VStack(alignment: .leading, spacing: 10) {
                status(record)
                if let agent = publishedWith(record) {
                    Text(verbatim: L("Its page came with publishing the \(agent) agent. Taking that agent down leaves this page up."))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if record.removedByAdmin {
                    removedNotice(record)
                } else if record.takenDown {
                    takenDownNotice
                } else {
                    linkField(record)
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.open(record.url)
                        } label: {
                            Label { Text("Open Page", bundle: .module) } icon: { Image(systemName: "safari") }
                        }
                        .assignedSettingsButtonStyle(.secondary, size: .compact)
                        ShareCardActions(
                            image: shareCard, pageURL: record.url, suggestedName: "\(record.slug)-card.png",
                            includesSave: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thumbnail: some View {
        Group {
            if let shareCard {
                Image(nsImage: shareCard)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
                    .aspectRatio(WorkflowShareCardView.size.width / WorkflowShareCardView.size.height, contentMode: .fit)
                    .settingsChrome(.subtle, radius: theme.radius.medium)
            }
        }
        .frame(width: 168)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
    }

    private func status(_ record: WorkflowRegistryRecord) -> some View {
        let version = detail?.latestVersion ?? record.registryLatestVersion ?? record.version
        let (title, rest, color): (String, String?, Color) = {
            if record.removedByAdmin { return (L("Removed by the Osaurus team"), nil, theme.status.error.foreground) }
            if record.takenDown { return (L("Taken down"), L("by \(handle(record))"), theme.text.tertiary) }
            let shown =
                PublishReviewState(record: record).isUnlistedUntilApproved
                ? L("Unlisted until approved") : record.visibility.title
            return (
                L("Live"), L("\(shown) · v\(version) · by \(handle(record))"),
                theme.status.success.foreground
            )
        }()
        return HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(verbatim: title)
                .font(SettingsFont.sectionTitle)
                .foregroundColor(color)
            if let rest {
                Text(verbatim: rest)
                    .font(SettingsFont.body)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isLoading { ProgressView().controlSize(.mini) }
        }
        .frame(height: 20)
    }

    /// The page address in one line, with its copy button inside.
    private func linkField(_ record: WorkflowRegistryRecord) -> some View {
        let full = record.url.absoluteString
        let shown = full.replacingOccurrences(of: "https://", with: "")
        return HStack(spacing: 8) {
            Image(systemName: "link")
                .glyphSize(11, weight: .medium)
                .foregroundColor(theme.text.tertiary)
            Text(verbatim: shown)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                ShareLinkPasteboard.copy(full)
                withAnimation(theme.motion.quick) { linkCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(theme.motion.quick) { linkCopied = false }
                }
            } label: {
                Image(systemName: linkCopied ? "checkmark" : "doc.on.doc")
                    .glyphSize(11, weight: .medium)
                    .foregroundColor(linkCopied ? theme.status.success.foreground : theme.text.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(linkCopied ? L("Copied") : L("Copy Link"))
        }
        .padding(.leading, theme.space.s8)
        .padding(.trailing, theme.space.s6)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.control)
    }

    private var takenDownNotice: some View {
        Text(
            "The page is off. People who installed it keep their copy. Publishing again brings the same link back.",
            bundle: .module
        )
        .font(SettingsFont.caption)
        .foregroundColor(theme.text.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func removedNotice(_ record: WorkflowRegistryRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The Osaurus team took this down. It can't be published again.", bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = detail?.removal?.reason, !reason.isEmpty {
                Text(verbatim: reason)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Stats

    private func stats(_ record: WorkflowRegistryRecord) -> some View {
        let installs = detail?.installCount ?? record.installCount
        let versionCount = detail.map { max($0.versions.count, 1) } ?? (record.registryLatestVersion ?? record.version)
        let since = detail?.createdAt ?? record.publishedAt ?? record.sharedAt
        let updated = detail?.updatedAt ?? record.updatedAt ?? record.sharedAt
        let changed = updated.timeIntervalSince(since) > 60
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                figure(L("Installs"), installs.map(String.init) ?? "—")
                    .settingsLandingAnchor(isAgent ? "agents.templates.publishedStats" : "workflows.publishedStats")
                figureDivider
                figure(versionCount == 1 ? L("Version") : L("Versions"), String(versionCount))
                figureDivider
                figure(L("Published"), Self.relative(since), caption: changed ? L("Updated \(Self.relative(updated))") : nil)
            }
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s12)
            .settingsChrome(.card)
            .overlay(RoundedRectangle(cornerRadius: theme.radius.large).stroke(theme.border.default, lineWidth: theme.stroke.default))
            if needsIdentity {
                Text("Refreshing these numbers needs your Osaurus ID; showing the last ones.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            } else if loadFailed {
                Text("Couldn't reach the registry; showing the last numbers.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            } else if banned {
                Text("This Osaurus ID can't publish right now.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
            }
        }
    }

    private var figureDivider: some View {
        Rectangle()
            .fill(theme.border.default)
            .frame(width: 1, height: 36)
            .padding(.horizontal, theme.space.s12)
    }

    private func figure(_ label: String, _ value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.tertiary)
            Text(verbatim: value)
                .font(SettingsFont.pageTitle)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(verbatim: caption)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return L("Just now") }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Versions

    private func versions(_ record: WorkflowRegistryRecord) -> some View {
        let publishedLatest = detail?.latestVersion ?? record.registryLatestVersion ?? record.version
        let local = templates.latest(id: template.id)
        let localAhead = local.map { $0.version > publishedLatest } ?? false
        let rows: [WorkflowsRegistryVersion] = detail?.versions ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SettingsFieldLabel("Versions")
                Spacer()
                if !localAhead && !record.removedByAdmin {
                    Text("Your library and the page match.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            VStack(spacing: 0) {
                if localAhead, let local, !record.removedByAdmin {
                    versionRow(
                        version: local.version, title: L("On this Mac, not published"), changelog: local.changelog,
                        isLive: false, dashed: true
                    ) {
                        Button {
                            onPublish(local)
                        } label: {
                            Text(verbatim: WorkflowShareCopy.publishLabel(version: local.version, record: record, short: true))
                        }
                        .assignedSettingsButtonStyle(.primary, size: .compact)
                        .disabled(banned)
                    }
                    if !rows.isEmpty { Divider().opacity(0.4) }
                }
                if rows.isEmpty {
                    versionRow(
                        version: publishedLatest, title: record.isLive ? L("Live") : L("Last published"),
                        changelog: nil, isLive: record.isLive, dashed: false, date: record.updatedAt ?? record.sharedAt
                    ) { reviewChip(version: publishedLatest, record: record) }
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.version) { index, row in
                        versionRow(
                            version: row.version,
                            title: row.version == publishedLatest ? (record.isLive ? L("Live") : L("Last published")) : L("Published"),
                            changelog: row.changelog, isLive: record.isLive && row.version == publishedLatest,
                            dashed: false, date: row.createdAt
                        ) { reviewChip(version: row.version, record: record) }
                        if index < rows.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
            .settingsChrome(.card)
            .overlay(RoundedRectangle(cornerRadius: theme.radius.large).stroke(theme.border.default, lineWidth: theme.stroke.default))
        }
    }

    private func versionRow<Trailing: View>(
        version: Int, title: String, changelog: String?, isLive: Bool, dashed: Bool, date: Date? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: "v\(version)")
                .font(SettingsFont.monoSmall)
                .foregroundColor(isLive ? theme.status.success.foreground : theme.text.secondary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: title)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    if let date {
                        Text(verbatim: "· \(Self.relative(date))")
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
                if let changelog, !changelog.isEmpty {
                    Text(verbatim: changelog)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .overlay {
            if dashed {
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .strokeBorder(theme.border.strong, style: StrokeStyle(lineWidth: theme.stroke.default, dash: [5, 4]))
                    .padding(theme.space.s4)
            }
        }
    }

    // MARK: - Who can see it

    private var visibilityDirty: Bool {
        guard let record, let selectedVisibility else { return false }
        if selectedVisibility != record.visibility { return true }
        if selectedVisibility == .workspace { return workspaceIDs != Set(record.workspaceIDs) }
        return selectedVisibility == .password && !password.isEmpty
    }

    private var canSaveVisibility: Bool {
        guard visibilityDirty, let selectedVisibility else { return false }
        switch selectedVisibility {
        case .password: return WorkflowVisibility.isValidPassword(password)
        case .workspace:
            return WorkflowVisibility.isValidWorkspaceSelection(Array(workspaceIDs))
                && (record?.visibility != .workspace || sharedWorkspacesLoaded)
        case .public, .hidden: return true
        }
    }

    private func whoCanSeeIt(_ record: WorkflowRegistryRecord) -> some View {
        let shown = selectedVisibility ?? record.visibility
        return VStack(alignment: .leading, spacing: 10) {
            SettingsFieldLabel("Who can see it")
            visibilitySegments(selected: shown)
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: shown.detail)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if visibilityDirty {
                    Button {
                        saveVisibility()
                    } label: {
                        Text("Save", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.primary, isLoading: isSavingVisibility, size: .compact)
                    .disabled(!canSaveVisibility || isSavingVisibility)
                    .transition(.opacity)
                } else if visibilitySaved {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").glyphSize(10, weight: .bold)
                        Text("Saved", bundle: .module).font(SettingsFont.smallLabel)
                    }
                    .foregroundColor(theme.status.success.foreground)
                    .transition(.opacity)
                }
            }
            .frame(minHeight: 28)
            if shown == .password {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsTextField(
                        placeholder: record.visibility == .password ? L("New password (optional)") : L("Password"),
                        text: $password, icon: "lock", isSecure: true, revealable: true)
                    Text(
                        record.visibility == .password
                            ? L("Leave it empty to keep the current password. Changing it signs everyone out.")
                            : L("\(WorkflowVisibility.passwordLength.lowerBound) to \(WorkflowVisibility.passwordLength.upperBound) characters.")
                    )
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                }
                .transition(.opacity)
            }
            if shown == .workspace {
                WorkspaceShareChooser(selection: $workspaceIDs)
                    .transition(.opacity)
                    .settingsLandingAnchor(isAgent ? "agents.templates.workspaces" : "workflows.shareWorkspaces")
                if record.visibility == .workspace, !sharedWorkspacesLoaded {
                    Text(
                        loadFailed
                            ? L("Couldn't load the workspaces it's shared with, so Save waits. Try again in a moment.")
                            : L("Loading the workspaces it's shared with…")
                    )
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                }
            }
            if visibilityDirty, !followers(to: shown).isEmpty {
                workflowsFollowOption(followers(to: shown), visibility: shown)
                    .transition(.opacity)
            }
            if let visibilityError {
                Text(verbatim: visibilityError)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsLandingAnchor(isAgent ? "agents.templates.visibility" : "workflows.visibility")
    }

    /// Public | Unlisted | Password | Workspace as one control; the detail line below
    /// says what the chosen one means.
    private func visibilitySegments(selected: WorkflowVisibility) -> some View {
        HStack(spacing: 3) {
            ForEach(WorkflowVisibility.allCases, id: \.self) { option in
                let isSelected = option == selected
                Button {
                    withAnimation(theme.motion.quick) {
                        selectedVisibility = option
                        visibilitySaved = false
                        visibilityError = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol).glyphSize(11, weight: .semibold)
                        Text(verbatim: option.title).font(SettingsFont.compactLabel)
                    }
                    .foregroundColor(isSelected ? theme.text.link : theme.text.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .fill(isSelected ? theme.surface.selected : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityLabel(Text(verbatim: option.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(theme.space.s4)
        .settingsChrome(.inset)
        .overlay(RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default))
    }

    /// The agent's workflow pages that would change with it.
    private func followers(to visibility: WorkflowVisibility) -> [WorkflowRegistryRecord] {
        guard isAgent else { return [] }
        return TemplateCascadePlan.visibilityFollowers(
            registryRecords.records(publishedWith: template.id), agentVisibility: visibility)
    }

    private func workflowName(_ record: WorkflowRegistryRecord) -> String {
        templates.latest(id: record.templateID)?.name ?? record.slug
    }

    private func workflowsFollowOption(_ followers: [WorkflowRegistryRecord], visibility: WorkflowVisibility)
        -> some View
    {
        let names = ListFormatter.localizedString(byJoining: followers.map(workflowName))
        return Toggle(isOn: $workflowsFollow) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also change its workflows", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: L("\(names) published with it become \(visibility.title) too, so its page keeps linking to them."))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsSwitch(showsLabel: true)
        .settingsLandingAnchor("agents.templates.visibilityWorkflows")
    }

    // MARK: - Listing

    private var templateDetails: (name: String, summary: String) {
        (template.name, (template.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var listingEdits: ListingEdits {
        ListingEdits(
            details: ListingEdits.details(
                name: listingName, summary: listingSummary, template: templateDetails,
                shown: (shownListing.name, shownListing.summary), edited: shownListing.edited),
            topics: topics == shownListing.topics ? nil : topics,
            examples: examplesLoaded && examples != shownListing.examples ? examples : nil)
    }

    private var listingDirty: Bool { !listingEdits.isEmpty }

    /// What the page shows, from the registry's detail (or, until it
    /// answers, what this Mac last recorded). Edits in progress stay.
    private func showListing(fromRecord record: WorkflowRegistryRecord) {
        let own = templateDetails
        shownListing.name = record.listingName ?? own.name
        shownListing.summary = record.listingSummary ?? own.summary
        shownListing.edited = record.listingName != nil
        shownListing.topics = record.topics
        listingName = shownListing.name
        listingSummary = shownListing.summary
        topics = shownListing.topics
    }

    private func showListing(fromDetail detail: WorkflowsRegistryDetail, keepingEdits: Bool) {
        let edits = keepingEdits ? listingEdits : ListingEdits()
        shownListing = ShownListing(
            name: detail.name, summary: detail.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            edited: detail.listingEdited, topics: ListingTopic.normalized(detail.tags),
            examples: detail.examples.map(ListingExampleBuilder.draft(from:)))
        if edits.details == nil {
            listingName = shownListing.name
            listingSummary = shownListing.summary
        }
        if edits.topics == nil { topics = shownListing.topics }
        if edits.examples == nil { examples = shownListing.examples }
        examplesLoaded = true
    }

    private func listing(_ record: WorkflowRegistryRecord) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsFieldLabel("Listing Details")
                ListingDetailsFields(
                    name: $listingName, summary: $listingSummary, kind: template.kind,
                    templateName: templateDetails.name, templateSummary: templateDetails.summary)
            }
            .settingsLandingAnchor(isAgent ? "agents.templates.listingDetails" : "workflows.listingDetails")
            VStack(alignment: .leading, spacing: 10) {
                SettingsFieldLabel("Topics")
                ListingTopicPicker(selection: $topics)
            }
            .settingsLandingAnchor(isAgent ? "agents.templates.topics" : "workflows.topics")
            VStack(alignment: .leading, spacing: 10) {
                SettingsFieldLabel("Example Runs")
                if examplesLoaded {
                    ListingExamplesEditor(
                        template: templates.latest(id: template.id) ?? template, examples: $examples,
                        latestVersion: detail?.latestVersion ?? record.registryLatestVersion ?? record.version)
                } else {
                    Text(
                        verbatim: needsIdentity
                            ? L("Changing example runs needs your Osaurus ID to read the ones on its page.")
                            : loadFailed
                                ? L("Couldn't read the example runs on its page. Close and open this again to retry.")
                                : L("Reading the example runs on its page…"))
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsLandingAnchor(isAgent ? "agents.templates.exampleRuns" : "workflows.exampleRuns")
            listingSaveRow
        }
    }

    private var listingSaveRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if listingDirty || listingSaved {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if listingSaved && !listingDirty {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").glyphSize(10, weight: .bold)
                            Text("Saved", bundle: .module).font(SettingsFont.smallLabel)
                        }
                        .foregroundColor(theme.status.success.foreground)
                        .transition(.opacity)
                    } else {
                        Button {
                            if let shown = detail { showListing(fromDetail: shown, keepingEdits: false) } else if let record {
                                showListing(fromRecord: record)
                            }
                        } label: {
                            Text("Discard Changes", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.tertiary, size: .compact)
                        .disabled(isSavingListing)
                        Button(action: requestSaveListing) {
                            Text("Save Listing", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.primary, isLoading: isSavingListing, size: .compact)
                        .disabled(
                            isSavingListing || banned || !ListingEdits.isValid(name: listingName, summary: listingSummary))
                    }
                }
                .frame(minHeight: 28)
            }
            if let listingResult {
                ListingEditsStatusView(result: listingResult, isRetrying: isSavingListing, onRetry: requestSaveListing)
            }
        }
    }

    private func requestSaveListing() {
        if listingEdits.sharesNewExamples {
            confirmExamples = true
        } else {
            saveListing()
        }
    }

    private func saveListing() {
        let edits = listingEdits
        guard !edits.isEmpty else { return }
        isSavingListing = true
        listingResult = nil
        Task { @MainActor in
            defer { isSavingListing = false }
            do {
                let result = try await WorkflowShareService.shared.applyListingEdits(templateID: template.id, edits)
                if let details = edits.details, result.detailsError == nil {
                    switch details {
                    case .set(let name, let summary):
                        shownListing.name = name
                        shownListing.summary = summary
                        shownListing.edited = true
                    case .reset:
                        shownListing.name = templateDetails.name
                        shownListing.summary = templateDetails.summary
                        shownListing.edited = false
                    }
                    listingName = shownListing.name
                    listingSummary = shownListing.summary
                }
                if let sent = edits.topics, result.topicsError == nil { shownListing.topics = sent }
                if let saved = result.savedExamples {
                    shownListing.examples = saved.map(ListingExampleBuilder.draft(from:))
                    examples = shownListing.examples
                }
                let notes = result.imagesSkipped || !result.unreadableImages.isEmpty
                listingResult = result.hasFailures || notes ? result : nil
                if !result.hasFailures {
                    withAnimation(theme.motion.quick) { listingSaved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation(theme.motion.quick) { listingSaved = false }
                    }
                }
                shareCard = nil
                renderShareCard()
            } catch {
                var failed = ListingEditsResult()
                failed.detailsError = edits.details == nil ? nil : error.localizedDescription
                failed.topicsError = edits.topics == nil ? nil : error.localizedDescription
                failed.examplesError = edits.examples == nil ? nil : error.localizedDescription
                listingResult = failed
            }
        }
    }

    // MARK: - Workflows it brings

    /// The agent this workflow's page came with, by name.
    private func publishedWith(_ record: WorkflowRegistryRecord) -> String? {
        guard !isAgent, let id = record.publishedWith else { return nil }
        return templates.latest(id: id)?.name
    }

    /// Each workflow the agent bundles, with its own page when it has one.
    /// Taking the agent down leaves these up, so each has its own Take Down.
    @ViewBuilder
    private func bundledWorkflows(_ record: WorkflowRegistryRecord) -> some View {
        let plan = TemplateCascadePlan.make(
            template: template, visibility: record.visibility, ownAddress: record.address,
            record: { registryRecords.record(for: $0) }, isBuiltIn: WorkflowShareService.isBuiltInTemplate)
        if !plan.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SettingsFieldLabel("Workflows it brings")
                CascadeWorkflowList(items: plan.rows) { row in
                    if let page = row.record, page.isLive {
                        CascadeWorkflowRow(
                            name: row.template.name, version: page.registryLatestVersion ?? page.version,
                            chip: TemplateCascadeCopy.chip(
                                TemplateCascadePlan.State.alreadyPublished(page), agentVisibility: record.visibility),
                            detail: TemplateCascadeCopy.live(page, agentVisibility: record.visibility)
                        ) {
                            HStack(spacing: theme.space.s8) {
                                Button {
                                    NSWorkspace.shared.open(page.url)
                                } label: {
                                    Text("Open Page", bundle: .module)
                                }
                                .assignedSettingsButtonStyle(.secondary, size: .compact)
                                Button {
                                    onTakeDownWorkflow(row.template)
                                } label: {
                                    Text("Take Down…", bundle: .module)
                                }
                                .buttonStyle(
                                    .settings(.destructive, isLoading: takingDownWorkflowID == row.id, size: .compact))
                                .disabled(takingDownWorkflowID != nil)
                                .help(Text("Its page stops working for everyone. The agent still carries it.", bundle: .module))
                            }
                        }
                    } else {
                        CascadeWorkflowRow(
                            name: row.template.name, version: row.template.version,
                            chip: TemplateCascadeCopy.chip(row.state == .willPublish ? .bundledOnly(.turnedOff) : row.state, agentVisibility: record.visibility),
                            detail: row.state == .willPublish
                                ? L("Only inside the agent. Publishing the agent again gives it its own page.")
                                : TemplateCascadeCopy.detail(row, agentVisibility: record.visibility, visibility: plan.visibility)
                        ) { EmptyView() }
                    }
                }
            }
            .settingsLandingAnchor("agents.templates.bundledPages")
        }
    }

    // MARK: - Bottom

    private func bottomActions(_ record: WorkflowRegistryRecord) -> some View {
        HStack(spacing: 14) {
            Button(action: onSaveAsFile) {
                Label { Text("Save as File…", bundle: .module) } icon: { Image(systemName: "doc.badge.arrow.up") }
                    .font(SettingsFont.compactLabel)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.text.secondary)
            .pointingHandCursor()
            Spacer()
            if record.isLive {
                Button {
                    confirmTakeDown = true
                } label: {
                    HStack(spacing: 5) {
                        if isTakingDown { ProgressView().controlSize(.mini) }
                        Text("Take Down…", bundle: .module)
                    }
                    .font(SettingsFont.compactLabel)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.status.error.foreground)
                .disabled(isTakingDown)
                .pointingHandCursor()
                .help(Text("Its page stops working for everyone. Publish again any time.", bundle: .module))
                .settingsLandingAnchor(isAgent ? "agents.templates.takeDown" : "workflows.takeDown")
            }
        }
        .padding(.top, theme.space.s4)
    }

    // MARK: - Actions

    private func refresh() {
        guard record != nil, !isLoading else { return }
        isLoading = true
        loadFailed = false
        needsIdentity = false
        Task { @MainActor in
            defer { isLoading = false }
            do {
                let wasDirty = visibilityDirty
                let refreshed = try await WorkflowShareService.shared.refreshOwned(templateID: template.id)
                detail = refreshed.detail
                banned = refreshed.banned
                showListing(fromDetail: refreshed.detail, keepingEdits: true)
                if !wasDirty {
                    selectedVisibility = refreshed.record.visibility
                    workspaceIDs = Set(refreshed.record.workspaceIDs)
                }
                sharedWorkspacesLoaded =
                    refreshed.record.visibility != .workspace || refreshed.detail.workspaceIDs != nil
                shareCard = nil
                renderShareCard()
            } catch WorkflowShareError.api(.notFound) {
                // The registry no longer knows it: nothing to manage.
                WorkflowShareService.shared.forget(templateID: template.id)
            } catch WorkflowShareError.noMasterKey, WorkflowShareError.identity(_) {
                needsIdentity = true
            } catch {
                loadFailed = true
                print("[WorkflowsRegistry] dashboard refresh failed: \(error)")
            }
        }
    }

    private func saveVisibility() {
        guard let selectedVisibility else { return }
        isSavingVisibility = true
        visibilityError = nil
        Task { @MainActor in
            defer { isSavingVisibility = false }
            do {
                let changingPassword = selectedVisibility == .password && !password.isEmpty
                let keepingPassword = selectedVisibility == .password && password.isEmpty
                if keepingPassword, record?.visibility == .password { return }
                let following = workflowsFollow ? followers(to: selectedVisibility) : []
                let workspaces = selectedVisibility == .workspace ? workspaceIDs.sorted() : []
                if following.isEmpty {
                    try await WorkflowShareService.shared.setVisibility(
                        templateID: template.id, visibility: selectedVisibility,
                        password: changingPassword ? password : nil, workspaceIDs: workspaces)
                } else {
                    let failed = try await WorkflowShareService.shared.setAgentVisibility(
                        templateID: template.id, visibility: selectedVisibility,
                        password: changingPassword ? password : nil, workspaceIDs: workspaces,
                        workflowIDs: following.map(\.templateID))
                    let unchanged = following.filter { failed[$0.templateID] != nil }
                    if let first = unchanged.first, let reason = failed[first.templateID] {
                        let names = ListFormatter.localizedString(byJoining: unchanged.map(workflowName))
                        visibilityError = L("The agent changed, but \(names) didn't: \(reason)")
                    }
                }
                password = ""
                sharedWorkspacesLoaded = true
                withAnimation(theme.motion.quick) { visibilitySaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(theme.motion.quick) { visibilitySaved = false }
                }
            } catch {
                visibilityError = error.localizedDescription
            }
        }
    }

    private func renderShareCard() {
        guard shareCard == nil, let record, record.isLive else { return }
        let content = WorkflowShareCardContent(
            name: record.listingName ?? template.name, summary: record.listingSummary ?? template.summary ?? "",
            facts: WorkflowCardFacts.template(template).joined(separator: " · "),
            handle: handle(record), url: record.url)
        shareCard = WorkflowShareCard.render(content)
    }
}

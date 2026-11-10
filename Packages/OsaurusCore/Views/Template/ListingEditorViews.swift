//
//  ListingEditorViews.swift
//  osaurus
//
//  The parts of a store listing a publisher edits without a new
//  version: the name and description it shows, its topics, and the example
//  runs under it. The publish step (`ShareWorkflowSheet`) and the
//  published workflow's dashboard (`PublishedWorkflowDashboard`) both use
//  them. Example runs are picked from what ran on this Mac, previewed
//  exactly as they'll appear, and shared only after the publisher agrees.
//

import AppKit
import SwiftUI

// MARK: - Copy

enum ListingCopy {
    static let topicsHint = L("Pick up to 3. People browsing by topic find it here.")

    static func detailsHint(_ kind: TemplateKind) -> String {
        kind == .agent
            ? L("Shown on its page instead of the template's own. New versions keep it; the template people install doesn't change.")
            : L("Shown on its page instead of the workflow's own. New versions keep it; the workflow people install doesn't change.")
    }

    static func examplesHint(_ kind: TemplateKind) -> String {
        kind == .agent
            ? L("Real conversations with an agent made from this template: what was asked, what it answered, and the images it shared. Up to \(ListingEdits.maxExamples).")
            : L("Real runs: what went in, what came out, and the images it made. Up to \(ListingEdits.maxExamples).")
    }

    static func consentTitle(_ count: Int) -> String {
        count == 1 ? L("Share 1 example run publicly?") : L("Share \(count) example runs publicly?")
    }

    static func consentMessage(images: Int, visibility: WorkflowVisibility) -> String {
        let who: String
        switch visibility {
        case .public: who = L("Anyone can see them on its page.")
        case .workspace: who = L("Members of the workspaces it's shared with can see them.")
        case .hidden, .password: who = L("Anyone who can open its page can see them.")
        }
        let pictures =
            images == 0
            ? ""
            : " " + (images == 1 ? L("1 image is included, without its location or camera details.")
                : L("\(images) images are included, without their location or camera details."))
        return L("The inputs and results you previewed leave this Mac. Secret inputs and local paths were left out.")
            + " " + who + pictures + " " + L("You can remove them any time.")
    }
}

// MARK: - Name and description

struct ListingDetailsFields: View {
    @Environment(\.theme) private var theme

    @Binding var name: String
    @Binding var summary: String
    let kind: TemplateKind
    /// The template's own name and summary, to go back to.
    let templateName: String
    let templateSummary: String

    private var nameInvalid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > ListingEdits.maxNameLength
    }

    private var differs: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != templateName
            || summary.trimmingCharacters(in: .whitespacesAndNewlines) != templateSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                SettingsFieldLabel("Name")
                SettingsTextField(placeholder: templateName, text: $name, icon: "textformat", isInvalid: nameInvalid)
            }
            VStack(alignment: .leading, spacing: theme.space.s6) {
                SettingsFieldLabel("Description")
                SettingsTextEditor(
                    text: $summary, placeholder: L("What it does and who it's for"), minHeight: 64, maxHeight: 160,
                    isInvalid: summary.count > ListingEdits.maxSummaryLength)
            }
            HStack(alignment: .top, spacing: theme.space.s8) {
                Text(verbatim: ListingCopy.detailsHint(kind))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: theme.space.s8)
                if differs {
                    Button {
                        name = templateName
                        summary = templateSummary
                    } label: {
                        Text("Use Original", bundle: .module)
                    }
                    .assignedSettingsButtonStyle(.tertiary, size: .compact)
                    .help(Text("Go back to the template's own name and summary.", bundle: .module))
                }
            }
        }
    }
}

// MARK: - Topics

struct ListingTopicPicker: View {
    @Environment(\.theme) private var theme

    @Binding var selection: [ListingTopic]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            FlowLayout(spacing: theme.space.s6) {
                ForEach(ListingTopic.allCases) { topic in
                    let selected = selection.contains(topic)
                    FilterChip(topic.title, isSelected: selected) { toggle(topic) }
                        .disabled(!selected && selection.count >= ListingTopic.maxSelected)
                }
            }
            Text(verbatim: ListingCopy.topicsHint)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
        }
    }

    private func toggle(_ topic: ListingTopic) {
        withAnimation(theme.motion.quick) {
            var ids = selection.map(\.rawValue)
            if let index = ids.firstIndex(of: topic.rawValue) {
                ids.remove(at: index)
            } else if ids.count < ListingTopic.maxSelected {
                ids.append(topic.rawValue)
            }
            selection = ListingTopic.normalized(ids)
        }
    }
}

// MARK: - Example runs

struct ListingExamplesEditor: View {
    @Environment(\.theme) private var theme

    let template: Template
    @Binding var examples: [ListingExampleDraft]
    /// The listing's newest version, to flag examples from older ones.
    var latestVersion: Int?

    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(verbatim: ListingCopy.examplesHint(template.kind))
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach($examples) { $draft in
                let id = draft.id
                ListingExampleRow(
                    draft: $draft, latestVersion: latestVersion,
                    onMoveUp: examples.first?.id == id ? nil : { moveUp(id) },
                    onRemove: { remove(id) })
            }
            Button {
                picking = true
            } label: {
                Label {
                    Text("Add Example Runs…", bundle: .module)
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)
            .disabled(examples.count >= ListingEdits.maxExamples)
        }
        .sheet(isPresented: $picking) {
            ListingExamplesPickerSheet(
                template: template, existing: Set(examples.map(\.source)),
                capacity: ListingEdits.maxExamples - examples.count,
                onAdd: { added in
                    examples.append(contentsOf: added)
                    picking = false
                },
                onCancel: { picking = false })
        }
    }

    private func moveUp(_ id: String) {
        guard let index = examples.firstIndex(where: { $0.id == id }), index > 0 else { return }
        withAnimation(theme.motion.quick) { examples.swapAt(index, index - 1) }
    }

    private func remove(_ id: String) {
        withAnimation(theme.motion.quick) { examples.removeAll { $0.id == id } }
    }
}

/// One example as it will show: its title (editable), where it came from,
/// its images (each can be left out), and the exact input and result.
struct ListingExampleRow: View {
    @Environment(\.theme) private var theme

    @Binding var draft: ListingExampleDraft
    var latestVersion: Int?
    var onMoveUp: (() -> Void)?
    let onRemove: () -> Void

    private static let thumbnail: CGFloat = 56

    private var isStale: Bool {
        guard let latestVersion, let version = draft.templateVersion else { return false }
        return version < latestVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: draft.status == .failed ? "xmark.octagon" : "checkmark.circle")
                    .glyphSize(13)
                    .foregroundColor(
                        draft.status == .failed ? theme.status.error.foreground : theme.status.success.foreground)
                SettingsTextField(placeholder: L("Title"), text: $draft.title)
                if let onMoveUp {
                    SettingsIconButton("arrow.up", help: L("Move Up"), size: .compact, action: onMoveUp)
                }
                SettingsIconButton("trash", help: L("Remove"), size: .compact, isDestructive: true, action: onRemove)
            }
            HStack(spacing: theme.space.s6) {
                Text(verbatim: facts)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                if isStale, let version = draft.templateVersion {
                    StatusChip(
                        L("Ran on version \(version)"), tone: .warning,
                        help: L("Newer versions may behave differently. Replace it with a newer run when you have one."))
                }
            }
            if !draft.images.isEmpty { images }
            DisclosureGroup {
                ListingExamplePayloadPreview(draft: draft)
                    .padding(.top, theme.space.s6)
            } label: {
                Text("What leaves this Mac", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)
            }
            .tint(theme.text.secondary)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }

    private var facts: String {
        var parts: [String] = []
        switch draft.source {
        case .run: parts.append(L("Run"))
        case .chat: parts.append(L("Conversation"))
        case .published: parts.append(L("On its page"))
        }
        parts.append(draft.date.formatted(date: .abbreviated, time: .shortened))
        if let ms = draft.durationMs { parts.append(Self.duration(ms)) }
        if draft.status == .failed { parts.append(L("Failed")) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return L("\(ms) ms") }
        let seconds = Double(ms) / 1000
        if seconds < 60 { return L("\(String(format: "%.1f", seconds)) s") }
        return L("\(Int(seconds) / 60) min \(Int(seconds) % 60) s")
    }

    private var images: some View {
        let includedCount = draft.includedImages.count
        return FlowLayout(spacing: theme.space.s8) {
            ForEach($draft.images) { $image in
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    thumbnail(image)
                        .frame(width: Self.thumbnail, height: Self.thumbnail)
                        .opacity(image.included ? 1 : 0.4)
                    Toggle(isOn: $image.included) {
                        Text("Include", bundle: .module)
                            .font(SettingsFont.smallLabel)
                    }
                    .settingsCheckbox()
                    .disabled(!image.included && includedCount >= ListingEdits.maxImagesPerExample)
                }
                .help(Text(verbatim: image.filename))
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ image: ListingExampleDraft.ImageDraft) -> some View {
        if let url = image.fileURL {
            WorkflowMediaThumbnail(path: url.path, side: Self.thumbnail)
        } else if let remote = image.uploaded?.url {
            AsyncImage(url: remote) { phase in
                if let loaded = phase.image {
                    loaded.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(theme.text.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.surface.subtle)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
        } else {
            Image(systemName: "photo")
                .foregroundColor(theme.text.tertiary)
        }
    }
}

/// The input, result, or error exactly as the listing will show them.
struct ListingExamplePayloadPreview: View {
    @Environment(\.theme) private var theme

    let draft: ListingExampleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            block(L("Input"), Self.pretty(draft.input))
            if let output = draft.output { block(L("Result"), Self.pretty(output)) }
            if let error = draft.error { block(L("Error"), error) }
        }
    }

    private func block(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(verbatim: label)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.tertiary)
            ScrollView {
                Text(verbatim: text)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(theme.space.s8)
            }
            .frame(maxHeight: 160)
            .settingsChrome(.subtle)
        }
    }

    /// Strings as they are; anything else as indented JSON, like the page.
    static func pretty(_ value: JSONValue) -> String {
        if case .string(let s) = value { return s }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

// MARK: - Picking runs

struct ListingExamplesPickerSheet: View {
    @Environment(\.theme) private var theme

    let template: Template
    /// Already chosen; not offered again.
    let existing: Set<ListingExampleDraft.Source>
    let capacity: Int
    let onAdd: ([ListingExampleDraft]) -> Void
    let onCancel: () -> Void

    @State private var candidates: [ListingExampleDraft] = []
    @State private var selected: [String] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(
                icon: "text.badge.checkmark", title: "Add Example Runs", subtitleText: template.name, onClose: onCancel)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, theme.space.s24)
                    } else if candidates.isEmpty {
                        Text(verbatim: emptyMessage)
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(verbatim: L("Pick up to \(capacity). You'll see exactly what each one shares before anything leaves this Mac."))
                            .font(SettingsFont.rowDescription)
                            .foregroundColor(theme.text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                .padding(theme.settingsSheetInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: selected.count > 1 ? LocalizedStringKey(L("Add \(selected.count) Runs")) : "Add",
                    isEnabled: !selected.isEmpty,
                    handler: { onAdd(candidates.filter { selected.contains($0.id) }) }),
                secondary: SettingsSheetFooter.Action(label: "Cancel", handler: onCancel))
        }
        .fittedSheetFrame(width: 560, height: 560)
        .settingsSheetSurface()
        .task { await load() }
    }

    private var emptyMessage: String {
        template.kind == .agent
            ? L("No conversations yet with an agent made from this template. Chat with one, then come back.")
            : L("No finished runs yet. Run it, or test it in the Architect, then come back.")
    }

    private func candidateRow(_ candidate: ListingExampleDraft) -> some View {
        let isOn = selected.contains(candidate.id)
        return Toggle(
            isOn: Binding(
                get: { isOn },
                set: { on in
                    if on {
                        if selected.count < capacity { selected.append(candidate.id) }
                    } else {
                        selected.removeAll { $0 == candidate.id }
                    }
                })
        ) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: candidate.title)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text(verbatim: details(candidate))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }
        }
        .settingsCheckbox()
        .disabled(!isOn && selected.count >= capacity)
        .padding(theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }

    private func details(_ candidate: ListingExampleDraft) -> String {
        var parts = [candidate.date.formatted(date: .abbreviated, time: .shortened)]
        if candidate.status == .failed { parts.append(L("Failed")) }
        if let version = candidate.templateVersion { parts.append(L("Version \(version)")) }
        let images = candidate.images.count
        if images > 0 { parts.append(images == 1 ? L("1 image") : L("\(images) images")) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        let found =
            template.kind == .agent
            ? await ListingExampleBuilder.chatCandidates(for: template)
            : ListingExampleBuilder.runCandidates(for: template)
        candidates = found.filter { !existing.contains($0.source) }
        isLoading = false
    }
}

// MARK: - How saving went

/// What didn't save after a publish or a dashboard save, with another try.
struct ListingEditsStatusView: View {
    @Environment(\.theme) private var theme

    let result: ListingEditsResult
    var isRetrying = false
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            if result.hasFailures {
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .glyphSize(13)
                        .foregroundColor(theme.status.warning.foreground)
                    VStack(alignment: .leading, spacing: theme.space.s6) {
                        Text("Some listing changes didn't save.", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        ForEach(failures, id: \.self) { line in
                            Text(verbatim: line)
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(action: onRetry) {
                            Text("Try Again", bundle: .module)
                        }
                        .assignedSettingsButtonStyle(.secondary, isLoading: isRetrying, size: .compact)
                        .disabled(isRetrying)
                    }
                }
                .padding(theme.space.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.status(.warning))
            }
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .top, spacing: theme.space.s6) {
                    Image(systemName: "info.circle")
                        .glyphSize(11)
                        .foregroundColor(theme.text.tertiary)
                    Text(verbatim: note)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var failures: [String] {
        var lines: [String] = []
        if let e = result.detailsError { lines.append(L("Name and description: \(e)")) }
        if let e = result.topicsError { lines.append(L("Topics: \(e)")) }
        if let e = result.examplesError { lines.append(L("Example runs: \(e)")) }
        return lines
    }

    private var notes: [String] {
        var lines: [String] = []
        if result.imagesSkipped {
            lines.append(L("Example runs were saved without their new images: the store can't save images right now."))
        }
        if !result.unreadableImages.isEmpty {
            lines.append(
                L("Left out \(result.unreadableImages.joined(separator: ", ")): couldn't be read or made small enough."))
        }
        return lines
    }
}

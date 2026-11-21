//
//  WorkflowMediaModelCard.swift
//  osaurus
//
//  In setup's Models step: one image or video model a workflow's steps run
//  on. Ready when one is here; otherwise the bundle to download, with its
//  size, progress, Cancel and Try Again, without leaving setup.
//

import SwiftUI

struct WorkflowMediaModelCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var downloads = ImageModelDownloadService.shared

    let requirement: MediaModelRequirement
    /// The steps that use it, by name.
    let steps: [String]
    /// What blocks it here; nil when a model is ready.
    let issue: SetupItem?
    /// Leaves setup for another tab. Nil hides those actions.
    let onLeave: ((ManagementTab) -> Void)?

    @State private var outcome: MediaModelSourceResolver.Outcome?
    @State private var selection: String?

    /// The installed or connected model it runs on now, if any.
    private var readyModel: String? {
        guard issue == nil,
            case .success(let hit) = MediaModelResolver.resolve(
                requirement.model, action: requirement.action, candidates: MediaModelResolver.liveCandidates())
        else { return nil }
        return hit.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: requirement.action.modelTitle)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                    if !steps.isEmpty {
                        Text(verbatim: L("Used by \(WorkflowSummary.list(steps))"))
                            .textStyle(.caption)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: theme.space.s8)
                if let name = requirement.model.id ?? requirement.model.family {
                    StatusChip(name, icon: "photo")
                }
            }
            if issue == nil {
                Label {
                    Text(verbatim: readyModel.map { L("Ready: \($0)") } ?? L("Ready"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(theme.status.success.foreground)
                }
                .textStyle(.caption, weight: 500)
                .foregroundColor(theme.text.secondary)
                .transition(.opacity)
            } else {
                source
                    .transition(.opacity)
            }
        }
        .padding(theme.space.s16)
        .settingsChrome(.inset)
        .animation(theme.motion.standard, value: issue == nil)
        .task(id: requirement.id) {
            guard issue != nil, outcome == nil else { return }
            outcome = await MediaModelSourceResolver.resolveLive(requirement)
        }
    }

    // MARK: - Source

    @ViewBuilder
    private var source: some View {
        switch outcome {
        case nil:
            HStack(spacing: theme.space.s8) {
                SettingsSpinner()
                Text("Finding where to get it…", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }
        case .download(let choice, let alternatives)?:
            downloadRow([choice] + alternatives)
        case .choose(let options)?:
            downloadRow(options)
        case .connectProvider?:
            row(icon: "cloud", text: issue?.detail ?? L("This step runs on a connected provider.")) {
                if let onLeave {
                    button(L("Connect a Provider"), icon: "link", primary: true) { onLeave(.providers) }
                }
            }
        case .unavailable?:
            row(icon: "questionmark.circle", text: issue?.detail ?? L("No model for this step is available to download.")) {
                if let onLeave {
                    button(L("Browse Models"), icon: "arrow.up.right", primary: false) { onLeave(.models) }
                }
            }
        }
    }

    @ViewBuilder
    private func downloadRow(_ options: [MediaModelSource]) -> some View {
        // A download already going for any of these (started here, in
        // Models, or by an install) is the one to show.
        let active = options.first { ModelDownloadProgressRow.state(of: .media(bundleId: $0.id)) != .notStarted }
        let chosen = active ?? options.first { $0.id == selection } ?? options.first
        if let chosen {
            if active != nil {
                ModelDownloadProgressRow(source: .media(bundleId: chosen.id), name: chosen.displayName) {
                    start(chosen)
                }
            } else {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    row(icon: "arrow.down.circle", text: Self.downloadText(chosen)) {
                        button(L("Download"), icon: "arrow.down", primary: true) { start(chosen) }
                    }
                    if options.count > 1 {
                        SettingsMenuPicker(selection: Binding(get: { chosen.id }, set: { selection = $0 })) {
                            ForEach(options) { option in
                                Text(verbatim: Self.optionLabel(option)).tag(option.id)
                            }
                        }
                        .settingsPickerHugging()
                    }
                }
            }
        }
    }

    static func downloadText(_ source: MediaModelSource) -> String {
        guard let bytes = source.sizeBytes, bytes > 0 else {
            return L("\(source.displayName) isn't downloaded yet.")
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return L("\(source.displayName) isn't downloaded yet. About \(size).")
    }

    static func optionLabel(_ source: MediaModelSource) -> String {
        guard let bytes = source.sizeBytes, bytes > 0 else { return source.displayName }
        return "\(source.displayName) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private func start(_ source: MediaModelSource) {
        downloads.download(repoId: source.repoId, displayName: source.displayName)
    }

    // MARK: - Parts

    private func row<Trailing: View>(
        icon: String, text: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.caption)
                .foregroundColor(theme.status.info.foreground)
            Text(verbatim: text)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 120, alignment: .leading)
                .layoutPriority(1)
            Spacer(minLength: theme.space.s8)
            trailing()
        }
    }

    private func button(_ title: String, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        SettingsButton(primary ? .primary : .secondary, title, icon: icon, size: .compact, verbatim: true, action: action)
            .fixedSize()
    }
}

extension WorkflowDefinition {
    /// The names of the steps a media requirement stands for: media steps
    /// with its action and model, or tool steps calling `tool`.
    func stepNames(for requirement: MediaModelRequirement, tool: String? = nil) -> [String] {
        nodes.compactMap { node in
            switch node.kind {
            case .media(let spec)?:
                guard tool == nil, MediaModelRequirement(action: spec.action, model: spec.model).id == requirement.id
                else { return nil }
                return node.name
            case .tool(let spec)?:
                return spec.tool.name == tool ? node.name : nil
            default:
                return nil
            }
        }
    }
}

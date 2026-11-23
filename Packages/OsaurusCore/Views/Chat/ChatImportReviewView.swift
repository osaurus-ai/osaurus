//
//  ChatImportReviewView.swift
//  OsaurusCore
//
//  The `osaurus_import` card: what a link or snippet sets up, one row per
//  item with a checkbox, a Skill / Agent choice for instructions, and
//  Replace / Keep both on name clashes. Manual steps are listed for the
//  user to do and are never run. Presented by `ConfigApprovalModal`.
//

import SwiftUI

struct ChatImportReviewView: View {
    let requestId: UUID
    let review: ChatImportReview
    let onCancel: () -> Void
    let onInstall: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var queue = ConfigApprovalQueue.shared

    private var choices: [String: ChatImportItemChoice] { queue.importChoices[requestId] ?? review.defaultChoices }

    private var actionableItems: [ChatImportItem] { review.items.filter { $0.kind != .manualStep } }
    private var manualSteps: [ChatImportItem] { review.items.filter { $0.kind == .manualStep } }
    private var includedCount: Int {
        actionableItems.filter { choices[$0.id]?.included == true && $0.isActionable }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s12) {
                    ForEach(sections, id: \.kind) { section in
                        VStack(alignment: .leading, spacing: theme.space.s6) {
                            Text(section.kind.sectionTitle)
                                .textStyle(.caption, weight: 600)
                                .foregroundColor(theme.text.tertiary)
                            ForEach(section.items) { item in row(item) }
                        }
                    }
                    if !manualSteps.isEmpty { manualStepsSection }
                    if !review.refusals.isEmpty || !review.notes.isEmpty { notesSection }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.space.s12)
            }
            .frame(maxHeight: 340)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(theme.surface.hover)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .stroke(theme.border.default, lineWidth: theme.stroke.default))
            )

            HStack(spacing: theme.space.s8) {
                Spacer()
                SettingsButton(.secondary, "Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                SettingsButton(.primary, installTitle, verbatim: true, action: onInstall)
                .keyboardShortcut(.defaultAction)
                .disabled(includedCount == 0)
            }
        }
    }

    private var installTitle: String {
        includedCount == 1 ? L("Install 1 Item") : L("Install \(includedCount) Items")
    }

    private struct Section {
        let kind: ChatImportItemKind
        let items: [ChatImportItem]
    }

    private var sections: [Section] {
        ChatImportItemKind.allCases.filter { $0 != .manualStep }.compactMap { kind in
            let items = actionableItems.filter { $0.kind == kind }
            return items.isEmpty ? nil : Section(kind: kind, items: items)
        }
    }

    // MARK: - Rows

    private func row(_ item: ChatImportItem) -> some View {
        let choice = choices[item.id] ?? ChatImportItemChoice(included: false, kind: item.kind, clash: item.clashChoice)
        return VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                Toggle(isOn: binding(item) { $0.included } set: { $0.included = $1 }) {
                    Text(item.name)
                        .textStyle(.label, weight: 500)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
                .disabled(!item.isActionable)
                if let chip = stateChip(item) { chip }
                Spacer(minLength: 0)
            }
            Group {
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(2)
                }
                if item.allowsKindChoice, item.isActionable {
                    AssignedBaseSegmentedPicker(
                        selection: binding(item) { $0.kind } set: { $0.kind = $1 },
                        options: [
                            .init(ChatImportItemKind.skill, review.surface == .agentCreation ? L("Add to this agent") : L("Skill"), verbatim: true),
                            .init(ChatImportItemKind.agent, review.surface == .agentCreation ? L("Separate agent") : L("Agent"), verbatim: true),
                        ],
                        size: .compact
                    )
                    .fixedSize()
                    .disabled(!choice.included)
                }
                if item.state == .nameClash, item.isActionable {
                    AssignedBaseSegmentedPicker(
                        selection: binding(item) { $0.clash ?? .keepBoth } set: { $0.clash = $1 },
                        options: [.init(ChatImportClashChoice.replace, "Replace"), .init(ChatImportClashChoice.keepBoth, "Keep both")],
                        size: .compact
                    )
                    .fixedSize()
                    .disabled(!choice.included)
                }
                ForEach(Array(item.risks.enumerated()), id: \.offset) { _, risk in
                    callout(risk, icon: "exclamationmark.triangle.fill", color: theme.status.warning.foreground)
                }
                if let blocked = item.blockedReason {
                    callout(blocked, icon: "nosign", color: theme.status.error.foreground)
                }
                if !item.needsSetup.isEmpty {
                    callout(
                        L("Needs setup: \(item.needsSetup.joined(separator: ", "))"), icon: "key.fill",
                        color: theme.text.secondary)
                }
                ForEach(Array(item.warnings.enumerated()), id: \.offset) { _, warning in
                    callout(warning, icon: "info.circle", color: theme.text.tertiary)
                }
                if !item.origin.isEmpty {
                    Text(item.origin)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.leading, theme.space.s24)
        }
    }

    private func stateChip(_ item: ChatImportItem) -> StatusChip? {
        switch item.state {
        case .new: return nil
        case .alreadyInstalled: return StatusChip(L("Already installed"), tone: .neutral)
        case .updateAvailable: return StatusChip(L("Update available"), tone: .info)
        case .nameClash: return StatusChip(L("Name in use"), tone: .warning)
        }
    }

    private func callout(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s4) {
            Image(systemName: icon).glyphSize(.tiny).foregroundColor(color)
            Text(text)
                .textStyle(.caption)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualStepsSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            Text(ChatImportItemKind.manualStep.sectionTitle)
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.tertiary)
            Text("Do these yourself. Osaurus doesn't run them.", bundle: .module)
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
            ForEach(manualSteps) { step in
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                    Text(verbatim: "•").textStyle(.caption).foregroundColor(theme.text.secondary)
                    Text(step.name)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            ForEach(Array(review.refusals.enumerated()), id: \.offset) { _, refusal in
                callout(refusal.message, icon: "nosign", color: theme.text.tertiary)
            }
            ForEach(Array(review.notes.enumerated()), id: \.offset) { _, note in
                callout(note, icon: "info.circle", color: theme.text.tertiary)
            }
        }
    }

    private func binding<Value>(
        _ item: ChatImportItem,
        get: @escaping (ChatImportItemChoice) -> Value,
        set: @escaping (inout ChatImportItemChoice, Value) -> Void
    ) -> Binding<Value> {
        let fallback = ChatImportItemChoice(included: false, kind: item.kind, clash: item.clashChoice)
        return Binding(
            get: { get(queue.importChoices[requestId]?[item.id] ?? fallback) },
            set: { value in queue.setImportChoice(requestId: requestId, itemId: item.id) { set(&$0, value) } }
        )
    }
}

//
//  CompactionDialogView.swift
//  osaurus
//
//  First-run / progress dialog for LLM context compaction.
//
//  Shown as a sheet when compaction is triggered without a configured model
//  (Models → Model Defaults → Compaction Model), and while an auto-triggered
//  pre-send compaction runs. Explains what compaction does, lets the user
//  pick a model (remote allowed — remote calls pass through the Privacy
//  Filter), and renders live progress from the service's phase states.
//

import SwiftUI

struct CompactionDialogView: View {
    @ObservedObject var session: ChatSession

    @Environment(\.theme) private var theme

    /// Model chosen in this dialog (pre-populated from settings when one is
    /// already configured — e.g. the dialog opened only to show progress).
    @State private var selectedModelId: String?
    @State private var showModelPicker = false

    init(session: ChatSession) {
        self.session = session
        _selectedModelId = State(
            initialValue: ContextCompactionService.configuredModelIdentifier())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 440)
        .background(theme.surface.canvas)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(theme.status.info.background)
                    .frame(width: 32, height: 32)
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .glyphSize(13, weight: .semibold)
                    .foregroundColor(theme.status.info.foreground)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Compact Conversation", bundle: .module)
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text("Free up context without losing your chat", bundle: .module)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch session.compactionState {
        case .needsModelSelection:
            modelSelectionContent
        case .running(let phase):
            progressContent(phase: phase)
        case .completed(let savedTokens):
            completedContent(savedTokens: savedTokens)
        case .failed(let message):
            failedContent(message: message)
        case .idle:
            // Transient (e.g. the sheet is animating out after a cancel).
            modelSelectionContent
        }
    }

    private var modelSelectionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "This conversation is close to the model's context limit. Osaurus can summarize the older messages with a model of your choice, so the chat can continue with full awareness of what happened — your visible transcript is never changed.",
                bundle: .module
            )
            .textStyle(.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Compaction model", bundle: .module)
                    .textStyle(.footnote, weight: 600)
                    .foregroundColor(theme.text.secondary)
                modelPickerButton
                Text(
                    "Remote models pass through your Privacy Filter. You can change this anytime in Models → Model Defaults.",
                    bundle: .module
                )
                .textStyle(.micro)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelPickerButton: some View {
        let currentItem = session.pickerItems.first { $0.id == selectedModelId }
        return Button {
            showModelPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube.fill")
                    .glyphSize(11, weight: .medium)
                    .foregroundColor(
                        selectedModelId == nil ? theme.text.tertiary : theme.text.secondary)
                if let currentItem {
                    Text(currentItem.displayName)
                        .textStyle(.label)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                } else if let selectedModelId {
                    Text(verbatim: selectedModelId)
                        .textStyle(.bodySmall)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                } else {
                    Text("Choose a model…", bundle: .module)
                        .textStyle(.bodySmall)
                        .foregroundColor(theme.text.placeholder)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .glyphSize(10, weight: .medium)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(theme.surface.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium)
                            .stroke(theme.border.strong, lineWidth: theme.stroke.default)
                    )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            ModelPickerView(
                options: session.pickerItems,
                selectedModel: $selectedModelId,
                agentId: nil,
                onDismiss: { showModelPicker = false }
            )
        }
    }

    private func progressContent(phase: ContextCompactionPhase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text(verbatim: phase.label)
                    .textStyle(.caption, weight: 500)
                    .foregroundColor(theme.text.primary)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            ProgressView(value: phase.progressFraction)
                .progressViewStyle(.linear)
                .tint(theme.status.info.foreground)
                .animation(theme.motion.standard, value: phase.progressFraction)
            Text(
                "Older messages are being summarized. Your visible chat stays exactly as it is.",
                bundle: .module
            )
            .textStyle(.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func completedContent(savedTokens: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .glyphSize(18)
                .foregroundColor(theme.status.success.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation compacted", bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text(
                    "About \(savedTokens.formatted()) tokens were reclaimed. A marker in the chat shows where the summary begins.",
                    bundle: .module
                )
                .textStyle(.footnote)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func failedContent(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(16)
                .foregroundColor(theme.status.warning.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compaction didn't finish", bundle: .module)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: message)
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if session.hasPendingSendAfterCompaction {
                    Text(
                        "Your message hasn't been sent yet. Retry, or send it without a summary — older messages will be trimmed to fit instead.",
                        bundle: .module
                    )
                    .textStyle(.micro)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            switch session.compactionState {
            case .needsModelSelection, .idle:
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    Text("Not Now", bundle: .module)
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.text.secondary)
                .keyboardShortcut(.cancelAction)

                Button {
                    if let id = selectedModelId {
                        session.chooseCompactionModelAndRun(id)
                    }
                } label: {
                    Text("Continue", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
                .disabled(selectedModelId == nil)
                .keyboardShortcut(.defaultAction)

            case .running:
                // The run keeps going if dismissed; its state stays visible
                // in the Context Budget popover.
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    Text("Hide", bundle: .module)
                }
                .assignedSettingsButtonStyle(.tertiary, size: .compact)
                .keyboardShortcut(.cancelAction)

            case .completed:
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    Text("Done", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)

            case .failed:
                // With a stashed auto-triggered send waiting, closing means
                // "go ahead without the summary" (the deterministic trimmer
                // still protects the request) — say so.
                Button {
                    session.cancelCompactionDialog()
                } label: {
                    if session.hasPendingSendAfterCompaction {
                        Text("Send without compacting", bundle: .module)
                    } else {
                        Text("Close", bundle: .module)
                    }
                }
                .assignedSettingsButtonStyle(.tertiary, size: .compact)
                .keyboardShortcut(.cancelAction)

                Button {
                    session.retryCompaction()
                } label: {
                    Text("Retry", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }
}

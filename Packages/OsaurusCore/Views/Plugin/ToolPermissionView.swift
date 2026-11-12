//
//  ToolPermissionView.swift
//  osaurus
//
//  The permission sheet shown before a tool runs: what the agent wants to
//  do in plain words, why (a workflow step's purpose), the exact command,
//  and a short list of what the app knows about the call: what to watch
//  for, what protects the person, and what came back clean.
//

import AppKit
import SwiftUI

struct ToolPermissionView: View {
    let presentation: ToolApprovalPresentation
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onAlwaysAllow: () -> Void
    var onAllowForRun: (() -> Void)? = nil
    /// Knowledge writes replace the generic details block with a
    /// per-document manifest and diffs. Approving a document replacement out
    /// of a pretty-printed JSON blob is not informed consent, and knowledge
    /// consent moved to this modal precisely so it could be reviewed here.
    /// Nil for every other tool.
    var knowledgeWritePreview: KnowledgeWritePreview? = nil
    /// Hides the lease menu (the caller also passes a nil `onAllowForRun`) so
    /// this call cannot be pre-granted. Set for destructive tools where a
    /// blanket grant would be the wrong thing to be able to give. See
    /// `PerCallApprovalTool`.
    var perCallApprovalOnly: Bool = false
    /// Number of approval requests waiting behind this one. The prompt
    /// service presents one card at a time; telling the user more are coming
    /// explains why another card appears right after this decision.
    var queuedBehind: Int = 0

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var showsDetails = false
    @State private var showAlwaysAllowConfirm = false
    @State private var appeared = false
    @State private var alertScopeId = UUID()
    private var alertScope: ThemedAlertScope { .toolPermission(alertScopeId) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            header
                .padding(.horizontal, theme.settingsSheetInset)
                .padding(.top, theme.settingsSheetInset)
                .padding(.bottom, theme.space.s16)

            ContentSizedScrollView(maxHeight: 460) {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    request
                    let facts = PermissionFact.facts(for: presentation)
                    if !facts.isEmpty {
                        VStack(alignment: .leading, spacing: theme.space.s12) {
                            ForEach(facts) { PermissionFactRow(fact: $0) }
                        }
                        .accessibilityIdentifier("toolPermission.facts")
                    }
                    if queuedBehind > 0 {
                        queuedFootnote
                    }
                }
                .padding(.horizontal, theme.settingsSheetInset)
                .padding(.bottom, theme.settingsSheetInset)
            }

            ThemeHairlineDivider(color: theme.border.default)
            footer
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -6)
        .frame(width: 440)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
        .settingsChrome(.overlay)
        .onAppear {
            withAnimation(theme.motion.springAnimation(responseMultiplier: 1.25).delay(0.05)) {
                appeared = true
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .themedAlert(
            L("Always Allow \"\(presentation.title)\"?"),
            isPresented: $showAlwaysAllowConfirm,
            message:
                L(
                    "This tool will be automatically allowed to run without prompting in the future. You can change this in the Tools settings."
                ),
            primaryButton: .primary(L("Always Allow")) { onAlwaysAllow() },
            secondaryButton: .cancel(L("Cancel"))
        )
        .themedAlertScope(alertScope)
        .overlay(ThemedAlertHost(scope: alertScope))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: presentation.icon)
                .glyphSize(.medium, weight: .semibold)
                .foregroundColor(theme.text.secondary)
                .frame(width: theme.space.s32 + theme.space.s4, height: theme.space.s32 + theme.space.s4)
                .settingsChrome(.subtle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                Text(verbatim: presentation.title)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: presentation.subtitle)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toolPermission.action")
    }

    // MARK: - Request

    @ViewBuilder
    private var request: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            if let reason = presentation.reason {
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Rectangle()
                        .fill(theme.border.strong)
                        .frame(width: theme.stroke.focus)
                    Text(verbatim: reason)
                        .font(SettingsFont.body)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "“\(reason)”"))
            }
            if let summary = presentation.summary {
                Text(verbatim: summary)
                    .font(SettingsFont.body)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let knowledgeWritePreview {
                KnowledgeWritePreviewView(preview: knowledgeWritePreview)
            } else if presentation.isShell, let command = presentation.fullDetail {
                CommandWell(command: command, collapsedHeight: 128)
                    .accessibilityIdentifier("toolPermission.fullDetail")
            } else {
                arguments
            }
        }
    }

    /// A non-shell call: the path it touches, with the raw arguments one
    /// click away.
    @ViewBuilder
    private var arguments: some View {
        if presentation.preview != nil || presentation.fullDetail != nil {
            HStack(spacing: theme.settingsControlGap) {
                if let preview = presentation.preview {
                    Text(verbatim: preview)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if presentation.fullDetail != nil {
                    SettingsButton(.tertiary, showsDetails ? "Hide details" : "Show details", size: .compact) {
                        withAnimation(theme.motion.quick) { showsDetails.toggle() }
                    }
                    .fixedSize()
                }
            }
            if showsDetails, let fullDetail = presentation.fullDetail {
                ContentSizedScrollView(maxHeight: 180) {
                    SettingsCodeBlock(code: fullDetail)
                }
                .accessibilityIdentifier("toolPermission.fullDetail")
            }
        }
    }

    // MARK: - Queue footnote

    private var queuedFootnote: some View {
        Label {
            Text(
                queuedBehind == 1
                    ? L("1 more approval is waiting behind this one.")
                    : L("\(queuedBehind) more approvals are waiting behind this one.")
            )
        } icon: {
            Image(systemName: "rectangle.stack")
        }
        .font(SettingsFont.rowDescription)
        .foregroundColor(theme.text.secondary)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: theme.settingsControlGap) {
            leaseControl
            Spacer(minLength: theme.space.s8)
            SettingsButton(.secondary, "Deny", help: L("Esc"), action: onDeny)
                .accessibilityIdentifier("toolPermission.deny")
            SettingsButton(.primary, "Run once", help: L("Return"), action: onAllow)
                .accessibilityIdentifier("toolPermission.runOnce")
        }
        .padding(.horizontal, theme.settingsSheetInset)
        .padding(.vertical, theme.space.s16)
        .background(theme.surface.subtle)
    }

    @ViewBuilder
    private var leaseControl: some View {
        if !perCallApprovalOnly {
            if let onAllowForRun {
                SettingsMenuButton(.tertiary, "Don't ask again", size: .compact) {
                    Button(presentation.leaseActionTitle, action: onAllowForRun)
                    Button(L("Always Allow…")) { showAlwaysAllowConfirm = true }
                }
                .fixedSize()
                .accessibilityIdentifier("toolPermission.lease")
            } else {
                SettingsButton(.tertiary, "Always Allow…", size: .compact) { showAlwaysAllowConfirm = true }
                    .accessibilityIdentifier("toolPermission.alwaysAllow")
            }
        }
    }
}

// MARK: - Facts

/// One line of what the app knows about the call: something to watch for,
/// a protection that applies, or the checks that came back clean.
struct PermissionFact: Identifiable, Equatable {
    enum Tone: Equatable {
        case warning
        case info
        case protection
        case clean
        case neutral
    }

    let id: Int
    let tone: Tone
    let icon: String
    let title: String
    let detail: String?

    /// Things to watch for first, then protections, then what came back
    /// clean.
    static func facts(for presentation: ToolApprovalPresentation) -> [PermissionFact] {
        var rows: [(Tone, String, String, String?)] = []
        for finding in presentation.risk?.findings ?? [] {
            rows.append(
                (finding.signal == .runsInBackground ? .info : .warning, icon(for: finding.signal),
                 finding.title, finding.detail))
        }
        for guarantee in presentation.guarantees {
            let tone: Tone =
                switch guarantee.kind {
                case .enforced: .protection
                case .caution: .warning
                case .note: .neutral
                }
            rows.append((tone, guarantee.icon, guarantee.title, guarantee.detail))
        }
        if let clean = presentation.risk?.cleanSummary {
            rows.append((.clean, "checkmark.circle", clean, nil))
        }
        return rows.enumerated().map { index, row in
            PermissionFact(id: index, tone: row.0, icon: row.1, title: row.2, detail: row.3)
        }
    }

    private static func icon(for signal: ShellCommandRiskScanner.Signal) -> String {
        switch signal {
        case .deletesFiles: "trash"
        case .usesAdminRights: "lock.open"
        case .downloads: "arrow.down.circle"
        case .changesMac: "desktopcomputer"
        case .runsInBackground: "clock.arrow.circlepath"
        case .uncheckable: "eye.slash"
        }
    }
}

private struct PermissionFactRow: View {
    let fact: PermissionFact

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            Image(systemName: fact.icon)
                .font(SettingsFont.glyph)
                .foregroundColor(tint)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                Text(verbatim: fact.title)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = fact.detail {
                    Text(verbatim: detail)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityTone)
    }

    private var tint: Color {
        switch fact.tone {
        case .warning: theme.status.warning.foreground
        case .info: theme.status.info.foreground
        case .protection, .clean: theme.status.success.foreground
        case .neutral: theme.text.secondary
        }
    }

    private var accessibilityTone: Text {
        switch fact.tone {
        case .warning: Text("Check before you approve", bundle: .module)
        case .protection: Text("Enforced", bundle: .module)
        case .info, .clean, .neutral: Text(verbatim: "")
        }
    }
}

/// The exact shell command. A long one starts collapsed with its cut-off
/// edge faded, so hidden text never reads as the end of the command.
private struct CommandWell: View {
    let command: String
    let collapsedHeight: CGFloat

    @Environment(\.theme) private var theme
    @State private var textHeight: CGFloat = 0
    @State private var expanded = false
    @State private var copied = false

    private var overflows: Bool { textHeight > collapsedHeight }
    private var collapsed: Bool { overflows && !expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .top, spacing: theme.settingsControlGap) {
                Text(verbatim: command)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { textHeight = $0 }
                    .frame(height: collapsed ? collapsedHeight : nil, alignment: .top)
                    .clipped()
                    .mask {
                        if collapsed {
                            VStack(spacing: theme.space.s0) {
                                Rectangle()
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: theme.space.s32)
                            }
                        } else {
                            Rectangle()
                        }
                    }
                SettingsIconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy", size: .compact, action: copy)
            }
            if overflows {
                SettingsButton(.tertiary, expanded ? "Show less" : "Show full command", size: .compact) {
                    withAnimation(theme.motion.quick) { expanded.toggle() }
                }
                .fixedSize()
            }
        }
        .padding(theme.settingsInlineGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.code)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// Vertical scroll area sized to its content up to `maxHeight`. The card sits
/// under `.fixedSize`, which lays children out at their ideal height — and a
/// plain ScrollView's ideal height is its minimum, so capped scroll areas can
/// collapse to a sliver depending on which layout pass the panel settles on.
/// Measuring the content and setting an explicit height sidesteps that.
private struct ContentSizedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
                .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                    contentHeight = $0
                }
        }
        .frame(height: min(contentHeight ?? maxHeight, maxHeight))
    }
}

// MARK: - Preview

#if DEBUG && canImport(PreviewsMacros)
    private func previewPresentation(
        _ tool: String, _ arguments: String, surface: ToolExecutionSurface?, reason: String? = nil,
        network: ToolApprovalPresentation.SandboxFacts.Network = .open
    ) -> ToolApprovalPresentation {
        ToolApprovalPresentation.make(
            toolName: tool, description: "Run a shell command in the working directory.",
            descriptionIsForModel: true, argumentsJSON: arguments, surface: surface, stepReason: reason,
            sandbox: surface == .sandboxVM ? .init(cpus: 2, memoryGB: 2, network: network) : nil)
    }

    #Preview("Permission sheet - Python script") {
        ToolPermissionView(
            presentation: previewPresentation(
                "shell_run", #"{"command": "python3 /workspace/runs/convert-1/main.py"}"#, surface: .sandboxVM,
                reason: "Convert the uploaded CSVs to Parquet."),
            onAllow: {}, onDeny: {}, onAlwaysAllow: {}, onAllowForRun: {}
        )
        .environment(\.theme, CustomizableTheme.light())
        .padding()
    }

    #Preview("Permission sheet - pip install") {
        ToolPermissionView(
            presentation: previewPresentation(
                "shell_run", #"{"command": "pip install pyarrow pandas"}"#, surface: .sandboxVM,
                reason: "Install the libraries the converter needs."),
            onAllow: {}, onDeny: {}, onAlwaysAllow: {}, onAllowForRun: {}
        )
        .environment(\.theme, CustomizableTheme.dark())
        .preferredColorScheme(.dark)
        .padding()
    }

    #Preview("Permission sheet - this Mac") {
        ToolPermissionView(
            presentation: previewPresentation(
                "shell_run", #"{"command": "rm -rf build && swift build"}"#, surface: .nativeHost),
            onAllow: {}, onDeny: {}, onAlwaysAllow: {}, onAllowForRun: {}
        )
        .environment(\.theme, CustomizableTheme.light())
        .padding()
    }

    #Preview("Permission sheet - long command") {
        ToolPermissionView(
            presentation: previewPresentation(
                "shell_run",
                #"{"command": "for f in README.md notes.txt; do wc -l \"$f\"; head -5 \"$f\"; done && git status --short --branch && git log --oneline --decorate --graph --all -n 50 && git branch -a -vv && find . -type f -not -path './.git/*' -print0 | xargs -0 ls -la && du -sh ./* 2>/dev/null | sort -h && echo \"Report for $(basename $(pwd)) by $(whoami) on $(hostname) running $(uname -sr)\""}"#,
                surface: .nativeHost),
            onAllow: {}, onDeny: {}, onAlwaysAllow: {}, onAllowForRun: {}
        )
        .environment(\.theme, CustomizableTheme.light())
        .padding()
    }

    /// The batch shape that motivated the manifest: the 62-document import
    /// from osaurus#2439, shown as a manifest rather than a JSON blob.
    #Preview("Permission sheet - Knowledge batch write") {
        ToolPermissionView(
            presentation: previewPresentation("write_knowledge", "{}", surface: .nativeHost),
            onAllow: {}, onDeny: {}, onAlwaysAllow: {},
            knowledgeWritePreview: KnowledgeWritePreview(
                collectionName: "packaging",
                entries: [
                    KnowledgeWritePreviewEntry(
                        relPath: "usage/how-to-deploy.md",
                        operation: .replace,
                        diff: """
                            --- usage/how-to-deploy.md (before)
                            +++ usage/how-to-deploy.md (after)
                            -Applies to PSAppDeployToolkit v3.
                            +Applies to PSAppDeployToolkit v4.1.
                            """,
                        diffTruncated: false,
                        deletedContent: "",
                        addedLines: 1,
                        removedLines: 1,
                        problem: nil
                    )
                ],
                rationale: "Replace the v3 wiki content with the 4.1 docs site.",
                parseError: nil
            )
        )
        .environment(\.theme, CustomizableTheme.light())
        .padding()
    }
#endif

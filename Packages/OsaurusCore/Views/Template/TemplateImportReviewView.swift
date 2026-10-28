//
//  TemplateImportReviewView.swift
//  osaurus
//
//  What a template will do on this Mac, shown before anything is saved:
//  its model and tools, what it needs here, how to connect its MCP
//  servers, and the author signature status.
//

import SwiftUI

struct TemplateImportReviewView: View {
    @Environment(\.theme) private var theme

    let template: Template

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(template)
            if let summary = template.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            agentDetail(template)
            requirementsList(template.requirements)
            serverHints(template.serverHints)
        }
    }

    private func header(_ t: Template) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(agentColorFor(t.name).opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(agentColorFor(t.name))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(t.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    chip(L("Agent"), color: theme.infoColor)
                    chip("v\(t.version)", color: theme.tertiaryText)
                }
                signatureRow(t)
                if !t.changelog.isEmpty {
                    Text(t.changelog)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func signatureRow(_ t: Template) -> some View {
        let status = TemplateSigner.status(of: t)
        let (icon, color): (String, Color) = {
            switch status {
            case .unsigned: return ("seal", theme.tertiaryText)
            case .signed(_, let known): return ("checkmark.seal.fill", known == nil ? theme.infoColor : theme.successColor)
            case .invalid: return ("exclamationmark.triangle.fill", theme.warningColor)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(status.label).font(.system(size: 11, weight: .medium))
            if case .signed(let address, _) = status {
                Text(address)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The name is the author's own claim; only the address is verified.
            if let name = t.author?.name, !name.isEmpty {
                Text(L("· named \(name)")).font(.system(size: 11))
            }
        }
        .foregroundColor(color)
    }

    private func agentDetail(_ t: Template) -> some View {
        HStack(spacing: 10) {
            detail("cube", t.agent.model.valueOrNil ?? L("Default Model"))
            if let mode = t.agent.tools?.mode {
                detail("wrench.and.screwdriver", mode == "manual" ? L("Custom Tools") : L("Auto tools"))
            }
        }
    }

    private func requirementsList(_ requirements: TemplateRequirements) -> some View {
        let items = requirements.items
        return Group {
            if !items.isEmpty {
                box(icon: "checklist", title: L("Needs on this Mac"), tint: theme.secondaryText) {
                    ForEach(items) { requirement in
                        HStack(spacing: 8) {
                            Image(systemName: requirement.kind.icon)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                                .frame(width: 14)
                            Text(requirement.kind.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                            Text(requirement.label ?? requirement.value)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serverHints(_ hints: [MCPServerHint]) -> some View {
        if !hints.isEmpty {
            box(icon: "server.rack", title: L("How to connect its MCP servers"), tint: theme.secondaryText) {
                ForEach(hints) { hint in
                    switch hint.transport {
                    case .http: line(hint.name, hint.url ?? "")
                    case .stdio: line(hint.name, L("Runs \(([hint.command ?? ""] + hint.args).joined(separator: " "))"))
                    }
                }
                Text("Setup offers these when a server isn't on this Mac. Nothing connects or runs until you save it, and keys are never included.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    private func box<Content: View>(
        icon: String, title: String, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(tint)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.6)))
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(theme.secondaryText)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func detail(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium))
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

//
//  GitHubImportSheet.swift
//  osaurus
//
//  Sheet for importing skills from GitHub repositories.
//

import SwiftUI

// MARK: - GitHub Import Sheet

struct GitHubImportSheet: View {
    @Environment(\.theme) private var theme
    @StateObject private var gitHubService = GitHubSkillService.shared

    let onImport: ([Skill]) -> Void
    let onCancel: () -> Void

    // MARK: - State

    enum ImportState {
        case urlInput
        case loading
        case skillSelection(GitHubSkillsResult)
        case importing(progress: Int, total: Int)
        case error(GitHubSkillError)
    }

    @State private var urlInput: String = ""
    @State private var importState: ImportState = .urlInput
    @State private var selectedSkillPaths: Set<String> = []
    @State private var hasAppeared = false
    @State private var isInputFocused = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView
            contentView
            footerView
        }
        .frame(width: 520, height: 480)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        .opacity(hasAppeared ? 1 : 0)
        .scaleEffect(hasAppeared ? 1 : 0.96)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hasAppeared)
        .onAppear {
            withAnimation { hasAppeared = true }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.2), theme.accentColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: headerIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.tertiaryBackground))
            }
            .buttonStyle(PlainButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(theme.secondaryBackground)
    }

    private var headerIcon: String {
        switch importState {
        case .urlInput, .loading: return "link"
        case .skillSelection: return "sparkles"
        case .importing: return "arrow.down.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var headerTitle: String {
        switch importState {
        case .urlInput: return "Import from GitHub"
        case .loading: return "Connecting..."
        case .skillSelection(let result): return result.repoName
        case .importing: return "Importing..."
        case .error: return "Import Failed"
        }
    }

    private var headerSubtitle: String {
        switch importState {
        case .urlInput: return "Paste a repository URL to get started"
        case .loading: return "Fetching repository information"
        case .skillSelection(let result): return "\(result.skills.count) skills available"
        case .importing(let progress, let total): return "Importing skill \(progress) of \(total)"
        case .error(let error): return error.localizedDescription
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch importState {
        case .urlInput:
            urlInputView
        case .loading:
            loadingView
        case .skillSelection(let result):
            skillSelectionView(result)
        case .importing(let progress, let total):
            importingView(progress: progress, total: total)
        case .error(let error):
            errorView(error)
        }
    }

    // MARK: - URL Input View

    private var urlInputView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Icon
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.08))
                        .frame(width: 72, height: 72)

                    Circle()
                        .fill(theme.accentColor.opacity(0.12))
                        .frame(width: 56, height: 56)

                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }

                VStack(spacing: 8) {
                    Text("Enter Repository URL")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Import skills from any GitHub repository")
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                }

                // URL input field
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isInputFocused ? theme.accentColor : theme.tertiaryText)
                        .frame(width: 16)

                    TextField(
                        "",
                        text: $urlInput,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isInputFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
                    .placeholder(when: urlInput.isEmpty) {
                        Text("github.com/owner/repository")
                            .font(.system(size: 13))
                            .foregroundColor(theme.placeholderText)
                    }
                    .onSubmit { fetchSkills() }

                    if !urlInput.isEmpty {
                        Button(action: { urlInput = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(theme.tertiaryText)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(
                                    isInputFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
                .frame(maxWidth: 360)
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView()
                .scaleEffect(1.0)
                .progressViewStyle(CircularProgressViewStyle(tint: theme.accentColor))

            Text("Fetching skills...")
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)

            Spacer()
        }
    }

    // MARK: - Skill Selection View

    private func skillSelectionView(_ result: GitHubSkillsResult) -> some View {
        VStack(spacing: 0) {
            // Repository info card
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.15), theme.accentColor.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    if let description = result.repoDescription {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Text("\(selectedSkillPaths.count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accentColor.opacity(0.1)))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Select all header
            HStack {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if selectedSkillPaths.count == result.skills.count {
                            selectedSkillPaths.removeAll()
                        } else {
                            selectedSkillPaths = Set(result.skills.map(\.path))
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(
                            systemName: selectedSkillPaths.count == result.skills.count
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(
                            selectedSkillPaths.count == result.skills.count ? theme.accentColor : theme.tertiaryText
                        )

                        Text("Select All")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Text("\(result.skills.count) skills")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            // Skills list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(result.skills) { skill in
                        GitHubSkillSelectionRow(
                            skill: skill,
                            isSelected: selectedSkillPaths.contains(skill.path)
                        ) {
                            withAnimation(.easeOut(duration: 0.1)) {
                                if selectedSkillPaths.contains(skill.path) {
                                    selectedSkillPaths.remove(skill.path)
                                } else {
                                    selectedSkillPaths.insert(skill.path)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Importing View

    private func importingView(progress: Int, total: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(theme.tertiaryBackground, lineWidth: 3)
                    .frame(width: 56, height: 56)

                Circle()
                    .trim(from: 0, to: CGFloat(progress) / CGFloat(total))
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress)

                Text("\(progress)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)
            }

            VStack(spacing: 4) {
                Text("Importing Skills")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Fetching skill \(progress) of \(total)...")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()
        }
    }

    // MARK: - Error View

    private func errorView(_ error: GitHubSkillError) -> some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(theme.errorColor.opacity(0.1))
                    .frame(width: 64, height: 64)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(theme.errorColor)
            }

            VStack(spacing: 6) {
                Text("Something went wrong")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(error.localizedDescription)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(action: { importState = .urlInput }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                    Text("Try Again")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accentColor.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(GitHubSecondaryButtonStyle())

            switch importState {
            case .urlInput:
                Button("Continue") { fetchSkills() }
                    .buttonStyle(GitHubPrimaryButtonStyle())
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)

            case .skillSelection:
                Button("Import \(selectedSkillPaths.count) Skills") {
                    if case .skillSelection(let result) = importState {
                        importSelectedSkills(from: result)
                    }
                }
                .buttonStyle(GitHubPrimaryButtonStyle())
                .disabled(selectedSkillPaths.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)

            case .loading, .importing, .error:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle().fill(theme.primaryBorder.opacity(0.5)).frame(height: 1),
                    alignment: .top
                )
        )
    }

    // MARK: - Actions

    private func fetchSkills() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        importState = .loading

        Task {
            do {
                let result = try await gitHubService.fetchSkills(from: url)
                selectedSkillPaths = Set(result.skills.map(\.path))
                importState = .skillSelection(result)
            } catch let error as GitHubSkillError {
                importState = .error(error)
            } catch {
                importState = .error(.networkError(error))
            }
        }
    }

    private func importSelectedSkills(from result: GitHubSkillsResult) {
        let selectedPaths = Array(selectedSkillPaths)
        guard !selectedPaths.isEmpty else { return }

        importState = .importing(progress: 0, total: selectedPaths.count)

        Task {
            var importedSkills: [Skill] = []

            for (index, path) in selectedPaths.enumerated() {
                importState = .importing(progress: index + 1, total: selectedPaths.count)

                do {
                    let content = try await gitHubService.fetchSkillContent(from: result.repo, skillPath: path)
                    let skill = try Skill.parseAnyFormat(from: content)
                    importedSkills.append(skill)
                } catch {
                    print("Failed to import skill at \(path): \(error)")
                }
            }

            if !importedSkills.isEmpty {
                onImport(importedSkills)
            } else {
                importState = .error(.noSkillsFound)
            }
        }
    }
}

// MARK: - Skill Selection Row

private struct GitHubSkillSelectionRow: View {
    @Environment(\.theme) private var theme

    let skill: GitHubSkillPreview
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    private var skillColor: Color {
        let hash = abs(skill.displayName.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                // Checkbox
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? theme.accentColor : Color.clear)
                        .frame(width: 16, height: 16)

                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? theme.accentColor : theme.tertiaryText.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }

                // Skill icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(skillColor.opacity(0.12))
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(skillColor)
                }
                .frame(width: 26, height: 26)

                // Skill name
                Text(skill.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? theme.secondaryBackground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Button Styles

private struct GitHubPrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.5)
    }
}

private struct GitHubSecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

// MARK: - Placeholder Modifier

private extension View {
    @ViewBuilder
    func placeholder<Content: View>(
        when shouldShow: Bool,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            if shouldShow {
                placeholder()
            }
            self
        }
    }
}

#Preview {
    GitHubImportSheet(
        onImport: { _ in },
        onCancel: {}
    )
}

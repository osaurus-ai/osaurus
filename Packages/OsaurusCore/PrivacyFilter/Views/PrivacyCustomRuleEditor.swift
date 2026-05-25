//
//  PrivacyCustomRuleEditor.swift
//  osaurus / PrivacyFilter
//
//  Sheet for adding or editing a user-defined `PrivacyRule`. Validates
//  the regex through `RegexEntityDetector.safeCompile` as the user
//  types so they can see compile errors immediately and try the
//  pattern against a sample string before saving. Save is disabled
//  until the pattern compiles cleanly.
//
//  Lives next to `PrivacyView` because it's the only place that
//  presents it. Kept in its own file so the editor surface can grow
//  (named capture groups, category palette, multi-rule import) without
//  ballooning the settings view.
//

import SwiftUI

struct PrivacyCustomRuleEditor: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Existing rule when editing, `nil` when adding. Captured into
    /// `@State` on appear so user edits don't mutate the caller's
    /// row until they hit Save.
    let initialRule: PrivacyRule?
    let onSave: (PrivacyRule) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var pattern: String = ""
    @State private var category: EntityCategory = .secret
    @State private var sample: String = ""

    /// Latest result of `RegexEntityDetector.safeCompile(pattern)`.
    /// `nil` while the field is empty; `.success` enables Save and
    /// powers the live-test panel; `.failure` blocks Save and shows
    /// a localized reason.
    @State private var compileResult: Result<NSRegularExpression, RegexEntityDetector.CompileError>?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isValid: Bool {
        guard case .success = compileResult else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameField
                    categoryField
                    patternField
                    testPanel
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
            }
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460)
        .background(theme.primaryBackground)
        .onAppear(perform: hydrate)
        .onChange(of: pattern) { _, newValue in
            recompile(newValue)
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                LocalizedStringKey(
                    initialRule == nil
                        ? "privacy.custom.editor.titleAdd"
                        : "privacy.custom.editor.titleEdit"
                ),
                bundle: .module
            )
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(theme.primaryText)
            Text(
                "Patterns run as NSRegularExpression. Catastrophic patterns and ones that match the empty string are rejected.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onCancel) {
                Text("privacy.custom.editor.cancel", bundle: .module)
                    .frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button(action: commit) {
                Text("privacy.custom.editor.save", bundle: .module)
                    .frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("privacy.custom.editor.name", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            TextField(L("privacy.customRule.placeholder.name"), text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("privacy.custom.editor.category", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            Picker(selection: $category) {
                ForEach(EntityCategory.allCases, id: \.self) { c in
                    Text(LocalizedStringKey(categoryKey(c)), bundle: .module)
                        .tag(c)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            Text(
                "Hits are filed under this category and use its placeholder prefix in the review sheet.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
        }
    }

    private var patternField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("privacy.custom.editor.pattern", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            TextField(L("privacy.customRule.placeholder.pattern"), text: $pattern, axis: .vertical)
                .lineLimit(3 ... 6)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            patternStatusRow
        }
    }

    @ViewBuilder
    private var patternStatusRow: some View {
        switch compileResult {
        case .none:
            Text(
                "Enter a pattern to validate.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(theme.successColor)
                Text(
                    "Pattern compiles.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.successColor)
            }
        case .failure(let err):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(theme.warningColor)
                Text(verbatim: localizedCompileError(err))
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("privacy.custom.editor.test", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            TextField(L("privacy.custom.editor.sample"), text: $sample, axis: .vertical)
                .lineLimit(2 ... 4)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            testResultRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var testResultRow: some View {
        if case .success(let regex) = compileResult,
            !sample.isEmpty
        {
            let ns = sample as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = regex.matches(in: sample, options: [], range: range)
            if matches.isEmpty {
                Text(
                    "No matches in sample.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0 ..< min(matches.count, 3), id: \.self) { i in
                        let m = matches[i]
                        if let r = Range(m.range, in: sample) {
                            Text(verbatim: "→ \(sample[r])")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.successColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if matches.count > 3 {
                        Text(verbatim: "… +\(matches.count - 3)")
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }
        } else if sample.isEmpty {
            Text(
                "Type a sample to see live matches.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
        } else {
            EmptyView()
        }
    }

    // MARK: - Behavior

    private func hydrate() {
        if let initialRule {
            name = initialRule.name
            pattern = initialRule.pattern
            category = initialRule.category
        }
        recompile(pattern)
    }

    private func recompile(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            compileResult = nil
            return
        }
        compileResult = RegexEntityDetector.safeCompile(trimmed)
    }

    private func commit() {
        guard isValid else { return }
        let id = initialRule?.id ?? UUID()
        let saved = PrivacyRule(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            enabled: initialRule?.enabled ?? true
        )
        onSave(saved)
    }

    // MARK: - Localization helpers

    private func categoryKey(_ category: EntityCategory) -> String {
        switch category {
        case .accountNumber: return "privacy.category.accountNumber"
        case .address: return "privacy.category.address"
        case .email: return "privacy.category.email"
        case .person: return "privacy.category.person"
        case .phone: return "privacy.category.phone"
        case .url: return "privacy.category.url"
        case .date: return "privacy.category.date"
        case .secret: return "privacy.category.secret"
        }
    }

    private func localizedCompileError(_ err: RegexEntityDetector.CompileError) -> String {
        switch err {
        case .empty:
            return String(localized: "privacy.custom.editor.patternEmpty", bundle: .module)
        case .tooLong(let n):
            let template = String(localized: "privacy.custom.editor.patternTooLong", bundle: .module)
            return String.localizedStringWithFormat(template, n, RegexEntityDetector.maxPatternLength)
        case .invalid(let detail):
            let template = String(localized: "privacy.custom.editor.patternInvalid", bundle: .module)
            return String.localizedStringWithFormat(template, detail)
        case .matchesEmpty:
            return String(localized: "privacy.custom.editor.patternMatchesEmpty", bundle: .module)
        }
    }
}

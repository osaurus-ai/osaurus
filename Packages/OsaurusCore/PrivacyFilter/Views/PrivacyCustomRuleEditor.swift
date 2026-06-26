//
//  PrivacyCustomRuleEditor.swift
//  osaurus / PrivacyFilter
//
//  Sheet for adding or editing a user-defined `PrivacyRule`. Two modes:
//
//    • "Simple" (builder): the user picks a match type (exact word, any
//      of a list of terms, number sequence, between two markers, …) and
//      types literals. We generate and escape the regex for them, so a
//      malformed pattern is impossible by construction.
//    • "Regex": the classic raw `NSRegularExpression` field, validated
//      through `RegexEntityDetector.safeCompile` as the user types.
//
//  Both modes share name, category, a case-sensitivity toggle, and a
//  live test panel. Save is disabled until the effective pattern
//  compiles cleanly and the name is non-empty.
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

    @State private var mode: RuleKind = .builder
    @State private var name: String = ""
    @State private var category: EntityCategory = .secret
    @State private var caseSensitive: Bool = true
    @State private var placeholderLabel: String = ""
    @State private var sample: String = ""

    // Regex mode
    @State private var pattern: String = ""

    // Builder mode
    @State private var matchType: RuleBuilder.MatchType = .anyOfTerms
    @State private var terms: String = ""
    @State private var digitsMin: String = "4"
    @State private var digitsMax: String = ""
    @State private var startMarker: String = ""
    @State private var endMarker: String = ""

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// The regex source the current state would produce, resolving the
    /// builder when in Simple mode. `nil` when inputs are incomplete.
    private var effectivePattern: String? {
        switch mode {
        case .regex:
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .builder:
            return currentBuilder.compile()
        }
    }

    private var currentBuilder: RuleBuilder {
        RuleBuilder(
            matchType: matchType,
            terms: termLines,
            digitsMin: Int(digitsMin.trimmingCharacters(in: .whitespaces)) ?? 0,
            digitsMax: Int(digitsMax.trimmingCharacters(in: .whitespaces)) ?? 0,
            startMarker: startMarker,
            endMarker: endMarker
        )
    }

    private var termLines: [String] {
        terms
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Live compile of the effective pattern with the case option.
    /// Recomputed each render — cheap for a settings sheet and keeps
    /// the status + test panels in sync without scattered `onChange`.
    private var compileResult: Result<NSRegularExpression, RegexEntityDetector.CompileError>? {
        guard let p = effectivePattern else { return nil }
        return RegexEntityDetector.safeCompile(p, caseSensitive: caseSensitive)
    }

    private var isValid: Bool {
        guard case .success = compileResult else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "wand.and.rays",
                title: LocalizedStringKey(
                    initialRule == nil
                        ? "privacy.custom.editor.titleAdd"
                        : "privacy.custom.editor.titleEdit"
                ),
                subtitle:
                    "Simple mode builds the pattern for you. Regex mode lets you write your own pattern; it's checked before you can save.",
                onClose: onCancel
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeField
                    nameField
                    categoryField
                    labelField
                    caseSensitiveField
                    if mode == .builder {
                        builderFields
                        generatedPatternRow
                    } else {
                        patternField
                    }
                    testPanel
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }

            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: "privacy.custom.editor.save",
                    isEnabled: isValid,
                    handler: commit
                ),
                secondary: AgentSheetFooter.Action(
                    label: "privacy.custom.editor.cancel",
                    handler: onCancel
                ),
                hint: "+ Enter to save"
            )
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 520)
        .background(theme.primaryBackground)
        .onAppear(perform: hydrate)
    }

    // MARK: - Shared fields

    private var modeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Mode")
            Picker(selection: $mode) {
                Text("Simple", bundle: .module).tag(RuleKind.builder)
                Text("Regex", bundle: .module).tag(RuleKind.regex)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("privacy.custom.editor.name")
            StyledTextField(
                placeholder: L("privacy.customRule.placeholder.name"),
                text: $name
            )
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("privacy.custom.editor.category")
            Picker(selection: $category) {
                ForEach(EntityCategory.allCases, id: \.self) { c in
                    Text(LocalizedStringKey(c.localizationKey), bundle: .module)
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

    private var labelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Placeholder label (optional)")
            StyledTextField(
                placeholder: L("e.g. CUSTOMER"),
                text: $placeholderLabel
            )
            Text(verbatim: labelHelpText)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Live preview of the token a hit mints, reflecting the sanitized
    /// label (uppercase letters only) or the category fallback.
    private var labelHelpText: String {
        let effective = PrivacyRule.sanitizedLabel(placeholderLabel) ?? category.prefix
        return "Uppercase letters only. Hits redact to [\(effective)_1]; blank uses the category prefix."
    }

    private var caseSensitiveField: some View {
        Toggle(isOn: $caseSensitive) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Case sensitive", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(
                    "When off, ALICE, Alice, and alice all match.",
                    bundle: .module
                )
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: - Regex mode

    private var patternField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("privacy.custom.editor.pattern")
            StyledTextField(
                placeholder: L("privacy.customRule.placeholder.pattern"),
                text: $pattern,
                axis: .vertical,
                lineLimit: 4
            )

            patternStatusRow
        }
    }

    // MARK: - Builder mode

    private var builderFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                AgentSheetSectionLabel("Match type")
                Picker(selection: $matchType) {
                    ForEach(RuleBuilder.MatchType.allCases, id: \.self) { t in
                        Text(LocalizedStringKey(matchTypeLabel(t)), bundle: .module)
                            .tag(t)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
            }

            switch matchType {
            case .exactWord, .anyOfTerms, .startsWith, .endsWith, .contains:
                termsField
            case .numberSequence:
                digitsFields
            case .betweenMarkers:
                markerFields
            }
        }
    }

    private var termsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Terms (one per line)")
            StyledTextField(
                placeholder: L("e.g. Project Apollo"),
                text: $terms,
                axis: .vertical,
                lineLimit: 3
            )
            Text(
                "Each line is matched literally — no regex needed. Special characters are escaped for you.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var digitsFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Number of digits")
            HStack(spacing: 10) {
                StyledTextField(placeholder: L("min"), text: $digitsMin)
                    .frame(width: 90)
                Text("to", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                StyledTextField(placeholder: L("max (blank = any)"), text: $digitsMax)
                    .frame(width: 170)
            }
            Text(
                "Matches a run of digits of this length, e.g. an account or ID number.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var markerFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Between markers")
            HStack(spacing: 10) {
                StyledTextField(placeholder: L("start, e.g. <secret>"), text: $startMarker)
                StyledTextField(placeholder: L("end, e.g. </secret>"), text: $endMarker)
            }
            Text(
                "Redacts everything from the start marker to the end marker, inclusive.",
                bundle: .module
            )
            .font(.system(size: 10))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var generatedPatternRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Generated pattern")
            if let p = effectivePattern {
                Text(verbatim: p)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Add terms above to generate a pattern.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            patternStatusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .editorCardSurface()
    }

    // MARK: - Status + test

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
            AgentSheetSectionLabel("privacy.custom.editor.test")

            StyledTextField(
                placeholder: L("privacy.custom.editor.sample"),
                text: $sample,
                axis: .vertical,
                lineLimit: 3
            )

            testResultRow
        }
        .editorCardSurface()
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
        guard let initialRule else {
            // New rule: default to the friendly Simple builder.
            mode = .builder
            return
        }
        name = initialRule.name
        category = initialRule.category
        caseSensitive = initialRule.caseSensitive
        placeholderLabel = initialRule.placeholderLabel ?? ""
        mode = initialRule.kind
        switch initialRule.kind {
        case .regex:
            pattern = initialRule.pattern
        case .builder:
            if let b = initialRule.builder {
                matchType = b.matchType
                terms = b.terms.joined(separator: "\n")
                digitsMin = String(b.digitsMin)
                digitsMax = b.digitsMax > 0 ? String(b.digitsMax) : ""
                startMarker = b.startMarker
                endMarker = b.endMarker
            }
        }
    }

    private func commit() {
        guard isValid else { return }
        let id = initialRule?.id ?? UUID()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = initialRule?.enabled ?? true
        // Persist the sanitized label (uppercase letters only) or nil
        // so on-disk rules never carry a token-shape the unscrubber
        // would fail to recognise.
        let label = PrivacyRule.sanitizedLabel(placeholderLabel)
        let saved: PrivacyRule
        switch mode {
        case .regex:
            saved = PrivacyRule(
                id: id,
                name: trimmedName,
                pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category,
                enabled: enabled,
                kind: .regex,
                caseSensitive: caseSensitive,
                builder: nil,
                placeholderLabel: label
            )
        case .builder:
            saved = PrivacyRule(
                id: id,
                name: trimmedName,
                pattern: "",
                category: category,
                enabled: enabled,
                kind: .builder,
                caseSensitive: caseSensitive,
                builder: currentBuilder,
                placeholderLabel: label
            )
        }
        onSave(saved)
    }

    // MARK: - Localization helpers

    private func matchTypeLabel(_ type: RuleBuilder.MatchType) -> String {
        switch type {
        case .exactWord: return "Exact word or phrase"
        case .anyOfTerms: return "Any of these terms"
        case .startsWith: return "Starts with"
        case .endsWith: return "Ends with"
        case .contains: return "Contains"
        case .numberSequence: return "Number sequence"
        case .betweenMarkers: return "Between two markers"
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

// MARK: - Card Surface

private extension View {
    /// Card chrome shared by the generated-pattern preview and the live
    /// test panel: the same 10pt `inputBackground` + 1pt `inputBorder`
    /// surface `StyledTextField` and the Privacy tab cards use, with
    /// 12pt inner padding. Mirrors `PrivacyView`'s `settingsRowCard()`
    /// (kept file-local rather than shared so neither view file depends
    /// on the other).
    func editorCardSurface() -> some View {
        modifier(EditorCardSurface())
    }
}

private struct EditorCardSurface: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
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
}

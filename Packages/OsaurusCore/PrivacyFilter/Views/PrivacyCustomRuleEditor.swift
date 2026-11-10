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

    private var theme: any ThemeProtocol { themeManager.currentTheme }

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
            SettingsSheetHeader(
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
                VStack(alignment: .leading, spacing: theme.space.s16) {
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
                .padding(.horizontal, theme.space.s24)
                .padding(.vertical, theme.space.s16)
            }

            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: "privacy.custom.editor.save",
                    isEnabled: isValid,
                    handler: commit
                ),
                secondary: SettingsSheetFooter.Action(
                    label: "privacy.custom.editor.cancel",
                    handler: onCancel
                ),
                hint: "+ Enter to save"
            )
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 520)
        .background(theme.surface.canvas)
        .onAppear(perform: hydrate)
    }

    // MARK: - Shared fields

    private var modeField: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("Mode")
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("privacy.custom.editor.name")
            SettingsTextField(
                placeholder: L("privacy.customRule.placeholder.name"),
                text: $name
            )
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("privacy.custom.editor.category")
            SettingsMenuPicker(selection: $category) {
                ForEach(EntityCategory.allCases, id: \.self) { c in
                    Text(LocalizedStringKey(c.localizationKey), bundle: .module)
                        .tag(c)
                }
            }
            Text(
                "Hits are filed under this category and use its placeholder prefix in the review sheet.",
                bundle: .module
            )
            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
        }
    }

    private var labelField: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("Placeholder label (optional)")
            SettingsTextField(
                placeholder: L("e.g. CUSTOMER"),
                text: $placeholderLabel
            )
            Text(verbatim: labelHelpText)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
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
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text("Case sensitive", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(
                    "When off, ALICE, Alice, and alice all match.",
                    bundle: .module
                )
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
        }
        .settingsSwitch(showsLabel: true)
    }

    // MARK: - Regex mode

    private var patternField: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("privacy.custom.editor.pattern")
            SettingsTextField(
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
        VStack(alignment: .leading, spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                SettingsFieldLabel("Match type")
                SettingsMenuPicker(selection: $matchType) {
                    ForEach(RuleBuilder.MatchType.allCases, id: \.self) { t in
                        Text(LocalizedStringKey(matchTypeLabel(t)), bundle: .module)
                            .tag(t)
                    }
                }
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
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("Terms (one per line)")
            SettingsTextField(
                placeholder: L("e.g. Project Apollo"),
                text: $terms,
                axis: .vertical,
                lineLimit: 3
            )
            Text(
                "Each line is matched literally — no regex needed. Special characters are escaped for you.",
                bundle: .module
            )
            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var digitsFields: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("Number of digits")
            HStack(spacing: theme.space.s8) {
                SettingsTextField(placeholder: L("min"), text: $digitsMin)
                    .frame(width: 90)
                Text("to", bundle: .module)
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                SettingsTextField(placeholder: L("max (blank = any)"), text: $digitsMax)
                    .frame(width: 170)
            }
            Text(
                "Matches a run of digits of this length, e.g. an account or ID number.",
                bundle: .module
            )
            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var markerFields: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("Between markers")
            HStack(spacing: theme.space.s8) {
                SettingsTextField(placeholder: L("start, e.g. <secret>"), text: $startMarker)
                SettingsTextField(placeholder: L("end, e.g. </secret>"), text: $endMarker)
            }
            Text(
                "Redacts everything from the start marker to the end marker, inclusive.",
                bundle: .module
            )
            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var generatedPatternRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            SettingsFieldLabel("Generated pattern")
            if let p = effectivePattern {
                Text(verbatim: p)
                    .catalogTypography(.code, theme: theme, fallback: SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Add terms above to generate a pattern.", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            patternStatusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowChrome()
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
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
        case .success:
            HStack(spacing: theme.space.s6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(theme.status.success.foreground)
                Text(
                    "Pattern compiles.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.status.success.foreground)
            }
        case .failure(let err):
            HStack(spacing: theme.space.s6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(theme.status.warning.foreground)
                Text(verbatim: localizedCompileError(err))
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.status.warning.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var testPanel: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsFieldLabel("privacy.custom.editor.test")

            SettingsTextField(
                placeholder: L("privacy.custom.editor.sample"),
                text: $sample,
                axis: .vertical,
                lineLimit: 3
            )

            testResultRow
        }
        .settingsRowChrome()
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
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            } else {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    ForEach(0 ..< min(matches.count, 3), id: \.self) { i in
                        let m = matches[i]
                        if let r = Range(m.range, in: sample) {
                            Text(verbatim: "→ \(sample[r])")
                                .catalogTypography(.code, theme: theme, fallback: SettingsFont.monoSmall)
                                .foregroundColor(theme.status.success.foreground)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if matches.count > 3 {
                        Text(verbatim: "… +\(matches.count - 3)")
                            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
            }
        } else if sample.isEmpty {
            Text(
                "Type a sample to see live matches.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
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


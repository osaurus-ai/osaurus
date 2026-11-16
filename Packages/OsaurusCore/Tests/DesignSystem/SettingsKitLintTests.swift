//
//  SettingsKitLintTests.swift
//  osaurusTests
//
//  Keeps one-off chrome out of the Management window and raw design values
//  out of every view. Component rules scan view files outside Chat /
//  Onboarding / the kit itself; token rules scan every view file. Counts may only go down: a file over its baseline fails, and a
//  file under its baseline also fails until the baseline is lowered, so the
//  ratchet never loosens. Regenerate with
//
//      SETTINGS_KIT_LINT_WRITE_BASELINE=1 swift test --filter SettingsKitLintTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct SettingsKitLintTests {
    /// One forbidden pattern and how to find it in a file's text.
    struct Rule: Sendable {
        let id: String
        let fix: String
        let count: @Sendable (_ lines: [Substring]) -> Int
    }

    /// Resolved so enumerated paths (`/private/tmp/…` for a `/tmp` checkout)
    /// share its prefix.
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .resolvingSymlinksInPath()

    /// Roots scanned, relative to the package.
    static let roots = ["Views", "PrivacyFilter/Views"]

    /// Top-level `Views/` folders that are not part of the Management window.
    static let excludedFolders: Set<String> = [
        "Chat", "Onboarding", "DesignSystem", "Toast", "Pairing",
    ]

    static let rules: [Rule] = [
        Rule(id: "rawToggle", fix: "SettingsToggle (switch / .checkbox), .settingsSwitch(), .settingsMiniSwitch(), or .settingsCheckbox()") {
            lines in
            countFollowed(lines, hints: ["Toggle("], by: /\bToggle\(/, within: 24) { window in
                !window.contains(".settingsSwitch(") && !window.contains(".settingsMiniSwitch(")
                    && !window.contains(".settingsCheckbox(")
            }
        },
        Rule(id: "rawTextInput", fix: "SettingsTextField / SettingsTextFieldRow") { lines in
            tally(lines, hints: ["Field(", "TextEditor("], /\b(TextField|SecureField|TextEditor)\(/)
        },
        Rule(id: "handChrome", fix: ".settingsChrome(_:)") { lines in
            countFollowed(lines, hints: ["RoundedRectangle(cornerRadius:"], by: /RoundedRectangle\(cornerRadius:/, within: 2) { window in
                window.contains(/\.fill\(\s*(theme|themeManager)/)
            }
        },
        Rule(id: "capsuleFill", fix: "StatusChip / CountBadge") { lines in
            countFollowed(lines, hints: ["Capsule("], by: /Capsule\([^)]*\)/, within: 1) { window in
                window.contains(/Capsule\([^)]*\)\s*\.fill\(/)
            }
        },
        Rule(id: "uppercaseTitle", fix: "sentence case via SettingsSection / SettingsFieldLabel") { lines in
            tally(
                lines, hints: [".tracking(", ".textCase(", ".uppercased()"],
                /\.tracking\(|\.textCase\(\.uppercase\)|Text\([^)\n]*\.uppercased\(\)/)
        },
        Rule(id: "rawTextFont", fix: "SettingsFont.*") { lines in
            countTextFonts(lines)
        },
        Rule(id: "adHocButton", fix: "SettingsButton / .buttonStyle(.settings(_:))") { lines in
            countAdHocButtons(lines)
        },
        Rule(id: "rawStepper", fix: "SettingsStepper / SettingsStepperRow") { lines in
            tally(lines, hints: ["Stepper("], /\bStepper\(/)
        },
        Rule(id: "borderlessMenu", fix: "SettingsOverflowMenu / SettingsMenuButton / SettingsMenuPicker") { lines in
            tally(lines, hints: [".menuStyle("], /\.menuStyle\(\.borderlessButton\)/)
        },
        Rule(id: "fakePopUp", fix: "SettingsMenuPicker, or SettingsPopUpButton for a popover picker") { lines in
            tally(lines, hints: ["chevron.up.chevron.down"], /"chevron\.up\.chevron\.down"/)
        },
        Rule(id: "rawSlider", fix: "SettingsSlider, or SettingsSliderRow for an optional override") { lines in
            tally(lines, hints: ["Slider("], /\bSlider\(/)
        },
        Rule(id: "rawDatePicker", fix: "SettingsDatePicker") { lines in
            tally(lines, hints: ["DatePicker("], /\bDatePicker\(/)
        },
        Rule(id: "systemButtonStyle", fix: ".buttonStyle(.settings(_:)) / SettingsButton") { lines in
            tally(
                lines, hints: [".bordered", "ButtonStyle()"],
                /\.buttonStyle\(\.(bordered|borderedProminent)\)|Bordered(Prominent)?ButtonStyle\(\)/)
        },
        Rule(id: "rawSheetClose", fix: "SettingsSheetHeader (or SettingsIconButton(\"xmark\"))") { lines in
            countFollowed(lines, hints: ["\"xmark\""], by: /Image\(systemName: "xmark"\)/, within: 6) { window in
                window.contains(/Circle\(\)/)
            }
        },
        // Token rules: literal metrics that a `theme.space` / `theme.radius`
        // token or a kit component already owns.
        Rule(id: "rawPadding", fix: "theme.space.s* (or the kit row / section that owns the inset)") { lines in
            tally(lines, hints: [".padding("], /\.padding\(([^()]*,\s*)?\d+(\.\d+)?\)/)
        },
        Rule(id: "rawRadius", fix: "theme.radius.* / .settingsChrome(_:)") { lines in
            tally(lines, hints: ["cornerRadius:"], /cornerRadius:\s*\d/)
        },
        Rule(id: "rawFixedWidth", fix: "SettingsSheetWidth / SettingsFieldRow label width, or a flexible frame") {
            lines in
            tally(lines, hints: [".frame(width:"], /\.frame\(width:\s*\d/)
        },
        // Page-pattern rules: one look per job across every page.
        Rule(id: "familyThemeWrapper", fix: "the inherited theme (product families re-skin a page off the kit)") { lines in
            codeTally(lines, hints: ["catalogFamily("], /catalogFamily\((2[1-9]|[3-9]\d|\d{3})\b/)
        },
        Rule(id: "inspectionSpacing", fix: "theme.space.s* / settingsSectionGap / settingsPageInset") { lines in
            codeTally(
                lines, hints: ["catalogLayoutMetric(", "NativeComponentInspectionStyle.metric(", "catalogMetric("],
                /catalogLayoutMetric\(|NativeComponentInspectionStyle\.metric\([^,()\n]+,\s*"(gap|padding)"|catalogMetric\("(gap|padding)"/
            )
        },
        Rule(id: "legacyBackBar", fix: "SettingsPageHeader with .settingsBackDestination(_:action:)") { lines in
            codeTally(lines, hints: ["Bar("], /\b(SettingsBackBar|SettingsSubPageBar|AgentDetailHeaderBar)\(/)
        },
        Rule(id: "rawMenuPicker", fix: "SettingsMenuPicker / SettingsPickerRow") { lines in
            codeTally(lines, hints: [".pickerStyle(.menu)"], /\.pickerStyle\(\.menu\)/)
        },
        Rule(id: "headerSecondaryRow", fix: "SettingsPageHeader(toolbar:) / SettingsHeaderToolbar") { lines in
            codeTally(lines, hints: ["secondaryRow:"], /\bsecondaryRow:/)
        },
        // A titled native Picker lays out as a macOS form row: label pushed
        // right, control centered, out of line with every other field.
        Rule(id: "labeledNativePicker", fix: "SettingsFieldRow + SettingsMenuPicker, or SettingsPickerRow") { lines in
            countFollowed(lines, hints: ["Picker("], by: /\bPicker\((L\("[^"]+"\)|"[^"]+")/, within: 16) { window in
                !window.contains(".labelsHidden()") && !window.contains(".pickerStyle(.segmented)")
            }
        },
        // Title + description stacked by hand beside a control: SettingsRow
        // owns that layout, its type roles, and the group inset.
        Rule(id: "handRolledRow", fix: "SettingsRow (title, description, trailing control)") { lines in
            countFollowed(lines, hints: ["VStack(alignment: .leading"], by: /VStack\(alignment: \.leading, spacing: (theme\.space\.s)?[0-9]\)/, within: 8) { window in
                window.contains(/SettingsFont\.(compactLabel|rowTitle)/) && window.contains("SettingsFont.rowDescription")
            }
        },
    ]

    /// Design-token rules. Unlike `rules` these cover every view folder,
    /// chat and the kit included: text, color, geometry and motion come from
    /// the theme everywhere. Documented exceptions (syntax palettes, terminal
    /// ANSI colors, artwork, chart series) live in the allowlist.
    static let tokenRules: [Rule] = [
        Rule(id: "rawSystemFont", fix: ".textStyle(_:) / SettingsFont.* / theme.nsFont(_:)") { lines in
            codeTally(
                lines, hints: [".system(", "ystemFont(", ".font(.", "Font."],
                /\.system\(size:|[sS]ystemFont\((ofSize:|\s*$)|\.font\(\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2|system)\b|\bFont\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b/
            )
        },
        Rule(id: "fontBridge", fix: ".textStyle(_:) (font alone drops line height and tracking)") { lines in
            codeTally(
                lines, hints: ["(size:", ".textStyle(", "font(for:"],
                /\b(font|monoFont)\(size:|\.font\([^()\n]*\.textStyle\(|\.font\([^()\n]*\bfont\(for:/
            )
        },
        Rule(id: "styleArithmetic", fix: "pick the text role whose recipe fits; never resize one") { lines in
            codeTally(
                lines, hints: ["scaledTextStyle(", ".pointSize"],
                /scaledTextStyle\(\.\w+\)\.(size|lineHeight)\)?\s*[-+*\/]|\.pointSize\s*[-+*\/]\s*\d/
            )
        },
        Rule(id: "namedColor", fix: "theme.status[...] / theme.action / theme.text roles, or .settingsChrome(.tinted(_:))") {
            lines in
            codeTally(
                lines, hints: ["Color", "(."],
                /\bColor\.(red|green|blue|orange|yellow|purple|pink|gray|grey|black|white|teal|mint|cyan|indigo|brown)\b|\bColor\(hex:|\bColor\((red|\.sRGB)|NSColor\((red|calibratedRed|srgbRed|white|calibratedWhite)|NSColor\.(system\w+|red|green|blue|orange|yellow|purple|pink|gray|grey|black|white|teal|mint|cyan|indigo|brown|labelColor|secondaryLabelColor|tertiaryLabelColor|quaternaryLabelColor|controlAccentColor|textColor|windowBackgroundColor|controlBackgroundColor|separatorColor)\b|(foregroundColor|foregroundStyle|fill|stroke|strokeBorder|background|tint|accentColor)\(\s*\.(red|green|blue|orange|yellow|purple|pink|gray|grey|black|white|teal|mint|cyan|indigo|brown)\b/
            )
        },
        Rule(id: "themeOpacityTone", fix: "the semantic role (border.subtle, surface.hover, text.tertiary, status.*)") {
            lines in
            codeTally(
                lines, hints: [".opacity("],
                /\btheme(Manager\.currentTheme)?\.(surface|text|border|action|status|chat|selection|danger|cursor|scrim|shadow|colors)[\w.\[\]]*\.opacity\(/
            )
        },
        Rule(id: "rawLineWidth", fix: "theme.stroke.default / theme.stroke.focus / hairline") { lines in
            codeTally(lines, hints: ["lineWidth:", "borderWidth"], /lineWidth:\s*(?:[1-9]|0\.\d)|borderWidth\s*=\s*(?:[1-9]|0\.\d)/)
        },
        Rule(id: "handAnimation", fix: "theme.motion.quick / standard / slow / springAnimation / loop(duration:)") {
            lines in
            codeTally(
                lines, hints: ["ease", "linear", "pring", "smooth", "snappy", "bouncy", "default", "Animation.", "duration"],
                /\.(easeOut|easeIn|easeInOut|linear|interactiveSpring|smooth|snappy|bouncy)\((duration:|\))|\.spring\(|(withAnimation|\.animation)\(\s*\.(easeOut|easeIn|easeInOut|linear|default|smooth|snappy|bouncy|spring)\b|Animation\.(easeOut|easeIn|easeInOut|linear|default|spring|smooth|snappy|bouncy)\b|\.duration\s*=\s*(?:[1-9]|0\.\d)/
            )
        },
        Rule(id: "handShadow", fix: ".themeElevation(theme.elevation.*) / layer.applyThemeElevation(_:)") { lines in
            codeTally(lines, hints: ["hadow"], /\.shadow\(|\bshadowOpacity\b|\bshadowRadius\b|\bNSShadow\(\)/)
        },
        Rule(id: "literalRadius", fix: "theme.radius.* / Capsule") { lines in
            codeTally(lines, hints: ["cornerRadius"], /cornerRadius:\s*(?:[1-9]|0\.\d)|cornerRadius\s*=\s*(?:[1-9]|0\.\d)/)
        },
        Rule(id: "glyphTextStyle", fix: ".glyphSize(_:weight:) (symbols are artwork; text roles inflate them)") {
            lines in
            countGlyphTextStyles(lines)
        },
    ]

    /// `Image(systemName:)` / `Image(nsImage:)` whose own modifier chain
    /// applies `.textStyle(`. Containers that style text and icons together
    /// are not counted.
    static func countGlyphTextStyles(_ lines: [Substring]) -> Int {
        var total = 0
        for (index, line) in lines.enumerated() where line.contains("Image(") {
            guard line.contains(/\bImage\((systemName|nsImage)/), !line.contains(/\bText\(|\bLabel\(/) else { continue }
            if line.contains(".textStyle(") {
                total += 1
                continue
            }
            for next in lines[(index + 1)..<min(index + 5, lines.count)] {
                let body = next.drop { $0 == " " || $0 == "\t" }
                guard body.hasPrefix(".") else { break }
                if body.hasPrefix(".textStyle(") {
                    total += 1
                    break
                }
            }
        }
        return total
    }

    // MARK: - Counting helpers

    /// Matches of `pattern` across `lines`. Regex matching is slow enough to
    /// time out CI over every Views file, so it only runs on lines that
    /// contain one of `hints` (literal text every match must include).
    static func tally(_ lines: [Substring], hints: [String], _ pattern: some RegexComponent) -> Int {
        lines.reduce(0) { total, line in
            hints.contains(where: { line.contains($0) }) ? total + line.matches(of: pattern).count : total
        }
    }

    /// `tally` that ignores whole-line `//` comments, so prose that names a
    /// forbidden API does not count.
    static func codeTally(_ lines: [Substring], hints: [String], _ pattern: some RegexComponent) -> Int {
        lines.reduce(0) { total, line in
            guard hints.contains(where: { line.contains($0) }) else { return total }
            if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") { return total }
            return total + line.matches(of: pattern).count
        }
    }

    /// Occurrences of `pattern` whose window (the match line plus `within`
    /// following lines) satisfies `predicate`. `hints` as in `tally`.
    static func countFollowed(
        _ lines: [Substring],
        hints: [String],
        by pattern: some RegexComponent,
        within: Int,
        _ predicate: (String) -> Bool
    ) -> Int {
        var total = 0
        for (index, line) in lines.enumerated()
        where hints.contains(where: { line.contains($0) }) && line.contains(pattern) {
            let window = lines[index...min(index + within, lines.count - 1)].joined(separator: "\n")
            if predicate(window) { total += 1 }
        }
        return total
    }

    /// `.font(.system(size:` applied to a `Text` (the nearest view
    /// constructor above it within four lines is `Text(`).
    static func countTextFonts(_ lines: [Substring]) -> Int {
        var total = 0
        for (index, line) in lines.enumerated() where line.contains(".font(.system(size:") {
            for back in 0...4 where index - back >= 0 {
                let candidate = lines[index - back]
                if candidate.contains(/\bText\(/) {
                    total += 1
                    break
                }
                if candidate.contains(/Image\(|Label\(|ProgressView\(|Circle\(|HStack|VStack|ZStack/) {
                    break
                }
            }
        }
        return total
    }

    /// A plain-styled button whose label paints its own padded rounded fill.
    static func countAdHocButtons(_ lines: [Substring]) -> Int {
        var total = 0
        for (index, line) in lines.enumerated()
        where line.contains(".buttonStyle(.plain)") || line.contains(".buttonStyle(PlainButtonStyle())") {
            let start = max(0, index - 14)
            let window = lines[start..<index].joined(separator: "\n")
            let painted =
                window.contains(/(RoundedRectangle|Capsule)\([^)]*\)\s*\n?\s*\.fill\(/)
                && window.contains(".padding(")
            if painted { total += 1 }
        }
        return total
    }

    // MARK: - Scan

    static func scan() throws -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for rootPath in roots {
            let root = packageRoot.appendingPathComponent(rootPath)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
                let components = relative.split(separator: "/")
                let isManagement =
                    !(rootPath == "Views" && components.count > 1 && excludedFolders.contains(String(components[1])))
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for rule in (isManagement ? rules : []) + tokenRules {
                    if SettingsKitLintBaseline.allowlist[relative]?.contains(rule.id) == true { continue }
                    let count = rule.count(lines)
                    if count > 0 { result[rule.id, default: [:]][relative] = count }
                }
            }
        }
        return result
    }

    // MARK: - Tests

    @Test func managementViewsStayOnTheKit() throws {
        let current = try Self.scan()

        if ProcessInfo.processInfo.environment["SETTINGS_KIT_LINT_WRITE_BASELINE"] == "1" {
            try Self.writeBaseline(current)
            return
        }

        var regressions: [String] = []
        var staleBaseline: [String] = []
        for rule in Self.rules + Self.tokenRules {
            let now = current[rule.id] ?? [:]
            let allowed = SettingsKitLintBaseline.counts[rule.id] ?? [:]
            for (file, count) in now where count > (allowed[file] ?? 0) {
                regressions.append("\(rule.id): \(file) has \(count), baseline \(allowed[file] ?? 0) — use \(rule.fix)")
            }
            for (file, count) in allowed where (now[file] ?? 0) < count {
                staleBaseline.append("\(rule.id): \(file) is \(now[file] ?? 0), baseline \(count)")
            }
        }
        #expect(regressions.isEmpty, "New one-off chrome:\n\(regressions.sorted().joined(separator: "\n"))")
        #expect(
            staleBaseline.isEmpty,
            "Baseline is looser than the code; lower it:\n\(staleBaseline.sorted().joined(separator: "\n"))"
        )
    }

    /// Design-token rules sit at zero outside the allowlist, so a new raw
    /// font, color, radius, stroke, animation or shadow cannot be absorbed by
    /// regenerating the baseline.
    @Test func tokenRulesHaveNoBaseline() {
        let tokenIds = Set(Self.tokenRules.map { $0.id })
        let baselined = SettingsKitLintBaseline.counts
            .filter { tokenIds.contains($0.key) && !$0.value.isEmpty }
            .flatMap { rule, files in files.map { "\(rule): \($0.key) (\($0.value))" } }
        #expect(baselined.isEmpty, "Token rules must not carry a baseline:\n\(baselined.sorted().joined(separator: "\n"))")
    }

    /// A page's inner navigation is header tabs (peer views of one
    /// collection) or drill-in rows (different kinds of page), never both.
    @Test func innerNavigationIsOneKindPerPage() throws {
        var mixed: [String] = []
        for rootPath in Self.roots {
            let root = Self.packageRoot.appendingPathComponent(rootPath)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(Self.packageRoot.path.count + 1))
                let components = relative.split(separator: "/")
                if rootPath == "Views", components.count > 1, Self.excludedFolders.contains(String(components[1])) {
                    continue
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("SettingsTabsRow("), text.contains(/SettingsDrillIn(Host|Rows|List)\(/) {
                    mixed.append(relative)
                }
            }
        }
        #expect(mixed.isEmpty, "Pages mixing header tabs and drill-in rows: \(mixed.sorted())")
    }

    /// The ⋯ overflow menu is the trailing control of its row (Apple HIG).
    /// Covers direct `SettingsOverflowMenu(` calls and `some View` properties
    /// that wrap one.
    @Test func overflowMenuIsTheLastAction() throws {
        var misplaced: [String] = []
        for rootPath in Self.roots {
            let root = Self.packageRoot.appendingPathComponent(rootPath)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(Self.packageRoot.path.count + 1))
                if relative.hasPrefix("Views/DesignSystem/") { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                guard text.contains("SettingsOverflowMenu(") else { continue }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for line in Self.overflowMenusFollowedBySiblings(lines) {
                    misplaced.append("\(relative):\(line)")
                }
            }
        }
        #expect(
            misplaced.isEmpty,
            "Overflow menu is not the last control in its row:\n\(misplaced.joined(separator: "\n"))"
        )
    }

    @Test func overflowCheckFlagsATrailingSibling() {
        func lines(_ text: String) -> [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
        let source = """
                SettingsButton(.secondary, "History") {}
                SettingsOverflowMenu(help: "More") {
                    Button(L("Import")) {}
                }
                .settingsLandingAnchor("a")
                SettingsButton(.primary, "Add") {}
            } secondaryRow: {
            }
            """
        #expect(Self.overflowMenusFollowedBySiblings(lines(source)) == [2])

        let fixed = """
                SettingsButton(.primary, "Add") {}
                SettingsOverflowMenu(help: "More") {
                    Button(L("Import")) {}
                }
                .settingsLandingAnchor("a")
            } secondaryRow: {
            """
        #expect(Self.overflowMenusFollowedBySiblings(lines(fixed)).isEmpty)
    }

    static func overflowMenusFollowedBySiblings(_ lines: [Substring]) -> [Int] {
        func indent(_ line: Substring) -> Int { line.prefix { $0 == " " }.count }
        func trimmed(_ line: Substring) -> Substring { line.drop { $0 == " " } }

        var wrappers: Set<Substring> = []
        for (index, line) in lines.enumerated() where index + 1 < lines.count {
            guard trimmed(lines[index + 1]).hasPrefix("SettingsOverflowMenu(") else { continue }
            if let match = line.firstMatch(of: /var (\w+): some View \{$/) { wrappers.insert(match.1) }
        }

        let controls = [
            "SettingsButton(", "SettingsMenuButton(", "SettingsIconButton(", "Button(", "Button {", "Menu", "Toggle("
        ]
        let trailers = ["}", ".", ")", "//"]
        var offenders: [Int] = []
        for (index, line) in lines.enumerated() {
            let head = trimmed(line)
            guard head.hasPrefix("SettingsOverflowMenu(") || wrappers.contains(head) else { continue }
            let level = indent(line)
            for next in lines[(index + 1)...] {
                let body = trimmed(next)
                if body.isEmpty || indent(next) > level { continue }
                if indent(next) < level { break }
                if trailers.contains(where: { body.hasPrefix($0) }) { continue }
                if controls.contains(where: { body.hasPrefix($0) }) { offenders.append(index + 1) }
                break
            }
        }
        return offenders
    }

    @Test func allowlistOnlyNamesExistingFilesAndRules() {
        let ruleIds = Set((Self.rules + Self.tokenRules).map(\.id))
        for (file, ids) in SettingsKitLintBaseline.allowlist {
            #expect(
                FileManager.default.fileExists(atPath: Self.packageRoot.appendingPathComponent(file).path),
                "allowlisted file no longer exists: \(file)"
            )
            #expect(ids.isSubset(of: ruleIds), "unknown rule in allowlist for \(file): \(ids.subtracting(ruleIds))")
        }
    }

    static func writeBaseline(_ counts: [String: [String: Int]]) throws {
        var body = ""
        for rule in rules + tokenRules {
            let files = counts[rule.id] ?? [:]
            guard !files.isEmpty else { continue }
            body += "        \"\(rule.id)\": [\n"
            for file in files.keys.sorted() {
                body += "            \"\(file)\": \(files[file]!),\n"
            }
            body += "        ],\n"
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("SettingsKitLintBaseline.swift")
        let existing = try String(contentsOf: url, encoding: .utf8)
        guard let start = existing.range(of: "    static let counts: [String: [String: Int]] = ["),
            let end = existing.range(of: "    ]\n    // END COUNTS", range: start.upperBound..<existing.endIndex)
        else { return }
        let replacement = "    static let counts: [String: [String: Int]] = [\n" + (body.isEmpty ? "        :\n" : body)
        let updated = existing.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: replacement)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }
}

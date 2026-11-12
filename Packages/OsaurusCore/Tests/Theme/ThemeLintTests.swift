//
//  ThemeLintTests.swift
//  osaurusTests
//
//  Zero-tolerance checks that keep the semantic theme roles the only colour,
//  material and motion source. Scans every Swift source in the package
//  except tests; a rule may name the single file that legitimately owns the
//  pattern.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ThemeLintTests {
    struct Rule: Sendable {
        let id: String
        let fix: String
        /// Package-relative path prefix the rule applies to; nil for all.
        var scope: String? = nil
        /// Package-relative files that own the pattern; an entry ending in
        /// `/` allows the whole directory.
        let allowedFiles: Set<String>
        let hints: [String]
        let pattern: @Sendable (Substring) -> Bool
    }

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .resolvingSymlinksInPath()

    static let excludedTopLevel: Set<String> = ["Tests", "DesignLibraryTests", ".build", "Resources"]

    /// The design inspector's own chrome and overlays, which must never read
    /// as the design under edit.
    static let inspectorChrome: Set<String> = [
        "DevelopmentDesign/",
        "Models/Theme/DesignLibrary/CatalogNativeTargets.swift",
        "Models/Theme/DesignLibrary/CatalogPreviewInspection.swift",
        "Models/Theme/DesignLibrary/DesignEffectStyles.swift",
        "Models/Theme/InspectionAdapters/InspectorAttachmentStyle.swift",
    ]

    /// Theme-independent colour owners.
    static let paletteOwners: Set<String> = inspectorChrome.union([
        "Models/Theme/FixedPalette.swift",
        "Models/Theme/BrandPalette.swift",
    ])

    /// Output that leaves the app (exports, screenshots, PDF annotations)
    /// or seeds fixtures; it never renders inside a themed window.
    static let offscreenRenderers: Set<String> = [
        "Managers/Chat/ChatSessionExporter.swift",
        "Services/Documents/MarkdownRichTextRenderer.swift",
        "Services/Documents/PDFEditor.swift",
        "ComputerUse/Driver/Mac/Screenshot.swift",
        "Utils/MockChatData.swift",
    ]

    static let deletedTypes = [
        "SettingsSidebarSearchField", "StatusBadge", "PanelStatusPill", "CircularIconButton",
        "PanelPillButtonStyle", "PillButtonStyle", "ShimmerProgressBar", "MinimalProgressViewStyle",
        "ToastProgressStyle", "OptionChip",
    ]

    /// Names of the v6 `ThemeProtocol` bridges and the theme fields that
    /// only survive inside the legacy decoder.
    static let legacyMembers = [
        "primaryText", "secondaryText", "tertiaryText", "placeholderText",
        "primaryBackground", "secondaryBackground", "tertiaryBackground",
        "sidebarBackground", "sidebarSelectedBackground", "cardBackground", "inputBackground",
        "codeBlockBackground", "accentColor", "accentColorLight", "primaryBorder", "secondaryBorder",
        "cardBorder", "inputBorder", "focusBorder", "successColor", "warningColor", "errorColor",
        "infoColor", "selectionColor", "cursorColor", "shadowColor", "shadowOpacity",
        "cardShadowRadius", "cardShadowY", "animationDurationQuick", "animationDurationMedium",
        "animationDurationSlow", "animationSpringResponse", "animationSpringDamping", "animationSpring",
        "primaryFontName", "monoFontName", "titleSize", "headingSize", "bodySize", "smallBodySize",
        "captionSize", "codeSize", "agentNameSize", "bubbleCornerRadius", "inlineAvatarSize",
        "defaultBorderWidth", "cardCornerRadius", "inputCornerRadius", "followsSystemAccent",
        "glassEnabled", "glassOpacity", "edgeLight", "windowBackingOpacity",
    ]

    static let rules: [Rule] = {
        let members = Set(legacyMembers)
        let deleted = Set(deletedTypes)
        let colorExempt = paletteOwners.union(offscreenRenderers)
        return [
            Rule(
                id: "hueColor",
                fix: "theme.dataInk(seed:) for hashed identity colours, or a BrandPalette entry",
                allowedFiles: colorExempt,
                hints: ["ue:"]
            ) { line in
                line.contains(/\bColor\(hue:|NSColor\((?:calibrated|device)?[Hh]ue:/)
            },
            Rule(
                id: "hardcodedColor",
                fix: "a theme role, a data swatch, or a BrandPalette / FixedPalette entry",
                allowedFiles: colorExempt,
                hints: ["Color("]
            ) { line in
                line.contains(/\bColor\((?:red|white|hex):|\bColor\(\.sRGB|NSColor\((?:calibrated|srgb|device)?(?:Red|White|red|white):/)
            },
            Rule(
                id: "systemColor",
                fix: "a theme role (text.*, status.*, surface.*) or theme.dataInk(_:) for categorical hues",
                allowedFiles: colorExempt,
                hints: ["Color", "(."]
            ) { line in
                line.contains(
                    /\bColor\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|primary|secondary|white|black)\b/
                )
                    || line.contains(
                        /(?:foregroundColor|foregroundStyle|fill|stroke|strokeBorder|tint|background)\(\s*\.(?:red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black)\b/
                    )
                    || line.contains(
                        /NSColor\.(?:system[A-Z]\w*|labelColor|secondaryLabelColor|tertiaryLabelColor|quaternaryLabelColor|white|black|red|green|blue|orange|gray)\b/
                    )
            },
            Rule(
                id: "hierarchicalStyle",
                fix: "theme.text.primary / .secondary / .tertiary",
                allowedFiles: colorExempt,
                hints: ["foregroundStyle", "Hierarchical"]
            ) { line in
                line.contains(/foregroundStyle\(\s*\.(?:primary|secondary|tertiary|quaternary)\b|HierarchicalShapeStyle/)
            },
            Rule(
                id: "alphaWash",
                fix: "a wash role: status.*.background, selection.*, surface.*, or theme.dataWash(_:)",
                allowedFiles: colorExempt,
                hints: ["opacity(", "withAlphaComponent("]
            ) { line in
                line.contains(
                    /(?:NSColor\(\s*(?:context\.)?theme[^)]*\)|theme\.[\w.]+)\.(?:withAlphaComponent|opacity)\(\s*0?\.\d/
                )
            },
            Rule(
                id: "fixedFont",
                fix: "a theme type role (.textStyle(_:), SettingsFont, theme.font)",
                allowedFiles: inspectorChrome.union(offscreenRenderers).union([
                    // The share card renders to an image at a fixed poster size.
                    "Views/Template/WorkflowShareCardView.swift"
                ]),
                hints: ["ize:"]
            ) { line in
                line.contains(
                    /\bFont\.system\(size:|\.font\(\.system\(size:|NSFont\.(?:systemFont|monospacedSystemFont|boldSystemFont|monospacedDigitSystemFont)\(ofSize:\s*[\d.]+/
                )
            },
            Rule(
                id: "numericGlyph",
                fix: "a ThemeGlyphSize step",
                allowedFiles: inspectorChrome,
                hints: ["glyphSize(points:"]
            ) { line in
                line.contains(/glyphSize\(points:\s*[\d.]+/)
            },
            Rule(
                id: "cornerRadiusLiteral",
                fix: "theme.radius.small / .medium / .large / .xlarge",
                allowedFiles: inspectorChrome,
                hints: ["ornerRadius"]
            ) { line in
                line.contains(/cornerRadius:\s*[\d.]+\b|\.cornerRadius\(\s*[\d.]+\)/)
            },
            Rule(
                id: "numericPadding",
                fix: "theme.space.sN",
                allowedFiles: inspectorChrome,
                hints: [".padding("]
            ) { line in
                line.contains(
                    /\.padding\(\s*(?:\.(?:horizontal|vertical|top|bottom|leading|trailing|all)\s*,\s*)?[\d.]+\s*\)/
                ) || line.contains(/\.padding\(\s*(?:\.\w+\s*,\s*)?[^)]*\?\s*[\d.]+\s*:\s*[\d.]+/)
            },
            Rule(
                id: "numericSpacing",
                fix: "theme.space.sN",
                allowedFiles: inspectorChrome,
                hints: ["pacing:"]
            ) { line in
                line.contains(/spacing:\s*[1-9][\d.]*\b|spacing:\s*[^,)]*\?\s*[\d.]+\s*:\s*[\d.]+|lineSpacing:\s*[1-9]/)
            },
            Rule(
                id: "rawProgressView",
                fix: "SettingsProgressBar(value:) (nil for indeterminate) or SettingsSpinner",
                allowedFiles: inspectorChrome.union([
                    "Models/Theme/DesignLibrary/InspectorAssignedProgress.swift",
                    "Views/DesignSystem/SettingsIndicators.swift",
                    "Views/DesignSystem/SettingsKitGallery.swift",
                ]),
                hints: ["ProgressView("]
            ) { line in
                line.contains(/\bProgressView\(/)
            },
            Rule(
                id: "deletedComponent",
                fix: "the kit replacement (SidebarSearchField, StatusChip, SettingsIconButton, SettingsProgressBar, FilterChip)",
                allowedFiles: [],
                hints: deletedTypes
            ) { line in
                line.matches(of: /\b[A-Z]\w*\b/).contains { deleted.contains(String($0.0)) }
            },
            Rule(
                id: "componentGlass",
                fix: "solid surface roles; the window's single material lives in WindowMaterialView",
                allowedFiles: [
                    "Views/Common/WindowMaterialView.swift",
                    // The design catalog previews the window material it inspects.
                    "DevelopmentDesign/CatalogInspector.swift",
                    // Onboarding frosts its panels and buttons over the landscape backdrop.
                    "Views/Onboarding/DesignSystem/OnboardingComponents.swift",
                ],
                hints: ["glass", "Glass", "Material", "NSVisualEffectView("]
            ) { line in
                line.contains(/\.glassEffect\(|GlassEffectContainer|glassBackgroundEffect/)
                    || line.contains(/\.(ultraThin|thin|regular|thick|ultraThick|bar)Material\b/)
                    || line.contains(/NSVisualEffectView\(/)
            },
            Rule(
                id: "legacyThemeToken",
                fix: "the semantic role from design/legacy-migration.json (text.*, surface.*, action.*, …)",
                allowedFiles: [],
                hints: ["theme", "Theme"]
            ) { line in
                line.matches(of: /\b(?:theme|currentTheme|chatTheme)\??\.(\w+)\b/).contains {
                    members.contains(String($0.1))
                }
            },
            Rule(
                id: "legacyThemeMember",
                fix: "do not reintroduce v6 bridges; read the role group instead",
                scope: "Models/Theme/",
                // `selectionColor` here is the NSTextView selection, not a v6 bridge.
                allowedFiles: ["Models/Theme/DesignLibrary/InspectorAssignedTextEditor.swift"],
                hints: ["var ", "let ", "func "]
            ) { line in
                line.matches(of: /\b(?:var|let|func)\s+(\w+)\b/).contains { members.contains(String($0.1)) }
            },
            Rule(
                id: "legacyMotionHelper",
                fix: "theme.motion.quick / .standard / .slow / .springAnimation",
                allowedFiles: [],
                hints: ["animation"]
            ) { line in
                line.contains(/\banimation(Quick|Medium|Slow)\(/)
            },
            Rule(
                id: "systemAccent",
                fix: "a theme role: action.primary for actions, text.link, selection.*, border.focus",
                // Inspector chrome stays on the system accent so it never reads as the design under edit.
                allowedFiles: ["DevelopmentDesign/CatalogComponents.swift"],
                hints: ["ccentColor"]
            ) { line in
                line.contains(/Color\.accentColor|controlAccentColor|\.accentColor\(/)
            },
            Rule(
                id: "derivedAccent",
                fix:
                    "selection.background, surface.selected or status.info.background — never a tint of the action fill",
                allowedFiles: [],
                hints: ["action.primary"]
            ) { line in
                line.contains(/action\.primary\.\w+\.background(\))?\.(opacity|withAlphaComponent)\(/)
            },
            Rule(
                id: "literalMetricFallback",
                fix: "theme.space.sN as the fallback of a spacing metric; only sizes stay literal",
                allowedFiles: inspectorChrome,
                hints: ["etric(", "layout("]
            ) { line in
                line.matches(
                    of: /(?:\bmetric\(\s*(?:\d+\s*,\s*)?|\.catalogMetric\(|\.assignedMetric\([^()]*?|\.catalogLayoutMetric\([^()]*?|\blayout\(\s*(?:\d+\s*,\s*)?)"[^"]*"\s*,\s*(?:"[^"]*"\s*,\s*)?(?:fallback:|inheriting:)?\s*-?\d+(?:\.\d+)?\s*[,)]/
                ).contains { call in
                    call.output.matches(of: /"([^"]*)"/).contains { name in
                        let property = name.output.1.split(separator: ".").last ?? ""
                        return property.contains(/padding|gap|inset|spacing|margin|indent/.ignoresCase())
                    }
                }
            },
            Rule(
                id: "localWash",
                fix: "theme.wash(behind:) / theme.rule(around:) or another wash role, never a tint of an ink",
                allowedFiles: colorExempt.union([
                    // Level-driven voice visualizations fade their ink with the input level.
                    "Views/Voice/VoiceComponents.swift",
                    "Views/Voice/VoiceSetupTab.swift",
                ]),
                hints: ["opacity(", "withAlphaComponent("]
            ) { line in
                !line.contains("Gradient") && !line.contains("colors: [")
                    && line.contains(
                        /(?:^|[^.\w])(?:[a-z]\w*(?:Tint|Color|Accent|Ink|Fill)|tint|color|accent|ink|fill)\.(?:opacity|withAlphaComponent)\(\s*0?\.\d/
                    )
            },
            Rule(
                id: "designAssignmentRead",
                fix: "paint from the resolved mappings; the assignment sets are editor bookkeeping",
                allowedFiles: [
                    "DevelopmentDesign/",
                    "Models/Theme/DesignLibrary/DesignLibraryDocument.swift",
                    "Models/Theme/DesignLibrary/DesignLibraryPruning.swift",
                    // Migration keeps a designer's explicit choice over a changed stock role.
                    "Models/Theme/DesignLibrary/CatalogElementAssignments.swift",
                ],
                hints: ["Assignments", "reassigned"]
            ) { line in
                line.contains(/(?:^|[^\w])(?:reassignedProperties|explicitAssignments|editedAssignments)(?:[^\w]|$)/)
            },
        ]
    }()

    /// Rules whose pattern spans a modifier chain, matched against the whole
    /// comment-stripped file.
    struct TextRule: Sendable {
        let id: String
        let fix: String
        let allowedFiles: Set<String>
        let hints: [String]
        let matches: @Sendable (Substring) -> [Range<Substring.Index>]
    }

    static let textRules: [TextRule] = [
        TextRule(
            id: "handDrawnDivider",
            fix: "ThemeHairlineDivider() (axis: .vertical for a column rule)",
            allowedFiles: inspectorChrome,
            hints: ["Divider()", ".border."]
        ) { text in
            text.matches(of: /(?:^|[^\w])Divider\(\)\s*(?:\.\w+\([^()]*\)\s*)*\.opacity\(/).map(\.range)
                + text.matches(
                    of: /Rectangle\(\)\s*\.fill\(\s*(?:[\w.]*\.)?(?:theme|currentTheme)\.border\.\w+\s*\)\s*\.frame\(\s*(?:height|width):\s*(?:1|theme\.stroke\.default)\s*\)/
                ).map(\.range)
                + text.matches(
                    of: /(?:^|[^\w.])(?:theme|currentTheme)\.border\.\w+\s*\.frame\(\s*(?:height|width):\s*1\s*\)/
                ).map(\.range)
        },
    ]

    static func violations() throws -> [String] {
        var found: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: packageRoot, includingPropertiesForKeys: nil)
        else { return found }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
            guard let top = relative.split(separator: "/").first, !excludedTopLevel.contains(String(top))
            else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.firstRange(of: "//").map { line[..<$0.lowerBound] } ?? line
            }
            for rule in rules
            where !isAllowed(relative, by: rule.allowedFiles) && rule.scope.map(relative.hasPrefix) ?? true {
                for (index, line) in lines.enumerated()
                where rule.hints.contains(where: { line.contains($0) }) && rule.pattern(line) {
                    found.append("\(rule.id): \(relative):\(index + 1) — use \(rule.fix)")
                }
            }
            let stripped = Substring(lines.joined(separator: "\n"))
            for rule in textRules
            where !isAllowed(relative, by: rule.allowedFiles) && rule.hints.contains(where: { stripped.contains($0) }) {
                for range in rule.matches(stripped) {
                    let line = stripped[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                    found.append("\(rule.id): \(relative):\(line) — use \(rule.fix)")
                }
            }
        }
        return found
    }

    static func isAllowed(_ relative: String, by allowed: Set<String>) -> Bool {
        allowed.contains { $0.hasSuffix("/") ? relative.hasPrefix($0) : $0 == relative }
    }

    @Test func sourcesUseSemanticRolesOnly() throws {
        let found = try Self.violations()
        #expect(found.isEmpty, "Theme lint:\n\(found.sorted().joined(separator: "\n"))")
    }

    @Test(arguments: [
        ("hueColor", "let c = Color(hue: 0.5, saturation: 1, brightness: 1)"),
        ("hardcodedColor", "let c = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)"),
        ("systemColor", ".foregroundColor(.red)"),
        ("systemColor", "let c = NSColor.secondaryLabelColor"),
        ("hierarchicalStyle", ".foregroundStyle(.secondary)"),
        ("alphaWash", ".background(theme.status.info.foreground.opacity(0.12))"),
        ("fixedFont", ".font(.system(size: 12))"),
        ("numericGlyph", ".glyphSize(points: 14)"),
        ("cornerRadiusLiteral", "RoundedRectangle(cornerRadius: 10)"),
        ("numericPadding", ".padding(.horizontal, 12)"),
        ("numericPadding", ".padding(.horizontal, compact ? 4 : 8)"),
        ("numericSpacing", "VStack(spacing: 6) {"),
        ("rawProgressView", "ProgressView(value: 0.5)"),
        ("deletedComponent", "StatusBadge(status: .ok)"),
        ("literalMetricFallback", "theme.catalogMetric(\"row.paddingX\", fallback: 8)"),
        ("literalMetricFallback", "metric(3, \"gap\", 6, theme)"),
        ("localWash", ".background(tint.opacity(0.12))"),
        ("localWash", ".stroke(statusColor.opacity(0.3))"),
        ("designAssignmentRead", "if document.explicitAssignments?.contains(key) == true {"),
    ])
    func ruleFlagsItsPattern(id: String, sample: String) throws {
        let rule = try #require(Self.rules.first { $0.id == id })
        let line = Substring(sample)
        #expect(rule.hints.contains(where: { line.contains($0) }) && rule.pattern(line))
    }

    @Test(arguments: [
        ("literalMetricFallback", "metric(\"height\", 28, theme)"),
        ("literalMetricFallback", "theme.catalogMetric(\"row.paddingX\", fallback: theme.space.s8)"),
        ("localWash", "Gradient(colors: [tint.opacity(0.4), tint])"),
    ])
    func ruleIgnoresSizesAndGradients(id: String, sample: String) throws {
        let rule = try #require(Self.rules.first { $0.id == id })
        #expect(!rule.pattern(Substring(sample)))
    }

    @Test(arguments: [
        "Divider().opacity(0.5)",
        "Divider()\n    .padding(.horizontal, theme.space.s8)\n    .opacity(0.4)",
        "Rectangle()\n    .fill(theme.border.subtle)\n    .frame(height: 1)",
        "theme.border.default.frame(width: 1)",
    ])
    func dividerRuleFlagsHandDrawnRules(sample: String) throws {
        let rule = try #require(Self.textRules.first { $0.id == "handDrawnDivider" })
        #expect(!rule.matches(Substring(sample)).isEmpty)
        #expect(rule.matches("ThemeHairlineDivider()\n    .opacity(compact ? 0 : 1)").isEmpty)
    }

    @Test func scannerSeesTheWholePackage() throws {
        let probe = Self.packageRoot.appendingPathComponent("Models/Theme/CustomTheme.swift")
        #expect(FileManager.default.fileExists(atPath: probe.path))
    }
}

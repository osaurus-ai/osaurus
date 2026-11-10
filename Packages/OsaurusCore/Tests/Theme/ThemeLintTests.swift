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
        /// Package-relative files that own the pattern.
        let allowedFiles: Set<String>
        let hints: [String]
        let pattern: @Sendable (Substring) -> Bool
    }

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .resolvingSymlinksInPath()

    static let excludedTopLevel: Set<String> = ["Tests", ".build", "Resources"]

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
        return [
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
        ]
    }()

    static func violations() throws -> [String] {
        var found: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: packageRoot, includingPropertiesForKeys: nil)
        else { return found }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
            guard let top = relative.split(separator: "/").first, !excludedTopLevel.contains(String(top))
            else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for rule in rules
            where !rule.allowedFiles.contains(relative) && rule.scope.map(relative.hasPrefix) ?? true {
                for (index, line) in lines.enumerated()
                where rule.hints.contains(where: { line.contains($0) }) && rule.pattern(line) {
                    found.append("\(rule.id): \(relative):\(index + 1) — use \(rule.fix)")
                }
            }
        }
        return found
    }

    @Test func sourcesUseSemanticRolesOnly() throws {
        let found = try Self.violations()
        #expect(found.isEmpty, "Theme lint:\n\(found.sorted().joined(separator: "\n"))")
    }

    @Test func scannerSeesTheWholePackage() throws {
        let probe = Self.packageRoot.appendingPathComponent("Models/Theme/CustomTheme.swift")
        #expect(FileManager.default.fileExists(atPath: probe.path))
    }
}

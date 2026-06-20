//
//  ThemeLibraryManagementService.swift
//  osaurus
//
//  Pure helpers for the Themes management center: provenance summaries,
//  validation, duplicate detection, and Import-by-ID diagnostics.
//

import AppKit
import CryptoKit
import Foundation

public enum ThemeValidationSeverity: String, Codable, Hashable, Sendable {
    case warning
    case error
}

public struct ThemeValidationIssue: Codable, Equatable, Hashable, Sendable {
    public let severity: ThemeValidationSeverity
    public let field: String
    public let message: String

    public init(severity: ThemeValidationSeverity, field: String, message: String) {
        self.severity = severity
        self.field = field
        self.message = message
    }
}

public struct ThemeValidationReport: Codable, Equatable, Sendable {
    public let themeID: UUID
    public let themeName: String
    public let source: ThemeLibrarySource
    public let issues: [ThemeValidationIssue]

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    public var isValid: Bool { errorCount == 0 }
    public var needsReview: Bool { !issues.isEmpty }
}

public struct ThemeDuplicateMember: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let source: ThemeLibrarySource
}

public struct ThemeDuplicateGroup: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let members: [ThemeDuplicateMember]

    public var count: Int { members.count }
}

public struct ThemeLibrarySummary: Codable, Equatable, Sendable {
    public let builtInCount: Int
    public let localCount: Int
    public let importedCount: Int
    public let sharedCount: Int
    public let validationErrorCount: Int
    public let validationWarningCount: Int
    public let duplicateGroupCount: Int

    public static let empty = ThemeLibrarySummary(
        builtInCount: 0,
        localCount: 0,
        importedCount: 0,
        sharedCount: 0,
        validationErrorCount: 0,
        validationWarningCount: 0,
        duplicateGroupCount: 0
    )
}

public enum ThemeImportInputKind: String, Codable, Sendable {
    case empty
    case rawHash
    case deepLink
    case webURL
    case invalid
}

public struct ThemeImportInstalledMatch: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let source: ThemeLibrarySource
}

public struct ThemeImportDiagnostics: Codable, Equatable, Sendable {
    public let kind: ThemeImportInputKind
    public let normalizedHash: String?
    public let deepLinkURL: URL?
    public let serverURL: URL?
    public let installedMatches: [ThemeImportInstalledMatch]

    public var canImport: Bool { normalizedHash != nil }
}

public enum ThemeLibraryManagementService {
    public static func source(for theme: CustomTheme) -> ThemeLibrarySource {
        if theme.isBuiltIn { return .builtIn }
        return theme.library?.source ?? .local
    }

    public static func validationReports(for themes: [CustomTheme]) -> [ThemeValidationReport] {
        themes.map(validate(_:))
    }

    public static func validate(_ theme: CustomTheme) -> ThemeValidationReport {
        var issues: [ThemeValidationIssue] = []

        if theme.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .error, field: "metadata.name", message: "Theme name is required."))
        } else if theme.metadata.name.count > 80 {
            issues.append(.init(severity: .warning, field: "metadata.name", message: "Theme name is very long."))
        }

        if theme.metadata.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .warning, field: "metadata.author", message: "Author is empty."))
        }

        validateColors(theme.colors, issues: &issues)
        validateBackground(theme.background, fallbackBackground: theme.colors.primaryBackground, issues: &issues)
        validateGlass(theme.glass, issues: &issues)
        validateTypography(theme.typography, issues: &issues)
        validateAnimation(theme.animationConfig, issues: &issues)
        validateShadows(theme.shadows, issues: &issues)
        validateMessages(theme.messages, issues: &issues)
        validateBorders(theme.borders, issues: &issues)
        validateLibrary(theme, issues: &issues)

        return ThemeValidationReport(
            themeID: theme.metadata.id,
            themeName: theme.metadata.name,
            source: source(for: theme),
            issues: issues
        )
    }

    public static func duplicateGroups(in themes: [CustomTheme]) -> [ThemeDuplicateGroup] {
        let grouped = Dictionary(grouping: themes) { theme in
            visualFingerprint(for: theme)
        }

        return grouped.compactMap { fingerprint, members -> ThemeDuplicateGroup? in
            guard members.count > 1 else { return nil }
            let sorted = members.sorted {
                $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending
            }
            return ThemeDuplicateGroup(
                id: fingerprint,
                members: sorted.map {
                    ThemeDuplicateMember(
                        id: $0.metadata.id,
                        name: $0.metadata.name,
                        source: source(for: $0)
                    )
                }
            )
        }
        .sorted { lhs, rhs in
            (lhs.members.first?.name ?? "").localizedCaseInsensitiveCompare(rhs.members.first?.name ?? "")
                == .orderedAscending
        }
    }

    public static func summary(
        for themes: [CustomTheme],
        reports: [ThemeValidationReport],
        duplicateGroups: [ThemeDuplicateGroup]
    ) -> ThemeLibrarySummary {
        let sources = themes.map(source(for:))
        return ThemeLibrarySummary(
            builtInCount: sources.filter { $0 == .builtIn }.count,
            localCount: sources.filter { $0 == .local }.count,
            importedCount: sources.filter { $0 == .imported }.count,
            sharedCount: sources.filter { $0 == .shared }.count,
            validationErrorCount: reports.reduce(0) { $0 + $1.errorCount },
            validationWarningCount: reports.reduce(0) { $0 + $1.warningCount },
            duplicateGroupCount: duplicateGroups.count
        )
    }

    public static func diagnoseImportInput(
        _ rawInput: String,
        installedThemes: [CustomTheme]
    ) -> ThemeImportDiagnostics {
        let parsed = parseImportInput(rawInput)
        guard let hash = parsed.hash else {
            return ThemeImportDiagnostics(
                kind: parsed.kind,
                normalizedHash: nil,
                deepLinkURL: nil,
                serverURL: nil,
                installedMatches: []
            )
        }

        let matches =
            installedThemes
            .filter { $0.library?.remoteHash?.lowercased() == hash }
            .sorted { $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending }
            .map {
                ThemeImportInstalledMatch(
                    id: $0.metadata.id,
                    name: $0.metadata.name,
                    source: source(for: $0)
                )
            }

        return ThemeImportDiagnostics(
            kind: parsed.kind,
            normalizedHash: hash,
            deepLinkURL: ThemeShareService.deepLink(for: hash),
            serverURL: ThemesAPIClient.defaultBaseURL.appendingPathComponent("themes/\(hash)"),
            installedMatches: matches
        )
    }

    public static func visualFingerprint(for theme: CustomTheme) -> String {
        let payload = VisualFingerprintPayload(theme: theme)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Validation helpers

    private static func validateColors(_ colors: ThemeColors, issues: inout [ThemeValidationIssue]) {
        let required: [(String, String)] = [
            ("colors.primaryText", colors.primaryText),
            ("colors.secondaryText", colors.secondaryText),
            ("colors.tertiaryText", colors.tertiaryText),
            ("colors.primaryBackground", colors.primaryBackground),
            ("colors.secondaryBackground", colors.secondaryBackground),
            ("colors.tertiaryBackground", colors.tertiaryBackground),
            ("colors.sidebarBackground", colors.sidebarBackground),
            ("colors.sidebarSelectedBackground", colors.sidebarSelectedBackground),
            ("colors.accentColor", colors.accentColor),
            ("colors.accentColorLight", colors.accentColorLight),
            ("colors.primaryBorder", colors.primaryBorder),
            ("colors.secondaryBorder", colors.secondaryBorder),
            ("colors.focusBorder", colors.focusBorder),
            ("colors.successColor", colors.successColor),
            ("colors.warningColor", colors.warningColor),
            ("colors.errorColor", colors.errorColor),
            ("colors.infoColor", colors.infoColor),
            ("colors.cardBackground", colors.cardBackground),
            ("colors.cardBorder", colors.cardBorder),
            ("colors.buttonBackground", colors.buttonBackground),
            ("colors.buttonBorder", colors.buttonBorder),
            ("colors.inputBackground", colors.inputBackground),
            ("colors.inputBorder", colors.inputBorder),
            ("colors.glassTintOverlay", colors.glassTintOverlay),
            ("colors.codeBlockBackground", colors.codeBlockBackground),
            ("colors.shadowColor", colors.shadowColor),
            ("colors.selectionColor", colors.selectionColor),
            ("colors.cursorColor", colors.cursorColor),
        ]

        required.forEach { validateHex($0.1, field: $0.0, issues: &issues) }
        if let placeholder = colors.placeholderText {
            validateHex(placeholder, field: "colors.placeholderText", issues: &issues)
        }
    }

    private static func validateBackground(
        _ background: ThemeBackground,
        fallbackBackground: String,
        issues: inout [ThemeValidationIssue]
    ) {
        switch background.type {
        case .solid:
            validateHex(background.solidColor ?? fallbackBackground, field: "background.solidColor", issues: &issues)
        case .gradient:
            let colors = background.gradientColors ?? []
            if colors.count < 2 {
                issues.append(
                    .init(
                        severity: .error,
                        field: "background.gradientColors",
                        message: "Gradient backgrounds need at least two colors."
                    )
                )
            }
            for (index, color) in colors.enumerated() {
                validateHex(color, field: "background.gradientColors[\(index)]", issues: &issues)
            }
        case .image:
            guard let imageData = background.imageData, !imageData.isEmpty else {
                issues.append(
                    .init(
                        severity: .error,
                        field: "background.imageData",
                        message: "Image backgrounds need image data."
                    )
                )
                break
            }
            guard let data = Data(base64Encoded: imageData) else {
                issues.append(
                    .init(severity: .error, field: "background.imageData", message: "Image data is not valid base64.")
                )
                break
            }
            if data.count > ThemesAPIClient.maxBodyBytes {
                issues.append(
                    .init(
                        severity: .warning,
                        field: "background.imageData",
                        message: "Image data may exceed the share upload limit."
                    )
                )
            }
            if NSImage(data: data) == nil {
                issues.append(
                    .init(severity: .error, field: "background.imageData", message: "Image data could not be decoded.")
                )
            }
        }

        if let overlay = background.overlayColor {
            validateHex(overlay, field: "background.overlayColor", issues: &issues)
        }
        validateUnit(background.imageOpacity, field: "background.imageOpacity", issues: &issues)
        validateUnit(background.overlayOpacity, field: "background.overlayOpacity", issues: &issues)
    }

    private static func validateGlass(_ glass: ThemeGlass, issues: inout [ThemeValidationIssue]) {
        validateRange(glass.blurRadius, 0 ... 120, field: "glass.blurRadius", issues: &issues)
        validateUnit(glass.opacityPrimary, field: "glass.opacityPrimary", issues: &issues)
        validateUnit(glass.opacitySecondary, field: "glass.opacitySecondary", issues: &issues)
        validateUnit(glass.opacityTertiary, field: "glass.opacityTertiary", issues: &issues)
        validateUnit(glass.tintOpacity, field: "glass.tintOpacity", issues: &issues)
        validateUnit(glass.windowBackingOpacity, field: "glass.windowBackingOpacity", issues: &issues)
        validateHex(glass.edgeLight, field: "glass.edgeLight", issues: &issues)
        if let tint = glass.tintColor {
            validateHex(tint, field: "glass.tintColor", issues: &issues)
        }
        if let width = glass.edgeLightWidth {
            validateRange(width, 0 ... 12, field: "glass.edgeLightWidth", issues: &issues)
        }
    }

    private static func validateTypography(_ typography: ThemeTypography, issues: inout [ThemeValidationIssue]) {
        if typography.primaryFont.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .warning, field: "typography.primaryFont", message: "Primary font is empty."))
        }
        if typography.monoFont.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .warning, field: "typography.monoFont", message: "Monospace font is empty."))
        }

        validateRange(typography.titleSize, 8 ... 72, field: "typography.titleSize", issues: &issues)
        validateRange(typography.headingSize, 8 ... 64, field: "typography.headingSize", issues: &issues)
        validateRange(typography.bodySize, 8 ... 36, field: "typography.bodySize", issues: &issues)
        validateRange(typography.captionSize, 8 ... 28, field: "typography.captionSize", issues: &issues)
        validateRange(typography.codeSize, 8 ... 36, field: "typography.codeSize", issues: &issues)
    }

    private static func validateAnimation(_ animation: ThemeAnimation, issues: inout [ThemeValidationIssue]) {
        validateRange(animation.durationQuick, 0 ... 5, field: "animationConfig.durationQuick", issues: &issues)
        validateRange(animation.durationMedium, 0 ... 5, field: "animationConfig.durationMedium", issues: &issues)
        validateRange(animation.durationSlow, 0 ... 5, field: "animationConfig.durationSlow", issues: &issues)
        validateRange(animation.springResponse, 0.01 ... 5, field: "animationConfig.springResponse", issues: &issues)
        validateRange(animation.springDamping, 0 ... 1.5, field: "animationConfig.springDamping", issues: &issues)
    }

    private static func validateShadows(_ shadows: ThemeShadows, issues: inout [ThemeValidationIssue]) {
        validateUnit(shadows.shadowOpacity, field: "shadows.shadowOpacity", issues: &issues)
        validateRange(shadows.cardShadowRadius, 0 ... 80, field: "shadows.cardShadowRadius", issues: &issues)
        validateRange(shadows.cardShadowRadiusHover, 0 ... 100, field: "shadows.cardShadowRadiusHover", issues: &issues)
        validateRange(shadows.cardShadowY, -40 ... 80, field: "shadows.cardShadowY", issues: &issues)
        validateRange(shadows.cardShadowYHover, -40 ... 100, field: "shadows.cardShadowYHover", issues: &issues)
    }

    private static func validateMessages(_ messages: ThemeMessages, issues: inout [ThemeValidationIssue]) {
        validateRange(messages.bubbleCornerRadius, 0 ... 80, field: "messages.bubbleCornerRadius", issues: &issues)
        validateUnit(messages.userBubbleOpacity, field: "messages.userBubbleOpacity", issues: &issues)
        validateUnit(messages.assistantBubbleOpacity, field: "messages.assistantBubbleOpacity", issues: &issues)
        validateRange(messages.borderWidth, 0 ... 12, field: "messages.borderWidth", issues: &issues)
        validateRange(messages.inlineAvatarSize, 10 ... 80, field: "messages.inlineAvatarSize", issues: &issues)
        validateRange(messages.agentNameSize, 8 ... 32, field: "messages.agentNameSize", issues: &issues)
        if let color = messages.userBubbleColor {
            validateHex(color, field: "messages.userBubbleColor", issues: &issues)
        }
        if let color = messages.assistantBubbleColor {
            validateHex(color, field: "messages.assistantBubbleColor", issues: &issues)
        }
    }

    private static func validateBorders(_ borders: ThemeBorders, issues: inout [ThemeValidationIssue]) {
        validateRange(borders.defaultWidth, 0 ... 12, field: "borders.defaultWidth", issues: &issues)
        validateRange(borders.cardCornerRadius, 0 ... 80, field: "borders.cardCornerRadius", issues: &issues)
        validateRange(borders.inputCornerRadius, 0 ... 80, field: "borders.inputCornerRadius", issues: &issues)
        validateUnit(borders.borderOpacity, field: "borders.borderOpacity", issues: &issues)
    }

    private static func validateLibrary(_ theme: CustomTheme, issues: inout [ThemeValidationIssue]) {
        if theme.isBuiltIn, theme.library != nil {
            issues.append(
                .init(severity: .warning, field: "library", message: "Built-in themes ignore library provenance.")
            )
        }

        guard let library = theme.library else { return }
        if library.source == .shared {
            guard let hash = library.remoteHash, ThemeShareService.isValidHash(hash) else {
                issues.append(
                    .init(
                        severity: .warning,
                        field: "library.remoteHash",
                        message: "Shared theme is missing a valid remote ID."
                    )
                )
                return
            }
            if let remoteURL = library.remoteURL, URL(string: remoteURL) == nil {
                issues.append(
                    .init(severity: .warning, field: "library.remoteURL", message: "Shared theme URL is invalid.")
                )
            }
        }
    }

    private static func validateHex(_ value: String, field: String, issues: inout [ThemeValidationIssue]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard [3, 6, 8].contains(body.count), body.allSatisfy(\.isHexDigit) else {
            issues.append(.init(severity: .error, field: field, message: "Expected #RGB, #RRGGBB, or #AARRGGBB."))
            return
        }
        if !trimmed.hasPrefix("#") {
            issues.append(.init(severity: .warning, field: field, message: "Hex colors should include a leading #."))
        }
    }

    private static func validateUnit(_ value: Double?, field: String, issues: inout [ThemeValidationIssue]) {
        guard let value else { return }
        validateUnit(value, field: field, issues: &issues)
    }

    private static func validateUnit(_ value: Double, field: String, issues: inout [ThemeValidationIssue]) {
        validateRange(value, 0 ... 1, field: field, issues: &issues)
    }

    private static func validateRange(
        _ value: Double,
        _ range: ClosedRange<Double>,
        field: String,
        issues: inout [ThemeValidationIssue]
    ) {
        guard range.contains(value), value.isFinite else {
            issues.append(
                .init(
                    severity: .error,
                    field: field,
                    message: "Value must be between \(range.lowerBound) and \(range.upperBound)."
                )
            )
            return
        }
    }

    private static func parseImportInput(_ rawInput: String) -> (kind: ThemeImportInputKind, hash: String?) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (.empty, nil) }

        if ThemeShareService.isValidHash(trimmed) {
            return (.rawHash, trimmed.lowercased())
        }

        guard let url = URL(string: trimmed),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return (.invalid, nil)
        }

        let scheme = url.scheme?.lowercased()
        if scheme == ThemeShareService.deepLinkScheme,
            url.host?.lowercased() == ThemeShareService.deepLinkHost
        {
            let value = components.queryItems?
                .first(where: { $0.name.lowercased() == ThemeShareService.deepLinkHashParam })?
                .value
            guard let value, ThemeShareService.isValidHash(value) else { return (.invalid, nil) }
            return (.deepLink, value.lowercased())
        }

        if scheme == "https" || scheme == "http" {
            let candidate = url.lastPathComponent
            if ThemeShareService.isValidHash(candidate) {
                return (.webURL, candidate.lowercased())
            }
        }

        return (.invalid, nil)
    }
}

private struct VisualFingerprintPayload: Encodable {
    let colors: ThemeColors
    let background: ThemeBackground
    let glass: ThemeGlass
    let typography: ThemeTypography
    let animationConfig: ThemeAnimation
    let shadows: ThemeShadows
    let messages: ThemeMessages
    let borders: ThemeBorders
    let codeHighlightTheme: String?
    let isDark: Bool

    init(theme: CustomTheme) {
        colors = theme.colors
        background = theme.background
        glass = theme.glass
        typography = theme.typography
        animationConfig = theme.animationConfig
        shadows = theme.shadows
        messages = theme.messages
        borders = theme.borders
        codeHighlightTheme = theme.codeHighlightTheme
        isDark = theme.isDark
    }
}

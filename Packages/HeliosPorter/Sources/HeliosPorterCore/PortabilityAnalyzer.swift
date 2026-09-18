import Foundation

public struct PortabilityAnalyzer {
    public let repoRoot: URL

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    public func analyze(slice: SliceDefinition) throws -> PortabilityReport {
        let findings = try slice.sourcePaths.map { relativePath in
            try analyzeFile(relativePath: relativePath)
        }

        let portableCount = findings.filter { $0.classification == .portable }.count
        let adapterCount = findings.filter { $0.classification == .adapter_needed }.count
        let rewriteCount = findings.filter { $0.classification == .rewrite }.count

        return PortabilityReport(
            slice: slice,
            findings: findings,
            summary: PortabilitySummary(
                totalFiles: findings.count,
                portableCount: portableCount,
                adapterNeededCount: adapterCount,
                rewriteCount: rewriteCount
            )
        )
    }

    private func analyzeFile(relativePath: String) throws -> PortabilityFinding {
        let source = try HeliosPorterSupport.readSource(at: relativePath, repoRoot: repoRoot)
        let symbols = HeliosPorterSupport.firstMatches(
            pattern: #"^\s*(?:public\s+)?(?:private\s+)?(?:fileprivate\s+)?(?:internal\s+)?(?:final\s+)?(?:struct|enum|protocol|class|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            in: source
        )

        let classification = classify(relativePath: relativePath, source: source)
        let platformDependencies = dependencies(for: relativePath, source: source)
        let reasons = classificationReasons(
            for: classification,
            relativePath: relativePath,
            source: source,
            platformDependencies: platformDependencies
        )

        return PortabilityFinding(
            sourcePath: relativePath,
            symbols: symbols,
            classification: classification,
            reasons: reasons,
            platformDependencies: platformDependencies,
            bridgeCapabilities: bridgeCapabilities(for: classification, source: source)
        )
    }

    private func classify(relativePath: String, source: String) -> PortabilityClass {
        if relativePath.hasSuffix("ManagementTab.swift") {
            return .portable
        }

        if HeliosPorterSupport.containsAny(
            ["import AppKit", "NSPasteboard", "NSWorkspace", "NSOpenPanel"],
            in: source
        ) {
            return .rewrite
        }

        return .adapter_needed
    }

    private func dependencies(for relativePath: String, source: String) -> [String] {
        if relativePath.hasSuffix("ManagementTab.swift") {
            return ["SwiftUI"]
        }

        var dependencies: [String] = []

        if source.contains("import AppKit") { dependencies.append("AppKit") }
        if source.contains("NSPasteboard") { dependencies.append("NSPasteboard") }
        if source.contains("NSWorkspace") { dependencies.append("NSWorkspace") }
        if source.contains("NSOpenPanel") { dependencies.append("NSOpenPanel") }
        if source.contains("UniformTypeIdentifiers") { dependencies.append("UniformTypeIdentifiers") }
        if source.contains(#"@Environment(\.theme)"#) || source.contains("theme.") {
            dependencies.append("Theme environment")
        }
        if source.contains(".shared") || source.contains("Manager.shared") {
            dependencies.append("Osaurus singleton managers")
        }
        if source.contains("onHover") {
            dependencies.append("Hover interactions")
        }
        if source.contains("AnimatedTabItem") {
            dependencies.append("AnimatedTabItem")
        }
        if source.contains("UnevenRoundedRectangle") {
            dependencies.append("UnevenRoundedRectangle")
        }
        if source.contains("SidebarNavigation") {
            dependencies.append("SidebarNavigation")
        }
        if source.contains("ManagerHeader") || source.contains("HeaderTabsRow") {
            dependencies.append("Manager header primitives")
        }

        if dependencies.isEmpty {
            dependencies.append("SwiftUI")
        }

        return dependencies
    }

    private func classificationReasons(
        for classification: PortabilityClass,
        relativePath: String,
        source: String,
        platformDependencies: [String]
    ) -> [String] {
        switch classification {
        case .portable:
            return [
                "Defines tab metadata and information architecture that can transfer directly into Helios.",
                "Avoids AppKit-only APIs and can be carried into the shared Helios manifest unchanged.",
            ]
        case .adapter_needed:
            var reasons = [
                "Uses SwiftUI-shaped composition that maps well into a Helios management slice, but it still depends on Osaurus-owned styling and navigation primitives.",
            ]

            if platformDependencies.contains("Osaurus singleton managers") {
                reasons.append("Reads live Osaurus singleton managers, so Helios needs its own state and service adapters before the view can be reused.")
            }
            if platformDependencies.contains("Theme environment") {
                reasons.append("Relies on the custom theme environment and shared chrome components that need Windows-native Helios counterparts.")
            }

            if reasons.count == 1 {
                reasons.append("Requires adapter work rather than a full rewrite because its blockers are mostly structural rather than AppKit-bound.")
            }

            return reasons
        case .rewrite:
            var reasons = [
                "Couples the slice directly to macOS-only behavior that cannot move across as-is.",
            ]

            if source.contains("NSPasteboard") {
                reasons.append("Uses NSPasteboard for clipboard flows that must become ClipboardService calls in Helios.")
            }
            if source.contains("NSWorkspace") {
                reasons.append("Uses NSWorkspace for external navigation and file launching, which must be rebound to ExternalLinkService in the Windows bridge.")
            }
            if source.contains("NSOpenPanel") {
                reasons.append("Uses NSOpenPanel for picker-heavy interactions, which need FilePickerService and a redesigned server tools surface.")
            }

            return reasons
        }
    }

    private func bridgeCapabilities(
        for classification: PortabilityClass,
        source: String
    ) -> [BridgeCapability] {
        switch classification {
        case .portable:
            return []
        case .adapter_needed:
            return []
        case .rewrite:
            var capabilities: [BridgeCapability] = []

            if source.contains("NSPasteboard") {
                capabilities.append(.clipboard)
            }
            if source.contains("NSWorkspace") {
                capabilities.append(.externalLink)
            }
            if source.contains("NSOpenPanel") {
                capabilities.append(.filePicker)
            }

            return capabilities
        }
    }
}

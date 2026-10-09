import Foundation

public struct ArchitectureDecisionEngine {
    public init() {}

    public func decide(
        slice: SliceDefinition,
        report: PortabilityReport
    ) -> ArchitectureDecision {
        let bridgeCapabilities = HeliosPorterSupport.deduplicatedBridgeCapabilities(in: report)

        return ArchitectureDecision(
            slice: slice,
            primaryUIFramework: slice.primaryUIFramework,
            windowsBridgePackage: slice.windowsBridgePackagePath,
            bridgeCapabilities: bridgeCapabilities,
            projectionNamespaces: bridgeCapabilities.map(\.projectionNamespace),
            rationale: [
                "`ManagementTab.swift` is already portable and should seed the shared Helios slice manifest directly.",
                "`ManagementView.swift`, `SidebarNavigation.swift`, `ManagerHeader.swift`, `SharedSidebarComponents.swift`, and `AnimatedTabSelector.swift` are SwiftUI-shaped and mainly blocked by Helios-owned state, theme, and chrome adapters.",
                "`ServerView.swift` is the only rewrite-heavy file in this slice, and its blockers line up with narrow Windows platform services rather than a second UI framework.",
            ],
            serverRewriteZones: [
                "Replace `NSPasteboard` copy actions with `ClipboardService`.",
                "Replace `NSWorkspace` launches with `ExternalLinkService`.",
                "Replace `NSOpenPanel` flows with `FilePickerService` and a Windows-native diagnostics flow.",
            ],
            guardrails: [
                "Keep WinRT references and projection scope files inside `Packages/HeliosWindowsBridge`.",
                "Keep `Helios/swiftcrossui` free of WinRT imports and direct Windows API types.",
                "Do not generate a broad WinUI surface; only project the namespaces required by the bridge capabilities.",
            ]
        )
    }
}

import Foundation

public struct ArchitectureDecisionRenderer {
    public init() {}

    public func render(portability: PortabilityReport, architecture: ArchitectureDecision) -> String {
        var lines: [String] = []
        lines.append("# \(portability.slice.displayName) SwiftCrossUI + swift-winrt Architecture")
        lines.append("")
        lines.append("## Decision")
        lines.append("- Primary UI framework: `\(architecture.primaryUIFramework)`")
        lines.append("- Windows bridge package: `\(architecture.windowsBridgePackage)`")
        lines.append("- Shared manifest: `Helios/shared/\(portability.slice.slug).slice.json`")
        lines.append("")
        lines.append("## Why this split")
        architecture.rationale.forEach { lines.append("- \($0)") }
        lines.append("")
        lines.append("## Bridge Capability Order")
        for (index, capability) in architecture.bridgeCapabilities.enumerated() {
            lines.append("\(index + 1). `\(capability.serviceInterface)` via `\(capability.rawValue)`")
        }
        lines.append("")
        lines.append("## Minimal swift-winrt Projection Scope")
        architecture.projectionNamespaces.forEach { lines.append("- `\($0)`") }
        lines.append("")
        lines.append("## ServerView Rewrite Zones")
        architecture.serverRewriteZones.forEach { lines.append("- \($0)") }
        lines.append("")
        lines.append("## Guardrails")
        architecture.guardrails.forEach { lines.append("- \($0)") }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

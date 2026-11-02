import Foundation
@preconcurrency import MLXLMCommon

/// Resolve an explicit agent preference on a copy; never persist it to Server settings.
enum AgentSpeculationPolicy {
    static func resolve(_ enabled: Bool?, inheriting settings: VMLXServerMTPSettings) -> VMLXServerMTPSettings {
        guard let enabled else { return settings }
        var resolved = settings
        resolved.mode = enabled ? .auto : .off
        // Reuse the same adaptive normalization as the existing chat/Server control.
        return enabled ? NativeMTPSelectionDefault.adaptiveSelection(resolved) : resolved
    }

    static func requiresPreparation(
        previous: VMLXServerMTPSettings, next: VMLXServerMTPSettings, hasLoadedStrategy: Bool = false
    ) -> Bool {
        // Off can reuse weights containing a head: requestStrategy disables EVERY drafter.
        guard next.mode != .off else { return false }
        var previous = previous
        var next = next
        // A default-on bundle already has its head/drafter. Do not reload it just to request Auto.
        if hasLoadedStrategy, previous.mode != .off { previous.mode = next.mode }
        // Returning to Default can reuse an On graph; admission decides whether to run its head.
        if next.mode == .familyDefault, previous.mode != .off {
            previous.mode = .auto
            next.mode = .auto
        }
        return ServerController.mtpLoadInputsChanged(previous: previous, next: next)
    }
}

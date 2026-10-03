import Foundation
import MLXLMCommon

/// Immutable bundle evidence captured with the loaded weights. Re-evaluate
/// settings against these same facts for warm requests, without rescanning
/// the model directory or assuming Auto loaded a native head.
struct NativeMTPAdmission: Sendable {
    var configData: Data?
    var jangConfig: JangConfig?
    var status: MTPBundleStatus?
    var externalDrafterSelected = false

    struct Refusal: Error, LocalizedError, Sendable {
        let reason: String

        var errorDescription: String? {
            "Native MTP request refused: \(reason) Choose Off or Auto in Server → Speculative Decoding, "
                + "or select an eligible manual depth in Chat and reload the model."
        }
    }

    func validateLoad(
        settings: VMLXServerRuntimeSettings,
        externalDrafterSelected: Bool
    ) throws {
        // An explicitly selected DFlash drafter is a separate runtime path.
        guard !externalDrafterSelected else { return }
        let launch = settings.resolvedMTPLaunch(configData: configData, jangConfig: jangConfig, status: status)
        if launch.launchMode == .blocked {
            throw Refusal(reason: launch.reason)
        }
    }

    func requestStrategy(
        loaded: DraftStrategy?,
        mtp: VMLXServerMTPSettings
    ) throws -> DraftStrategy? {
        if externalDrafterSelected { return loaded }
        var settings = VMLXServerRuntimeSettings()
        settings.mtp = mtp
        try validateLoad(settings: settings, externalDrafterSelected: false)
        let launch = settings.resolvedMTPLaunch(configData: configData, jangConfig: jangConfig, status: status)
        guard launch.launchMode == .speculative, let recommendation = launch.recommendation else { return nil }
        guard loaded?.usesNativeMTP == true else {
            throw Refusal(reason: "The selected mode requires a native head that is not loaded.")
        }
        return .nativeMTP(depth: recommendation.depth, verifierMode: recommendation.verifierMode)
    }
}

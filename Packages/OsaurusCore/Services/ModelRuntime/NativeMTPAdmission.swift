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
    /// The loaded bundle, so a drafter it ships in `dflash/` is found.
    var modelDirectory: URL? = nil

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

    /// The DFlash 2 drafter a request made now would use — a selected folder
    /// that fits, else the bundle's own unless it is turned off.
    func dflash2Selection(mtp: VMLXServerMTPSettings) -> VMLXDFlash2DrafterInfo? {
        var settings = VMLXServerRuntimeSettings()
        settings.mtp = mtp
        return settings.resolvedDFlash2Selection(configData: configData, modelDirectory: modelDirectory)
    }

    /// One line for the resolved-state readout when a drafter is involved:
    /// which one drafts, or why the bundle's own does not. `nil` when there
    /// is no drafter to talk about.
    func dflash2Status(mtp: VMLXServerMTPSettings) -> String? {
        if let selection = dflash2Selection(mtp: mtp) {
            let bundled = modelDirectory.map {
                URL(fileURLWithPath: selection.path).standardizedFileURL
                    == $0.appendingPathComponent(VMLXDFlash2DrafterInfo.bundledFolderName).standardizedFileURL
            } ?? false
            return bundled
                ? "The DFlash 2 drafter this model ships with drafts for it."
                : "The selected DFlash 2 drafter drafts for this model."
        }
        var settings = VMLXServerRuntimeSettings()
        settings.mtp = mtp
        return settings.dflash2RejectionReason(configData: configData, modelDirectory: modelDirectory)
    }

    func requestStrategy(
        loaded: DraftStrategy?,
        mtp: VMLXServerMTPSettings
    ) throws -> DraftStrategy? {
        // A drafter is resolved per request: turning the bundled one off (or
        // back on) applies to the next message, with no reload — its weights
        // load on first use and the model's own graph is unchanged.
        if let selection = dflash2Selection(mtp: mtp) {
            return .dflash2(
                drafterPath: URL(fileURLWithPath: selection.path),
                blockSize: mtp.dflash2BlockSize
            )
        }
        if externalDrafterSelected { return nil }
        var settings = VMLXServerRuntimeSettings()
        settings.mtp = mtp
        try validateLoad(settings: settings, externalDrafterSelected: false)
        let launch = settings.resolvedMTPLaunch(configData: configData, jangConfig: jangConfig, status: status)
        guard launch.launchMode == .speculative, let recommendation = launch.recommendation else { return nil }
        // Loaded with a drafter that no longer applies: whether the native
        // head was loaded alongside it is not recorded, so decode normally
        // rather than refuse a request the user just turned speculation off
        // for.
        if loaded?.dflash2DrafterPath != nil { return nil }
        guard loaded?.usesNativeMTP == true else {
            throw Refusal(reason: "The selected mode requires a native head that is not loaded.")
        }
        return .nativeMTP(depth: recommendation.depth, verifierMode: recommendation.verifierMode)
    }
}

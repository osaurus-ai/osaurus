//
//  ImportSettings.swift
//  osaurus
//
//  Where `PendingImportProcessor` reads and writes the settings a bundle
//  may change (`BundleSetting.all`), through the same stores the Settings
//  controls use.
//

import Foundation
@preconcurrency import MLXLMCommon
import OsaurusRepository

@MainActor
protocol ImportSettingsAccess: AnyObject {
    func value(of setting: BundleSetting) -> BundleSettingValue
    func set(_ value: BundleSettingValue, for setting: BundleSetting)
    func hasAccessKeys() -> Bool
    /// Runs the parts of `set` that restart the server. Called once the
    /// import has answered, so a live `/admin/import/apply` is not cut off
    /// by its own restart.
    func applyDeferredChanges() async
}

@MainActor
final class LiveImportSettings: ImportSettingsAccess {
    static let shared = LiveImportSettings()

    /// Runtime settings saved to disk but not yet handed to the server.
    private var pendingRuntimeSettings: VMLXServerRuntimeSettings?

    private var runtimeSettings: VMLXServerRuntimeSettings {
        pendingRuntimeSettings ?? ServerController.runtimeSettingsForConfigureTool().settings
    }

    func value(of setting: BundleSetting) -> BundleSettingValue {
        switch setting.id {
        case .requireLocalAccessKey:
            return .bool(LocalAPIKeyPolicy.isEnabled())
        case .allowedOrigins:
            // "*" is the editor's placeholder for an empty list; the server
            // never treats it as an origin.
            return .strings(runtimeSettings.network.corsOrigins.filter { $0 != "*" })
        }
    }

    func set(_ value: BundleSettingValue, for setting: BundleSetting) {
        switch (setting.id, value) {
        case (.requireLocalAccessKey, .bool(let enabled)):
            LocalAPIKeyPolicy.setEnabled(enabled)
        case (.allowedOrigins, .strings(let origins)):
            var settings = runtimeSettings
            settings.network.corsOrigins = origins.isEmpty ? ["*"] : origins
            ServerRuntimeSettingsStore.save(settings)
            pendingRuntimeSettings = settings
        default:
            assertionFailure("\(setting.key) does not take \(value)")
        }
    }

    func hasAccessKeys() -> Bool {
        !APIKeyManager.shared.listKeys().isEmpty
    }

    func applyDeferredChanges() async {
        guard let settings = pendingRuntimeSettings else { return }
        pendingRuntimeSettings = nil
        _ = await ServerController.applyRuntimeSettingsFromConfigureTool(settings)
    }
}

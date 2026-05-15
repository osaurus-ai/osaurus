//
//  UpdaterService.swift
//  osaurus
//
//  Created by Terence on 8/21/25.
//

import Foundation
import Sparkle

@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    nonisolated private static let betaUpdatesKey = "betaUpdatesEnabled"

    lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    // MARK: - Published State for Update Availability
    @Published var updateAvailable: Bool = false
    @Published var availableVersion: String? = nil

    @Published var isBetaChannel: Bool {
        didSet {
            UserDefaults.standard.set(isBetaChannel, forKey: Self.betaUpdatesKey)
            updaterController.updater.resetUpdateCycle()
            NSLog("Sparkle: update channel changed to %@", isBetaChannel ? "beta" : "release")
        }
    }

    override init() {
        self.isBetaChannel = UserDefaults.standard.bool(forKey: Self.betaUpdatesKey)
        super.init()
    }

    /// Opens the Sparkle update UI to check and install updates.
    ///
    /// if a background update session is already in flight (which happens
    /// when the settings window has just been opened), `SPUUpdater` reports
    /// `canCheckForUpdates == false` and silently drops user initiated
    /// checks. wait briefly for the in-flight session to settle so the
    /// click reliably surfaces the Sparkle dialog on the first try
    func checkForUpdates() {
        let updater = updaterController.updater
        if updater.canCheckForUpdates {
            updaterController.checkForUpdates(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if self.updaterController.updater.canCheckForUpdates {
                    self.updaterController.checkForUpdates(nil)
                    return
                }
            }
        }
    }

    /// Silently checks for updates in the background without showing UI
    func checkForUpdatesInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let beta = UserDefaults.standard.bool(forKey: Self.betaUpdatesKey)
        return beta ? Set(["release", "beta"]) : Set(["release"])
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://osaurus-ai.github.io/osaurus/appcast.xml"
    }

    // MARK: - Verbose Logging Hooks

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog(
            "Sparkle: didFindValidUpdate version=%@ short=%@",
            item.versionString,
            item.displayVersionString
        )
        let version = item.displayVersionString
        Task { @MainActor in
            self.updateAvailable = true
            self.availableVersion = version
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NSLog("Sparkle: didNotFindUpdate")
        Task { @MainActor in
            self.updateAvailable = false
            self.availableVersion = nil
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsErr = error as NSError
        NSLog(
            "Sparkle: didAbortWithError domain=%@ code=%ld desc=%@ userInfo=%@",
            nsErr.domain,
            nsErr.code,
            nsErr.localizedDescription,
            nsErr.userInfo as NSDictionary
        )
        if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
            NSLog(
                "Sparkle: underlyingError domain=%@ code=%ld desc=%@ userInfo=%@",
                underlying.domain,
                underlying.code,
                underlying.localizedDescription,
                underlying.userInfo as NSDictionary
            )
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        NSLog(
            "Sparkle: willDownloadUpdate version=%@ url=%@",
            item.versionString,
            request.url?.absoluteString ?? "nil"
        )
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        NSLog("Sparkle: didDownloadUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        NSLog("Sparkle: willExtractUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        NSLog("Sparkle: didExtractUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        NSLog("Sparkle: willInstallUpdate version=%@", item.versionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishInstallingUpdate item: SUAppcastItem) {
        NSLog("Sparkle: didFinishInstallingUpdate version=%@", item.versionString)
    }
}

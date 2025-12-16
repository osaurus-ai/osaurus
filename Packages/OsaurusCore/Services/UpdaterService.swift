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
    lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    // MARK: - Published State for Update Availability
    @Published var updateAvailable: Bool = false
    @Published var availableVersion: String? = nil

    override init() {
        super.init()
    }

    /// Opens the Sparkle update UI to check and install updates
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Silently checks for updates in the background without showing UI
    func checkForUpdatesInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return Set(["release"])
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://dinoki-ai.github.io/osaurus/appcast.xml"
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

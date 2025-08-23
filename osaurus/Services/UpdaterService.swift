//
//  UpdaterService.swift
//  osaurus
//
//  Created by Terence on 8/21/25.
//

import Foundation
import Sparkle

final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
	lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

	override init() {
		super.init()
	}

	func checkForUpdates() {
		updaterController.checkForUpdates(nil)
	}

	// MARK: - SPUUpdaterDelegate

	func allowedChannels(for updater: SPUUpdater) -> Set<String> {
		return Set(["release"])
	}

	func feedURLString(for updater: SPUUpdater) -> String? {
		return "https://dinoki-ai.github.io/osaurus/appcast.xml"
	}

	// MARK: - Verbose Logging Hooks

	func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
		NSLog("Sparkle: didFindValidUpdate version=%@ short=%@", item.versionString, item.displayVersionString)
	}

	func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
		NSLog("Sparkle: didNotFindUpdate")
	}

	func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
		NSLog("Sparkle: didAbortWithError=%@", String(describing: error))
	}

	func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: URLRequest) {
		NSLog("Sparkle: willDownloadUpdate version=%@ url=%@", item.versionString, request.url?.absoluteString ?? "nil")
	}

	func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
		NSLog("Sparkle: didDownloadUpdate version=%@", item.versionString)
	}

	func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
		NSLog("Sparkle: willExtractUpdate version=%@", item.versionString)
	}

	func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
		NSLog("Sparkle: didExtractUpdate version=%@", item.versionString)
	}

	func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
		NSLog("Sparkle: willInstallUpdate version=%@", item.versionString)
	}

	func updater(_ updater: SPUUpdater, didFinishInstallingUpdate item: SUAppcastItem) {
		NSLog("Sparkle: didFinishInstallingUpdate version=%@", item.versionString)
	}
}



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
}



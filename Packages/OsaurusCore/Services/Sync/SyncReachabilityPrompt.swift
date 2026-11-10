//
//  SyncReachabilityPrompt.swift
//  osaurus
//
//  When the first iPhone joins the sync account, asks once whether to turn
//  on Anywhere (Beta). With Same Network the iPhone reaches this Mac only on
//  the same Wi-Fi, which is rarely where a phone is.
//

import Combine
import Foundation

@MainActor
final class SyncReachabilityPrompt {
    static let shared = SyncReachabilityPrompt()

    static let askedDefaultsKey = "syncAnywherePromptAsked"
    /// How long to wait before asking again when another dialog is up.
    private static let busyRetry: Duration = .seconds(30)

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var retryTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        guard cancellables.isEmpty else { return }
        SyncPhoneDevices.shared.$hasPhone
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { hasPhone in MainActor.assumeIsolated { SyncReachabilityPrompt.shared.consider(hasPhone: hasPhone) } }
            .store(in: &cancellables)
    }

    /// Whether to ask: an iPhone is in the account, sync is on and only finds
    /// devices on the same network, and the user hasn't been asked.
    nonisolated static func shouldAsk(hasPhone: Bool, configuration: SyncConfiguration, asked: Bool) -> Bool {
        hasPhone && !asked && configuration.networkEnabled && configuration.networkMode == .localNetworkOnly
    }

    func consider(hasPhone: Bool) {
        let asked = defaults.bool(forKey: Self.askedDefaultsKey)
        guard Self.shouldAsk(hasPhone: hasPhone, configuration: SyncConfigurationStore.load(), asked: asked) else {
            return
        }
        guard !ThemedAlertCenter.shared.hasAnyActiveAlert else {
            retryTask?.cancel()
            retryTask = Task { @MainActor in
                try? await Task.sleep(for: Self.busyRetry)
                guard !Task.isCancelled else { return }
                SyncReachabilityPrompt.shared.consider(hasPhone: SyncPhoneDevices.shared.hasPhone)
            }
            return
        }
        defaults.set(true, forKey: Self.askedDefaultsKey)
        present()
    }

    static var title: String { L("Reach this Mac from anywhere?") }

    static var message: String {
        L(
            "Your iPhone joined this Mac's sync. With Same Network it reaches this Mac only on the same Wi-Fi. Anywhere (Beta) also connects through Osaurus relay and discovery servers, so your iPhone can use this Mac's agents from any network, cellular included. Chats stay end-to-end encrypted. You can change this in Settings → Sharing → Devices → Find Devices."
        )
    }

    static var confirmTitle: String { L("Turn On Anywhere") }

    /// The focused chat window, else Settings, else the screen-level overlay,
    /// like the app's other one-time prompts: the overlay floats above other
    /// apps, so it's only for when no Osaurus window is up.
    static func scope(
        focusedChat: UUID?,
        chatVisible: (UUID) -> Bool,
        managementVisible: Bool
    ) -> ThemedAlertScope {
        if let focusedChat, chatVisible(focusedChat) { return .chat(focusedChat) }
        if managementVisible { return .management }
        return .toastOverlay
    }

    private func present() {
        let id = UUID()
        let scope = Self.scope(
            focusedChat: ChatWindowManager.shared.lastFocusedWindowId,
            chatVisible: { ChatWindowManager.shared.getNSWindow(id: $0)?.isVisible == true },
            managementVisible: WindowManager.shared.isVisible(.management)
        )
        ThemedAlertCenter.shared.present(
            ThemedAlertRequest(
                id: id,
                title: Self.title,
                message: Self.message,
                buttons: [
                    .cancel(L("Not Now")),
                    .primary(Self.confirmTitle) { SyncStatusModel.shared.setNetworkMode(.anywhere) },
                ],
                onDismiss: { ThemedAlertCenter.shared.dismiss(scope: scope, id: id) }
            ),
            scope: scope
        )
    }

    #if DEBUG
        func _resetForTesting() {
            cancellables.removeAll()
            retryTask?.cancel()
            retryTask = nil
        }
    #endif
}

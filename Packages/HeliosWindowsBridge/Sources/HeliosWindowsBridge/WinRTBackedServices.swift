import Foundation

struct WinRTProjectionScope: Equatable {
    let serviceInterface: String
    let namespace: String
}

enum HeliosWindowsBridgePlan {
    static let projectionOrder = [
        WinRTProjectionScope(
            serviceInterface: "ClipboardService",
            namespace: "Windows.ApplicationModel.DataTransfer"
        ),
        WinRTProjectionScope(
            serviceInterface: "ExternalLinkService",
            namespace: "Windows.System"
        ),
        WinRTProjectionScope(
            serviceInterface: "FilePickerService",
            namespace: "Windows.Storage.Pickers"
        ),
    ]
}

struct WinRTClipboardService: ClipboardService {
    func copy(_ text: String) {
        // TODO(Helios): Implement with swift-winrt projections for Windows.ApplicationModel.DataTransfer.
    }
}

struct WinRTExternalLinkService: ExternalLinkService {
    func open(_ url: String) {
        // TODO(Helios): Implement with swift-winrt projections for Windows.System launcher APIs.
    }
}

struct WinRTFilePickerService: FilePickerService {
    func pickFile(_ request: FilePickerRequest) -> String? {
        // TODO(Helios): Implement with swift-winrt projections for Windows.Storage.Pickers.
        return nil
    }
}

extension PlatformServices {
    static func winRTBacked() -> PlatformServices {
        PlatformServices(
            clipboard: WinRTClipboardService(),
            links: WinRTExternalLinkService(),
            server: PlaceholderServerControlService(),
            navigation: PlaceholderSettingsNavigationService(),
            filePicker: WinRTFilePickerService()
        )
    }
}

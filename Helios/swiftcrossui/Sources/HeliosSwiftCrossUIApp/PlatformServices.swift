import Foundation

struct FilePickerRequest: Equatable {
    let title: String
    let allowedExtensions: [String]
}

protocol ClipboardService {
    func copy(_ text: String)
}

protocol ExternalLinkService {
    func open(_ url: String)
}

protocol ServerControlService {
    func currentStatus() -> String
    func localServerURL() -> String
    func refreshStatus()
}

protocol SettingsNavigationService {
    func showServerOverview()
    func showAPIReference()
}

protocol FilePickerService {
    func pickFile(_ request: FilePickerRequest) -> String?
}

struct PlatformServices {
    let clipboard: ClipboardService
    let links: ExternalLinkService
    let server: ServerControlService
    let navigation: SettingsNavigationService
    let filePicker: FilePickerService
}

struct PlaceholderClipboardService: ClipboardService {
    func copy(_ text: String) {}
}

struct PlaceholderExternalLinkService: ExternalLinkService {
    func open(_ url: String) {}
}

struct PlaceholderServerControlService: ServerControlService {
    func currentStatus() -> String { "Unknown" }
    func localServerURL() -> String { "http://127.0.0.1:1337" }
    func refreshStatus() {}
}

struct PlaceholderSettingsNavigationService: SettingsNavigationService {
    func showServerOverview() {}
    func showAPIReference() {}
}

struct PlaceholderFilePickerService: FilePickerService {
    func pickFile(_ request: FilePickerRequest) -> String? { nil }
}

extension PlatformServices {
    static let placeholder = PlatformServices(
        clipboard: PlaceholderClipboardService(),
        links: PlaceholderExternalLinkService(),
        server: PlaceholderServerControlService(),
        navigation: PlaceholderSettingsNavigationService(),
        filePicker: PlaceholderFilePickerService()
    )
}

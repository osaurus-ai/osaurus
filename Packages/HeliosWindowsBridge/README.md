# HeliosWindowsBridge

This package is the only Helios boundary that should touch `swift-winrt` scope files, generated projections, or Windows-native API adapters.

## Responsibilities
- `ClipboardService` first
- `ExternalLinkService` second
- `FilePickerService` third

## Shared Service Surface
- `ClipboardService`, `ExternalLinkService`, `ServerControlService`, `SettingsNavigationService`, `FilePickerService`

## Projection Policy
- Keep projection scope limited to the namespaces listed in `projections/swift-winrt-scope.json`.
- Do not leak WinRT types into `Helios/swiftcrossui`.
- Add concrete adapters incrementally behind the shared service protocols.

# Management/Settings SwiftCrossUI + swift-winrt Architecture

## Decision
- Primary UI framework: `SwiftCrossUI`
- Windows bridge package: `Packages/HeliosWindowsBridge`
- Shared manifest: `Helios/shared/management-settings.slice.json`

## Why this split
- `ManagementTab.swift` is already portable and should seed the shared Helios slice manifest directly.
- `ManagementView.swift`, `SidebarNavigation.swift`, `ManagerHeader.swift`, `SharedSidebarComponents.swift`, and `AnimatedTabSelector.swift` are SwiftUI-shaped and mainly blocked by Helios-owned state, theme, and chrome adapters.
- `ServerView.swift` is the only rewrite-heavy file in this slice, and its blockers line up with narrow Windows platform services rather than a second UI framework.

## Bridge Capability Order
1. `ClipboardService` via `clipboard`
2. `ExternalLinkService` via `external_link`
3. `FilePickerService` via `file_picker`

## Minimal swift-winrt Projection Scope
- `Windows.ApplicationModel.DataTransfer`
- `Windows.System`
- `Windows.Storage.Pickers`

## ServerView Rewrite Zones
- Replace `NSPasteboard` copy actions with `ClipboardService`.
- Replace `NSWorkspace` launches with `ExternalLinkService`.
- Replace `NSOpenPanel` flows with `FilePickerService` and a Windows-native diagnostics flow.

## Guardrails
- Keep WinRT references and projection scope files inside `Packages/HeliosWindowsBridge`.
- Keep `Helios/swiftcrossui` free of WinRT imports and direct Windows API types.
- Do not generate a broad WinUI surface; only project the namespaces required by the bridge capabilities.

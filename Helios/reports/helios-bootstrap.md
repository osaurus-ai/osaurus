# Helios Bootstrap Report

## Current Slice
- Slice: Management/Settings
- Portability mix: 1 portable, 5 adapter_needed, 1 rewrite
- Primary UI framework: `SwiftCrossUI`
- Windows bridge package: `Packages/HeliosWindowsBridge`

## Portability Inventory
| File | Class | Key blockers | Bridge capabilities |
| --- | --- | --- | --- |
| Packages/OsaurusCore/Views/Management/ManagementView.swift | `adapter_needed` | Theme environment, Osaurus singleton managers, SidebarNavigation | - |
| Packages/OsaurusCore/Models/Configuration/ManagementTab.swift | `portable` | SwiftUI | - |
| Packages/OsaurusCore/Views/Settings/ServerView.swift | `rewrite` | AppKit, NSPasteboard, NSWorkspace, NSOpenPanel, UniformTypeIdentifiers, Theme environment, Osaurus singleton managers, AnimatedTabItem, Manager header primitives | clipboard, external_link, file_picker |
| Packages/OsaurusCore/Views/Management/SidebarNavigation.swift | `adapter_needed` | Theme environment, Hover interactions, SidebarNavigation | - |
| Packages/OsaurusCore/Views/Management/ManagerHeader.swift | `adapter_needed` | Theme environment, AnimatedTabItem, Manager header primitives | - |
| Packages/OsaurusCore/Views/Management/SharedSidebarComponents.swift | `adapter_needed` | Theme environment, UnevenRoundedRectangle | - |
| Packages/OsaurusCore/Views/Common/AnimatedTabSelector.swift | `adapter_needed` | Theme environment, Hover interactions, AnimatedTabItem | - |

## Architecture Decision
- UI shell and management layout stay in `Helios/swiftcrossui`.
- Windows-native clipboard, shell launch, and picker flows move into `Packages/HeliosWindowsBridge`.
- Keep `swift-winrt` projection scope limited to Windows.ApplicationModel.DataTransfer, Windows.System, Windows.Storage.Pickers.

## Next Slices
- chat_surface
- app_shell
- platform_services

## Top Windows Blockers
- Replace AppKit clipboard, shell, and picker flows in `ServerView.swift` with Windows-native platform services.
- Rebind `ManagementView.swift` away from Osaurus singleton managers and onto Helios-owned application state.
- Recreate the theme, sidebar, and header primitives as Helios-owned Windows-native chrome instead of copying the macOS shell directly.
- Keep `swift-winrt` projection scope narrow so the bridge package only covers clipboard, external links, and file picking.

## Generated Outputs
- Helios/shared/management-settings.slice.json
- Helios/swiftcrossui
- Packages/HeliosWindowsBridge
- Helios/reports/swiftcrossui-winrt-architecture.md

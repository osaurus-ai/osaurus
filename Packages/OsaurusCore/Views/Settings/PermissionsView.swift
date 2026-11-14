//
//  PermissionsView.swift
//  osaurus
//
//  System permissions management view.
//

import SwiftUI

// MARK: - Permissions View

struct PermissionsView: View {
    @ObservedObject private var permissionService = SystemPermissionService.shared

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Permissions",
                subtitle: "Manage system permissions for plugins and features",
                onRefresh: { permissionService.refreshAllPermissions() },
                refreshHelp: "Refresh permission status"
            )
        } content: {
            SettingsSection(
                title: "System Permissions",
                subtitle:
                    "Some plugins require additional system permissions to function. Grant permissions below to enable advanced features like automation, calendar access, and more.",
                anchorId: "permissions.tools"
            ) {
                ForEach(SystemPermission.allCases, id: \.rawValue) { permission in
                    SettingsPermissionRow(permission: permission, showsTest: true)
                }
            }
        }
        .onAppear { permissionService.startPeriodicRefresh(interval: 2.0) }
        .onDisappear { permissionService.stopPeriodicRefresh() }
    }
}

#if DEBUG && canImport(PreviewsMacros)
    #Preview {
        PermissionsView()
    }
#endif

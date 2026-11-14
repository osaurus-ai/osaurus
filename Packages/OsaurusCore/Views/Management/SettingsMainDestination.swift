//
//  SettingsMainDestination.swift
//  osaurus
//
//  Settings as a destination of the chat window, beside Chat and
//  Workflows: its sidebar takes the column the chat sidebar uses (same
//  width, fill and resize handle) and its pages sit on the chat canvas
//  under the window's titlebar strip.
//

import SwiftUI

struct SettingsMainDestination: View, Equatable {
    let topInset: CGFloat
    let sidebarWidth: CGFloat
    let isSidebarCollapsed: Bool
    let sidebarWidthRange: ClosedRange<Double>
    @Binding var storedSidebarWidth: Double
    @Binding var liveSidebarWidth: Double?

    /// The chat view re-renders on every streamed token; the settings
    /// shell only needs to when its column changes.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.topInset == rhs.topInset && lhs.sidebarWidth == rhs.sidebarWidth
            && lhs.isSidebarCollapsed == rhs.isSidebarCollapsed
    }

    var body: some View {
        if let app = AppDelegate.shared {
            ManagementView(
                column: SidebarNavigationColumn(
                    topInset: topInset,
                    expandedWidth: sidebarWidth,
                    isCollapsed: isSidebarCollapsed,
                    resizeHandle: AnyView(
                        ColumnResizeHandle(
                            edge: .trailing,
                            range: sidebarWidthRange,
                            storedWidth: $storedSidebarWidth,
                            liveWidth: $liveSidebarWidth
                        )
                    )
                )
            )
            .environmentObject(app.serverController)
            .environmentObject(app.updater)
        }
    }
}

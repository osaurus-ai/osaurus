//
//  ManagementStateManager.swift
//  osaurus
//
//  Manages the session state for the management interface.
//

import Foundation
import Combine

/// Manages the session state for the management interface.
@MainActor
public final class ManagementStateManager: ObservableObject {
    public static let shared = ManagementStateManager()

    /// Persists the last selected tab within the current app session.
    @Published public var selectedTab: ManagementTab = .settings

    /// One-shot request to focus a specific sub-tab inside `VoiceView`.
    /// VoiceView observes this and resets it to nil after applying.
    @Published public var voiceSubTabRequest: String?

    /// One-shot request to open the detail page for a specific plugin id from a deeplink.
    /// `PluginsView` observes this and resets it to nil after applying.
    @Published public var pendingPluginDetailId: String?

    /// One-shot request to open the schedule editor for a specific schedule id.
    /// `SchedulesView` observes this and resets it to nil after applying. Used
    /// by the Claude plugin import summary to deep-link to schedules that
    /// landed disabled because no cron expression was found.
    @Published public var pendingScheduleEditId: UUID?

    private init() {}
}

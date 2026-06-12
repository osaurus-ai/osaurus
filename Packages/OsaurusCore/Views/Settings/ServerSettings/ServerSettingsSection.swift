//
//  ServerSettingsSection.swift
//  osaurus
//
//  Anchor + grouping model for the Server → Settings sidebar
//  navigation. Each case is the `.id(...)` of one section card in
//  `ServerSettingsTabContent`; the sidebar uses these to render the
//  left rail and to drive `ScrollViewReader.scrollTo(...)`.
//

import SwiftUI

/// One anchor row in the Server → Settings sidebar. Order of the
/// `allCases` array is also the visual order in the panel (sidebar +
/// scroll content), so keep new cases inserted in the position they
/// should render.
enum ServerSettingsSection: String, CaseIterable, Hashable, Identifiable {
    case connection
    case globalProxy
    case authentication
    case sampling
    case concurrency
    case cache
    case memorySafety
    case decodePerformance
    case speculative
    case liveActivity
    case multimodal
    case tools
    case modelMemory
    case power
    case requestLimits

    var id: String { rawValue }

    /// User-facing row title.
    var title: String {
        switch self {
        case .connection: return L("Connection")
        case .globalProxy: return L("Global Proxy")
        case .authentication: return L("Authentication")
        case .sampling: return L("Sampling Defaults")
        case .concurrency: return L("Concurrency & Batching")
        case .cache: return L("Cache")
        case .memorySafety: return L("Memory Safety")
        case .decodePerformance: return L("Decode Performance")
        case .speculative: return L("Speculative Decoding")
        case .liveActivity: return L("Live Activity")
        case .multimodal: return L("Multimodal")
        case .tools: return L("Tools & Templates")
        case .modelMemory: return L("Model Memory")
        case .power: return L("Power & Sleep")
        case .requestLimits: return L("Request Limits")
        }
    }

    /// SF Symbol used for the sidebar row icon.
    var icon: String {
        switch self {
        case .connection: return "network"
        case .globalProxy: return "shield.lefthalf.filled"
        case .authentication: return "key.horizontal"
        case .sampling: return "slider.horizontal.3"
        case .concurrency: return "gauge.with.dots.needle.bottom.0percent"
        case .cache: return "externaldrive.connected.to.line.below"
        case .memorySafety: return "memorychip.fill"
        case .decodePerformance: return "speedometer"
        case .speculative: return "bolt.horizontal"
        case .liveActivity: return "waveform.path.ecg"
        case .multimodal: return "photo.on.rectangle.angled"
        case .tools: return "wrench.and.screwdriver"
        case .modelMemory: return "memorychip"
        case .power: return "powersleep"
        case .requestLimits: return "shield.lefthalf.filled"
        }
    }

    var group: ServerSettingsSectionGroup {
        switch self {
        case .connection, .globalProxy, .authentication:
            return .server
        case .sampling:
            return .generation
        case .concurrency, .cache, .memorySafety, .decodePerformance, .speculative, .liveActivity:
            return .performance
        case .multimodal, .tools:
            return .capabilities
        case .modelMemory, .power, .requestLimits:
            return .lifecycle
        }
    }
}

/// Sidebar group header. Order here drives the visual order of groups
/// in the sidebar; sections inside a group preserve `ServerSettingsSection.allCases` order.
enum ServerSettingsSectionGroup: String, CaseIterable, Hashable {
    case server
    case generation
    case performance
    case capabilities
    case lifecycle

    var title: String {
        switch self {
        case .server: return L("Server")
        case .generation: return L("Generation")
        case .performance: return L("Performance")
        case .capabilities: return L("Capabilities")
        case .lifecycle: return L("Lifecycle")
        }
    }

    /// Sections in this group, preserving `ServerSettingsSection.allCases` order.
    var sections: [ServerSettingsSection] {
        ServerSettingsSection.allCases.filter { $0.group == self }
    }
}

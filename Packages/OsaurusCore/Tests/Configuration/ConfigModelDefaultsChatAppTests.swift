//
//  ConfigModelDefaultsChatAppTests.swift
//  OsaurusCoreTests
//
//  The `model_defaults`, `chat`, and `app` document sections: hotkey text,
//  validation, apply → export round trips against the same stores the
//  Settings pages write, and the catalog rows that point at them.
//

import Carbon.HIToolbox
import Foundation
import Testing

@testable import OsaurusCore

struct HotkeyTextTests {

    @Test
    func parse_readsModifiersAndKey() throws {
        let hotkey = try HotkeyText.parse("cmd+shift+o").get()
        #expect(hotkey.keyCode == UInt32(kVK_ANSI_O))
        #expect(hotkey.carbonModifiers == UInt32(cmdKey) | UInt32(shiftKey))
        #expect(hotkey.displayString == "⌘⇧O")

        let spaced = try HotkeyText.parse(" Command + Option + Space ").get()
        #expect(spaced.displayString == "⌘⌥Space")
    }

    @Test
    func glyphForm_matchesTheShippedDefault() throws {
        #expect(try HotkeyText.parse("⌘;").get() == ChatConfiguration.default.hotkey)
        #expect(try HotkeyText.parse("cmd+;").get() == ChatConfiguration.default.hotkey)
    }

    @Test
    func parse_rejectsUnusableHotkeys() {
        for bad in ["shift+a", "a", "cmd+", "cmd+hyper", "hyper+a", "cmd+escape", ""] {
            guard case .failure = HotkeyText.parse(bad) else {
                Issue.record("`\(bad)` should not parse")
                continue
            }
        }
    }

    @Test
    func text_roundTripsEveryKey() throws {
        for key in HotkeyText.keys {
            let hotkey = try HotkeyText.parse("ctrl+\(key.names[0])").get()
            #expect(try HotkeyText.parse(HotkeyText.text(for: hotkey)).get() == hotkey, "\(key.names[0])")
        }
        let defaultHotkey = try #require(ChatConfiguration.default.hotkey)
        #expect(HotkeyText.text(for: defaultHotkey) == "cmd+;")
    }
}

@Suite(.serialized)
@MainActor
struct ConfigModelDefaultsChatAppTests {

    private static func apply(_ mutate: (inout OsaurusConfigDocument) -> Void) async -> [ConfigApplyResult] {
        var document = OsaurusConfigDocument()
        mutate(&document)
        return await ConfigApplier.apply(document: document, prune: false)
    }

    private static func expectNoFailures(_ results: [ConfigApplyResult]) {
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
    }

    private static func expectIdempotentExport(sections: Set<ConfigSectionID>) throws {
        let scoped = ConfigExporter.export().filtered(to: sections)
        let plan = try ConfigPlanner.plan(document: scoped, prune: false)
        #expect(plan.isEmpty, "expected no-op plan, got:\n\(plan.summaryText())")
    }

    private static func planIssues(_ mutate: (inout OsaurusConfigDocument) -> Void) -> [String] {
        var document = OsaurusConfigDocument()
        mutate(&document)
        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            return []
        } catch let error as ConfigPlanIssues {
            return error.issues
        } catch {
            return ["unexpected error: \(error)"]
        }
    }

    @Test
    func yaml_decodesTheNewSections() throws {
        let document = try ConfigYAML.decode(
            """
            model_defaults:
              core_model: null
            chat:
              smooth_streaming: false
              keep_mac_awake: true
            app:
              hotkey: "cmd+shift+o"
              show_notifications: false
            """)
        #expect(document.modelDefaults?.coreModel == .null)
        #expect(document.chat?.smoothStreaming == false)
        #expect(document.chat?.keepMacAwake == true)
        #expect(document.app?.hotkey == .value("cmd+shift+o"))
        #expect(document.app?.showNotifications == false)
        #expect(document.app?.startAtLogin == nil)
    }

    @Test
    func invalidValues_failPlanning() {
        let issues = Self.planIssues { document in
            var app = AppSection()
            app.hotkey = .value("shift+a")
            document.app = app
            var roles = ModelDefaultsSection()
            roles.coreModel = .value("no-such-provider-\(UUID().uuidString.prefix(6))/model")
            document.modelDefaults = roles
        }
        #expect(issues.contains { $0.contains("app.hotkey") }, "\(issues)")
        #expect(issues.contains { $0.contains("model_defaults.core_model") }, "\(issues)")
    }

    @Test
    func chat_applyThenExportRoundTrip() async throws {
        let before = try #require(ConfigExporter.export().chat)
        var desired = ChatSection()
        desired.smoothStreaming = !(before.smoothStreaming ?? true)
        desired.groupActivity = !(before.groupActivity ?? true)
        desired.expandThinking = !(before.expandThinking ?? false)
        desired.spellCheck = !(before.spellCheck ?? false)
        desired.autoTitles = !(before.autoTitles ?? true)
        desired.followUpSuggestions = !(before.followUpSuggestions ?? true)
        desired.clipboardMonitoring = !(before.clipboardMonitoring ?? true)
        desired.keepMacAwake = !(before.keepMacAwake ?? true)

        Self.expectNoFailures(await Self.apply { $0.chat = desired })

        #expect(ConfigExporter.export().chat == desired)
        #expect(ContentBlock.ActivityRollupSetting.isEnabled == desired.groupActivity)
        #expect(ComposerSpellCheckSetting.isEnabled == desired.spellCheck)
        #expect(AgentRunPowerManager.isKeepAwakeEnabled() == desired.keepMacAwake)
        #expect(ChatConfigurationStore.load().enableClipboardMonitoring == desired.clipboardMonitoring)
        try Self.expectIdempotentExport(sections: [.chat])

        _ = await Self.apply { $0.chat = before }
        #expect(ConfigExporter.export().chat == before)
    }

    @Test
    func modelDefaults_storeThePickerPairAndClear() async throws {
        let original = ChatConfigurationStore.load()
        defer { ChatConfigurationStore.save(original) }

        var roles = ModelDefaultsSection()
        roles.coreModel = .value("Foundation")
        roles.compactionModel = .null
        Self.expectNoFailures(await Self.apply { $0.modelDefaults = roles })

        let stored = ChatConfigurationStore.load()
        #expect(stored.coreModelProvider == nil)
        #expect(stored.coreModelName == "foundation")
        #expect(stored.compactionModelIdentifier == nil)
        #expect(ConfigExporter.export().modelDefaults?.coreModel == .value("foundation"))
        try Self.expectIdempotentExport(sections: [.modelDefaults])

        var clear = ModelDefaultsSection()
        clear.coreModel = .null
        Self.expectNoFailures(await Self.apply { $0.modelDefaults = clear })
        #expect(ChatConfigurationStore.load().coreModelIdentifier == nil)
        #expect(ConfigExporter.export().modelDefaults?.coreModel == .null)
    }

    @Test
    func app_hotkeyAndNotificationsRoundTrip() async throws {
        let originalChat = ChatConfigurationStore.load()
        let originalToast = ToastManager.shared.configuration
        defer {
            ChatConfigurationStore.save(originalChat)
            ToastManager.shared.updateConfiguration(originalToast)
        }

        var app = AppSection()
        app.hotkey = .value("Control+Option+K")
        app.showNotifications = !originalToast.enabled
        Self.expectNoFailures(await Self.apply { $0.app = app })

        #expect(ChatConfigurationStore.load().hotkey?.displayString == "⌥⌃K")
        #expect(ToastManager.shared.configuration.enabled == !originalToast.enabled)
        let exported = try #require(ConfigExporter.export().app)
        #expect(exported.hotkey == .value("option+ctrl+k"))
        #expect(exported.showNotifications == !originalToast.enabled)
        try Self.expectIdempotentExport(sections: [.app])

        var off = AppSection()
        off.hotkey = .null
        Self.expectNoFailures(await Self.apply { $0.app = off })
        #expect(ChatConfigurationStore.load().hotkey == nil)
        #expect(ConfigExporter.export().app?.hotkey == .null)
    }

    /// A hotkey recorded on another keyboard layout has no text form and
    /// exports as its display string; re-applying that export must stay a
    /// no-op instead of failing validation.
    @Test
    func app_unparseableStoredHotkeyReappliesAsNoOp() async throws {
        let original = ChatConfigurationStore.load()
        defer { ChatConfigurationStore.save(original) }
        var config = original
        config.hotkey = Hotkey(keyCode: 999, carbonModifiers: UInt32(cmdKey), displayString: "⌘ß")
        ChatConfigurationStore.save(config)

        #expect(ConfigExporter.export().app?.hotkey == .value("⌘ß"))
        try Self.expectIdempotentExport(sections: [.app])
        let results = await Self.apply { $0.app = ConfigExporter.export().app }
        Self.expectNoFailures(results)
        #expect(ChatConfigurationStore.load().hotkey?.keyCode == 999)
    }

    @Test
    func catalogRows_pointAtRealSections() {
        let sections = Set(ConfigSectionID.allNames)
        for entry in SettingsSearchIndex.entries {
            guard let section = entry.declarativeSection else { continue }
            #expect(sections.contains(section), "\(entry.id) names unknown section `\(section)`")
        }
        let expected: [String: String] = [
            "settings.general.hotkey": "app",
            "settings.general.login": "app",
            "settings.notifications.toasts": "app",
            "settings.general.coreModel": "model_defaults",
            "settings.chat.compactionModel": "model_defaults",
            "settings.chat.smoothStreaming": "chat",
            "settings.chat.activityRollup": "chat",
            "settings.chat.thinkingDisplay": "chat",
            "settings.chat.spellCheck": "chat",
            "settings.chat.autoGenerateTitles": "chat",
            "settings.chat.generateFollowUps": "chat",
            "settings.chat.clipboard": "chat",
            "settings.chat.keepAwakeForAgentRuns": "chat",
        ]
        for (id, section) in expected {
            let entry = SettingsSearchIndex.entries.first { $0.id == id }
            #expect(entry?.declarativeSection == section, "\(id)")
        }
    }
}

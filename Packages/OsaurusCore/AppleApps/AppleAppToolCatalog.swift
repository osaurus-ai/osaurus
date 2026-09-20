//
//  AppleAppToolCatalog.swift
//  osaurus
//
//  Builds every built-in Apple app tool for `ToolRegistry.registerBuiltInTools`.
//  All tools are always registered (so the runtime can execute them and the
//  Tools tab can show their policies); `SystemPromptComposer.resolveTools`
//  strips the ones whose app the agent has not enabled.
//

import Foundation

enum AppleAppToolCatalog {
    /// Every Apple tool, in `AppleApp.allCases` order.
    static func makeTools() -> [OsaurusTool] {
        var tools: [OsaurusTool] = []
        tools += CalendarToolFactory.makeTools()
        tools += RemindersToolFactory.makeTools()
        tools += ContactsToolFactory.makeTools()
        tools += NotesToolFactory.makeTools()
        tools += MailToolFactory.makeTools()
        tools += MessagesToolFactory.makeTools()
        tools += MapsToolFactory.makeTools()
        tools += WeatherToolFactory.makeTools()
        tools += MusicToolFactory.makeTools()
        tools += ShortcutsToolFactory.makeTools()
        return tools
    }

    /// Sanity check used by tests: every registered tool name is declared on
    /// its app, and every declared name has a tool.
    static func undeclaredOrMissingNames(in tools: [OsaurusTool]) -> (undeclared: Set<String>, missing: Set<String>) {
        let names = Set(tools.map(\.name))
        return (names.subtracting(AppleApp.allToolNames), AppleApp.allToolNames.subtracting(names))
    }
}

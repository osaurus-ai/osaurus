import Testing

@testable import OsaurusCore

/// A settings entry a user cannot find by typing the words it displays is
/// invisible in practice. That is how the Sampling Defaults / Live Activity
/// pair went unreachable for "sampler" — see
/// `searchFindsSamplerByTheWordShownOnScreen`.
///
/// This sweeps the whole index rather than naming entries, so an entry added
/// later inherits the guarantee instead of needing its own test.
@Suite("settings search self-findability")
struct SettingsSearchSelfFindProbe {

    @Test("every entry is findable by its own title")
    func everyEntryFindsItselfByTitle() {
        let unfindable = SettingsSearchIndex.entries
            .filter { entry in
                !SettingsSearchIndex.search(entry.title).contains { $0.id == entry.id }
            }
            .map(\.id)

        #expect(unfindable.isEmpty, "entries not found by their own title: \(unfindable)")
    }

    /// Section is optional — several entries are the whole tab and carry an
    /// empty one. Only entries that actually display a section header are
    /// required to be reachable by it.
    @Test("every entry with a section header is findable by that header")
    func everyEntryFindsItselfBySection() {
        let unfindable = SettingsSearchIndex.entries
            .filter { !$0.section.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { entry in
                !SettingsSearchIndex.search(entry.section).contains { $0.id == entry.id }
            }
            .map(\.id)

        #expect(unfindable.isEmpty, "entries not found by their own section: \(unfindable)")
    }

    /// Titles and section headers are not what the user reads. The Cache
    /// section passed both sweeps above on its title "Prompt Cache" while
    /// `0 settings match "disk cache"` — every control inside it is labelled
    /// "Disk Cache", "SSD Cache (L2)", "Disk Cache Size (% of disk)" or
    /// "Clear SSD Cache", and none of those resolved. An entry can be
    /// self-findable and still unreachable by every word on screen.
    ///
    /// So this pins the CONTROL labels, which the sweeps structurally cannot
    /// see. Add a row whenever a control is added or renamed.
    @Test("controls are findable by the label they display")
    func controlsFindableByOnScreenLabel() {
        let labels: [(query: String, entryID: String)] = [
            ("disk cache", "server.cache"),
            ("ssd cache", "server.cache"),
            ("disk cache size", "server.cache"),
            ("clear ssd cache", "server.cache"),
            ("gpu cache", "server.cache"),
            ("context window cap", "settings.chat.contextLength"),
            ("max context", "settings.chat.contextLength"),
            ("kv retention", "settings.chat.contextLength"),
            ("metadata fallback", "settings.chat.contextLength"),
            // Reasoning was unfindable by every one of its own words while
            // three real controls existed: Reasoning Parser Override, Expand
            // Thinking While Streaming, Group Thinking & Tool Activity.
            ("reasoning", "server.tools"),
            ("reasoning parser", "server.tools"),
            ("effort", "server.tools"),
            ("preserve thinking", "server.tools"),
            ("thinking", "settings.chat.thinkingDisplay"),
            // The control that makes every tool always allowed. It had no
            // entry at all, and "tool calls" matched Max Tool Attempts —
            // a wrong-destination hit, which is worse than no hit.
            ("auto allow", "settings.chat.autoAllowAllTools"),
            ("allow all tools", "settings.chat.autoAllowAllTools"),
            ("always allow", "settings.chat.autoAllowAllTools"),
            ("approve tools", "settings.chat.autoAllowAllTools"),
        ]

        let missed = labels.filter { label in
            !SettingsSearchIndex.search(label.query).contains { $0.id == label.entryID }
        }
        .map { "\"\($0.query)\" -> \($0.entryID)" }

        #expect(missed.isEmpty, "control labels that find nothing: \(missed)")
    }

    /// Guards the probe itself: an index that shrank to nothing, or a matcher
    /// that started returning everything, would pass both sweeps vacuously.
    @Test("the sweep runs against a real index and a discriminating matcher")
    func sweepIsNotVacuous() {
        #expect(SettingsSearchIndex.entries.count > 50)
        #expect(SettingsSearchIndex.search("zzzznotasetting").isEmpty)
        // The label sweep above is only meaningful if a plausible-but-absent
        // label still fails — otherwise it would pass on any index.
        #expect(SettingsSearchIndex.search("disk cache turbo mode").isEmpty)
    }
}

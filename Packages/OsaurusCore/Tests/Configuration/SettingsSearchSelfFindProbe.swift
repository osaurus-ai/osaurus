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

    /// Guards the probe itself: an index that shrank to nothing, or a matcher
    /// that started returning everything, would pass both sweeps vacuously.
    @Test("the sweep runs against a real index and a discriminating matcher")
    func sweepIsNotVacuous() {
        #expect(SettingsSearchIndex.entries.count > 50)
        #expect(SettingsSearchIndex.search("zzzznotasetting").isEmpty)
    }
}

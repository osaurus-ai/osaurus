//
//  CoreMLLoadSentinelTests.swift
//  osaurus
//
//  A Core ML crash while the speech models load at launch (macOS 27.0.x,
//  `MLE5ProgramLibrary` null dereference) used to repeat on every launch:
//  `LaunchGuard` had already marked startup complete, so its safe mode never
//  engaged. These tests pin the marker that breaks that loop.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct CoreMLLoadSentinelTests {
    private func freshDefaults() -> UserDefaults {
        let name = "CoreMLLoadSentinelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func clean_defaults_report_no_crashed_load() {
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        let defaults = freshDefaults()
        #expect(CoreMLLoadSentinel.crashedLoad(.speech, defaults: defaults) == nil)
        #expect(CoreMLLoadSentinel.crashedLoad(.tts, defaults: defaults) == nil)
    }

    @Test func load_that_never_returned_is_reported_to_the_next_process() {
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        let defaults = freshDefaults()
        CoreMLLoadSentinel.begin(.speech, modelId: "v3", defaults: defaults, osBuild: "26A434")

        // While this process's own load runs it is not a crashed load.
        #expect(CoreMLLoadSentinel.crashedLoad(.speech, defaults: defaults, osBuild: "26A434") == nil)

        // The process dies inside Core ML; the next launch sees the marker.
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        #expect(
            CoreMLLoadSentinel.crashedLoad(.speech, defaults: defaults, osBuild: "26A434")
                == .init(modelId: "v3", osBuild: "26A434")
        )
        // Other slots are unaffected.
        #expect(CoreMLLoadSentinel.crashedLoad(.tts, defaults: defaults, osBuild: "26A434") == nil)
    }

    @Test func finished_load_leaves_no_marker() {
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        let defaults = freshDefaults()
        CoreMLLoadSentinel.begin(.tts, modelId: "pocket-tts", defaults: defaults, osBuild: "b")
        CoreMLLoadSentinel.end(.tts, defaults: defaults)
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        #expect(CoreMLLoadSentinel.crashedLoad(.tts, defaults: defaults, osBuild: "b") == nil)
    }

    @Test func overlapping_loads_keep_the_marker_until_the_last_one_ends() {
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        let defaults = freshDefaults()
        CoreMLLoadSentinel.begin(.speech, modelId: "v3", defaults: defaults, osBuild: "b")
        CoreMLLoadSentinel.begin(.speech, modelId: "v3", defaults: defaults, osBuild: "b")
        CoreMLLoadSentinel.end(.speech, defaults: defaults)
        // One load is still running; if the process dies now the marker must remain.
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        #expect(CoreMLLoadSentinel.crashedLoad(.speech, defaults: defaults, osBuild: "b") != nil)
    }

    @Test func a_new_os_build_retries_automatically() {
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        let defaults = freshDefaults()
        CoreMLLoadSentinel.begin(.speech, modelId: "v3", defaults: defaults, osBuild: "26A434")
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        #expect(CoreMLLoadSentinel.crashedLoad(.speech, defaults: defaults, osBuild: "26B100") == nil)
    }

    /// End to end through `SpeechService`: after a launch died mid-load the
    /// automatic load is skipped (no Core ML call) and says why.
    @Test @MainActor func speech_service_skips_the_automatic_load_after_a_crashed_load() async throws {
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        let defaults = UserDefaults.standard
        let key = CoreMLLoadSentinel.defaultsKey(.speech)
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
            CoreMLLoadSentinel.forgetInProcessLoadsForTesting()
        }

        CoreMLLoadSentinel.begin(.speech, modelId: "v3")
        CoreMLLoadSentinel.forgetInProcessLoadsForTesting()

        let service = SpeechService.shared
        let loaded = try await service.loadModelAutomatically("v3")
        #expect(loaded == false)
        #expect(service.isLoadingModel == false)
        #expect(service.lastError?.isEmpty == false)
    }
}

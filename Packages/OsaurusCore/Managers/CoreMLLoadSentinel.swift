//
//  CoreMLLoadSentinel.swift
//  osaurus
//
//  Remembers a Core ML model load that was still running when the process
//  died, so the next launch does not repeat it automatically.
//
//  The FluidAudio speech models (Parakeet ASR + Silero VAD, PocketTTS) are
//  loaded automatically at launch and when the chat input appears. On some
//  macOS 27.0.x Macs Core ML segfaults inside its on-device program
//  compilation (`MLE5ProgramLibrary` → `makeProgramWithMemoryLayout`, null
//  dereference) while loading one of them. A segfault cannot be caught, and
//  `LaunchGuard` has already marked startup complete by the time these loads
//  run, so its safe mode never engaged: every launch crashed the same way and
//  the app could not be opened at all.
//
//  Every load writes a marker (model id + OS build) before it starts and
//  removes it when the load returns or throws. A marker that survives into a
//  new process means the previous process died during that load. Automatic
//  loads for that slot are then skipped; a load the user starts (mic button,
//  speaker button, Download in settings) always runs and clears the marker
//  when it finishes. A new OS build clears it too, since an OS update can fix
//  the Core ML fault.
//

import Foundation

enum CoreMLLoadSentinel {
    enum Slot: String, CaseIterable, Sendable {
        case speech
        case tts
    }

    struct CrashedLoad: Equatable, Sendable {
        let modelId: String
        let osBuild: String
    }

    private static let lock = NSLock()
    /// In-flight loads in this process, per slot. Only this process's own
    /// loads count, so a running load is never mistaken for a crashed one.
    nonisolated(unsafe) private static var inFlight: [Slot: Int] = [:]

    static var currentOSBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static func defaultsKey(_ slot: Slot) -> String { "CoreMLLoadSentinel.inFlight.\(slot.rawValue)" }

    /// Call right before a Core ML load starts.
    static func begin(
        _ slot: Slot,
        modelId: String,
        defaults: UserDefaults = .standard,
        osBuild: String = currentOSBuild
    ) {
        lock.lock()
        inFlight[slot, default: 0] += 1
        lock.unlock()
        defaults.set(["model": modelId, "os": osBuild], forKey: defaultsKey(slot))
        // The marker must reach disk before Core ML can take the process down.
        defaults.synchronize()
    }

    /// Call when the load returned or threw.
    static func end(_ slot: Slot, defaults: UserDefaults = .standard) {
        lock.lock()
        let remaining = max(0, inFlight[slot, default: 0] - 1)
        inFlight[slot] = remaining
        lock.unlock()
        if remaining == 0 { defaults.removeObject(forKey: defaultsKey(slot)) }
    }

    /// The load that was in flight when a previous process died on this OS
    /// build, or nil. Nil while this process has its own load running.
    static func crashedLoad(
        _ slot: Slot,
        defaults: UserDefaults = .standard,
        osBuild: String = currentOSBuild
    ) -> CrashedLoad? {
        lock.lock()
        let running = inFlight[slot, default: 0] > 0
        lock.unlock()
        guard !running,
            let marker = defaults.dictionary(forKey: defaultsKey(slot)),
            let modelId = marker["model"] as? String,
            let markedBuild = marker["os"] as? String,
            markedBuild == osBuild
        else { return nil }
        return CrashedLoad(modelId: modelId, osBuild: markedBuild)
    }

    /// Tests: drop this process's in-flight bookkeeping, as if the process
    /// had died mid-load and a new one started.
    static func forgetInProcessLoadsForTesting() {
        lock.lock()
        inFlight = [:]
        lock.unlock()
    }
}

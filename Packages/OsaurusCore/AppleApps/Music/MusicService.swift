//
//  MusicService.swift
//  osaurus
//
//  Apple Music (Music.app) control over AppleScript. Music is launched in
//  the background when needed and never activated (the plugin's `open_music`
//  called `activate`, yanking focus mid-turn). Tracks and playlists are
//  addressed by `persistent ID`, which is stable across launches and unique
//  in the library.
//

import AppKit
import Foundation

struct MusicTrackInfo: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let durationSeconds: Double?
    let year: Int?
    let genre: String?
    let rating: Int?
    let playedCount: Int?
}

struct MusicPlaylistInfo: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let trackCount: Int
    let durationSeconds: Double?
    let kind: String?
}

struct MusicNowPlaying: Codable, Sendable, Equatable {
    let state: String
    let track: MusicTrackInfo?
    let positionSeconds: Double?
    let volume: Int
    let shuffle: Bool
    let repeatMode: String
}

enum MusicPlaybackAction: String, CaseIterable, Sendable {
    case play, pause, toggle, next, previous, stop
}

enum MusicSearchField: String, CaseIterable, Sendable {
    case any, title, artist, album
}

struct MusicPlayRequest: Sendable, Equatable {
    var trackId: String?
    var playlist: String?
    var query: String?
    var shuffle: Bool?
}

protocol MusicServicing: Sendable {
    func nowPlaying() async throws -> MusicNowPlaying
    func playback(_ action: MusicPlaybackAction) async throws -> MusicNowPlaying
    func setVolume(_ level: Int) async throws -> Int
    func playlists() async throws -> [MusicPlaylistInfo]
    func search(_ query: String, field: MusicSearchField, limit: Int) async throws -> [MusicTrackInfo]
    func play(_ request: MusicPlayRequest) async throws -> MusicNowPlaying
}

final class AppleScriptMusicService: MusicServicing, @unchecked Sendable {
    static let bundleIdentifier = "com.apple.Music"
    static let appName = "Music"

    /// `isWrite` scripts (transport, volume, queueing) are never retried after
    /// a -600/-609 and report an unknown outcome on timeout; reads are retried
    /// once if Music vanished mid-call. `with timeout` keeps AppleScript's
    /// 60s per-event cap from lying about the Swift budget.
    private func run(_ body: String, timeout: TimeInterval = AppleScriptBridge.defaultTimeout, isWrite: Bool = false) async throws -> String {
        guard await AppleScriptBridge.ensureRunning(bundleIdentifier: Self.bundleIdentifier, appName: Self.appName) else {
            throw AppleToolError.unavailable("Music could not be launched on this Mac.", retryable: true)
        }
        let source = """
            \(AppleScriptBridge.separatorPrelude)
            \(Self.helperHandlers)
            with timeout of \(Int(timeout)) seconds
            \(body)
            end timeout
            """
        return try await AppleScriptBridge.runRetryingIfAppGone(
            bundleIdentifier: Self.bundleIdentifier, appName: Self.appName, isWrite: isWrite
        ) {
            try await AppleScriptBridge.run(source, permission: .automationMusic, appName: Self.appName, timeout: timeout, isWrite: isWrite)
        }
    }

    private static let helperHandlers = """
        on encodeTrack(t, FS)
            using terms from application "Music"
                set trackName to ""
                set artistName to ""
                set albumName to ""
                set durationText to ""
                set yearText to ""
                set genreText to ""
                set ratingText to ""
                set playCountText to ""
                try
                    set trackName to name of t
                end try
                try
                    set artistName to artist of t
                end try
                try
                    set albumName to album of t
                end try
                try
                    set durationText to (duration of t) as string
                end try
                try
                    set yearText to (year of t) as string
                end try
                try
                    set genreText to genre of t
                end try
                try
                    set ratingText to (rating of t) as string
                end try
                try
                    set playCountText to (played count of t) as string
                end try
                return (persistent ID of t) & FS & trackName & FS & artistName & FS & albumName & FS & durationText & FS & yearText & FS & genreText & FS & ratingText & FS & playCountText
            end using terms from
        end encodeTrack
        on encodeState(FS)
            using terms from application "Music"
                tell application "Music"
                    set playerStateText to (player state as string)
                    set positionText to ""
                    try
                        set positionText to (player position) as string
                    end try
                    set volumeValue to sound volume
                    set shuffleText to "false"
                    try
                        set shuffleText to (shuffle enabled) as string
                    end try
                    set repeatText to "off"
                    try
                        set repeatText to (song repeat as string)
                    end try
                    set trackRow to ""
                    try
                        set trackRow to my encodeTrack(current track, FS)
                    end try
                    return playerStateText & FS & positionText & FS & (volumeValue as string) & FS & shuffleText & FS & repeatText & (character id 30) & trackRow
                end tell
            end using terms from
        end encodeState
        """

    private static func decodeTrack(_ r: [String]) -> MusicTrackInfo? {
        guard r.count >= 9, !r[0].isEmpty else { return nil }
        return MusicTrackInfo(
            id: r[0], name: r[1], artist: r[2], album: r[3],
            durationSeconds: AppleScriptBridge.double(r[4]), year: (Int(r[5]) ?? 0) > 0 ? Int(r[5]) : nil,
            genre: r[6].isEmpty ? nil : r[6], rating: Int(r[7]), playedCount: Int(r[8])
        )
    }

    private static func decodeState(_ out: String) -> MusicNowPlaying {
        let sections = out.split(separator: AppleScriptBridge.recordSeparator, omittingEmptySubsequences: false).map(String.init)
        let head = (sections.first ?? "").split(separator: AppleScriptBridge.fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        let track = sections.count > 1
            ? decodeTrack(sections[1].split(separator: AppleScriptBridge.fieldSeparator, omittingEmptySubsequences: false).map(String.init))
            : nil
        var state = head.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "stopped"
        if let code = Int(state) { state = ["stopped", "playing", "paused", "fast forwarding", "rewinding"][safe: code] ?? state }
        return MusicNowPlaying(
            state: state,
            track: track,
            positionSeconds: head.count > 1 ? AppleScriptBridge.double(head[1]) : nil,
            volume: head.count > 2 ? (Int(head[2]) ?? 0) : 0,
            shuffle: head.count > 3 ? AppleScriptBridge.bool(head[3]) : false,
            repeatMode: head.count > 4 ? head[4] : "off"
        )
    }

    func nowPlaying() async throws -> MusicNowPlaying {
        Self.decodeState(try await run("return my encodeState(FS)"))
    }

    func playback(_ action: MusicPlaybackAction) async throws -> MusicNowPlaying {
        let command: String
        switch action {
        case .play: command = "play"
        case .pause: command = "pause"
        case .toggle: command = "playpause"
        case .next: command = "next track"
        case .previous: command = "previous track"
        case .stop: command = "stop"
        }
        let out = try await run(
            """
            tell application "Music"
                \(command)
            end tell
            delay 0.2
            return my encodeState(FS)
            """,
            isWrite: true
        )
        return Self.decodeState(out)
    }

    func setVolume(_ level: Int) async throws -> Int {
        let clamped = max(0, min(100, level))
        let out = try await run(
            """
            tell application "Music"
                set sound volume to \(clamped)
                return (sound volume as string)
            end tell
            """,
            isWrite: true
        )
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? clamped
    }

    func playlists() async throws -> [MusicPlaylistInfo] {
        let out = try await run(
            """
            tell application "Music"
                set rows to {}
                repeat with p in playlists
                    set kindText to ""
                    try
                        set kindText to (special kind of p) as string
                    end try
                    set durationText to ""
                    try
                        set durationText to (duration of p) as string
                    end try
                    set end of rows to (persistent ID of p) & FS & (name of p) & FS & ((count of tracks of p) as string) & FS & durationText & FS & kindText
                end repeat
                set AppleScript's text item delimiters to RS
                set joined to rows as text
                set AppleScript's text item delimiters to ""
                return joined
            end tell
            """,
            timeout: 120
        )
        return AppleScriptBridge.parseRecords(out).compactMap { r in
            guard r.count >= 5 else { return nil }
            return MusicPlaylistInfo(
                id: r[0], name: r[1], trackCount: Int(r[2]) ?? 0, durationSeconds: AppleScriptBridge.double(r[3]),
                kind: r[4].isEmpty || r[4] == "none" ? nil : r[4]
            )
        }
    }

    func search(_ query: String, field: MusicSearchField, limit: Int) async throws -> [MusicTrackInfo] {
        let only: String
        switch field {
        case .any: only = ""
        // Music's search `only` enumeration is albums / all / artists /
        // composers / displayed / names (track names) — there is no `songs`.
        case .title: only = " only names"
        case .artist: only = " only artists"
        case .album: only = " only albums"
        }
        let out = try await run(
            """
            tell application "Music"
                set found to search (first library playlist) for \(AppleScriptBridge.literal(query))\(only)
                set rows to {}
                set n to 0
                repeat with t in found
                    set end of rows to my encodeTrack(t, FS)
                    set n to n + 1
                    if n ≥ \(limit) then exit repeat
                end repeat
                set AppleScript's text item delimiters to RS
                set joined to rows as text
                set AppleScript's text item delimiters to ""
                return joined
            end tell
            """
        )
        return AppleScriptBridge.parseRecords(out).compactMap(Self.decodeTrack)
    }

    /// AppleScript body for `play`. Every user-supplied value goes through
    /// `AppleScriptBridge.literal` — including the ones inside `error "…"`
    /// strings, which previously interpolated raw text and let a playlist
    /// name like `" & (system attribute "HOME") & "` break out of the
    /// literal. Shuffle is only touched when the caller asked for it; the
    /// resulting state reports the effective value.
    static func playScriptBody(_ request: MusicPlayRequest) -> String {
        var body = ""
        if let shuffle = request.shuffle {
            body += "set shuffle enabled to \(shuffle)\n"
        }
        if let trackId = request.trackId, !trackId.isEmpty {
            let lit = AppleScriptBridge.literal(trackId)
            body += """
                set matches to (tracks of (first library playlist) whose persistent ID is \(lit))
                if (count of matches) is 0 then error ("No track with persistent ID " & \(lit)) number -1728
                play (item 1 of matches)
                """
        } else if let playlist = request.playlist, !playlist.isEmpty {
            let lit = AppleScriptBridge.literal(playlist)
            body += """
                set matches to (playlists whose persistent ID is \(lit))
                if (count of matches) is 0 then set matches to (playlists whose name is \(lit))
                if (count of matches) is 0 then error ("No playlist named or with ID " & \(lit)) number -1728
                play (item 1 of matches)
                """
        } else if let query = request.query, !query.isEmpty {
            let lit = AppleScriptBridge.literal(query)
            body += """
                set found to search (first library playlist) for \(lit)
                if (count of found) is 0 then error ("No tracks match " & \(lit)) number -1728
                play (item 1 of found)
                """
        } else {
            body += "play"
        }
        return body
    }

    func play(_ request: MusicPlayRequest) async throws -> MusicNowPlaying {
        let out = try await run(
            """
            tell application "Music"
                \(Self.playScriptBody(request))
            end tell
            delay 0.3
            return my encodeState(FS)
            """,
            isWrite: true
        )
        return Self.decodeState(out)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

//
//  MusicScriptsTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Music's AppleScript generation: user-supplied names/ids never break out of
//  a string literal (including inside `error "…"` messages), the search
//  `only` term is a real Music enumeration, and the side-effecting tools ask
//  for approval.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Music scripts")
struct MusicScriptsTests {

    @Test("a playlist name with an AppleScript injection payload round-trips as one literal")
    func playlistLiteralIsNotBrokenOutOf() {
        let payload = "\" & (system attribute \"HOME\") & \""
        let body = AppleScriptMusicService.playScriptBody(MusicPlayRequest(playlist: payload))
        let lit = AppleScriptBridge.literal(payload)
        // The escaped literal appears verbatim wherever the name is used…
        #expect(body.contains("whose name is \(lit)"))
        #expect(body.contains("error (\"No playlist named or with ID \" & \(lit)) number -1728"))
        // …and the raw payload never does.
        #expect(!body.contains(payload))
        #expect(!body.contains("error \"No playlist"))
    }

    @Test("track ids and queries inside error strings are literals too")
    func trackAndQueryLiterals() {
        let evil = "x\" & \"y"
        let track = AppleScriptMusicService.playScriptBody(MusicPlayRequest(trackId: evil))
        #expect(track.contains("error (\"No track with persistent ID \" & \(AppleScriptBridge.literal(evil)))"))
        #expect(!track.contains("ID x\""))
        let query = AppleScriptMusicService.playScriptBody(MusicPlayRequest(query: evil))
        #expect(query.contains("error (\"No tracks match \" & \(AppleScriptBridge.literal(evil)))"))
        #expect(!query.contains("match x\""))
    }

    @Test("shuffle is only touched when requested")
    func shuffleUntouchedByDefault() {
        #expect(!AppleScriptMusicService.playScriptBody(MusicPlayRequest()).contains("shuffle enabled"))
        #expect(AppleScriptMusicService.playScriptBody(MusicPlayRequest(shuffle: true)).contains("set shuffle enabled to true"))
        #expect(AppleScriptMusicService.playScriptBody(MusicPlayRequest()) == "play")
    }

    @Test("play, playback and set_volume are side-effecting and require approval by default")
    @MainActor
    func writeToolsAskForApproval() {
        let tools = MusicToolFactory.makeTools(service: FakeMusicService()).compactMap { $0 as? AppleToolBase }
        #expect(tools.count == 6)
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for name in ["music_play", "music_playback", "music_set_volume"] {
            #expect(byName[name]?.isWrite == true, "\(name) must be a write tool")
            #expect(byName[name]?.defaultPermissionPolicy == .ask, "\(name) must ask")
        }
        for name in ["music_now_playing", "music_playlists", "music_search"] {
            #expect(byName[name]?.isWrite == false, "\(name) is read-only")
        }
    }
}

private struct FakeMusicService: MusicServicing {
    func nowPlaying() async throws -> MusicNowPlaying { .init(state: "stopped", track: nil, positionSeconds: nil, volume: 50, shuffle: false, repeatMode: "off") }
    func playback(_ action: MusicPlaybackAction) async throws -> MusicNowPlaying { try await nowPlaying() }
    func setVolume(_ level: Int) async throws -> Int { level }
    func playlists() async throws -> [MusicPlaylistInfo] { [] }
    func search(_ query: String, field: MusicSearchField, limit: Int) async throws -> [MusicTrackInfo] { [] }
    func play(_ request: MusicPlayRequest) async throws -> MusicNowPlaying { try await nowPlaying() }
}

//
//  MusicTools.swift
//  osaurus
//
//  Built-in `music_*` tools (per-agent opt-in via `AppleApp.music`).
//

import Foundation

enum MusicToolFactory {
    static func makeTools(service: MusicServicing = AppleScriptMusicService()) -> [OsaurusTool] {
        [
            MusicNowPlayingTool(service: service),
            MusicPlaybackTool(service: service),
            MusicSetVolumeTool(service: service),
            MusicPlaylistsTool(service: service),
            MusicSearchTool(service: service),
            MusicPlayTool(service: service),
        ]
    }
}

final class MusicNowPlayingTool: AppleToolBase, @unchecked Sendable {
    private let service: MusicServicing
    init(service: MusicServicing) {
        self.service = service
        super.init(
            app: .music, name: "music_now_playing",
            description: "Report Music's player state: playing/paused/stopped, the current track (with its id), position, volume, shuffle and repeat.",
            parameters: AppleSchema.object([:]), isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        AppleToolPayload(["player": try await service.nowPlaying()])
    }
}

final class MusicPlaybackTool: AppleToolBase, @unchecked Sendable {
    private let service: MusicServicing
    init(service: MusicServicing) {
        self.service = service
        super.init(
            app: .music, name: "music_playback",
            description: "Control playback: play, pause, toggle (play/pause), next, previous, or stop. Returns the resulting player state.",
            parameters: AppleSchema.object(
                ["action": AppleSchema.string("Playback command.", enum: MusicPlaybackAction.allCases.map(\.rawValue))],
                required: ["action"]
            ),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let raw = try AppleArgs.enumeration(args, "action", allowed: MusicPlaybackAction.allCases.map(\.rawValue)) ?? ""
        guard let action = MusicPlaybackAction(rawValue: raw) else {
            throw AppleToolError.invalidArgs("Missing required argument `action`.", field: "action", expected: MusicPlaybackAction.allCases.map(\.rawValue).joined(separator: " | "))
        }
        return AppleToolPayload(["action": action.rawValue, "player": try await service.playback(action)])
    }
}

final class MusicSetVolumeTool: AppleToolBase, @unchecked Sendable {
    private let service: MusicServicing
    init(service: MusicServicing) {
        self.service = service
        super.init(
            app: .music, name: "music_set_volume",
            description: "Set Music's own volume (0–100). This is the app volume, not the system volume.",
            parameters: AppleSchema.object(["level": AppleSchema.integer("Volume from 0 (mute) to 100.")], required: ["level"]),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        guard let level = try AppleArgs.int(args, "level") else {
            throw AppleToolError.invalidArgs("Missing required argument `level`.", field: "level", expected: "an integer 0–100")
        }
        guard (0...100).contains(level) else {
            throw AppleToolError.invalidArgs("`level` must be between 0 and 100. Got \(level).", field: "level", expected: "0–100")
        }
        return AppleToolPayload(["volume": try await service.setVolume(level)])
    }
}

final class MusicPlaylistsTool: AppleToolBase, @unchecked Sendable {
    private let service: MusicServicing
    static let defaultLimit = 100
    init(service: MusicServicing) {
        self.service = service
        super.init(
            app: .music, name: "music_playlists",
            description: "List playlists with track counts and stable ids (use the id or exact name with music_play).",
            parameters: AppleSchema.object([
                "query": AppleSchema.string("Only playlists whose name contains this text."),
                "limit": AppleSchema.limit(default: Self.defaultLimit, max: 500),
            ]),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let query = try AppleArgs.string(args, "query")
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 500)
        var lists = try await service.playlists()
        if let query, !query.isEmpty { lists = lists.filter { AppleServiceSupport.matches($0.name, query: query) } }
        let page = AppleServiceSupport.page(lists, limit: limit)
        return AppleToolPayload(["playlists": page.items, "count": page.items.count, "total": page.total, "truncated": page.truncated])
    }
}

final class MusicSearchTool: AppleToolBase, @unchecked Sendable {
    private let service: MusicServicing
    static let defaultLimit = 25
    init(service: MusicServicing) {
        self.service = service
        super.init(
            app: .music, name: "music_search",
            description: "Search the library for tracks by title, artist, or album. Returns tracks with stable ids for music_play.",
            parameters: AppleSchema.object(
                [
                    "query": AppleSchema.string("Search text."),
                    "field": AppleSchema.string("Restrict the match (default any).", enum: MusicSearchField.allCases.map(\.rawValue)),
                    "limit": AppleSchema.limit(default: Self.defaultLimit, max: 200),
                ],
                required: ["query"]
            ),
            isWrite: false
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let query = try AppleArgs.requiredString(args, "query", expected: "search text")
        let fieldRaw = try AppleArgs.enumeration(args, "field", allowed: MusicSearchField.allCases.map(\.rawValue), default: "any") ?? "any"
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 200)
        let tracks = try await service.search(query, field: MusicSearchField(rawValue: fieldRaw) ?? .any, limit: limit)
        return AppleToolPayload(["tracks": tracks, "count": tracks.count, "query": query, "field": fieldRaw])
    }
}

final class MusicPlayTool: AppleToolBase, @unchecked Sendable {
    private let service: MusicServicing
    init(service: MusicServicing) {
        self.service = service
        super.init(
            app: .music, name: "music_play",
            description: "Play something: a track by `track_id` (from music_search), a `playlist` by id or exact name, or the first match for `query`. With none of those, resumes playback. Optional `shuffle`.",
            parameters: AppleSchema.object([
                "track_id": AppleSchema.string("Track id from music_search."),
                "playlist": AppleSchema.string("Playlist id or exact name from music_playlists."),
                "query": AppleSchema.string("Free-text search; plays the first matching track."),
                "shuffle": AppleSchema.boolean("Turn shuffle on/off before playing. Omit to leave the user's current shuffle setting alone; this changes Music's own setting and stays in effect afterwards."),
            ]),
            isWrite: true
        )
    }
    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let request = MusicPlayRequest(
            trackId: try AppleArgs.string(args, "track_id"),
            playlist: try AppleArgs.string(args, "playlist"),
            query: try AppleArgs.string(args, "query"),
            shuffle: try AppleArgs.bool(args, "shuffle")
        )
        return AppleToolPayload(["player": try await service.play(request)])
    }
}

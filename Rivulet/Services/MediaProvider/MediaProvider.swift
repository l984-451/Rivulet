// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProvider.swift
//  Rivulet
//
//  The agnostic seam every backend implements. Views talk only to this
//  protocol; backend specifics live below the boundary.
//

import Foundation

/// Per-playback-session progress reporter. Provider creates a value-typed
/// concrete reporter (e.g. `PlexTimelineReporter`) capturing whatever
/// session state it needs.
protocol ProgressReporter: Sendable {
    func start(position: TimeInterval) async
    func progress(position: TimeInterval) async
    func paused(at position: TimeInterval) async
    func stopped(at position: TimeInterval) async
}

protocol MediaProvider: Sendable, Identifiable {
    var id: String { get }                       // "plex:<machineId>"
    var kind: MediaProviderKind { get }
    var displayName: String { get }
    var connectionState: ConnectionState { get }

    // MARK: - Browse
    func libraries() async throws -> [MediaLibrary]
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem>
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem]
    func search(_ query: String) async throws -> [MediaItem]
    /// Search limited to these libraries' ids. Default: all libraries.
    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem]

    /// Provider-curated "related/recommended like this" items, and the
    /// collection the item belongs to when the provider picks one. `kind` is
    /// the item's own kind, which a ref does not carry.
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent

    /// All episodes flattened across all seasons of a show. For shows only.
    /// Plex: getAllLeaves. Jellyfin: /Shows/{id}/Episodes.
    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem]

    // MARK: - Detail
    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail

    // MARK: - Home rails
    func continueWatching(limit: Int) async throws -> [MediaItem]
    func recentlyAdded(limit: Int) async throws -> [MediaItem]
    /// Plex-native curated hubs. Other providers may return [] and rely on
    /// `HomeComposer` to synthesize from primitives.
    func hubs() async throws -> [MediaHub]

    /// Library-scoped hubs (the library's own Continue Watching, Recently Added,
    /// genre rows, etc.) — NOT the global home hubs.
    func hubs(in library: MediaLibrary) async throws -> [MediaHub]
    /// The signed-in user on this server, when the server has its own users
    /// (Jellyfin). Per-user settings such as hidden libraries key on it.
    var accountID: String? { get }
    /// Just the library's Recently Added row (`<library id>.recentlyAdded`),
    /// nil when it has none. Home asks for this per library on every reload,
    /// so a provider whose `hubs(in:)` costs more than one request overrides it.
    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub?
    /// The library's collections (Plex collections, Jellyfin box sets), in
    /// the server's order. Default: none.
    func collections(in library: MediaLibrary) async throws -> [MediaItem]
    /// Title counts per first letter of the sort title, "#" first then A to Z,
    /// for the library's A to Z bar. Default: none, which hides the bar.
    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter]
    /// Ask the server to re-read the item's metadata. Default: unsupported.
    func refreshMetadata(_ itemRef: MediaItemRef) async throws

    // MARK: - Playback
    /// A nil `sourceID` plays the best version by `VersionRanking`.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo

    /// A server-side transcode starting at `startTime`, played with AVPlayer.
    /// For when the client cannot play the direct-play stream.
    /// Default: unsupported.
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval) async throws -> StreamInfo
    /// `sourceID` is the `MediaSource.id` being played. Jellyfin needs it on
    /// every report; without it a multi-version item reports against the
    /// wrong version.
    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter

    // MARK: - Per-item track selection (server-side persistent)

    /// Set the user's preferred audio track for a specific media source on this
    /// item. Plex persists this per-user-per-part so the choice carries across
    /// clients; Jellyfin equivalent is `Items/{id}/UserData`. Implementations
    /// should issue the call against the user's account, not the device.
    /// `trackID` is the agnostic `AudioTrack.id` — provider-native string ID.
    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws

    /// Set (or clear, with `nil`) the user's preferred subtitle track for a
    /// media source. Passing `nil` disables subtitles server-side.
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws

    // MARK: - Watch state
    func markPlayed(_ itemRef: MediaItemRef) async throws
    func markUnplayed(_ itemRef: MediaItemRef) async throws
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws

    // MARK: - Watchlist
    var supportsWatchlist: Bool { get }
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool
    func addToWatchlist(_ ref: MediaItemRef) async throws
    func removeFromWatchlist(_ ref: MediaItemRef) async throws

    // MARK: - Content advisory

    /// Provider-agnostic content advisory (Common Sense Media on Plex). Returns
    /// nil when the backend has none. Default = nil so backends opt in.
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory?

    /// Skip markers (intro, credits, ...) for the item. Default: none.
    /// Best effort: a backend without the data returns an empty value.
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras
}

extension MediaProvider {
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval) async throws -> StreamInfo {
        throw MediaProviderError.transcodeRequired
    }
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras { PlaybackExtras() }
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory? { nil }
    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem] {
        try await search(query)
    }
    func collections(in library: MediaLibrary) async throws -> [MediaItem] { [] }
    var accountID: String? { nil }
    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        try await hubs(in: library).first { $0.id == "\(library.id).recentlyAdded" }
    }
    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter] { [] }
    func refreshMetadata(_ itemRef: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "refresh not supported")
    }
}

/// The Related row and, when the item has one, its collection row.
nonisolated struct RelatedContent: Sendable {
    let items: [MediaItem]
    let collection: CollectionRow?
}

/// The item's collection: the other members in the collection's own order,
/// and the collection itself as a trailing tile when the provider returned
/// only some of the members.
nonisolated struct CollectionRow: Sendable {
    let title: String
    let members: [MediaItem]
    let collection: MediaItem?
}

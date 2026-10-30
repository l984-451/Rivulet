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
    /// Immutable authentication/profile revision captured by this provider instance.
    var authorityRevision: UInt64 { get }
    /// Native planners may reserve a counted server session before media is read.
    var reservesPlaybackOnResolve: Bool { get }

    // MARK: - Browse
    func libraries() async throws -> [MediaLibrary]
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem>
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem]
    func search(_ query: String) async throws -> [MediaItem]
    /// Search limited to these libraries' ids. Default: all libraries.
    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem]
    /// Native people results retain the source provider's identity.
    func searchPeople(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaPersonResult]
    func personDetail(_ person: MediaPersonResult, inLibraries libraryIDs: [String]) async throws -> PersonDetail
    /// The returned choices are the only values authorized for this library and profile.
    func catalogFacets(in library: MediaLibrary) async throws -> [MediaCatalogFacet]?
    func catalogItems(in library: MediaLibrary, filter: MediaCatalogFilter, sort: SortOption,
                      page: Page) async throws -> PagedResult<MediaItem>

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
    func dismiss(_ dismissal: MediaDismissal) async throws
    func recentlyAdded(limit: Int) async throws -> [MediaItem]
    /// Plex-native curated hubs. Other providers may return [] and rely on
    /// `HomeComposer` to synthesize from primitives.
    func hubs() async throws -> [MediaHub]
    /// Whether curated rail headers offer a separate See All destination.
    /// Independent of hub paging: hiding the button must not truncate the rail.
    var showsHubBrowseAll: Bool { get }
    /// Continue a provider-native row using the exact page returned by its previous response.
    func hubItems(_ hubID: String, page: Page) async throws -> PagedResult<MediaItem>
    /// nil means unsupported; an empty array is a supported, empty Discover feed.
    func discoveryHubs() async throws -> [MediaHub]?

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
    /// The library's titles on `trending`, in its order, at most `limit`.
    /// Home's hero on a server with no TMDB index of its own. Default: none.
    func trending(in library: MediaLibrary, from trending: [TMDBListItem], limit: Int) async throws -> [MediaItem]
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
    /// `maxBitrate` (bps, nil uncapped) is the most the stream may use; a provider without caps ignores it.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo
    /// Replan a stream that cannot seek locally. nil keeps the current stream.
    func seekStream(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?,
                    position: TimeInterval) async throws -> StreamInfo?
    /// Release a reserved native plan without reporting playback. False requires legacy reporter cleanup.
    func discardStream(_ stream: StreamInfo) async throws -> Bool
    /// Replace an active plan using its native session. nil delegates to the legacy replacement path.
    func replaceStream(for itemRef: MediaItemRef, current: StreamInfo, sourceID: String?,
                       position: TimeInterval, maxBitrate: Int?, audioStreamIndex: Int?,
                       subtitleStreamIndex: Int?, forceTranscode: Bool) async throws -> StreamInfo?
    /// Native quality uses an opaque offered ID; unsupported providers throw.
    func replaceStream(for itemRef: MediaItemRef, current: StreamInfo, sourceID: String?,
                       position: TimeInterval, quality: MediaQualityPreference) async throws -> StreamInfo

    /// A server-side transcode starting at `startTime`, played with AVPlayer.
    /// For when the client cannot play the direct-play stream, or a quality cap.
    /// The stream indices are the provider's own track ids; subtitle -1 is off. Default: unsupported.
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws -> StreamInfo
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

    // MARK: - Deletion

    /// Whether this account may delete media from the server. Default: no.
    func canDeleteMedia() async -> Bool
    /// Deletes the item and its files from the server.
    func deleteMedia(_ itemRef: MediaItemRef) async throws

    // MARK: - Watchlist
    var supportsWatchlist: Bool { get }
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool
    func addToWatchlist(_ ref: MediaItemRef) async throws
    func removeFromWatchlist(_ ref: MediaItemRef) async throws
    func watchlistItems() async throws -> [MediaItem]
    var supportsFavorites: Bool { get }
    func isFavorite(_ ref: MediaItemRef) async -> Bool
    func setFavorite(_ ref: MediaItemRef, isFavorite: Bool) async throws

    // MARK: - Playlists (video)
    var supportsPlaylists: Bool { get }
    /// Regular and smart video playlists, sorted by title.
    func videoPlaylists() async throws -> [MediaPlaylist]
    /// Every row, all pages, in the server's order.
    func playlistEntries(_ playlist: MediaItemRef) async throws -> [PlaylistEntry]
    func createPlaylist(title: String, seededWith items: [MediaItemRef]) async throws -> MediaPlaylist
    func addToPlaylist(_ playlist: MediaItemRef, items: [MediaItemRef]) async throws
    func removeFromPlaylist(_ playlist: MediaItemRef, entryID: String) async throws
    /// `entries` is the order before the move; each backend derives what its server takes.
    func movePlaylistEntry(_ playlist: MediaItemRef, entryID: String, toIndex: Int, in entries: [PlaylistEntry]) async throws
    func renamePlaylist(_ playlist: MediaItemRef, title: String) async throws
    func deletePlaylist(_ playlist: MediaItemRef) async throws

    // MARK: - Content advisory

    /// Provider-agnostic content advisory (Common Sense Media on Plex). Returns
    /// nil when the backend has none. Default = nil so backends opt in.
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory?

    /// Canonical movie/show identity keys, by catalog item id,
    /// fetched in as few requests as the server allows. Default: none.
    func itemIdentityKeys(for itemIDs: [String]) async -> [String: [String]]

    /// Skip markers (intro, credits, ...) for the item. Default: none.
    /// Best effort: a backend without the data returns an empty value.
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras
}

extension MediaProvider {
    func searchPeople(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaPersonResult] {
        throw MediaProviderError.backendSpecific(underlying: "native people search not supported")
    }
    func personDetail(_ person: MediaPersonResult, inLibraries libraryIDs: [String]) async throws -> PersonDetail {
        throw MediaProviderError.backendSpecific(underlying: "native person detail not supported")
    }
    func catalogFacets(in library: MediaLibrary) async throws -> [MediaCatalogFacet]? { nil }
    func catalogItems(in library: MediaLibrary, filter: MediaCatalogFilter, sort: SortOption,
                      page: Page) async throws -> PagedResult<MediaItem> {
        throw MediaProviderError.backendSpecific(underlying: "catalog filters not supported")
    }
    func dismiss(_ dismissal: MediaDismissal) async throws {
        throw MediaProviderError.backendSpecific(underlying: "native rail dismissal not supported")
    }
    func replaceStream(for itemRef: MediaItemRef, current: StreamInfo, sourceID: String?,
                       position: TimeInterval, quality: MediaQualityPreference) async throws -> StreamInfo {
        throw MediaProviderError.backendSpecific(underlying: "native quality not supported")
    }
    var authorityRevision: UInt64 { 0 }
    var reservesPlaybackOnResolve: Bool { false }
    var showsHubBrowseAll: Bool { true }
    func hubItems(_ hubID: String, page: Page) async throws -> PagedResult<MediaItem> {
        throw MediaProviderError.backendSpecific(underlying: "hub paging not supported")
    }
    func discoveryHubs() async throws -> [MediaHub]? { nil }
    func watchlistItems() async throws -> [MediaItem] { [] }
    var supportsFavorites: Bool { false }
    func isFavorite(_ ref: MediaItemRef) async -> Bool { false }
    func setFavorite(_ ref: MediaItemRef, isFavorite: Bool) async throws {
        throw MediaProviderError.backendSpecific(underlying: "favorites not supported")
    }
    func seekStream(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?,
                    position: TimeInterval) async throws -> StreamInfo? { nil }
    func discardStream(_ stream: StreamInfo) async throws -> Bool { false }
    func replaceStream(for itemRef: MediaItemRef, current: StreamInfo, sourceID: String?,
                       position: TimeInterval, maxBitrate: Int?, audioStreamIndex: Int?,
                       subtitleStreamIndex: Int?, forceTranscode: Bool) async throws -> StreamInfo? { nil }
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo {
        try await resolveStream(for: itemRef, sourceID: sourceID, maxBitrate: nil)
    }
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval) async throws -> StreamInfo {
        try await transcodeStream(for: itemRef, sourceID: sourceID, startTime: startTime, maxBitrate: nil)
    }
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?) async throws -> StreamInfo {
        try await transcodeStream(for: itemRef, sourceID: sourceID, startTime: startTime, maxBitrate: maxBitrate,
                                  audioStreamIndex: nil, subtitleStreamIndex: nil)
    }
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws -> StreamInfo {
        throw MediaProviderError.transcodeRequired
    }
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras { PlaybackExtras() }
    func itemIdentityKeys(for itemIDs: [String]) async -> [String: [String]] { [:] }
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory? { nil }
    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem] {
        try await search(query)
    }
    func collections(in library: MediaLibrary) async throws -> [MediaItem] { [] }
    var accountID: String? { nil }
    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        try await hubs(in: library).first { $0.id == "\(library.id).recentlyAdded" }
    }
    func trending(in library: MediaLibrary, from trending: [TMDBListItem], limit: Int) async throws -> [MediaItem] { [] }
    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter] { [] }
    func refreshMetadata(_ itemRef: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "refresh not supported")
    }
    func canDeleteMedia() async -> Bool { false }
    func deleteMedia(_ itemRef: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "delete not supported")
    }

    var supportsPlaylists: Bool { false }
    func videoPlaylists() async throws -> [MediaPlaylist] { [] }
    func playlistEntries(_ playlist: MediaItemRef) async throws -> [PlaylistEntry] { [] }
    func createPlaylist(title: String, seededWith items: [MediaItemRef]) async throws -> MediaPlaylist {
        throw MediaProviderError.backendSpecific(underlying: "playlists not supported")
    }
    func addToPlaylist(_ playlist: MediaItemRef, items: [MediaItemRef]) async throws {
        throw MediaProviderError.backendSpecific(underlying: "playlists not supported")
    }
    func removeFromPlaylist(_ playlist: MediaItemRef, entryID: String) async throws {
        throw MediaProviderError.backendSpecific(underlying: "playlists not supported")
    }
    func movePlaylistEntry(_ playlist: MediaItemRef, entryID: String, toIndex: Int, in entries: [PlaylistEntry]) async throws {
        throw MediaProviderError.backendSpecific(underlying: "playlists not supported")
    }
    func renamePlaylist(_ playlist: MediaItemRef, title: String) async throws {
        throw MediaProviderError.backendSpecific(underlying: "playlists not supported")
    }
    func deletePlaylist(_ playlist: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "playlists not supported")
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

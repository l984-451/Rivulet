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
    /// `items(in:sort:page:)` narrowed by the library page's filter. Default: the plain listing when
    /// the filter is off, and a refusal when it is on, since a provider must not pretend to filter.
    func items(in library: MediaLibrary, sort: SortOption, filter: LibraryFilter, page: Page) async throws -> PagedResult<MediaItem>
    /// The genres and decades a filtered listing of this library can use. Default: none.
    func filterOptions(in library: MediaLibrary) async throws -> LibraryFilterOptions
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem]
    /// At most `limit` playable titles of a video library (movies, videos, a TV library's episodes) in
    /// an order the server randomizes. Default: a refusal.
    func shuffledItems(in library: MediaLibrary, unwatchedOnly: Bool, limit: Int) async throws -> [MediaItem]
    func search(_ query: String) async throws -> [MediaItem]
    /// Search limited to these libraries' ids. Default: all libraries.
    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem]
    /// The Search page's answer: titles, people, and collection and genre shelves. `libraryIDs` nil
    /// is every library. Default: `search`'s titles, ranked, and nothing else.
    func searchHits(_ query: String, inLibraries libraryIDs: [String]?) async throws -> SearchHits

    // MARK: - People
    /// The person's movies and shows on this server. A person from another server (or TMDB) is
    /// found by name. Default: none.
    func filmography(of person: MediaPerson) async throws -> [FilmographyEntry]
    /// The person's biography as this server holds it. Default: nil.
    func biography(of person: MediaPerson) async -> String?

    /// Provider-curated "related/recommended like this" items, and the
    /// collection the item belongs to when the provider picks one. `kind` is
    /// the item's own kind, which a ref does not carry.
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent

    /// The detail page's "More Like This" row. Default: the related row. Plex keeps only its
    /// similar-title hubs, uncapped, which is what iOS shows.
    func moreLikeThis(for ref: MediaItemRef, kind: MediaKind) async throws -> [MediaItem]

    /// All episodes flattened across all seasons of a show. For shows only.
    /// Plex: getAllLeaves. Jellyfin: /Shows/{id}/Episodes.
    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem]

    // MARK: - Detail
    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail

    /// A direct-play URL for a title's theme video, used as a muted backdrop. Nil when the
    /// server has none or it cannot direct play on AVPlayer; never a transcode. Default: nil (Plex).
    func themeVideoURL(for itemRef: MediaItemRef) async throws -> URL?

    // MARK: - Home rails
    func continueWatching(limit: Int) async throws -> [MediaItem]
    func recentlyAdded(limit: Int) async throws -> [MediaItem]
    /// Plex-native curated hubs. Other providers may return [] and rely on
    /// `HomeComposer` to synthesize from primitives.
    func hubs() async throws -> [MediaHub]

    /// Library-scoped hubs (the library's own Continue Watching, Recently Added,
    /// genre rows, etc.) — NOT the global home hubs.
    func hubs(in library: MediaLibrary) async throws -> [MediaHub]
    /// The hubs each library promotes to Home, by library id. A library left out failed.
    /// Default: each library's `hubs(in:)`, a few at a time; Plex answers in one request.
    func promotedHubs(in libraries: [MediaLibrary]) async throws -> [String: [MediaHub]]
    /// The signed-in user on this server, when the server has its own users
    /// (Jellyfin). Per-user settings such as hidden libraries key on it.
    var accountID: String? { get }
    /// Just the library's Recently Added row (`<library id>.recentlyAdded`),
    /// nil when it has none. Home asks for this per library on every reload,
    /// so a provider whose `hubs(in:)` costs more than one request overrides it.
    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub?
    /// Whether the server has favorites (Jellyfin's flag; Plex: rated above
    /// three stars). Settings offers the favorites rows only then.
    var supportsFavorites: Bool { get }
    /// The library's favorites, by name, at most `limit`.
    /// Home asks for them per movie or TV library while that kind's favorites
    /// row is on in Settings > Home > Rows. Default: none.
    func favorites(in library: MediaLibrary, limit: Int) async throws -> [MediaItem]
    /// Marks a movie or show a favorite, or clears it. Plex: five stars, or no rating.
    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws
    /// The library's titles on `trending`, in its order, at most `limit`.
    /// Home's hero on a server with no TMDB index of its own. Default: none.
    func trending(in library: MediaLibrary, from trending: [TMDBListItem], limit: Int) async throws -> [MediaItem]
    /// One page of a row's See All grid, through `hub.pagingKey`. Default (and a row with no key):
    /// the row's own items as the only page.
    func hubPage(_ hub: MediaHub, page: Page) async throws -> PagedResult<MediaItem>
    /// The server's items for these titles, in title order, each once, at most `limit`.
    /// Home's watchlist hero. Default: none.
    func ownedItems(matching titles: [TitleMatch], limit: Int) async throws -> [MediaItem]
    /// `url` (one of this provider's artwork URLs) resized to fit a `width` x `height` box in pixels,
    /// by the server. Any other URL comes back unchanged. Default: unchanged.
    func imageURL(_ url: URL, width: Int, height: Int) -> URL
    /// The clear logo of the item's title: a movie's or show's own, an episode's or season's show.
    /// May ask the server, since list responses often carry none. Default: what the item already holds.
    func logoURL(for item: MediaItem) async -> URL?
    /// The library's collections (Plex collections, Jellyfin box sets), in
    /// the server's order. Default: none.
    func collections(in library: MediaLibrary) async throws -> [MediaItem]
    /// Title counts per first letter of the sort title, "#" first then A to Z,
    /// for the library's A to Z bar. Default: none, which hides the bar.
    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter]
    /// Ask the server to re-read the item's metadata. Default: unsupported.
    func refreshMetadata(_ itemRef: MediaItemRef) async throws
    /// Whether this account may ask for a refresh, for menus that offer it. Default: yes, the
    /// server answers for itself. Emby accepts a refresh from anyone, so it says no for non-admins.
    func canRefreshMetadata() async -> Bool
    /// The sorts the library page offers for this kind of library, each one
    /// `items(in:sort:page:)` can apply. Default: Plex's list minus resolution.
    func sortOptions(for kind: MediaLibrary.LibraryKind) -> [LibrarySortOption]

    // MARK: - Playback
    /// A nil `sourceID` plays the best version by `VersionRanking`.
    /// `maxBitrate` (bps, nil uncapped) is the most the stream may use; a provider without caps ignores it.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo
    /// As above, for a play that starts at `startTime`: a capped stream that comes back as a
    /// transcode starts there, so the player does not have to restart it with a seek. Default: ignores it.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?,
                       startTime: TimeInterval) async throws -> StreamInfo

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
    /// Takes the item off Continue Watching. Default: clears a non-episode's resume position,
    /// which drops it from the row; an episode would only move to Next Up, so it is left alone.
    /// Plex has its own call and Emby hides the entry.
    func removeFromContinueWatching(_ item: MediaItem) async throws
    /// Whether `removeFromContinueWatching` does something for this item, for menus that offer it.
    /// Default: not an episode, since clearing an episode's position moves it to Next Up.
    func canRemoveFromContinueWatching(_ item: MediaItem) -> Bool

    // MARK: - Subtitle search

    /// Whether this account may search the server's subtitle providers. Default: no, which hides the menu row.
    func canSearchSubtitles() async -> Bool
    /// Subtitles the server's providers offer for the item; `language` is ISO 639-1.
    func searchSubtitles(for ref: MediaItemRef, language: String) async throws -> [SubtitleSearchResult]
    /// Saves a result next to the media. The server lists it as a new external stream shortly after.
    func downloadSubtitle(_ result: SubtitleSearchResult, for ref: MediaItemRef) async throws

    // MARK: - Deletion

    /// Whether this account may delete media from the server. Default: no.
    func canDeleteMedia() async -> Bool
    /// Deletes the item and its files from the server.
    func deleteMedia(_ itemRef: MediaItemRef) async throws
    /// What the delete confirmation says. Default: the files go. A server that removes more than
    /// the item (Emby deletes a movie's whole folder) says so.
    func deleteConfirmation(for item: MediaItem) async -> String

    // MARK: - Watchlist
    var supportsWatchlist: Bool { get }
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool
    func addToWatchlist(_ ref: MediaItemRef) async throws
    func removeFromWatchlist(_ ref: MediaItemRef) async throws

    // MARK: - Playlists (video)
    var supportsPlaylists: Bool { get }
    /// Regular and smart video playlists, sorted by title.
    func videoPlaylists() async throws -> [MediaPlaylist]
    /// Every row, all pages, in the server's order.
    func playlistEntries(_ playlist: MediaItemRef) async throws -> PlaylistContents
    func createPlaylist(title: String, seededWith items: [MediaItemRef]) async throws -> MediaPlaylist
    func addToPlaylist(_ playlist: MediaItemRef, items: [MediaItemRef]) async throws
    func removeFromPlaylist(_ playlist: MediaItemRef, entryID: String) async throws
    /// `entries` is the order before the move; each backend derives what its server takes.
    func movePlaylistEntry(_ playlist: MediaItemRef, entryID: String, toIndex: Int, in entries: [PlaylistEntry]) async throws
    func renamePlaylist(_ playlist: MediaItemRef, title: String) async throws
    func deletePlaylist(_ playlist: MediaItemRef) async throws

    // MARK: - Downloads

    /// Whether this account may save the server's files for offline use. Default: no. Plex says yes
    /// and downloads through its own conversion queue, not `downloadSource`.
    func canDownloadMedia() async throws -> Bool
    /// The original file of the version (nil: the item's own) as a ranged GET. Default: unsupported.
    func downloadSource(for itemRef: MediaItemRef, sourceID: String?) async throws -> DownloadSource

    // MARK: - Content advisory

    /// Provider-agnostic content advisory (Common Sense Media on Plex). Returns
    /// nil when the backend has none. Default = nil so backends opt in.
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory?

    /// Identity keys (`ContinueWatchingMerge`) for these shows, by show item id,
    /// fetched in as few requests as the server allows. Default: none.
    func showIdentityKeys(for showIDs: [String]) async -> [String: [String]]

    /// Skip markers (intro, credits, ...) for the item. Default: none.
    /// Best effort: a backend without the data returns an empty value.
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras

    /// Server-made scrub stills for the version (Jellyfin trickplay), or nil. Default: nil.
    func scrubPreviews(for itemRef: MediaItemRef, sourceID: String?) async -> (any ScrubPreviewSource)?
}

extension MediaProvider {
    func themeVideoURL(for itemRef: MediaItemRef) async throws -> URL? { nil }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?,
                       startTime: TimeInterval) async throws -> StreamInfo {
        try await resolveStream(for: itemRef, sourceID: sourceID, maxBitrate: maxBitrate)
    }
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
    func moreLikeThis(for ref: MediaItemRef, kind: MediaKind) async throws -> [MediaItem] {
        try await related(for: ref, kind: kind).items
    }
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras { PlaybackExtras() }
    func scrubPreviews(for itemRef: MediaItemRef, sourceID: String?) async -> (any ScrubPreviewSource)? { nil }
    func showIdentityKeys(for showIDs: [String]) async -> [String: [String]] { [:] }
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory? { nil }
    func search(_ query: String, inLibraries libraryIDs: [String]) async throws -> [MediaItem] {
        try await search(query)
    }
    func searchHits(_ query: String, inLibraries libraryIDs: [String]?) async throws -> SearchHits {
        let titles: [MediaItem]
        if let libraryIDs { titles = try await search(query, inLibraries: libraryIDs) } else { titles = try await search(query) }
        return SearchHits(titles: SearchRank.ranked(titles, query: query))
    }
    func filmography(of person: MediaPerson) async throws -> [FilmographyEntry] { [] }
    func biography(of person: MediaPerson) async -> String? { nil }
    func collections(in library: MediaLibrary) async throws -> [MediaItem] { [] }
    func sortOptions(for kind: MediaLibrary.LibraryKind) -> [LibrarySortOption] {
        LibrarySortOption.expressible(for: kind)
    }
    var accountID: String? { nil }
    func promotedHubs(in libraries: [MediaLibrary]) async throws -> [String: [MediaHub]] {
        let found = await BoundedFanOut.map(libraries) { library in
            (library.id, try? await hubs(in: library).filter(\.isPromoted))
        }
        var byLibrary: [String: [MediaHub]] = [:]
        for case let (id, hubs?) in found { byLibrary[id] = hubs }
        return byLibrary
    }
    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        try await hubs(in: library).first { $0.id == "\(library.id).recentlyAdded" }
    }
    var supportsFavorites: Bool { false }
    func favorites(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] { [] }
    func setFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "favorites not supported")
    }
    func trending(in library: MediaLibrary, from trending: [TMDBListItem], limit: Int) async throws -> [MediaItem] { [] }
    func items(in library: MediaLibrary, sort: SortOption, filter: LibraryFilter, page: Page) async throws -> PagedResult<MediaItem> {
        guard filter.isActive else { return try await items(in: library, sort: sort, page: page) }
        throw MediaProviderError.backendSpecific(underlying: "library filter not supported")
    }
    func filterOptions(in library: MediaLibrary) async throws -> LibraryFilterOptions { LibraryFilterOptions() }
    func items(in library: MediaLibrary, sort: SortOption, unwatchedOnly: Bool, page: Page) async throws -> PagedResult<MediaItem> {
        try await items(in: library, sort: sort, filter: LibraryFilter(unwatchedOnly: unwatchedOnly), page: page)
    }
    func shuffledItems(in library: MediaLibrary, unwatchedOnly: Bool, limit: Int) async throws -> [MediaItem] {
        throw MediaProviderError.backendSpecific(underlying: "shuffle not supported")
    }
    func hubPage(_ hub: MediaHub, page: Page) async throws -> PagedResult<MediaItem> {
        PagedResult(items: page.offset == 0 ? hub.items : [], total: hub.items.count, nextPage: nil)
    }
    func ownedItems(matching titles: [TitleMatch], limit: Int) async throws -> [MediaItem] { [] }
    func imageURL(_ url: URL, width: Int, height: Int) -> URL { url }
    func logoURL(for item: MediaItem) async -> URL? {
        switch item.kind {
        case .episode: item.grandparentArtwork?.logo ?? item.artwork.logo
        case .season: item.parentArtwork?.logo ?? item.artwork.logo
        default: item.artwork.logo
        }
    }
    func letterCounts(in library: MediaLibrary) async throws -> [PlexFirstCharacter] { [] }
    func refreshMetadata(_ itemRef: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "refresh not supported")
    }
    func canRefreshMetadata() async -> Bool { true }
    func removeFromContinueWatching(_ item: MediaItem) async throws {
        guard item.kind != .episode else { return }
        try await updateProgress(item.ref, position: 0)
    }
    func canRemoveFromContinueWatching(_ item: MediaItem) -> Bool { item.kind != .episode }
    func canDownloadMedia() async -> Bool { false }
    func downloadSource(for itemRef: MediaItemRef, sourceID: String?) async throws -> DownloadSource {
        throw MediaProviderError.backendSpecific(underlying: "downloads not supported")
    }
    func canSearchSubtitles() async -> Bool { false }
    func searchSubtitles(for ref: MediaItemRef, language: String) async throws -> [SubtitleSearchResult] { [] }
    func downloadSubtitle(_ result: SubtitleSearchResult, for ref: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "subtitle search not supported")
    }
    func canDeleteMedia() async -> Bool { false }
    func deleteConfirmation(for item: MediaItem) async -> String { standardDeleteConfirmation(for: item) }
    /// The default text, for an override that has nothing more to say about this item.
    func standardDeleteConfirmation(for item: MediaItem) -> String {
        item.kind == .show || item.kind == .season
            ? String(localized: "Every episode's files will be deleted from \(displayName). This cannot be undone.")
            : String(localized: "The files will be deleted from \(displayName). This cannot be undone.")
    }
    func deleteMedia(_ itemRef: MediaItemRef) async throws {
        throw MediaProviderError.backendSpecific(underlying: "delete not supported")
    }

    var supportsPlaylists: Bool { false }
    func videoPlaylists() async throws -> [MediaPlaylist] { [] }
    func playlistEntries(_ playlist: MediaItemRef) async throws -> PlaylistContents {
        PlaylistContents(entries: [], isSmart: false)
    }
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

extension LibrarySortOption {
    /// Plex's sorts for the library kind, minus resolution: `SortOption` cannot send it,
    /// and Jellyfin ignores an unknown sortBy.
    static func expressible(for kind: MediaLibrary.LibraryKind) -> [LibrarySortOption] {
        let plexType: String? = switch kind {
        case .movies: "movie"
        case .shows: "show"
        default: nil
        }
        return options(for: plexType).filter { $0 != .resolutionDesc && $0 != .resolutionAsc }
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

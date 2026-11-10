// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BrowseStore.swift
//  Rivulet
//
//  What the browse screens show, for every signed-in server: Home, libraries and playlists, read
//  through MediaProviderRegistry. The counterpart of tvOS's PlexDataStore and ServerDataStore.
//  The assembly lives in RivuletCore (HomeFeed); this publishes it and runs the actions the
//  menus offer. Plex sign-in and profile state stay in PlexSession.
//

import Combine
import Foundation

@MainActor
final class BrowseStore: ObservableObject {
    @Published private(set) var libraries: [MediaLibrary] = []
    /// Photo libraries across servers, for the sidebar; never in `libraries`.
    @Published private(set) var photoLibraries: [MediaLibrary] = []
    /// Home rows after Continue Watching: promoted rows of the selected Plex server, then each other server's.
    @Published private(set) var shelves: [MediaHub] = []
    /// One row across every server: the same title on two servers is one card.
    @Published private(set) var continueWatching: [MediaItem] = []
    /// Each server's video playlists by provider id; only servers that have any.
    @Published private(set) var playlists: [String: [MediaPlaylist]] = [:]
    /// Favorites and playlist rows, for Home and the hero (`PersonalRows`).
    @Published var personalRows: [PersonalRow] = []
    /// Bumped when a Home or hero setting changes, so Home redraws from `UserDefaults`.
    @Published var homeSettingsRevision = 0
    @Published private(set) var isLoadingContent = false
    /// Other servers still to answer; a tab on one of their libraries waits for this.
    @Published private(set) var isLoadingOtherServers = false
    @Published private(set) var contentError: String?
    /// Bumped after a watched-state change so open grids and detail pages reload.
    @Published private(set) var watchStateRevision = 0
    /// Favorites changed here this session, so menus and hearts are right before lists refetch.
    @Published private(set) var favoriteOverrides: [MediaItemRef: Bool] = [:]
    /// Libraries the profile hid from the sidebar (`SidebarLibraryVisibility`).
    @Published var hiddenSidebarLibraries: Set<String> = SidebarLibraryVisibility.stored() {
        didSet {
            guard hiddenSidebarLibraries != oldValue else { return }
            loader.hiddenLibraries = hiddenSidebarLibraries
            loader.publish()
            reloadPersonalRows()
        }
    }
    /// Bumped on a server or profile switch; the tab stacks rebuild on it.
    @Published private(set) var sessionGeneration = 0
    /// Providers where the account may delete media; asked once per session.
    @Published private(set) var deletableProviders: Set<String> = []
    /// Providers where the account may save files for offline use; asked once per session.
    @Published private(set) var downloadableProviders: Set<String> = []
    private var downloadPermissions = DownloadPermissions()
    @Published private(set) var labels = ServerLabels([])
    /// Any server to browse, Plex or not: Home shows content, not the sign-in prompt.
    @Published private(set) var hasServers = false
    /// Servers whose last fetch failed, by provider id, with the error's message.
    @Published private(set) var failures: [String: String] = [:]

    /// Run after each refresh that reached a server (Plex sends its offline progress here).
    var afterRefresh: (() async -> Void)?

    let registry = MediaProviderRegistry.shared
    private let loader = HomeFeedLoader()
    private let heroSources = HomeHeroSources()
    private var cwRows: [[MediaItem]] = []
    /// A merged card's copies on other servers, by the card's ref.
    private var cwCopies: [MediaItemRef: [MediaItem]] = [:]
    private var refreshGeneration = 0
    private var lastContentRefresh: Date?
    private var signature = ""
    private var checkedPermissions: Set<String> = []
    private var refreshBlocked: Set<String> = []
    private var logos: [MediaItemRef: URL] = [:]
    var cancellables = Set<AnyCancellable>()
    var personalTask: Task<Void, Never>?

    init() {
        loader.onChange = { [weak self] home in self?.apply(home) }
        loader.hiddenLibraries = hiddenSidebarLibraries
        loader.onSecondaryFinished = { [weak self] in
            self?.isLoadingOtherServers = false
            self?.reloadPersonalRows()
        }
        observeHomeSettings()
        ContinueWatchingRow.shared.fetchShowKeys = { providerID, showIDs in
            await MediaProviderRegistry.shared.provider(for: providerID)?.showIdentityKeys(for: showIDs) ?? [:]
        }
        ContinueWatchingRow.shared.$version.dropFirst()
            .sink { [weak self] _ in self?.mergeContinueWatching() }
            .store(in: &cancellables)
    }

    // MARK: - Providers

    /// The selected Plex server, then every other server a restricted profile may see.
    var providersInPlay: (selected: (any MediaProvider)?, secondary: [any MediaProvider]) {
        let restricted = PlexUserProfileManager.shared.isRestrictedProfile
        return (registry.plexProvider, registry.secondaryProviders.filter { $0.kind == .plex || !restricted })
    }

    var allProviders: [any MediaProvider] {
        let (selected, secondary) = providersInPlay
        return (selected.map { [$0] } ?? []) + secondary
    }

    func provider(for providerID: String) -> (any MediaProvider)? { registry.provider(for: providerID) }

    func provider(for ref: MediaItemRef) throws -> any MediaProvider {
        guard let provider = registry.provider(for: ref.providerID) else { throw MediaProviderError.unreachable }
        return provider
    }

    /// The selected Plex server first; the order tabs, search and groups keep.
    var providerOrder: [String] { allProviders.map(\.id) }

    /// Every server a search asks.
    var searchProviders: [any MediaProvider] { allProviders }

    // MARK: - Content

    func refresh() async {
        let (selected, secondary) = providersInPlay
        let providers = (selected.map { [$0] } ?? []) + secondary
        labels = ServerLabels(providers: providers)
        hasServers = !providers.isEmpty
        guard !providers.isEmpty else { return clearContent() }
        refreshGeneration += 1
        let generation = refreshGeneration
        let current = Self.signature(selected: selected, secondary: secondary)
        if current != signature {
            signature = current
            resetForNewSession()
        }
        isLoadingContent = true
        defer { if generation == refreshGeneration { isLoadingContent = false } }
        isLoadingOtherServers = !secondary.isEmpty
        do {
            // The selected server's failure is the page's; another server's only drops its rows.
            async let lists = playlistsOf(selected.map { [$0] } ?? [])
            try await loader.load(selected: selected, secondary: secondary)
            let selectedLists = await lists
            guard generation == refreshGeneration else { return }
            applyPlaylists(selectedLists)
            reloadPersonalRows()
            contentError = nil
            lastContentRefresh = .now
        } catch let error where isCancellationError(error) {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            contentError = error.localizedDescription
            return await PlexWatchlistService.shared.fetchWatchlist()
        }
        if !secondary.isEmpty {
            Task {
                let lists = await playlistsOf(secondary)
                guard generation == refreshGeneration else { return }
                applyPlaylists(lists)
            }
        }
        if selected != nil { await PlexWatchlistService.shared.fetchWatchlist() }
        await afterRefresh?()
        await loadPermissions(providers)
    }

    /// Foreground return: refetch only when Home is more than five minutes old.
    func refreshIfStale() async {
        guard let lastContentRefresh, Date.now.timeIntervalSince(lastContentRefresh) > 300 else { return }
        await refresh()
    }

    /// A server or profile switch: open pages belong to the old one, so the tab stacks reset.
    func contentSessionChanged() {
        favoriteOverrides = [:]
        hiddenSidebarLibraries = SidebarLibraryVisibility.stored()
        sessionGeneration += 1
    }

    /// Called after playback or a watched toggle: repaint open pages, then Home.
    func watchStateDidChange() async {
        PlexNetworkManager.shared.forgetRecentReads()
        watchStateRevision += 1
        await refresh()
    }

    func clearContent() {
        resetForNewSession()
        signature = ""
        libraries = []
        photoLibraries = []
        shelves = []
        continueWatching = []
        playlists = [:]
        personalRows = []
        hasServers = false
        labels = ServerLabels([])
        failures = [:]
        contentError = nil
        lastContentRefresh = nil
        isLoadingOtherServers = false
        PlexWatchlistService.shared.reset()
    }

    private func resetForNewSession() {
        favoriteOverrides = [:]
        loader.reset()
        heroSources.reset()
        personalTask?.cancel()
        personalRows = []
        cwRows = []
        cwCopies = [:]
        logos = [:]
        checkedPermissions = []
        downloadPermissions.reset()
        downloadableProviders = []
        deletableProviders = []
        refreshBlocked = []
        libraries = []
        photoLibraries = []
        shelves = []
        continueWatching = []
        failures = [:]
    }

    /// The servers and the Plex token: a change of either means different rows, not a refresh.
    private static func signature(selected: (any MediaProvider)?, secondary: [any MediaProvider]) -> String {
        let plex = (selected as? PlexProvider).map { "\($0.id)|\($0.serverURL)|\($0.authToken)" } ?? ""
        return ([plex] + secondary.map { ($0 as? PlexProvider).map { "\($0.id)|\($0.authToken)" } ?? $0.id }).joined(separator: ",")
    }

    private func apply(_ assembled: HomeFeed.Assembled) {
        let home = ClientHost.transformHome(assembled)
        failures = home.failures
        libraries = home.libraries
        photoLibraries = home.photoLibraries
        shelves = home.shelves
        cwRows = home.continueWatching
        mergeContinueWatching()
    }

    /// Re-merges the servers' rows; runs again when show identities arrive.
    private func mergeContinueWatching() {
        let cards = HomeFeed.continueWatchingCards(cwRows)
        cwCopies = Dictionary(cards.filter { !$0.others.isEmpty }.map { ($0.item.ref, $0.others) }, uniquingKeysWith: { first, _ in first })
        continueWatching = cards.map(\.item)
    }

    struct FailedServer: Identifiable {
        let id: String
        let name: String
        let message: String
    }

    /// The servers that failed, in server order, for the banners that name them.
    var failedServers: [FailedServer] {
        let order = providerOrder
        return failures.keys.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }.map { id in
            FailedServer(id: id, name: registry.provider(for: id)?.displayName
                         ?? MediaProviderKind(providerID: id)?.displayName ?? id, message: failures[id] ?? "")
        }
    }

    /// Continue Watching as a row with no key: a merged row has no one server to page from.
    var continueWatchingHub: MediaHub? {
        continueWatching.isEmpty ? nil : MediaHub(id: Self.continueWatchingID, providerID: "",
                                                  title: String(localized: "Continue Watching"), style: .shelf, items: continueWatching)
    }

    static let continueWatchingID = "continueWatching"

    // MARK: - Playlists

    private func playlistsOf(_ providers: [any MediaProvider]) async -> [String: [MediaPlaylist]?] {
        await withTaskGroup(of: (String, [MediaPlaylist]?).self) { group in
            for provider in providers where provider.supportsPlaylists {
                group.addTask { (provider.id, try? await provider.videoPlaylists()) }
            }
            return await group.reduce(into: [:]) { $0[$1.0] = .some($1.1) }
        }
    }

    /// Nil keeps the server's last answer.
    private func applyPlaylists(_ answers: [String: [MediaPlaylist]?]) {
        let present = Set(allProviders.map(\.id))
        playlists = playlists.filter { present.contains($0.key) }
        for case let (id, lists?) in answers { playlists[id] = lists.isEmpty ? nil : lists }
    }

    /// After a playlist edit: the Library rows and sidebar tabs follow the new lists.
    func refreshPlaylists() async {
        applyPlaylists(await playlistsOf(allProviders))
        reloadPersonalRows()
    }

    func playlists(providerID: String) -> [MediaPlaylist] { playlists[providerID] ?? [] }

    // MARK: - Permissions

    /// Asks each provider not yet asked this session whether the account may delete or refresh there.
    private func loadPermissions(_ providers: [any MediaProvider]) async {
        for provider in providers where !checkedPermissions.contains(provider.id) {
            checkedPermissions.insert(provider.id)
            if await provider.canDeleteMedia() { deletableProviders.insert(provider.id) }
            if await !provider.canRefreshMetadata() { refreshBlocked.insert(provider.id) }
        }
        // Download is asked until a server answers, so one failed read never hides it for the session.
        var asked = downloadPermissions
        await asked.ask(providers)
        downloadPermissions = asked
        if asked.allowed != downloadableProviders { downloadableProviders = asked.allowed }
    }

    /// Whether the item can be downloaded: a Plex server still signed in, or a server whose account may.
    func canDownload(_ item: MediaItem) -> Bool {
        IOSDownloadGate.canDownload(item.ref)
            && (item.ref.plexRoute != nil || downloadableProviders.contains(item.ref.providerID))
    }

    func canDelete(_ item: MediaItem) -> Bool {
        item.kind.plexType != nil && deletableProviders.contains(item.ref.providerID)
    }

    /// Refresh stays offered until a server says this account may not (Emby non-admins).
    func canRefreshMetadata(_ item: MediaItem) -> Bool {
        item.kind.plexType != nil && !refreshBlocked.contains(item.ref.providerID)
    }

    func supportsWatchlist(_ item: MediaItem) -> Bool {
        registry.provider(for: item.ref.providerID)?.supportsWatchlist == true
            && PlexAuthManager.shared.accountContentToken != nil && item.kind.plexType != nil
    }

    // MARK: - Actions on items

    /// Marks a show or season as a whole, like any client; a merged card reaches its other copies too.
    func setWatched(_ watched: Bool, for item: MediaItem) async throws {
        try await WatchStateRouting.setPlayed(watched, item: item, copies: cwCopies[item.ref] ?? [],
                                              provider: { MediaProviderRegistry.shared.provider(for: $0) })
        await watchStateDidChange()
    }

    /// Offered on a Continue Watching card whose server can drop it.
    func canRemoveFromContinueWatching(_ item: MediaItem) -> Bool {
        continueWatching.contains { $0.ref == item.ref } && registry.provider(for: item.ref.providerID)?.canRemoveFromContinueWatching(item) == true
    }

    /// Drops the card; a merged card's other copies go with it, or the row brings it back.
    func removeFromContinueWatching(_ item: MediaItem) async throws {
        try await provider(for: item.ref).removeFromContinueWatching(item)
        for copy in cwCopies[item.ref] ?? [] { try? await registry.provider(for: copy.ref.providerID)?.removeFromContinueWatching(copy) }
        await watchStateDidChange()
    }

    func refreshMetadata(_ item: MediaItem) async throws {
        try await provider(for: item.ref).refreshMetadata(item.ref)
        await watchStateDidChange()
    }

    func delete(_ item: MediaItem) async throws {
        try await provider(for: item.ref).deleteMedia(item.ref)
        await watchStateDidChange()
    }

    func deleteConfirmation(for item: MediaItem) async -> String {
        guard let provider = registry.provider(for: item.ref.providerID) else { return "" }
        return await provider.deleteConfirmation(for: item)
    }

    /// Without a request, from the ids a list carries: Plex's list of movies and shows.
    func isOnWatchlist(_ item: MediaItem) -> Bool {
        let service = PlexWatchlistService.shared
        return WatchlistMembership.isListed(item, plexGUIDs: Set(service.watchlistItems.compactMap(\.plexGUID)),
                                            contains: { service.contains(guid: $0) })
    }

    /// The item's favorite state, as changed here or as its list said.
    func isFavorite(_ item: MediaItem) -> Bool {
        favoriteOverrides[item.ref] ?? item.userState.isFavorite
    }

    func setFavorite(_ on: Bool, item: MediaItem) async throws {
        try await FavoritesFeed.set(on, for: item)
        favoriteOverrides[item.ref] = on
        await watchStateDidChange()
    }

    func setWatchlisted(_ on: Bool, item: MediaItem) async throws {
        let provider = try provider(for: item.ref)
        if on { try await provider.addToWatchlist(item.ref) } else { try await provider.removeFromWatchlist(item.ref) }
    }

    // MARK: - Hero

    func trendingHeroItems() async -> [MediaItem] {
        await heroSources.trending(providers: allProviders).filter(isShownOnHome)
    }

    /// The watchlist's first ten entries that any server owns, in watchlist order.
    func watchlistHeroItems() async -> [MediaItem] {
        let entries = Array(PlexWatchlistService.shared.watchlistItems.prefix(10))
        return await heroSources.watchlist(titles: entries.map(TitleMatch.init), key: entries.map(\.id), providers: allProviders)
            .filter(isShownOnHome)
    }

    /// False for an item from a hidden library; an item that names no library stays.
    func isShownOnHome(_ item: MediaItem) -> Bool {
        guard let libraryID = item.libraryID else { return true }
        return !hiddenSidebarLibraries.contains(SidebarLibraryVisibility.key(providerID: item.ref.providerID, libraryID: libraryID))
    }

    // MARK: - Artwork

    /// Which artwork a call site wants. `.thumb` on an episode is a 16:9 still, while `.poster` on the
    /// same episode is its show's 2:3 poster; the wrong one letterboxes or crops every tile in a rail.
    enum ArtworkKind {
        /// 2:3 tile art. Episodes resolve to the show poster (tvOS `PosterCell`).
        case poster
        /// The item's own image. 16:9 for episodes, square for music.
        case thumb
        /// Wide background art.
        case backdrop
    }

    func artworkURL(for item: MediaItem, kind: ArtworkKind = .thumb, width: Int = 900, height: Int = 1350) -> URL? {
        let url: URL? = switch kind {
        case .poster: item.grandparentArtwork?.poster ?? item.artwork.poster ?? item.parentArtwork?.poster
        case .thumb: item.artwork.thumbnail ?? item.artwork.poster
        case .backdrop: item.kind == .episode
            ? (item.grandparentArtwork?.backdrop ?? item.artwork.backdrop ?? item.artwork.thumbnail)
            : (item.artwork.backdrop ?? item.artwork.thumbnail)
        }
        return imageURL(url, providerID: item.ref.providerID, width: width, height: height)
    }

    /// `url` resized by its server at the given pixel size. A server no longer signed in leaves it as is.
    func imageURL(_ url: URL?, providerID: String, width: Int, height: Int) -> URL? {
        guard let url else { return nil }
        return registry.provider(for: providerID)?.imageURL(url, width: width, height: height) ?? url
    }

    /// Episodes and seasons take their show's logo, which list responses omit; the provider finds
    /// and remembers it. Kept here too so a view can draw it on its first frame.
    func logoURL(for item: MediaItem) async -> URL? {
        guard let provider = registry.provider(for: item.ref.providerID) else { return item.artwork.logo }
        let url = await provider.logoURL(for: item)
        if let url { logos[item.logoOwner] = url }
        return url
    }

    /// The logo if `logoURL(for:)` already resolved it.
    func cachedLogoURL(for item: MediaItem) -> URL? { logos[item.logoOwner] }

    /// Resolves logos and downloads them with the art, in row order, four at a time, so cards
    /// scrolled into view are already complete. Each `art` must be the URL the card itself requests.
    func prefetchArtwork(_ jobs: [(item: MediaItem, art: URL?)]) async {
        let prefetch = ClientHost.prefetchImage
        await withTaskGroup(of: Void.self) { group in
            for (index, job) in jobs.enumerated() {
                if Task.isCancelled { break }
                if index >= 4 { await group.next() }
                group.addTask {
                    if let logo = await self.logoURL(for: job.item) { await prefetch(logo) }
                    if let art = job.art { await prefetch(art) }
                }
            }
        }
    }
}

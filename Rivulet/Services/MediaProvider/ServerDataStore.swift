// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ServerDataStore.swift
//  Rivulet
//
//  What the browse surfaces show from every server beside the selected Plex
//  one (the account's other Plex servers, Jellyfin): their libraries (sidebar,
//  Settings) and their Home rows. The counterpart of PlexDataStore's library
//  list and Home projection, without disk caches. Rows are never merged across
//  servers; each server's sit together, in `sources` order.
//

import Combine
import Foundation

@MainActor
final class ServerDataStore: ObservableObject {
    static let shared = ServerDataStore()

    /// One signed-in server.
    struct Source: Equatable {
        let providerID: String
        let name: String
    }

    /// The servers shown, in order: extra Plex servers by name, then Jellyfin.
    @Published private(set) var sources: [Source] = []
    /// Every browsable library, server by server in server order. The sidebar
    /// and Home use `visibleLibraries`; Settings > Sidebar Libraries lists these.
    @Published private(set) var libraries: [MediaLibrary] = []
    /// Every row, hidden ones included: Settings > Home Rows lists them so a
    /// hidden row can be switched back on. Per server: Continue Watching first,
    /// then one Recently Added row per library in server order.
    @Published private(set) var homeRows: CachedHomeRail = []
    @Published private(set) var isLoading = false
    /// Each library's titles on TMDB's trending lists, in trending order, by
    /// `settingsKey`. Home's hero reads them through `visibleTrending`.
    @Published private(set) var trending: [String: [MediaItem]] = [:]

    /// Video, photo and music libraries.
    static let browsableKinds: Set<MediaLibrary.LibraryKind> = [.movies, .shows, .mixed, .photos, .music]

    /// Libraries with a Recently Added row. Photo and music tiles would open the video detail.
    static let homeRowKinds: Set<MediaLibrary.LibraryKind> = [.movies, .shows, .mixed]

    private struct Slice {
        var libraries: [MediaLibrary] = []
        var rows: CachedHomeRail = []
        var trending: [String: [MediaItem]] = [:]
        var trendingAt: Date?
    }

    /// TMDB's own list cache lifetime; each server's matches are refetched no sooner.
    private static let trendingLifetime: TimeInterval = 3600

    private var slices: [String: Slice] = [:]
    private var loadTask: Task<Void, Never>?
    private var loadsInFlight = 0
    private var refreshObserver: NSObjectProtocol?

    init(observesRefresh: Bool = true) {
        guard observesRefresh else { return }
        // Before the first sidebar render, so a Jellyfin-only launch never
        // flashes the signed-out welcome.
        if !PlexUserProfileManager.shared.isRestrictedProfile, let account = JellyfinSession.account {
            sources = [Source(providerID: account.providerID, name: account.serverName)]
        }
        // Watch-state changes (detail page, tile menus, playback) post this.
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .plexDataNeedsRefresh, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var isSignedIn: Bool { !sources.isEmpty }

    /// The signed-in Jellyfin server, which owns Live TV and the restricted-profile rule.
    var jellyfinSource: Source? { sources.first { $0.providerID.hasPrefix("jellyfin:") } }

    /// The sidebar's server sections, in the user's order.
    var visibleLibraries: [MediaLibrary] {
        LibrarySettingsManager.shared.filterAndSort(libraries)
    }

    /// Per server: Continue Watching, then each visible library's row in
    /// sidebar order. Settings > Home Rows lists these, hidden rows included.
    var homeRowsInSidebarOrder: CachedHomeRail {
        let visible = visibleLibraries
        let providerIDs = sources.map(\.providerID)
            + Set(homeRows.map(\.providerID)).subtracting(sources.map(\.providerID)).sorted()
        return providerIDs.flatMap { providerID in
            homeRows.filter { $0.isContinueWatching && $0.providerID == providerID }
                + visible.filter { $0.providerID == providerID }.compactMap { library in
                    let id = Self.rowID(providerID, "\(library.id).recentlyAdded")
                    return homeRows.first { $0.id == id }
                }
        }
    }

    /// The rows Home draws: `homeRowsInSidebarOrder` minus rows hidden in
    /// Settings > Home Rows. Home's empty check reads this too, so a Home
    /// whose only rows are hidden takes the empty state rather than drawing
    /// nothing.
    var visibleHomeRows: CachedHomeRail {
        homeRowsInSidebarOrder.filter { !HomeRowSettings.isHidden($0.hubIdentifier) }
    }

    /// `trending` for the sidebar's visible libraries, in sidebar order.
    var visibleTrending: [[MediaItem]] {
        visibleLibraries.compactMap { trending[$0.settingsKey] }
    }

    /// More than one source is signed in, so rows and tiles name their server.
    var labelsServers: Bool {
        sources.count + (PlexAuthManager.shared.hasCredentials ? 1 : 0) > 1
    }

    /// Re-reads the signed-in servers and refetches each. Called at launch,
    /// from `JellyfinSession.onChanged`, when the extra Plex servers change,
    /// on `.plexDataNeedsRefresh`, and on foreground.
    // ponytail: no timed poll; content added on a server shows on the next
    // foreground or watch-state change. Add one like PlexDataStore's 30s
    // poll if that proves too slow.
    func reload() {
        loadTask?.cancel()
        // The sidebar's Playlists rows follow every server reload, the selected Plex server's included.
        if self === Self.shared { Task { await PlaylistAvailability.shared.refresh() } }
        // A restricted profile does not see the Jellyfin server; a signed-out one is gone.
        let jellyfinID = PlexUserProfileManager.shared.isRestrictedProfile ? nil : JellyfinSession.account?.providerID
        let providers = MediaProviderRegistry.shared.secondaryProviders.filter { $0.kind != .jellyfin || $0.id == jellyfinID }
        // Assigned only on change: Plex-only users reach here on every launch,
        // foreground and watch-state change, and each publish redraws Home.
        update(\.sources, providers.map { Source(providerID: $0.id, name: $0.displayName) })
        // The server's Live TV follows the account into and out of Live TV.
        JellyfinLiveTVProvider.sync(providers.first { $0.kind == .jellyfin } as? JellyfinProvider)
        let gone = Set(slices.keys).subtracting(providers.map(\.id))
        gone.forEach { slices.removeValue(forKey: $0) }
        if !gone.isEmpty || providers.isEmpty { publish() }
        guard !providers.isEmpty else {
            update(\.isLoading, false)
            return
        }
        // Synchronous, so the first render after sign-in shows loading, not empty.
        update(\.isLoading, true)
        loadTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for provider in providers {
                    group.addTask { await self.load(from: provider) }
                }
            }
            // Shared store only: tests load providers without reaching TMDB.
            if self === Self.shared { await self.loadTrending(from: providers) }
        }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ServerDataStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// One server's fetch. A failed fetch keeps what was there: a server that
    /// drops off for a moment must not empty the sidebar or Home under the user.
    func load(from provider: any MediaProvider) async {
        loadsInFlight += 1
        update(\.isLoading, true)
        defer {
            loadsInFlight -= 1
            if loadsInFlight == 0 { update(\.isLoading, false) }
        }
        let previous = slices[provider.id] ?? Slice()
        async let fetchedContinuing = provider.continueWatching(limit: 20)
        let fetched: [MediaLibrary]
        do {
            fetched = try await provider.libraries()
        } catch {
            DiagLog.error(.servers, "\(provider.kind) libraries failed: \(DiagLog.describe(error))")
            _ = try? await fetchedContinuing
            return
        }
        var browsable = fetched.filter { Self.browsableKinds.contains($0.kind) }
        // Music plays through the selected server only (MusicProviderRegistry).
        if provider.kind == .plex { browsable.removeAll { $0.kind == .music } }
        var recent: [CachedHomeHub] = []
        for library in browsable where Self.homeRowKinds.contains(library.kind) {
            let id = Self.rowID(provider.id, "\(library.id).recentlyAdded")
            do {
                if let hub = try await provider.recentlyAddedHub(in: library) {
                    var row = Self.row(hub)
                    row.libraryKey = library.settingsKey
                    recent.append(row)
                }
            } catch {
                DiagLog.error(.servers, "\(provider.kind) recently added failed: \(DiagLog.describe(error))")
                // This library's fetch failed: keep its row.
                if let previous = previous.rows.first(where: { $0.id == id }) { recent.append(previous) }
            }
        }
        var continuingRow: [CachedHomeHub] = []
        var fetchedContinue: [MediaItem]?
        do {
            fetchedContinue = try await fetchedContinuing
        } catch {
            DiagLog.error(.servers, "\(provider.kind) continue watching failed: \(DiagLog.describe(error))")
        }
        if let continuing = fetchedContinue {
            if !continuing.isEmpty {
                let id = Self.rowID(provider.id, "continueWatching")
                continuingRow = [CachedHomeHub(
                    id: id, title: "Continue Watching", isContinueWatching: true, hubKey: nil,
                    hubIdentifier: id, totalSize: nil, items: continuing)]
            }
        } else {
            continuingRow = previous.rows.filter(\.isContinueWatching)
        }
        guard !Task.isCancelled else { return }
        DiagLog.notice(.servers, "\(provider.kind) loaded: \(browsable.count) libraries, continue watching \(continuingRow.first?.items.count ?? 0), recent rows \(recent.count)")
        slices[provider.id] = Slice(libraries: browsable, rows: continuingRow + recent,
                                    trending: previous.trending, trendingAt: previous.trendingAt)
        publish()
    }

    /// Each server's trending matches, at most once per `trendingLifetime`.
    /// A failed library keeps its previous matches.
    private func loadTrending(from providers: [any MediaProvider]) async {
        let due = providers.filter { provider in
            guard let slice = slices[provider.id] else { return false }
            return slice.trendingAt.map { Date().timeIntervalSince($0) > Self.trendingLifetime } ?? true
        }
        guard !due.isEmpty else { return }
        async let movies = TMDBDiscoverService.shared.fetchSection(.movieTrending)
        async let shows = TMDBDiscoverService.shared.fetchSection(.tvTrending)
        let titles = TrendingMatch.interleave(movies: await movies, shows: await shows)
        guard !titles.isEmpty else { return }
        for provider in due {
            guard var slice = slices[provider.id] else { continue }
            for library in slice.libraries where Self.homeRowKinds.contains(library.kind) {
                do {
                    slice.trending[library.settingsKey] = try await provider.trending(in: library, from: titles, limit: 10)
                } catch {
                    DiagLog.error(.servers, "\(provider.kind) trending failed: \(DiagLog.describe(error))")
                }
            }
            guard !Task.isCancelled else { return }
            slices[provider.id]?.trending = slice.trending
            slices[provider.id]?.trendingAt = Date()
        }
        publish()
    }

    /// Flattens the slices in `sources` order; a slice whose source is not
    /// listed (tests load providers directly) follows.
    private func publish() {
        let order = sources.map(\.providerID) + slices.keys.sorted().filter { id in !sources.contains { $0.providerID == id } }
        let ordered = order.compactMap { slices[$0] }
        update(\.libraries, ordered.flatMap(\.libraries))
        update(\.trending, ordered.reduce(into: [:]) { $0.merge($1.trending) { a, _ in a } })
        let rows = ordered.flatMap(\.rows)
        guard !(rows.isEmpty && homeRows.isEmpty) else { return }
        homeRows = rows
        refreshTopShelf()
    }

    private func refreshTopShelf() {
        guard self === Self.shared else { return }
        Task { await TopShelfFeed.refresh() }
    }

    /// Provider-prefixed ids keep each server's rows distinct from every other
    /// server's in the Home snapshot and in `HomeRowSettings`.
    static func rowID(_ providerID: String, _ hubID: String) -> String { "\(providerID)|\(hubID)" }

    static func row(_ hub: MediaHub) -> CachedHomeHub {
        let id = rowID(hub.providerID, hub.id)
        return CachedHomeHub(id: id, title: hub.title, isContinueWatching: hub.id.hasSuffix(".continueWatching"),
                             hubKey: nil, hubIdentifier: id, totalSize: nil, items: hub.items)
    }
}

private extension CachedHomeHub {
    /// The server a row came from: its id is "<providerID>|<hub id>".
    var providerID: String { String(id.prefix { $0 != "|" }) }
}

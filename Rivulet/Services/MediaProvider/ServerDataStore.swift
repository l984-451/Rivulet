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
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var visibilityVersion = 0
    @Published private(set) var visibilityErrors: [String: String] = [:]

    var isResolvingVisibility: Bool {
        if !membershipTasks.isEmpty { return true }
        return slices.contains { providerID, slice in
            guard providerID.hasPrefix("silo:"), errors[providerID] == nil else { return false }
            let scope = membershipScope(slice.libraries)
            return scope.allLibraries != scope.visibleLibraries && visibleMembership[providerID]?.scope != scope
        }
    }
    var feedErrors: [String: String] {
        errors.merging(visibilityErrors) { feed, visibility in "\(feed)\n\(visibility)" }
    }
    /// Each library's titles on TMDB's trending lists, in trending order, by
    /// `settingsKey`. Home's hero reads them through `visibleTrending`.
    @Published private(set) var trending: [String: [MediaItem]] = [:]

    /// Video, photo and music libraries.
    static let browsableKinds: Set<MediaLibrary.LibraryKind> = [.movies, .shows, .mixed, .photos, .music]

    /// Libraries with a Recently Added row. Photo and music tiles would open the video detail.
    static let homeRowKinds: Set<MediaLibrary.LibraryKind> = [.movies, .shows, .mixed]

    private struct Slice {
        let accountID: String?
        let authorityRevision: UInt64
        var libraries: [MediaLibrary] = []
        var rows: CachedHomeRail = []
        var trending: [String: [MediaItem]] = [:]
        var trendingAt: Date?

        init(_ provider: any MediaProvider, libraries: [MediaLibrary], rows: CachedHomeRail,
             trending: [String: [MediaItem]] = [:], trendingAt: Date? = nil) {
            accountID = provider.accountID
            authorityRevision = provider.authorityRevision
            self.libraries = libraries
            self.rows = rows
            self.trending = trending
            self.trendingAt = trendingAt
        }

        func isOwned(by provider: any MediaProvider) -> Bool {
            accountID == provider.accountID && authorityRevision == provider.authorityRevision
        }
    }

    /// TMDB's own list cache lifetime; each server's matches are refetched no sooner.
    private static let trendingLifetime: TimeInterval = 3600

    private var slices: [String: Slice] = [:]
    private var loadTask: Task<Void, Never>?
    private var loadsInFlight = 0
    private var refreshObserver: NSObjectProtocol?
    private var generation = 0
    private struct MembershipScope: Equatable {
        let allLibraries: Set<String>
        let visibleLibraries: Set<String>
    }
    private struct VisibleMembership {
        let scope: MembershipScope
        let token: Int
        var itemIDs: Set<String> = []
        var seriesIDs: Set<String> = []
        mutating func include(_ items: [MediaItem], providerID: String) {
            for item in items where item.ref.providerID == providerID {
                itemIDs.insert(item.ref.itemID)
                if item.kind == .show { seriesIDs.insert(item.ref.itemID) }
            }
        }
    }
    private var visibleMembership: [String: VisibleMembership] = [:]
    private var membershipTasks: [String: Task<Void, Never>] = [:]
    private var membershipToken = 0
    private var librarySettingsObserver: AnyCancellable?

    init(observesRefresh: Bool = true) {
        guard observesRefresh else { return }
        // Before the first sidebar render, so a Jellyfin-only launch never
        // flashes the signed-out welcome.
        if !PlexUserProfileManager.shared.isRestrictedProfile, let account = JellyfinSession.account {
            sources = [Source(providerID: account.providerID, name: account.serverName)]
        }
        if !PlexUserProfileManager.shared.isRestrictedProfile, let account = SiloSession.account {
            sources.append(Source(providerID: account.providerID, name: account.serverName))
        }
        // Watch-state changes (detail page, tile menus, playback) post this.
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .plexDataNeedsRefresh, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        librarySettingsObserver = LibrarySettingsManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibleMembership() }
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
        return providerIDs.flatMap { providerID -> CachedHomeRail in
            guard LibrarySettingsManager.shared.areServerLibrariesVisible(providerID),
                  visible.contains(where: { $0.providerID == providerID }) else { return [] }
            let rows = homeRows.filter { $0.providerID == providerID }
            // Native feeds own their ordering, including featured and custom rows.
            if rows.contains(where: { $0.nativeProviderID?.hasPrefix("silo:") == true }) {
                return rows.filter { row in
                    row.libraryKey.map { key in visible.contains { $0.settingsKey == key } } ?? true
                }
            }
            let libraryRows = visible.filter { $0.providerID == providerID }.compactMap { library in
                let id = Self.rowID(providerID, "\(library.id).recentlyAdded")
                return rows.first { $0.id == id }
            }
            let orderedIDs = Set(libraryRows.map(\.id))
            return rows.filter(\.isContinueWatching) + libraryRows
                + rows.filter { !$0.isContinueWatching && $0.libraryKey == nil && !orderedIDs.contains($0.id) }
        }
    }

    /// The rows Home draws: `homeRowsInSidebarOrder` minus rows hidden in
    /// Settings > Home Rows. Home's empty check reads this too, so a Home
    /// whose only rows are hidden takes the empty state rather than drawing
    /// nothing.
    var visibleHomeRows: CachedHomeRail {
        homeRowsInSidebarOrder.filter { !HomeRowSettings.isHidden($0.hubIdentifier) }.compactMap { row in
            guard row.nativeProviderID?.hasPrefix("silo:") == true else { return row }
            var row = row
            row.items = visibleItems(row.items)
            return row.items.isEmpty && row.nextPage == nil ? nil : row
        }
    }

    /// Global Silo cards omit library identity. With hidden libraries, authorize them
    /// against the current profile's library-scoped catalog ID index, never their title.
    func visibleItems(_ items: [MediaItem]) -> [MediaItem] {
        let visible = Set(visibleLibraries.map(\.settingsKey))
        let hiddenProviders = Set(libraries.filter { !visible.contains($0.settingsKey) }.map(\.providerID))
        let scopes = Dictionary(uniqueKeysWithValues: hiddenProviders.map {
            ($0, membershipScope(slices[$0]?.libraries ?? []))
        })
        return items.filter { item in
            guard LibrarySettingsManager.shared.areServerLibrariesVisible(item.ref.providerID) else { return false }
            guard item.ref.providerID.hasPrefix("silo:") else { return true }
            if item.isAvailable == false, item.libraryID == nil { return true }
            guard slices[item.ref.providerID] != nil else { return false }
            guard let libraryID = item.libraryID else {
                guard hiddenProviders.contains(item.ref.providerID) else { return true }
                guard let membership = visibleMembership[item.ref.providerID],
                      membership.scope == scopes[item.ref.providerID] else { return false }
                if membership.itemIDs.contains(item.ref.itemID) { return true }
                let seriesRef = item.kind == .episode ? item.grandparentRef
                    : item.kind == .season ? item.parentRef : nil
                return seriesRef.map { $0.providerID == item.ref.providerID && membership.seriesIDs.contains($0.itemID) } ?? false
            }
            guard let library = libraries.first(where: { $0.providerID == item.ref.providerID && $0.id == libraryID })
            else { return false }
            return visible.contains(library.settingsKey)
        }
    }

    private func membershipScope(_ libraries: [MediaLibrary]) -> MembershipScope {
        let video = libraries.filter { Self.homeRowKinds.contains($0.kind) }
        let visible = video.filter { LibrarySettingsManager.shared.isLibraryVisible($0.settingsKey) }
        return MembershipScope(allLibraries: Set(video.map(\.id)), visibleLibraries: Set(visible.map(\.id)))
    }

    private func invalidateVisibleMembership() {
        let hadMembership = !membershipTasks.isEmpty || !visibleMembership.isEmpty || !visibilityErrors.isEmpty
        membershipTasks.values.forEach { $0.cancel() }
        membershipTasks = [:]
        visibleMembership = [:]
        update(\.visibilityErrors, [:])
        if hadMembership { visibilityVersion += 1 }
    }

    private func refreshVisibleMembership() {
        for (providerID, slice) in slices {
            guard let provider = MediaProviderRegistry.shared.provider(for: providerID) else { continue }
            ensureVisibleMembership(for: provider, libraries: slice.libraries)
        }
    }

    private func ensureVisibleMembership(for provider: any MediaProvider, libraries: [MediaLibrary]) {
        guard provider.kind == .silo else { return }
        let scope = membershipScope(libraries)
        guard scope.allLibraries != scope.visibleLibraries else {
            let hadIndex = visibleMembership.removeValue(forKey: provider.id) != nil
            membershipTasks.removeValue(forKey: provider.id)?.cancel()
            visibilityErrors.removeValue(forKey: provider.id)
            if hadIndex { visibilityVersion += 1 }
            return
        }
        guard visibleMembership[provider.id]?.scope != scope else { return }
        membershipTasks.removeValue(forKey: provider.id)?.cancel()
        membershipToken += 1
        let token = membershipToken
        let expected = generation
        visibleMembership[provider.id] = VisibleMembership(scope: scope, token: token)
        visibilityErrors.removeValue(forKey: provider.id)
        visibilityVersion += 1
        let visible = libraries.filter { scope.visibleLibraries.contains($0.id) }
        guard !visible.isEmpty else { return }
        membershipTasks[provider.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if visibleMembership[provider.id]?.token == token {
                    membershipTasks.removeValue(forKey: provider.id)
                    visibilityVersion += 1
                }
            }
            do {
                for library in visible {
                    var page: Page? = Page(offset: 0, limit: 200)
                    var requested = Set<String>()
                    while let current = page {
                        if let cursor = current.cursor, !requested.insert(cursor).inserted {
                            throw MediaProviderError.backendSpecific(underlying: "Library visibility received a repeated catalog page.")
                        }
                        let result = try await provider.items(in: library, sort: .titleAsc, page: current)
                        guard !Task.isCancelled, generation == expected,
                              visibleMembership[provider.id]?.token == token,
                              membershipScope(slices[provider.id]?.libraries ?? []) == scope else { return }
                        visibleMembership[provider.id]?.include(result.items, providerID: provider.id)
                        visibilityVersion += 1
                        page = result.nextPage
                    }
                }
            } catch {
                guard !Task.isCancelled, generation == expected,
                      visibleMembership[provider.id]?.token == token else { return }
                visibilityErrors[provider.id] = "Library visibility: \(error.localizedDescription)"
            }
        }
    }

    /// `trending` for the sidebar's visible libraries, in sidebar order.
    var visibleTrending: [[MediaItem]] {
        visibleLibraries.compactMap { trending[$0.settingsKey] }
    }

    /// Name sources only when libraries from multiple visible servers remain.
    var labelsServers: Bool {
        let plexID = MediaProviderRegistry.shared.plexProvider?.id
        let plexSources = PlexDataStore.shared.visibleSidebarLibraries.isEmpty ? [] : [plexID ?? "plex"]
        return Set(visibleLibraries.map(\.providerID) + plexSources).count > 1
    }

    /// Re-reads the signed-in servers and refetches each. Called at launch,
    /// from `JellyfinSession.onChanged`, when the extra Plex servers change,
    /// on `.plexDataNeedsRefresh`, and on foreground.
    // ponytail: no timed poll; content added on a server shows on the next
    // foreground or watch-state change. Add one like PlexDataStore's 30s
    // poll if that proves too slow.
    func reload() {
        loadTask?.cancel()
        generation += 1
        loadsInFlight = 0
        invalidateVisibleMembership()
        let loadGeneration = generation
        // The sidebar's Playlists rows follow every server reload, the selected Plex server's included.
        if self === Self.shared { Task { await PlaylistAvailability.shared.refresh() } }
        // A restricted profile does not see the Jellyfin server; a signed-out one is gone.
        let jellyfinID = PlexUserProfileManager.shared.isRestrictedProfile ? nil : JellyfinSession.account?.providerID
        let providers = MediaProviderRegistry.shared.secondaryProviders.filter {
            ($0.kind != .jellyfin || $0.id == jellyfinID)
                && ($0.kind != .silo || (!PlexUserProfileManager.shared.isRestrictedProfile
                    && $0.id == SiloSession.account?.providerID))
        }
        // Assigned only on change: Plex-only users reach here on every launch,
        // foreground and watch-state change, and each publish redraws Home.
        update(\.sources, providers.map { Source(providerID: $0.id, name: $0.displayName) })
        // The server's Live TV follows the account into and out of Live TV.
        JellyfinLiveTVProvider.sync(providers.first { $0.kind == .jellyfin } as? JellyfinProvider)
        let gone = Set(slices.compactMap { id, slice in
            providers.contains { $0.id == id && slice.isOwned(by: $0) } ? nil : id
        })
        gone.forEach { slices.removeValue(forKey: $0) }
        update(\.errors, errors.filter { key, _ in !gone.contains(key) && providers.contains { $0.id == key } })
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
                    group.addTask { await self.load(from: provider, generation: loadGeneration) }
                }
            }
            // Shared store only: tests load providers without reaching TMDB.
            if self === Self.shared { await self.loadTrending(from: providers, generation: loadGeneration) }
        }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ServerDataStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// One server's fetch. A failed fetch keeps what was there: a server that
    /// drops off for a moment must not empty the sidebar or Home under the user.
    func load(from provider: any MediaProvider) async {
        await load(from: provider, generation: generation)
    }

    private func load(from provider: any MediaProvider, generation expected: Int) async {
        guard expected == generation, !Task.isCancelled else { return }
        loadsInFlight += 1
        update(\.isLoading, true)
        defer {
            if expected == generation {
                loadsInFlight -= 1
                if loadsInFlight == 0 { update(\.isLoading, false) }
            }
        }
        let previous = slices[provider.id].flatMap { $0.isOwned(by: provider) ? $0 : nil }
        async let fetchedContinuing = provider.continueWatching(limit: 20)
        let fetched: [MediaLibrary]
        do {
            fetched = try await provider.libraries()
        } catch {
            DiagLog.error(.servers, "\(provider.kind) libraries failed: \(DiagLog.describe(error))")
            guard expected == generation, !Task.isCancelled else { return }
            // Even a first-load failure belongs to this account, not the next
            // user who signs in to the same server identity.
            if previous == nil {
                slices[provider.id] = Slice(provider, libraries: [], rows: [])
            }
            errors[provider.id] = error.localizedDescription
            visibilityVersion += 1
            _ = try? await fetchedContinuing
            return
        }
        var browsable = fetched.filter { Self.browsableKinds.contains($0.kind) }
        // Music plays through the selected server only (MusicProviderRegistry).
        if provider.kind == .plex { browsable.removeAll { $0.kind == .music } }
        if provider.kind != .plex && provider.kind != .jellyfin {
            guard expected == generation, !Task.isCancelled else { return }
            // Sidebar/library access must not depend on the independent Home feed succeeding.
            slices[provider.id] = Slice(provider, libraries: browsable, rows: previous?.rows ?? [])
            publish()
            ensureVisibleMembership(for: provider, libraries: browsable)
            do {
                let hubs = try await provider.hubs()
                _ = try? await fetchedContinuing
                guard expected == generation, !Task.isCancelled else { return }
                slices[provider.id] = Slice(provider, libraries: browsable, rows: hubs.map(Self.row))
                errors.removeValue(forKey: provider.id)
                publish()
            } catch {
                _ = try? await fetchedContinuing
                guard expected == generation, !Task.isCancelled else { return }
                errors[provider.id] = error.localizedDescription
                DiagLog.error(.servers, "\(provider.kind) home feed failed: \(DiagLog.describe(error))")
            }
            return
        }
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
                if let row = previous?.rows.first(where: { $0.id == id }) { recent.append(row) }
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
            continuingRow = previous?.rows.filter(\.isContinueWatching) ?? []
        }
        guard expected == generation, !Task.isCancelled else { return }
        errors.removeValue(forKey: provider.id)
        DiagLog.notice(.servers, "\(provider.kind) loaded: \(browsable.count) libraries, continue watching \(continuingRow.first?.items.count ?? 0), recent rows \(recent.count)")
        slices[provider.id] = Slice(provider, libraries: browsable, rows: continuingRow + recent,
                                    trending: previous?.trending ?? [:], trendingAt: previous?.trendingAt)
        publish()
    }

    /// Jellyfin's trending matches, at most once per `trendingLifetime`.
    /// Native Silo feeds own their recommendations and never need TMDB here.
    /// A failed library keeps its previous matches.
    private func loadTrending(from providers: [any MediaProvider], generation expected: Int) async {
        guard expected == generation, !Task.isCancelled else { return }
        let due = providers.filter { provider in
            guard provider.kind == .jellyfin,
                  MediaProviderRegistry.shared.isCurrentAuthority(provider),
                  let slice = slices[provider.id], slice.isOwned(by: provider),
                  slice.libraries.contains(where: { Self.homeRowKinds.contains($0.kind) }) else { return false }
            return slice.trendingAt.map { Date().timeIntervalSince($0) > Self.trendingLifetime } ?? true
        }
        guard !due.isEmpty else { return }
        async let movies = TMDBDiscoverService.shared.fetchSection(.movieTrending)
        async let shows = TMDBDiscoverService.shared.fetchSection(.tvTrending)
        let titles = TrendingMatch.interleave(movies: await movies, shows: await shows)
        guard expected == generation, !Task.isCancelled, !titles.isEmpty else { return }
        for provider in due {
            guard MediaProviderRegistry.shared.isCurrentAuthority(provider),
                  var slice = slices[provider.id], slice.isOwned(by: provider) else { continue }
            let libraries = slice.libraries.filter { Self.homeRowKinds.contains($0.kind) }
            let keys = Set(libraries.map(\.settingsKey))
            slice.trending = slice.trending.filter { keys.contains($0.key) }
            for library in libraries {
                do {
                    let items = try await provider.trending(in: library, from: titles, limit: 10)
                    guard expected == generation, !Task.isCancelled,
                          MediaProviderRegistry.shared.isCurrentAuthority(provider),
                          slices[provider.id]?.isOwned(by: provider) == true else { return }
                    slice.trending[library.settingsKey] = items
                } catch {
                    guard expected == generation, !Task.isCancelled,
                          MediaProviderRegistry.shared.isCurrentAuthority(provider),
                          slices[provider.id]?.isOwned(by: provider) == true else { return }
                    DiagLog.error(.servers, "\(provider.kind) trending failed: \(DiagLog.describe(error))")
                }
            }
            guard expected == generation, !Task.isCancelled,
                  MediaProviderRegistry.shared.isCurrentAuthority(provider),
                  slices[provider.id]?.isOwned(by: provider) == true else { return }
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
        return CachedHomeHub(id: id, title: hub.title,
                             isContinueWatching: hub.id == "continueWatching" || hub.id.hasSuffix(".continueWatching"),
                             hubKey: nil, hubIdentifier: id, totalSize: hub.total, items: hub.items,
                             nativeProviderID: hub.providerID, providerHubID: hub.id,
                             style: hub.style, nextPage: hub.nextPage, canBrowse: hub.canBrowse)
    }
}

private extension CachedHomeHub {
    /// The server a row came from: its id is "<providerID>|<hub id>".
    var providerID: String { String(id.prefix { $0 != "|" }) }
}

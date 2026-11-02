// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonalHomeRows.swift
//  Rivulet
//
//  Home rows the user asks for in Settings > Home > Rows: Favorite Movies and
//  Favorite TV Shows (off by default), one row each per server, and the
//  playlists switched on there (`HomePlaylistPins`). Every server, the
//  selected Plex one included.
//  `PlexHomeViewController.homeRail` places a favorites row after its
//  library's rows and the playlist rows after every library row.
//

import Combine
import Foundation

@MainActor
final class PersonalHomeRows: ObservableObject {
    static let shared = PersonalHomeRows()

    /// Favorites rows (with `libraryKey`), then playlist rows in pin order:
    /// those switched on as Home rows and those the hero shows (`HeroSources`).
    @Published private(set) var rows: CachedHomeRail = []

    /// The rows switched on as Home rows; the rest are fetched for the hero only.
    var homeRows: CachedHomeRail {
        let pinned = Set(HomePlaylistPins.pins.map { Self.playlistRowID(providerID: $0.providerID, playlistID: $0.playlistID) })
        return rows.filter { row in
            if let kind = Self.favoriteKinds.first(where: { Self.favoritesIdentifier($0) == row.hubIdentifier }) {
                return Self.showsFavorites(kind)
            }
            return pinned.contains(row.id)
        }
    }

    /// The hero source that shows a favorites kind.
    nonisolated static func heroSource(_ kind: MediaLibrary.LibraryKind) -> HeroSources.Source {
        kind == .shows ? .favoriteShows : .favoriteMovies
    }

    /// Tiles per row. None of these rows pages; a playlist's own page lists the rest.
    nonisolated static let rowLimit = 50

    static let favoritesChangedNotification = Notification.Name("homeFavoritesSettingChanged")

    /// The library kinds with a favorites row. Mixed libraries (home videos) have none.
    static let favoriteKinds: [MediaLibrary.LibraryKind] = [.movies, .shows]

    private static func favoritesKey(_ kind: MediaLibrary.LibraryKind) -> String {
        kind == .shows ? "showHomeFavoriteShows" : "showHomeFavoriteMovies"
    }

    /// Off by default, so a fresh install's Home is still what the servers say.
    static func showsFavorites(_ kind: MediaLibrary.LibraryKind) -> Bool {
        UserDefaults.standard.bool(forKey: favoritesKey(kind))
    }

    static func setShowsFavorites(_ shown: Bool, _ kind: MediaLibrary.LibraryKind) {
        UserDefaults.standard.set(shown, forKey: favoritesKey(kind))
        NotificationCenter.default.post(name: favoritesChangedNotification, object: nil)
    }

    /// Every favorites row of a kind, on every server, shares this identifier, so
    /// Settings > Home > Rows lists and moves them as one row (`HomeRowOrder`).
    nonisolated static func favoritesIdentifier(_ kind: MediaLibrary.LibraryKind) -> String {
        kind == .shows ? "rivulet.favorites.shows" : "rivulet.favorites.movies"
    }

    /// A playlist row's id and identifier (its `HomeRowOrder` key).
    nonisolated static func playlistRowID(providerID: String, playlistID: String) -> String {
        "\(playlistRowPrefix)\(providerID)/\(playlistID)"
    }

    nonisolated static let playlistRowPrefix = "rivulet.playlist."

    static func favoritesTitle(_ kind: MediaLibrary.LibraryKind) -> String {
        kind == .shows ? String(localized: "Favorite TV Shows") : String(localized: "Favorite Movies")
    }

    /// Whether any signed-in server has favorites, so Settings offers the rows.
    static var offersFavorites: Bool {
        let registry = MediaProviderRegistry.shared
        return registry.plexProvider?.supportsFavorites == true || ServerDataStore.shared.sources.contains {
            registry.provider(for: $0.providerID)?.supportsFavorites == true
        }
    }

    private var loadTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []

    init() {
        // Watch-state and playlist edits, pins, the setting, each server's
        // library list (which also follows sign-in and profile switches) and
        // the sidebar's library visibility.
        let center = NotificationCenter.default
        center.publisher(for: .plexDataNeedsRefresh).map { _ in () }
            .merge(with: center.publisher(for: HomePlaylistPins.changedNotification).map { _ in () },
                   center.publisher(for: Self.favoritesChangedNotification).map { _ in () },
                   center.publisher(for: HeroSources.changedNotification).map { _ in () },
                   PlexDataStore.shared.$libraries.map { _ in () },
                   ServerDataStore.shared.$libraries.map { _ in () },
                   LibrarySettingsManager.shared.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &observers)
    }

    /// Refetches every row. A row whose fetch fails keeps its last items, as
    /// `ServerDataStore` does, so a server blip does not drop it from Home.
    func reload() {
        loadTask?.cancel()
        let registry = MediaProviderRegistry.shared
        let plex = registry.plexProvider
        // The servers Home shows: a restricted profile has no Jellyfin source.
        let shown = Set([plex?.id].compactMap { $0 } + ServerDataStore.shared.sources.map(\.providerID))

        // One row per server and kind, from every library of that kind Home
        // shows, on servers with favorites (`MediaProvider.supportsFavorites`).
        // The selected Plex server's libraries key on the section, the others' on `settingsKey`.
        let kinds = Self.favoriteKinds.filter { Self.showsFavorites($0) || HeroSources.isOn(Self.heroSource($0)) }
        var candidates: [(provider: any MediaProvider, library: MediaLibrary, key: String)] = []
        if let plex {
            candidates += PlexDataStore.shared.librariesPinnedToHome.map { section in
                (plex, PlexMediaMapper.library(section, providerID: plex.id), section.key)
            }
        }
        for library in ServerDataStore.shared.visibleLibraries {
            guard let provider = registry.provider(for: library.providerID) else { continue }
            candidates.append((provider, library, library.settingsKey))
        }
        var favorites: [(provider: any MediaProvider, kind: MediaLibrary.LibraryKind,
                         libraries: [MediaLibrary], libraryKey: String)] = []
        for (provider, library, key) in candidates where kinds.contains(library.kind) && provider.supportsFavorites {
            if let i = favorites.firstIndex(where: { $0.provider.id == provider.id && $0.kind == library.kind }) {
                favorites[i].libraries.append(library)
            } else {
                favorites.append((provider, library.kind, [library], key))
            }
        }
        var pins = HomePlaylistPins.pins
        for pin in HomePlaylistPins.pins(in: .hero) where !pins.contains(where: { $0.id == pin.id }) { pins.append(pin) }
        pins.removeAll { !shown.contains($0.providerID) }

        // A row just switched off leaves Home now, not when the fetch below ends.
        let wanted = Set(pins.map { Self.playlistRowID(providerID: $0.providerID, playlistID: $0.playlistID) }
            + kinds.map(Self.favoritesIdentifier))
        let kept = rows.filter { wanted.contains($0.libraryKey == nil ? $0.id : $0.hubIdentifier ?? "") }
        if kept.count != rows.count { rows = kept }

        guard !favorites.isEmpty || !pins.isEmpty else { return }
        let previous = rows
        loadTask = Task {
            var next: CachedHomeRail = []
            for (provider, kind, libraries, libraryKey) in favorites {
                let id = ServerDataStore.rowID(provider.id, Self.favoritesIdentifier(kind))
                do {
                    var items: [MediaItem] = []
                    for library in libraries { items += try await provider.favorites(in: library, limit: Self.rowLimit) }
                    // Each library's come sorted by name; merge them the same way.
                    if libraries.count > 1 {
                        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    }
                    if !items.isEmpty {
                        var row = CachedHomeHub(id: id, title: Self.favoritesTitle(kind),
                                                isContinueWatching: false, hubKey: nil,
                                                hubIdentifier: Self.favoritesIdentifier(kind),
                                                totalSize: nil, items: Array(items.prefix(Self.rowLimit)))
                        // Placed with the first of its libraries.
                        row.libraryKey = libraryKey
                        next.append(row)
                    }
                } catch {
                    DiagLog.error(.servers, "\(provider.kind) favorites failed: \(DiagLog.describe(error))")
                    if let kept = previous.first(where: { $0.id == id }) { next.append(kept) }
                }
            }
            for pin in pins {
                guard let provider = registry.provider(for: pin.providerID) else { continue }
                let id = Self.playlistRowID(providerID: pin.providerID, playlistID: pin.playlistID)
                // A rename shows once the sidebar's playlist list has it.
                let title = PlaylistAvailability.shared.playlistsByProvider[pin.providerID]?
                    .first { $0.item.ref.itemID == pin.playlistID }?.item.title ?? pin.title
                do {
                    let ref = MediaItemRef(providerID: pin.providerID, itemID: pin.playlistID)
                    let items = try await provider.playlistEntries(ref).entries.prefix(Self.rowLimit).map(\.item)
                    guard !items.isEmpty else { continue }
                    next.append(CachedHomeHub(id: id, title: title, isContinueWatching: false, hubKey: nil,
                                              hubIdentifier: id, totalSize: nil, items: items))
                } catch {
                    DiagLog.error(.servers, "\(provider.kind) pinned playlist failed: \(DiagLog.describe(error))")
                    if let kept = previous.first(where: { $0.id == id }) { next.append(kept) }
                }
            }
            guard !Task.isCancelled else { return }
            rows = next
        }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  Home rows the user asks for in Settings > Home > Rows: Favorite Movies and Favorite
//  TV Shows (off by default), one row each per server, and the playlists switched on there
//  (`HomePlaylistPins`). The hero reads the same lists. Both apps fetch them here and
//  each draws the result in its own Home.
//

import Foundation

nonisolated struct PersonalRow: Sendable, Equatable {
    /// A favorites row's is the app's row id for its server; a playlist row's is `PersonalRows.playlistRowID`.
    var id: String
    /// The server the items come from.
    var providerID: String
    var title: String
    /// What `HomeRowOrder` keys on: shared by a kind's favorites rows on every server.
    var identifier: String
    /// The library a favorites row follows on Home; nil for a playlist.
    var libraryKey: String?
    var items: [MediaItem]
}

nonisolated enum PersonalRows {

    /// Tiles per row. None of these rows pages; a playlist's own page lists the rest.
    static let rowLimit = 50

    /// The library kinds with a favorites row. Mixed libraries (home videos) have none.
    static let favoriteKinds: [MediaLibrary.LibraryKind] = [.movies, .shows]

    static let favoritesChangedNotification = Notification.Name("homeFavoritesSettingChanged")

    static let playlistRowPrefix = "rivulet.playlist."

    private static func favoritesKey(_ kind: MediaLibrary.LibraryKind) -> String {
        HomeSettingsScope.key(kind == .shows ? "showHomeFavoriteShows" : "showHomeFavoriteMovies")
    }

    /// Off by default, so a fresh install's Home is still what the servers say.
    static func showsFavorites(_ kind: MediaLibrary.LibraryKind) -> Bool {
        UserDefaults.standard.bool(forKey: favoritesKey(kind))
    }

    static func setShowsFavorites(_ shown: Bool, _ kind: MediaLibrary.LibraryKind) {
        UserDefaults.standard.set(shown, forKey: favoritesKey(kind))
        NotificationCenter.default.post(name: favoritesChangedNotification, object: nil)
    }

    static func favoritesIdentifier(_ kind: MediaLibrary.LibraryKind) -> String {
        kind == .shows ? "rivulet.favorites.shows" : "rivulet.favorites.movies"
    }

    static func playlistRowID(providerID: String, playlistID: String) -> String {
        "\(playlistRowPrefix)\(providerID)/\(playlistID)"
    }

    static func favoritesTitle(_ kind: MediaLibrary.LibraryKind) -> String {
        kind == .shows ? String(localized: "Favorite TV Shows") : String(localized: "Favorite Movies")
    }

    /// The hero source that shows a favorites kind.
    static func heroSource(_ kind: MediaLibrary.LibraryKind) -> HeroSources.Source {
        kind == .shows ? .favoriteShows : .favoriteMovies
    }

    /// The kinds whose favorites are fetched: a Home row or a hero source asks for them.
    static var wantedKinds: [MediaLibrary.LibraryKind] {
        favoriteKinds.filter { showsFavorites($0) || HeroSources.isOn(heroSource($0)) }
    }

    /// Every playlist the hero or Home shows, hero pins after row pins, once each.
    static var wantedPins: [HomePlaylistPins.Pin] {
        var pins = HomePlaylistPins.pins
        for pin in HomePlaylistPins.pins(in: .hero) where !pins.contains(where: { $0.id == pin.id }) { pins.append(pin) }
        return pins
    }

    /// One server's favorites for a library kind, from every library of that kind Home shows.
    struct FavoritesRequest {
        let provider: any MediaProvider
        let kind: MediaLibrary.LibraryKind
        var libraries: [MediaLibrary]
        /// Placed with the first of its libraries.
        let libraryKey: String
    }

    /// Groups Home's libraries into one request per server and kind, on servers with favorites.
    /// `key` is how the app's Home places a library (the section key, or `settingsKey`).
    static func requests(libraries: [(provider: any MediaProvider, library: MediaLibrary, key: String)],
                         kinds: [MediaLibrary.LibraryKind]) -> [FavoritesRequest] {
        var found: [FavoritesRequest] = []
        for (provider, library, key) in libraries where kinds.contains(library.kind) && provider.supportsFavorites {
            if let i = found.firstIndex(where: { $0.provider.id == provider.id && $0.kind == library.kind }) {
                found[i].libraries.append(library)
            } else {
                found.append(FavoritesRequest(provider: provider, kind: library.kind, libraries: [library], libraryKey: key))
            }
        }
        return found
    }

    /// Whether any server has favorites, so Settings offers the rows.
    static func offersFavorites(_ providers: [any MediaProvider]) -> Bool {
        providers.contains { $0.supportsFavorites }
    }

    /// Fetches the rows. A row whose fetch fails keeps its last items from `previous`, so a
    /// server blip does not drop it from Home. `rowID` names a favorites row for its server;
    /// `currentTitle` finds a playlist's present title (a rename), else the pin's.
    static func fetch(favorites: [FavoritesRequest], pins: [HomePlaylistPins.Pin], previous: [PersonalRow],
                      providerFor: (String) -> (any MediaProvider)?,
                      rowID: (_ providerID: String, _ identifier: String) -> String,
                      currentTitle: (HomePlaylistPins.Pin) -> String?) async -> [PersonalRow] {
        var next: [PersonalRow] = []
        for request in favorites {
            let id = rowID(request.provider.id, favoritesIdentifier(request.kind))
            do {
                var items: [MediaItem] = []
                for library in request.libraries {
                    items += try await request.provider.favorites(in: library, limit: rowLimit)
                }
                // Each library's come sorted by name; merge them the same way.
                if request.libraries.count > 1 {
                    items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                }
                if !items.isEmpty {
                    next.append(PersonalRow(id: id, providerID: request.provider.id, title: favoritesTitle(request.kind),
                                            identifier: favoritesIdentifier(request.kind),
                                            libraryKey: request.libraryKey, items: Array(items.prefix(rowLimit))))
                }
            } catch {
                DiagLog.error(.servers, "\(request.provider.kind) favorites failed: \(DiagLog.describe(error))")
                if let kept = previous.first(where: { $0.id == id }) { next.append(kept) }
            }
        }
        for pin in pins {
            guard let provider = providerFor(pin.providerID) else { continue }
            let id = playlistRowID(providerID: pin.providerID, playlistID: pin.playlistID)
            do {
                let ref = MediaItemRef(providerID: pin.providerID, itemID: pin.playlistID)
                let items = try await provider.playlistEntries(ref).entries.prefix(rowLimit).map(\.item)
                guard !items.isEmpty else { continue }
                next.append(PersonalRow(id: id, providerID: pin.providerID, title: currentTitle(pin) ?? pin.title,
                                        identifier: id, libraryKey: nil, items: items))
            } catch {
                DiagLog.error(.servers, "\(provider.kind) pinned playlist failed: \(DiagLog.describe(error))")
                if let kept = previous.first(where: { $0.id == id }) { next.append(kept) }
            }
        }
        return next
    }

    /// Drops the rows nothing asks for now, so a row just switched off leaves Home before the refetch ends.
    static func keeping(_ rows: [PersonalRow], kinds: [MediaLibrary.LibraryKind], pins: [HomePlaylistPins.Pin]) -> [PersonalRow] {
        let wanted = Set(pins.map { playlistRowID(providerID: $0.providerID, playlistID: $0.playlistID) }
            + kinds.map(favoritesIdentifier))
        return rows.filter { wanted.contains($0.identifier) }
    }

    /// The rows Home draws, not those fetched for the hero alone.
    static func homeRows(_ rows: [PersonalRow]) -> [PersonalRow] {
        let pinned = Set(HomePlaylistPins.pins.map { playlistRowID(providerID: $0.providerID, playlistID: $0.playlistID) })
        return rows.filter { row in
            if let kind = favoriteKinds.first(where: { favoritesIdentifier($0) == row.identifier }) {
                return showsFavorites(kind)
            }
            return pinned.contains(row.id)
        }
    }

    /// The rows of one favorites kind, every server's, round-robin.
    static func favoriteItems(_ rows: [PersonalRow], _ kind: MediaLibrary.LibraryKind) -> [[MediaItem]] {
        rows.filter { $0.identifier == favoritesIdentifier(kind) }.map(\.items)
    }

    /// A hero playlist's items.
    static func playlistItems(_ rows: [PersonalRow], _ pin: HomePlaylistPins.Pin) -> [MediaItem] {
        let id = playlistRowID(providerID: pin.providerID, playlistID: pin.playlistID)
        return rows.first { $0.id == id }?.items ?? []
    }
}

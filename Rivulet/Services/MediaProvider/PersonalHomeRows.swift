// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PersonalHomeRows.swift
//  Rivulet
//
//  tvOS's holder for the favorites and playlist rows (`PersonalRows`, RivuletCore): it picks
//  the libraries Home shows, refetches on the settings that change them, and publishes the
//  rows as `CachedHomeHub`. `PlexHomeViewController.homeRail` places a favorites row after
//  its library's rows and the playlist rows after every library row.
//

import Combine
import Foundation

@MainActor
final class PersonalHomeRows: ObservableObject {
    static let shared = PersonalHomeRows()

    /// Favorites rows (with `libraryKey`), then playlist rows in pin order: those switched on as
    /// Home rows and those the hero shows (`HeroSources`).
    @Published private(set) var rows: [PersonalRow] = []

    /// The rows Home draws; the rest are fetched for the hero only.
    var homeRows: CachedHomeRail { PersonalRows.homeRows(rows).map(Self.cached) }

    /// The servers Home shows: the selected Plex server and every other signed in.
    static var providers: [any MediaProvider] {
        let registry = MediaProviderRegistry.shared
        return ([registry.plexProvider] + ServerDataStore.shared.sources.map { registry.provider(for: $0.providerID) })
            .compactMap { $0 }
    }

    /// Whether any signed-in server has favorites, so Settings offers the rows and the Favorites page.
    static var offersFavorites: Bool { PersonalRows.offersFavorites(providers) }

    private static func cached(_ row: PersonalRow) -> CachedHomeHub {
        var hub = CachedHomeHub(id: row.id, title: row.title, isContinueWatching: false, hubKey: nil,
                                hubIdentifier: row.identifier, totalSize: nil, items: row.items)
        hub.libraryKey = row.libraryKey
        return hub
    }

    private var loadTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []

    init() {
        // Watch-state and playlist edits, pins, the settings, each server's library list
        // (which also follows sign-in and profile switches) and the sidebar's library visibility.
        let center = NotificationCenter.default
        center.publisher(for: .plexDataNeedsRefresh).map { _ in () }
            .merge(with: center.publisher(for: HomePlaylistPins.changedNotification).map { _ in () },
                   center.publisher(for: PersonalRows.favoritesChangedNotification).map { _ in () },
                   center.publisher(for: HeroSources.changedNotification).map { _ in () },
                   PlexDataStore.shared.$libraries.map { _ in () },
                   ServerDataStore.shared.$libraries.map { _ in () },
                   LibrarySettingsManager.shared.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &observers)
    }

    func reload() {
        loadTask?.cancel()
        let registry = MediaProviderRegistry.shared
        let plex = registry.plexProvider
        // The servers Home shows: a restricted profile has no Jellyfin source.
        let shown = Set([plex?.id].compactMap { $0 } + ServerDataStore.shared.sources.map(\.providerID))

        // The selected Plex server's libraries key on the section, the others' on `settingsKey`.
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
        let kinds = PersonalRows.wantedKinds
        let favorites = PersonalRows.requests(libraries: candidates, kinds: kinds)
        let pins = PersonalRows.wantedPins.filter { shown.contains($0.providerID) }

        let kept = PersonalRows.keeping(rows, kinds: kinds, pins: pins)
        if kept.count != rows.count { rows = kept }
        guard !favorites.isEmpty || !pins.isEmpty else { return }

        let previous = rows
        loadTask = Task {
            let next = await PersonalRows.fetch(
                favorites: favorites, pins: pins, previous: previous,
                providerFor: { registry.provider(for: $0) },
                rowID: { ServerDataStore.rowID($0, $1) },
                // A rename shows once the sidebar's playlist list has it.
                currentTitle: { pin in
                    PlaylistAvailability.shared.playlistsByProvider[pin.providerID]?
                        .first { $0.item.ref.itemID == pin.playlistID }?.item.title
                })
            guard !Task.isCancelled else { return }
            rows = next
        }
    }
}

extension HomeRowOrder {
    static func key(for row: CachedHomeHub) -> String {
        key(isContinueWatching: row.isContinueWatching, identifier: row.hubIdentifier, fallback: row.id)
    }
}

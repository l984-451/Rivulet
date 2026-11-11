// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BrowseStore+HomeRows.swift
//  Rivulet
//
//  Home's rows as the user arranged them: hidden rows left out, the saved order applied, and
//  the favorites and playlist rows (`PersonalRows`) added. The keys are tvOS's, so a profile
//  and iCloud sync agree. Home's rows by server and the settings page both read from here.
//

import Combine
import Foundation

/// One row of Settings > Home > Rows.
struct HomeRowEntry: Identifiable {
    enum Kind {
        case continueWatching
        case shelf(hiddenID: String)
        case favorites(MediaLibrary.LibraryKind)
        case playlist(HomePlaylistPins.Pin)
    }

    /// The row's `HomeRowOrder` key.
    let id: String
    let title: String
    let kind: Kind
    var isOn: Bool
}

extension BrowseStore {

    func observeHomeSettings() {
        let center = NotificationCenter.default
        center.publisher(for: HomeRowSettings.changedNotification)
            .sink { [weak self] _ in self?.homeSettingsRevision += 1 }
            .store(in: &cancellables)
        // The settings that change which lists are fetched.
        center.publisher(for: HomePlaylistPins.changedNotification)
            .merge(with: center.publisher(for: PersonalRows.favoritesChangedNotification),
                   center.publisher(for: HeroSources.changedNotification))
            .sink { [weak self] _ in
                self?.homeSettingsRevision += 1
                self?.reloadPersonalRows()
            }
            .store(in: &cancellables)
    }

    /// Refetches the favorites and playlists rows. A failed row keeps its last items.
    func reloadPersonalRows() {
        personalTask?.cancel()
        let (selected, secondary) = providersInPlay
        let providers = (selected.map { [$0] } ?? []) + secondary
        let shown = Set(providers.map(\.id))
        // The selected server's pinned libraries, and every library of the others, less the hidden ones.
        let candidates = libraries.compactMap { library -> (provider: any MediaProvider, library: MediaLibrary, key: String)? in
            guard let provider = providers.first(where: { $0.id == library.providerID }),
                  provider.id != selected?.id || library.isPinnedToHome,
                  isSidebarLibraryShown(library) else { return nil }
            return (provider, library, library.id)
        }
        let kinds = PersonalRows.wantedKinds
        let favorites = PersonalRows.requests(libraries: candidates, kinds: kinds)
        let pins = PersonalRows.wantedPins.filter { shown.contains($0.providerID) }

        let kept = PersonalRows.keeping(personalRows, kinds: kinds, pins: pins)
        if kept != personalRows { personalRows = kept }
        guard !favorites.isEmpty || !pins.isEmpty else { return }

        let previous = personalRows
        let lists = playlists
        personalTask = Task {
            let next = await PersonalRows.fetch(
                favorites: favorites, pins: pins, previous: previous,
                providerFor: { [registry] in registry.provider(for: $0) },
                rowID: { "\($0)|\($1)" },
                currentTitle: { pin in lists[pin.providerID]?.first { $0.item.ref.itemID == pin.playlistID }?.item.title })
            guard !Task.isCancelled else { return }
            personalRows = next
        }
    }

    // MARK: - Home's rows

    /// The identifier a shelf is hidden by: the selected Plex server's rows drop their provider prefix, as on tvOS.
    private func hiddenID(of hub: MediaHub) -> String {
        HomeRowSettings.identifier(ofShelf: hub.id, selectedProviderID: registry.plexProvider?.id)
    }

    private var continueWatchingIDs: [String] {
        HomeRowSettings.continueWatchingIdentifiers(
            hasSelectedPlex: registry.plexProvider != nil,
            otherProviderIDs: providersInPlay.secondary.map(\.id))
    }

    private var isContinueWatchingShown: Bool {
        continueWatchingIDs.contains { !HomeRowSettings.isHidden($0) }
    }

    private func personalHub(_ row: PersonalRow) -> MediaHub {
        MediaHub(id: row.id, providerID: row.providerID, title: row.title, style: .shelf, items: row.items)
    }

    /// The rows Home draws, in the user's order.
    var homeRows: [MediaHub] {
        var rows: [(key: String, hub: MediaHub)] = []
        if let cw = continueWatchingHub, isContinueWatchingShown { rows.append((HomeRowOrder.continueWatchingKey, cw)) }
        for hub in shelves where !HomeRowSettings.isHidden(hiddenID(of: hub)) { rows.append((hiddenID(of: hub), hub)) }
        for row in PersonalRows.homeRows(personalRows) { rows.append((row.identifier, personalHub(row))) }
        return HomeRowOrder.arrange(rows, key: \.key).map(\.hub)
    }

    /// Every row Home can draw, in Home's order, with the ones that are off marked: one entry per
    /// `HomeRowOrder` key. Favorites and playlists are listed whether or not they have loaded.
    var homeRowEntries: [HomeRowEntry] {
        var entries: [HomeRowEntry] = []
        if continueWatchingHub != nil {
            entries.append(HomeRowEntry(id: HomeRowOrder.continueWatchingKey, title: String(localized: "Continue Watching"),
                                           kind: .continueWatching, isOn: isContinueWatchingShown))
        }
        for hub in shelves {
            let id = hiddenID(of: hub)
            let badge = labels.badge(providerID: hub.providerID)
            entries.append(HomeRowEntry(id: id, title: badge.map { "\(hub.title) (\($0))" } ?? hub.title,
                                           kind: .shelf(hiddenID: id), isOn: !HomeRowSettings.isHidden(id)))
        }
        if offersFavorites {
            for kind in PersonalRows.favoriteKinds {
                entries.append(HomeRowEntry(id: PersonalRows.favoritesIdentifier(kind), title: PersonalRows.favoritesTitle(kind),
                                               kind: .favorites(kind), isOn: PersonalRows.showsFavorites(kind)))
            }
        }
        for pin in playlistEntries {
            let id = PersonalRows.playlistRowID(providerID: pin.providerID, playlistID: pin.playlistID)
            let badge = labels.badge(providerID: pin.providerID)
            entries.append(HomeRowEntry(id: id, title: badge.map { "\(pin.title) (\($0))" } ?? pin.title, kind: .playlist(pin),
                                           isOn: HomePlaylistPins.pins.contains { $0.id == pin.id }))
        }
        return HomeRowOrder.arrange(entries, key: \.id)
    }

    /// Every server's video playlists, plus any pin whose playlist is no longer listed, so it can still be switched off.
    var playlistEntries: [HomePlaylistPins.Pin] {
        var pins = providerOrder.flatMap { id in
            playlists(providerID: id).map { HomePlaylistPins.Pin(providerID: id, playlistID: $0.item.ref.itemID, title: $0.item.title) }
        }
        for pin in HomePlaylistPins.pins where !pins.contains(where: { $0.id == pin.id }) { pins.append(pin) }
        return pins
    }

    /// Whether any signed-in server has favorites, so Settings offers the rows.
    var offersFavorites: Bool { PersonalRows.offersFavorites(allProviders) }

    /// Switching a row on or off. A row turned on goes last.
    func setHomeRow(_ entry: HomeRowEntry, shown: Bool) {
        if shown {
            let entries = homeRowEntries
            HomeRowOrder.placeLast(entry.id, among: (entries.filter(\.isOn) + entries.filter { !$0.isOn }).map(\.id))
        }
        switch entry.kind {
        case .continueWatching: continueWatchingIDs.forEach { HomeRowSettings.setHidden(!shown, for: $0) }
        case .shelf(let id): HomeRowSettings.setHidden(!shown, for: id)
        case .favorites(let kind): PersonalRows.setShowsFavorites(shown, kind)
        case .playlist(let pin):
            if shown { HomePlaylistPins.pin(pin) } else { HomePlaylistPins.unpin(MediaItemRef(providerID: pin.providerID, itemID: pin.playlistID)) }
        }
        homeSettingsRevision += 1
    }

    /// Back to Home's own order with every row shown, favorites and playlists off.
    func resetHomeRows() {
        HomeRowSettings.showAll()
        HomeRowOrder.reset()
        PersonalRows.favoriteKinds.forEach { PersonalRows.setShowsFavorites(false, $0) }
        HomePlaylistPins.removeAll()
    }
}

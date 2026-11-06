// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Account > Home: what the hero shows, and the way into the rows. The same settings as tvOS's Home pages.
struct IOSHomeSettingsView: View {
    @EnvironmentObject private var browse: IOSBrowseStore
    @State private var confirmingReset = false

    private func title(_ source: HeroSources.Source) -> LocalizedStringKey {
        switch source {
        case .trending: "Trending"
        case .continueWatching: "Continue Watching"
        case .recentlyAdded: "Recently Added"
        case .watchlist: "Watchlist"
        case .favoriteMovies: "Favorite Movies"
        case .favoriteShows: "Favorite TV Shows"
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(HeroSources.Source.allCases.filter { !$0.isFavorites || browse.offersFavorites }, id: \.self) { source in
                    Toggle(title(source), isOn: Binding(get: { HeroSources.isOn(source) },
                                                        set: { HeroSources.set(source, on: $0) }))
                }
            } header: {
                Text("Hero")
            } footer: {
                Text("Choose what the hero shows. Pick more than one to mix them. Turn all off to hide the hero.")
            }

            let playlists = browse.playlistEntries
            if !playlists.isEmpty {
                Section("Hero Playlists") {
                    ForEach(playlists, id: \.id) { pin in
                        let ref = MediaItemRef(providerID: pin.providerID, itemID: pin.playlistID)
                        Toggle(isOn: Binding(
                            get: { HomePlaylistPins.isPinned(ref, in: .hero) },
                            set: { if $0 { HomePlaylistPins.pin(pin, in: .hero) } else { HomePlaylistPins.unpin(ref, in: .hero) } }
                        )) { Text(verbatim: browse.labels.badge(providerID: pin.providerID).map { "\(pin.title) (\($0))" } ?? pin.title) }
                    }
                }
            }

            Section {
                Button("Reset Hero", role: .destructive) { confirmingReset = true }
            }

            Section {
                NavigationLink("Rows") { IOSHomeRowsSettingsView() }
            }
        }
        .navigationTitle("Home")
        .confirmationDialog("Reset the Hero?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { HeroSources.reset() }
        } message: {
            Text("The hero shows Trending only, with no playlists.")
        }
    }
}

private extension HeroSources.Source {
    var isFavorites: Bool { self == .favoriteMovies || self == .favoriteShows }
}

/// Account > Home > Rows: which rows Home shows and in what order. Drag the shown rows in Edit.
struct IOSHomeRowsSettingsView: View {
    @EnvironmentObject private var browse: IOSBrowseStore
    @State private var confirmingReset = false

    var body: some View {
        let entries = browse.homeRowEntries
        let shown = entries.filter(\.isOn)
        let hidden = entries.filter { !$0.isOn }
        List {
            Section {
                ForEach(shown) { row($0) }
                    .onMove { from, to in
                        guard let i = from.first else { return }
                        HomeRowOrder.move(shown[i].id, to: to > i ? to - 1 : to, among: shown.map(\.id))
                    }
            } footer: {
                Text("Choose what appears on Home and in what order.")
            }
            if !hidden.isEmpty {
                Section("Hidden from Home") { ForEach(hidden) { row($0) } }
            }
            Section {
                Button("Reset", role: .destructive) { confirmingReset = true }
            }
        }
        .navigationTitle("Rows")
        .toolbar { EditButton() }
        .confirmationDialog("Reset Home Rows?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { browse.resetHomeRows() }
        } message: {
            Text("Every row from your servers comes back in the original order. Favorites and playlists are turned off.")
        }
    }

    private func row(_ entry: IOSHomeRowEntry) -> some View {
        Toggle(isOn: Binding(get: { entry.isOn }, set: { browse.setHomeRow(entry, shown: $0) })) {
            Text(verbatim: entry.title)
        }
    }
}

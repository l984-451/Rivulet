// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Settings > Home: what the hero shows, and the way into the rows. Parity source: IOSHomeSettingsView.
struct MacHomeSettingsView: View {
    @EnvironmentObject private var browse: BrowseStore
    @State private var confirmingReset = false
    @State private var editingRows = false

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
                Button("Reset Hero…", role: .destructive) { confirmingReset = true }
                Button("Arrange Rows…") { editingRows = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the Hero?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { HeroSources.reset() }
        } message: {
            Text("The hero shows Trending only, with no playlists.")
        }
        .sheet(isPresented: $editingRows) { MacHomeRowsSettingsView() }
    }
}

private extension HeroSources.Source {
    var isFavorites: Bool { self == .favoriteMovies || self == .favoriteShows }
}

/// Which rows Home shows and in what order. Drag the shown rows to reorder.
struct MacHomeRowsSettingsView: View {
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false

    var body: some View {
        let entries = browse.homeRowEntries
        let shown = entries.filter(\.isOn)
        let hidden = entries.filter { !$0.isOn }
        VStack(spacing: 0) {
            Text("Home Rows").font(.headline).padding(.top, 16)
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
            }
            Divider()
            HStack {
                Button("Reset…", role: .destructive) { confirmingReset = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 480)
        .confirmationDialog("Reset Home Rows?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { browse.resetHomeRows() }
        } message: {
            Text("Every row from your servers comes back in the original order. Favorites and playlists are turned off.")
        }
    }

    private func row(_ entry: HomeRowEntry) -> some View {
        Toggle(isOn: Binding(get: { entry.isOn }, set: { browse.setHomeRow(entry, shown: $0) })) {
            Text(verbatim: entry.title)
        }
    }
}

/// Settings > Library. Parity source: IOSLibrarySettingsView.
struct MacLibrarySettingsView: View {
    @EnvironmentObject private var browse: BrowseStore
    @AppStorage(MacSettingsKeys.showPlaylists) private var showPlaylists = true
    @AppStorage(MacSettingsKeys.showFavorites) private var showFavorites = false

    var body: some View {
        Form {
            Section {
                Toggle("Playlists", isOn: $showPlaylists)
            } footer: {
                Text("Lists each server's video playlists under Library.")
            }
            if browse.offersFavorites {
                Section {
                    Toggle("Favorites", isOn: $showFavorites)
                } footer: {
                    Text("Lists your favorite movies and shows from every server under Library.")
                }
            }
            if !(browse.libraries + browse.photoLibraries).isEmpty { sidebarLibraries }
        }
        .formStyle(.grouped)
    }

    /// Which libraries the sidebar lists, for this profile.
    private var sidebarLibraries: some View {
        Section {
            ForEach((browse.libraries + browse.photoLibraries).sidebarOrder(servers: browse.providerOrder)) { library in
                Toggle(isOn: Binding(get: { browse.isSidebarLibraryShown(library) },
                                     set: { browse.setSidebarLibrary(library, shown: $0) })) {
                    Text(verbatim: browse.labels.title(library.title, providerID: library.providerID))
                }
            }
            HStack {
                Button("Show All") { browse.setSidebarLibraries(browse.libraries + browse.photoLibraries, shown: true) }
                Button("Hide All") { browse.setSidebarLibraries(browse.libraries + browse.photoLibraries, shown: false) }
            }
        } header: {
            Text("Sidebar Libraries")
        } footer: {
            Text("Hidden libraries stay on the server and are left out of the sidebar, the Go menu and Home.")
        }
    }
}

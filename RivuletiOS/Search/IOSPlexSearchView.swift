// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The Search tab: the system search field, scopes, recent searches and grouped results.
struct IOSPlexSearchView: View {
    enum Scope: CaseIterable, Identifiable {
        case all, movies, shows

        var id: Self { self }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .movies: String(localized: "Movies")
            case .shows: String(localized: "TV Shows")
            }
        }

        var scope: SearchResults.Scope {
            switch self {
            case .all: .all
            case .movies: .movies
            case .shows: .shows
            }
        }
    }

    @EnvironmentObject private var browse: IOSBrowseStore
    @AppStorage("iosRecentSearches") private var recentsRaw = ""
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies, Shows, and Episodes")
            .searchScopes($scope) {
                ForEach(Scope.allCases) { Text($0.title).tag($0) }
            }
            .onSubmit(of: .search) { remember(trimmedQuery) }
            .toolbar {
                IOSAccountToolbarItem()
            }
            .task(id: query) { await search() }
            // Opening a result pushes over this view; that is when the query counts as a recent search.
            .onDisappear { if !groups.isEmpty { remember(trimmedQuery) } }
    }

    @ViewBuilder
    private var content: some View {
        if !browse.hasServers {
            IOSPlexConnectView()
        } else if trimmedQuery.isEmpty {
            recentSearches
        } else if let error {
            ContentUnavailableView("Couldn’t Search", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if groups.isEmpty {
            if isSearching {
                ProgressView()
            } else {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section(title(of: group)) {
                        ForEach(group.items) { item in
                            NavigationLink(value: item) { IOSPlexSearchRow(item: item) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if recents.isEmpty {
            ContentUnavailableView(
                "Search Your Libraries",
                systemImage: "magnifyingglass",
                description: Text("Find movies, TV shows, and episodes.")
            )
        } else {
            List {
                Section {
                    ForEach(recents, id: \.self) { term in
                        Button { query = term } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { offsets in
                        var updated = recents
                        updated.remove(atOffsets: offsets)
                        recentsRaw = updated.joined(separator: "\n")
                    }
                } header: {
                    HStack {
                        Text("Recent Searches")
                        Spacer()
                        Button("Clear") { recentsRaw = "" }
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var recents: [String] { recentsRaw.split(separator: "\n").map(String.init) }

    /// By kind; with several servers, each server's own, under its name.
    private var groups: [SearchResults.Group] {
        SearchResults.groups(results, scope: scope.scope, providerOrder: browse.providerOrder)
    }

    private func title(of group: SearchResults.Group) -> String {
        let kind = switch group.section {
        case .movies: String(localized: "Movies")
        case .shows: String(localized: "TV Shows")
        case .episodes: String(localized: "Episodes")
        }
        return group.providerID.flatMap { browse.labels.badge(providerID: $0) }.map { "\(kind) · \($0)" } ?? kind
    }

    private func remember(_ term: String) {
        guard !term.isEmpty else { return }
        let updated = [term] + recents.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        recentsRaw = updated.prefix(10).joined(separator: "\n")
    }

    private func search() async {
        let value = trimmedQuery
        error = nil
        guard !value.isEmpty, browse.hasServers else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            results = try await SearchResults.search(value, providers: browse.searchProviders)
            #if DEBUG
            results = IOSScreenshotMode.demoItems(results, libraries: browse.libraries)
            #endif
        } catch {
            // A newer keystroke cancelled this request; the next task owns the state.
            if Task.isCancelled || isCancellationError(error) { return }
            self.error = error.localizedDescription
        }
        isSearching = false
    }
}

/// A search result like the TV app's: artwork, title, then kind and year or episode.
struct IOSPlexSearchRow: View {
    @EnvironmentObject private var browse: IOSBrowseStore
    let item: MediaItem

    private var isEpisode: Bool { item.kind == .episode }

    var body: some View {
        HStack(spacing: 12) {
            IOSShellArtwork(url: artworkURL) { Rectangle().fill(.quaternary) }
                .aspectRatio(isEpisode ? 16 / 9 : 2 / 3, contentMode: .fit)
                .frame(width: isEpisode ? 96 : 54)
                .clipShape(.rect(cornerRadius: 6))
                .plexZoomSource(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(2)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var artworkURL: URL? {
        isEpisode
            ? browse.artworkURL(for: item, kind: .thumb, width: 320, height: 180)
            : browse.artworkURL(for: item, kind: .poster, width: 180, height: 270)
    }

    private var detail: String {
        let parts: [String?] = switch item.kind {
        case .movie: [String(localized: "Movie"), item.year.map(String.init)]
        case .show: [String(localized: "TV Show"), item.year.map(String.init)]
        case .season: [String(localized: "Season"), item.seriesTitle]
        case .episode: [item.seriesTitle, item.episodeCode]
        default: []
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The Search tab: the system search field, scopes, recent searches and grouped results.
struct IOSPlexSearchView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case movies = "Movies"
        case shows = "TV Shows"

        var id: Self { self }

        func includes(_ item: PlexMetadata) -> Bool {
            switch self {
            case .all: true
            case .movies: item.type == "movie"
            case .shows: item.type != "movie"
            }
        }
    }

    @EnvironmentObject private var plex: IOSPlexSession
    @AppStorage("iosRecentSearches") private var recentsRaw = ""
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var results: [PlexMetadata] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies, Shows, and Episodes")
            .searchScopes($scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
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
        if !plex.isConfigured {
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
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
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
                "Search Your Plex Libraries",
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

    private var groups: [(title: String, items: [PlexMetadata])] {
        let visible = results.filter(scope.includes)
        let sections: [(String, Set<String>)] = [
            ("Movies", ["movie"]),
            ("TV Shows", ["show", "season"]),
            ("Episodes", ["episode"]),
        ]
        return sections.compactMap { title, types in
            let items = visible.filter { types.contains($0.type ?? "") }
            return items.isEmpty ? nil : (title, items)
        }
    }

    private func remember(_ term: String) {
        guard !term.isEmpty else { return }
        let updated = [term] + recents.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        recentsRaw = updated.prefix(10).joined(separator: "\n")
    }

    private func search() async {
        let value = trimmedQuery
        error = nil
        guard !value.isEmpty, plex.isConfigured else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            results = try await plex.search(value)
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
    @EnvironmentObject private var plex: IOSPlexSession
    let item: PlexMetadata

    private var isEpisode: Bool { item.type == "episode" }

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
            ? plex.artworkURL(for: item, kind: .thumb, width: 320, height: 180)
            : plex.artworkURL(for: item, kind: .poster, width: 180, height: 270)
    }

    private var detail: String {
        let parts: [String?] = switch item.type {
        case "movie": ["Movie", item.year.map(String.init)]
        case "show": ["TV Show", item.year.map(String.init)]
        case "season": ["Season", item.parentTitle]
        case "episode": [item.grandparentTitle, episodeCode]
        default: [item.type?.capitalized]
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private var episodeCode: String? {
        guard let season = item.parentIndex, let episode = item.index else { return nil }
        return "S\(season), E\(episode)"
    }
}

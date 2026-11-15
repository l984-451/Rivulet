// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Search across every server, scoped to All, Movies or TV Shows, with recent searches and
/// results grouped by kind (and by server when several are signed in). Port of IOSPlexSearchView.
/// Cmd-F is the Go menu's Search item (it selects this row) and focuses the toolbar field here.
struct MacSearchView: View {
    enum Scope: CaseIterable, Identifiable {
        case all, movies, shows

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .movies: "Movies"
            case .shows: "TV Shows"
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

    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.macOpen) private var open
    @AppStorage("macRecentSearches") private var recentsRaw = ""
    @State private var query = ""
    @State private var scope = Scope.all
    @State private var results = SearchHits()
    @State private var isSearching = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies, Shows, People, and More")
            .searchFocused($fieldFocused)
            .searchScopes($scope) {
                ForEach(Scope.allCases) { Text($0.title).tag($0) }
            }
            .onSubmit(of: .search) { remember(trimmedQuery) }
            .task(id: query) { await search() }
            .onAppear { fieldFocused = true }
            .onReceive(NotificationCenter.default.publisher(for: .macFocusSearch)) { _ in fieldFocused = true }
            // Opening a result pushes over this view; that is when the query counts as a recent search.
            .onDisappear { if !groups.isEmpty { remember(trimmedQuery) } }
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            recentSearches
        } else if let error {
            MacErrorView(title: "Couldn’t Search", message: error) { await search() }
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
                            MacTileButton(item: item) { MacSearchRow(item: item) }
                                .listRowSeparator(.visible)
                        }
                        ForEach(group.people) { person in
                            Button { open(.person(person, providerID: person.providerID ?? "")) } label: {
                                MacSearchPersonRow(person: person)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.visible)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if recents.isEmpty {
            ContentUnavailableView(
                "Search Your Libraries",
                systemImage: "magnifyingglass",
                description: Text("Find movies, TV shows, episodes, people, collections, and genres.")
            )
        } else {
            List {
                Section {
                    ForEach(recents, id: \.self) { term in
                        Button { query = term } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove") { forget(term) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent Searches")
                        Spacer()
                        Button("Clear") { recentsRaw = "" }
                            .buttonStyle(.link)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.inset)
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
        case .people: String(localized: "People")
        case .collection(let name): String(localized: "\(name) · Collection")
        case .genre(let name): String(localized: "\(name) · Genre")
        }
        return group.providerID.flatMap { browse.labels.badge(providerID: $0) }.map { "\(kind) · \($0)" } ?? kind
    }

    private func remember(_ term: String) {
        guard !term.isEmpty else { return }
        let updated = [term] + recents.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        recentsRaw = updated.prefix(10).joined(separator: "\n")
    }

    private func forget(_ term: String) {
        recentsRaw = recents.filter { $0 != term }.joined(separator: "\n")
    }

    private func search() async {
        let value = trimmedQuery
        error = nil
        guard !value.isEmpty, browse.hasServers else {
            results = SearchHits()
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            results = try await SearchResults.search(value, providers: browse.searchProviders)
        } catch {
            // A newer keystroke cancelled this request; the next task owns the state.
            if Task.isCancelled || isCancellationError(error) { return }
            self.error = error.localizedDescription
        }
        isSearching = false
    }
}

/// A person result: round photo, name, then role.
struct MacSearchPersonRow: View {
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    let person: MediaPerson
    @State private var hovering = false

    var body: some View {
        let pixels = Int((54 * displayScale).rounded(.up))
        HStack(spacing: 12) {
            MacImage(url: browse.imageURL(person.imageURL, providerID: person.providerID ?? "", width: pixels, height: pixels))
                .overlay {
                    if person.imageURL == nil {
                        Image(systemName: "person.fill").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: person.name).lineLimit(2)
                if let role = person.role {
                    Text(verbatim: role).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(hovering ? 0.6 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// A result row: artwork, title, then kind and year or episode.
struct MacSearchRow: View {
    let item: MediaItem
    @State private var hovering = false

    private var isEpisode: Bool { item.kind == .episode }
    private var width: CGFloat { isEpisode ? 112 : 54 }

    var body: some View {
        HStack(spacing: 12) {
            MacItemArtwork(item: item, kind: isEpisode ? .thumb : .poster,
                           width: width, aspectRatio: isEpisode ? 16 / 9 : 2 / 3)
                .aspectRatio(isEpisode ? 16 / 9 : 2 / 3, contentMode: .fit)
                .frame(width: width)
                .clipShape(.rect(cornerRadius: 6))
                .macWatchState(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(2)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(hovering ? 0.6 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
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

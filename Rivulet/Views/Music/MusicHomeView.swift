// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicHomeView.swift
//  Rivulet
//
//  Apple Music tvOS-inspired music library home.
//

import SwiftUI
import UIKit

enum MusicLibraryCategory: String, Hashable, CaseIterable {
    case recentlyAdded
    case playlists
    case artists
    case albums
    case songs

    var title: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .songs: return "Songs"
        }
    }

    var showsHeader: Bool {
        self != .recentlyAdded
    }

    var supportsPlaybackActions: Bool {
        self != .playlists
    }
}

struct MusicHomeView: View {
    let libraryKey: String
    let libraryTitle: String

    @Environment(\.nestedNavigationState) private var nestedNavState
    @Environment(MusicProviderRegistry.self) private var registry

    @ObservedObject private var authManager = PlexAuthManager.shared
    @ObservedObject private var dataStore = PlexDataStore.shared
    @ObservedObject private var musicQueue = MusicQueue.shared

    @State private var recentlyAddedItems: [MusicAlbum] = []
    @State private var recentlyAddedTotal: Int?
    @State private var isLoadingMoreRecentlyAdded = false
    @State private var allArtists: [MusicArtist] = []
    @State private var allAlbums: [MusicAlbum] = []
    @State private var allTracks: [MusicTrack] = []
    @State private var playlists: [PlexMetadata] = []
    @State private var genres: [String] = []
    @State private var isLoading = false
    @State private var loadedCategories: Set<MusicLibraryCategory> = []

    private let recentlyAddedPageSize = 60

    @State private var selectedCategory: MusicLibraryCategory = .recentlyAdded
    @State private var selectedGenre: String?
    @State private var selectedArtist: MusicArtist?
    @State private var selectedAlbum: MusicAlbum?
    @State private var selectedPlaylist: PlexMetadata?
    @State private var albumSortAscending = true
    @State private var songSortAscending = true

    private let networkManager = PlexNetworkManager.shared

    // Layout constants — matches the approved wireframe
    private let sidebarWidth: CGFloat = 380
    private let sidebarLeadingPad: CGFloat = 60
    private let sidebarTrailingInset: CGFloat = 36
    private let contentLeadingPad: CGFloat = 24
    private let contentTrailingPad: CGFloat = 80
    private let contentTopPad: CGFloat = 80
    private let gridColumnSpacing: CGFloat = 48
    private let gridRowSpacing: CGFloat = 60

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridColumnSpacing, alignment: .top), count: 4)
    }

    private var provider: (any MusicProvider)? {
        registry.primaryProvider
    }

    private var currentLibrary: MediaLibrary {
        MediaLibrary(
            id: libraryKey,
            providerID: provider?.id ?? "",
            title: libraryTitle,
            kind: .music
        )
    }

    var body: some View {
        // No left-escape block here. It dates from the SwiftUI
        // `TabView(.sidebarAdaptable)` shell, which owned Left itself; under the
        // UIKit shell the exit is the edge catcher at x=0, and blocking the move
        // with an empty `onLeftBlocked` left Music with no way back to the
        // sidebar at all. Left now walks content -> Music's own sidebar -> the
        // catcher, which is what every other tab does.
        NavigationStack {
            HStack(alignment: .top, spacing: 0) {
                sidebar
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationDestination(item: $selectedArtist) { artist in
                MusicArtistDetailView(artist: artist)
            }
            .navigationDestination(item: $selectedAlbum) { album in
                MusicAlbumDetailView(album: album)
            }
            .navigationDestination(item: $selectedPlaylist) { playlist in
                MusicPlaylistView(playlist: playlist)
            }
        }
        .onChange(of: selectedArtist) { _, new in
            nestedNavState.isNested = new != nil || selectedAlbum != nil || selectedPlaylist != nil
        }
        .onChange(of: selectedAlbum) { _, new in
            nestedNavState.isNested = new != nil || selectedArtist != nil || selectedPlaylist != nil
        }
        .onChange(of: selectedPlaylist) { _, new in
            nestedNavState.isNested = new != nil || selectedArtist != nil || selectedAlbum != nil
        }
        .task(id: libraryKey) {
            await loadRecentlyAdded()
            await loadGenres()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MusicLibraryCategory.allCases, id: \.self) { category in
                    sidebarRow(
                        title: category.title,
                        isSelected: selectedCategory == category && selectedGenre == nil
                    ) {
                        selectCategory(category)
                    }
                }

                if !genres.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .padding(.leading, 28)
                        .padding(.trailing, 56)
                        .padding(.top, 28)
                        .padding(.bottom, 18)

                    Text("Genres")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)

                    ForEach(genres, id: \.self) { genre in
                        sidebarRow(
                            title: genre,
                            isSelected: selectedGenre == genre
                        ) {
                            selectGenre(genre)
                        }
                    }
                }
            }
            .padding(.top, contentTopPad)
            .padding(.leading, sidebarLeadingPad)
            .padding(.trailing, sidebarTrailingInset)
            .padding(.bottom, 80)
        }
        .frame(width: sidebarWidth)
        .focusSection()
    }

    private func sidebarRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        MusicSidebarRow(title: title, isSelected: isSelected, action: action)
    }

    // MARK: - Content

    private var content: some View {
        ZStack(alignment: .top) {
            // Scroll view fills the entire content area edge-to-edge so its
            // clipping bounds (after .scrollClipDisabled) extend to the screen
            // edges, letting focused cards in the leftmost/rightmost columns
            // grow without being clipped. The header floats on top with an
            // opaque background and masks any scroll content that overflows
            // upward into the header band.
            Group {
                switch selectedCategory {
                case .recentlyAdded:
                    albumGrid(items: displayedRecentlyAdded, loading: isLoading)
                case .playlists:
                    playlistGrid(items: displayedPlaylists, loading: !loadedCategories.contains(.playlists))
                case .artists:
                    artistGrid
                case .albums:
                    albumGrid(items: displayedAlbums, loading: !loadedCategories.contains(.albums))
                case .songs:
                    songsList
                }
            }
            // Reserve top space so the first row of grid items isn't under the
            // floating header at rest position.
            .padding(.top, selectedCategory.showsHeader ? (contentTopPad + 88) : contentTopPad)
            .padding(.leading, contentLeadingPad)
            .padding(.trailing, contentTrailingPad)

            if selectedCategory.showsHeader {
                contentHeader
                    .padding(.leading, contentLeadingPad)
                    .padding(.trailing, contentTrailingPad)
                    .padding(.top, contentTopPad)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.98),
                                Color.black.opacity(0.92),
                                Color.black.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusSection()
    }

    private var contentHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(1)

                if !contentCountText.isEmpty {
                    Text(contentCountText)
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.56))
                }
            }

            Spacer(minLength: 24)

            HStack(spacing: 14) {
                if selectedCategory.supportsPlaybackActions {
                    Button {
                        Task { await playAll(shuffled: false) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color.white.opacity(0.16))

                    Button {
                        Task { await playAll(shuffled: true) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color.white.opacity(0.13))
                }

                if selectedCategory == .albums || selectedCategory == .songs {
                    Button {
                        toggleSortDirection()
                    } label: {
                        Image(systemName: currentSortIcon)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(Color.white.opacity(0.14))
                }
            }
        }
    }

    private var headerTitle: String {
        if let selectedGenre {
            return selectedGenre
        }
        return selectedCategory.title
    }

    // MARK: - Grids

    private func albumGrid(items: [MusicAlbum], loading: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if items.isEmpty {
                emptyState(
                    title: "No items",
                    subtitle: selectedGenre == nil ? "" : "Try another genre."
                )
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.ref) { index, item in
                        albumCard(item: item)
                            .musicItemContextMenu(item: .album(item), style: .album)
                            .onAppear {
                                // Paginate Recently Added as the user scrolls.
                                guard selectedCategory == .recentlyAdded else { return }
                                if index >= items.count - 12 {
                                    Task { await loadMoreRecentlyAddedIfNeeded() }
                                }
                            }
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .contentMargins(.top, 40, for: .scrollContent)
        .contentMargins(.leading, 32, for: .scrollContent)
        .contentMargins(.trailing, 32, for: .scrollContent)
        .scrollClipDisabled()
    }

    private func playlistGrid(items: [PlexMetadata], loading: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if items.isEmpty {
                emptyState(
                    title: "No items",
                    subtitle: selectedGenre == nil ? "" : "Try another genre."
                )
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
                    ForEach(items, id: \.ratingKey) { item in
                        playlistCard(item: item)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .contentMargins(.top, 40, for: .scrollContent)
        .contentMargins(.leading, 32, for: .scrollContent)
        .contentMargins(.trailing, 32, for: .scrollContent)
        .scrollClipDisabled()
    }

    private var artistGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if !loadedCategories.contains(.artists) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if displayedArtists.isEmpty {
                emptyState(
                    title: "No artists",
                    subtitle: selectedGenre == nil ? "" : "Try another genre."
                )
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: gridRowSpacing) {
                    ForEach(displayedArtists) { artist in
                        artistCard(item: artist)
                    }
                }
                .padding(.bottom, 100)
            }
        }
        .contentMargins(.top, 40, for: .scrollContent)
        .contentMargins(.leading, 32, for: .scrollContent)
        .contentMargins(.trailing, 32, for: .scrollContent)
        .scrollClipDisabled()
    }

    private var songsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if !loadedCategories.contains(.songs) {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else if displayedTracks.isEmpty {
                emptyState(
                    title: "No songs",
                    subtitle: selectedGenre == nil ? "" : "Try another genre."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.ref) { index, track in
                        songRow(track: track, index: index)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 80)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - Cards

    @ViewBuilder
    private func albumCard(item: MusicAlbum) -> some View {
        MusicGridCard(
            title: item.title,
            artistSubtitle: item.artistName,
            artworkURL: item.artwork.poster,
            shape: .square
        ) {
            selectedAlbum = item
        }
    }

    @ViewBuilder
    private func artistCard(item: MusicArtist) -> some View {
        MusicGridCard(
            title: item.name,
            artistSubtitle: nil,
            artworkURL: item.artwork.poster,
            shape: .circle
        ) {
            selectedArtist = item
        }
    }

    @ViewBuilder
    private func playlistCard(item: PlexMetadata) -> some View {
        let artworkURL: URL? = {
            guard let thumb = item.thumb ?? item.parentThumb,
                  let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return nil }
            return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
        }()
        MusicGridCard(
            title: item.title ?? "",
            artistSubtitle: nil,
            artworkURL: artworkURL,
            shape: .square
        ) {
            selectedPlaylist = item
        }
    }

    // MARK: - Songs

    private func songRow(track: MusicTrack, index: Int) -> some View {
        let isCurrent = musicQueue.currentTrack?.ref == track.ref

        return Button {
            musicQueue.playAlbum(tracks: displayedTracks, startingAt: index)
        } label: {
            HStack(spacing: 18) {
                if isCurrent {
                    PlaybackIndicator(isPlaying: musicQueue.playbackState == .playing, size: .small)
                        .frame(width: 28)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(track.artistName ?? "")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if track.duration > 0 {
                    Text(formatDuration(track.duration))
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                musicQueue.addNext(track: track)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                musicQueue.addToEnd(track: track)
            } label: {
                Label("Play After", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.5))

            Text(title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    // MARK: - Filtered / sorted data

    private var filteredArtists: [MusicArtist] {
        guard let g = selectedGenre else { return allArtists }
        return allArtists.filter { $0.genres.contains(g) }
    }

    private var filteredAlbums: [MusicAlbum] {
        guard let g = selectedGenre else { return allAlbums }
        return allAlbums.filter { $0.genres.contains(g) }
    }

    private var filteredTracks: [MusicTrack] {
        // MusicTrack doesn't carry genres. Wave 1: return unfiltered.
        // TODO(post-wave-1): expose genre on MusicTrack or filter via album.
        return allTracks
    }

    private var displayedRecentlyAdded: [MusicAlbum] {
        guard let g = selectedGenre else { return recentlyAddedItems }
        return recentlyAddedItems.filter { $0.genres.contains(g) }
    }

    private var displayedPlaylists: [PlexMetadata] {
        playlists.sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    private var displayedArtists: [MusicArtist] {
        filteredArtists
            .sorted { ($0.sortName ?? $0.name) < ($1.sortName ?? $1.name) }
    }

    private var displayedAlbums: [MusicAlbum] {
        let items = filteredAlbums
        return items.sorted { lhs, rhs in
            let left = lhs.title
            let right = rhs.title
            return albumSortAscending
                ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    private var displayedTracks: [MusicTrack] {
        let items = filteredTracks
        return items.sorted { lhs, rhs in
            let left = lhs.title
            let right = rhs.title
            return songSortAscending
                ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    private var contentCountText: String {
        switch selectedCategory {
        case .recentlyAdded:
            return ""
        case .playlists:
            return displayedPlaylists.isEmpty ? "" : "\(displayedPlaylists.count) playlists"
        case .artists:
            return displayedArtists.isEmpty ? "" : "\(displayedArtists.count) artists"
        case .albums:
            return displayedAlbums.isEmpty ? "" : "\(displayedAlbums.count) albums"
        case .songs:
            return displayedTracks.isEmpty ? "" : "\(displayedTracks.count) songs"
        }
    }

    private var currentSortIcon: String {
        let ascending = selectedCategory == .albums ? albumSortAscending : songSortAscending
        return ascending ? "arrow.up" : "arrow.down"
    }

    // MARK: - Actions

    private func selectCategory(_ category: MusicLibraryCategory) {
        selectedCategory = category
        selectedGenre = nil
        Task { await loadCategoryData(category) }
    }

    private func selectGenre(_ genre: String) {
        selectedGenre = (selectedGenre == genre) ? nil : genre
        // Make sure the underlying category data is loaded so the filter has something to chew on
        if selectedGenre != nil {
            Task { await loadCategoryData(selectedCategory) }
        }
    }

    private func toggleSortDirection() {
        if selectedCategory == .albums {
            albumSortAscending.toggle()
        } else if selectedCategory == .songs {
            songSortAscending.toggle()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    // MARK: - Data loading

    private func loadRecentlyAdded() async {
        guard let provider = provider else { return }
        isLoading = true
        recentlyAddedItems = []
        recentlyAddedTotal = nil
        do {
            let result = try await provider.albums(
                in: currentLibrary,
                sort: .addedAtDesc,
                page: Page(offset: 0, limit: recentlyAddedPageSize)
            )
            recentlyAddedItems = result.items
            recentlyAddedTotal = result.total
        } catch {
            print("MusicHome: Failed to load recently added: \(error)")
        }
        isLoading = false
    }

    private func loadMoreRecentlyAddedIfNeeded() async {
        guard !isLoadingMoreRecentlyAdded else { return }
        guard let total = recentlyAddedTotal else { return }
        guard recentlyAddedItems.count < total else { return }
        guard let provider = provider else { return }

        isLoadingMoreRecentlyAdded = true
        defer { isLoadingMoreRecentlyAdded = false }

        do {
            let result = try await provider.albums(
                in: currentLibrary,
                sort: .addedAtDesc,
                page: Page(offset: recentlyAddedItems.count, limit: recentlyAddedPageSize)
            )
            // De-dupe by ref in case the server returns overlap.
            let existing = Set(recentlyAddedItems.map(\.ref))
            let newItems = result.items.filter { !existing.contains($0.ref) }
            recentlyAddedItems.append(contentsOf: newItems)
            recentlyAddedTotal = result.total
        } catch {
            print("MusicHome: Failed to load more recently added: \(error)")
        }
    }

    private func loadGenres() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        guard let url = URL(string: "\(serverURL)/library/sections/\(libraryKey)/genre?X-Plex-Token=\(token)") else { return }

        do {
            struct GenreResponse: Codable {
                struct Container: Codable { var Directory: [Entry]? }
                struct Entry: Codable { var title: String? }
                var MediaContainer: Container
            }

            let data = try await networkManager.requestData(url, method: "GET", headers: ["X-Plex-Token": token])
            let response = try JSONDecoder().decode(GenreResponse.self, from: data)
            genres = (response.MediaContainer.Directory ?? []).compactMap(\.title).sorted()
        } catch {
            print("MusicHome: Failed to load genres: \(error)")
        }
    }

    private func loadCategoryData(_ category: MusicLibraryCategory) async {
        guard !loadedCategories.contains(category) else { return }

        switch category {
        case .recentlyAdded:
            break
        case .playlists:
            // Keep existing Plex-specific path (playlists deferred to post-Wave-1).
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            playlists = (try? await networkManager.getPlaylists(serverURL: serverURL, authToken: token)) ?? []
        case .artists:
            guard let provider = provider else { return }
            let result = try? await provider.artists(
                in: currentLibrary,
                sort: .titleAsc,
                page: Page(offset: 0, limit: 500)
            )
            allArtists = result?.items ?? []
        case .albums:
            guard let provider = provider else { return }
            let result = try? await provider.albums(
                in: currentLibrary,
                sort: .titleAsc,
                page: Page(offset: 0, limit: 500)
            )
            allAlbums = result?.items ?? []
        case .songs:
            // No provider method for "all tracks in a library". Wave 1: use
            // the Plex-specific getLibraryItems path and map client-side.
            // TODO(post-wave-1): expose tracks(in:sort:page:) on MusicProvider.
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken,
                  let providerID = provider?.id else { return }
            let plexTracks = (try? await networkManager.getLibraryItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: 500,
                type: 10
            )) ?? []
            allTracks = plexTracks.map {
                PlexMusicMapper.track(
                    $0, providerID: providerID,
                    serverURL: serverURL, authToken: token
                )
            }
        }

        loadedCategories.insert(category)
    }

    private func playAll(shuffled: Bool) async {
        guard let provider = provider else { return }

        var tracks: [MusicTrack]
        if selectedCategory == .songs, !displayedTracks.isEmpty {
            tracks = displayedTracks
        } else {
            // Pull ALL tracks for the library. Wave 1 Plex-specific fallback.
            // TODO(post-wave-1): expose tracks(in:sort:page:) on MusicProvider.
            guard let serverURL = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else { return }
            let plexTracks = (try? await networkManager.getLibraryItems(
                serverURL: serverURL,
                authToken: token,
                sectionId: libraryKey,
                start: 0,
                size: 1000,
                type: 10
            )) ?? []
            tracks = plexTracks.map {
                PlexMusicMapper.track(
                    $0, providerID: provider.id,
                    serverURL: serverURL, authToken: token
                )
            }
        }

        if shuffled { tracks.shuffle() }
        if !tracks.isEmpty {
            musicQueue.playAlbum(tracks: tracks)
        }
    }
}

// MARK: - MusicSidebarRow

/// Apple Music tvOS sidebar row.
/// Uses the system `Button` focus (white glass pill, dark text on focus) for the focus state.
/// "Selected but unfocused" is shown via a small leading accent dot, NOT a background pill —
/// because the system focus highlight already owns the background treatment.
private struct MusicSidebarRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Leading accent dot — only visible when this row represents the selected
                // category but isn't currently focused. When focused, the system pill is
                // the indicator, so we hide the dot to avoid double-marking.
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .opacity(isSelected && !isFocused ? 0.95 : 0)

                Text(title)
                    .font(.system(size: 26, weight: (isSelected || isFocused) ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - MusicGridCard

private struct MusicGridCard: View {
    enum Shape {
        case square
        case circle
    }

    let title: String
    let artistSubtitle: String?
    let artworkURL: URL?
    let shape: Shape
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: shape == .circle ? .center : .leading, spacing: 0) {
                artwork
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(isFocused ? 1.08 : 1.0)
                    .shadow(
                        color: .black.opacity(isFocused ? 0.55 : 0.35),
                        radius: isFocused ? 24 : 14,
                        x: 0,
                        y: isFocused ? 18 : 12
                    )

                Text(title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .multilineTextAlignment(shape == .circle ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: shape == .circle ? .center : .leading)
                    .padding(.top, isFocused ? 22 : 16)

                if let artistSubtitle, !artistSubtitle.isEmpty {
                    Text(artistSubtitle)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: shape == .circle ? .center : .leading)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: shape == .circle ? .center : .leading)
        }
        .buttonStyle(CardButtonStyle())
        .hoverEffectDisabled()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.22), value: isFocused)
    }

    @ViewBuilder
    private var artwork: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty, .failure:
                ZStack {
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: shape == .circle ? "person.fill" : "music.note")
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(.white.opacity(0.28))
                }
            @unknown default:
                Color.white.opacity(0.08)
            }
        }
        .clipShape(artworkClipShape)
    }

    private var artworkClipShape: AnyShape {
        switch shape {
        case .square:
            return AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .circle:
            return AnyShape(Circle())
        }
    }
}

// MARK: - Focus container

/// Wraps the music view in a UIHostingController that overrides `shouldUpdateFocus`
/// to block leftward focus escape — preventing the system tvOS sidebar tab bar from
/// stealing focus when the user navigates left within the music section.
///

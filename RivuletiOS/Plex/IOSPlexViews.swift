// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

struct IOSPlexHomeView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @State private var heroSelection = 0
    let showSettings: () -> Void

    init(showSettings: @escaping () -> Void = {}) {
        self.showSettings = showSettings
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let portrait = iosInterfaceIsPortrait(fallback: geometry.size)
                let heroArtworkTopInset = portrait
                    ? max(geometry.safeAreaInsets.top, iosStatusBarHeight) + 12
                    : 0
                let homeShelves = plex.shelves.filter { !$0.isOnDeck }
                let heroItems = Array(
                    homeShelves
                        .filter { !$0.isContinueWatching }
                        .flatMap(\.items)
                        .prefix(5)
                )

                ZStack {
                    IOSPlexAmbientBackdrop(
                        item: heroItems[safe: heroSelection],
                        isPortrait: portrait
                    )

                    Group {
                        if !plex.isConfigured {
                            VStack(spacing: 0) {
                                IOSPlexTopChrome(showSettings: showSettings)
                                IOSPlexConnectView()
                            }
                        } else if homeShelves.isEmpty, plex.isLoadingContent {
                            VStack(spacing: 0) {
                                IOSPlexTopChrome(showSettings: showSettings)
                                ProgressView("Loading Plex…")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else if homeShelves.isEmpty {
                            VStack(spacing: 0) {
                                IOSPlexTopChrome(showSettings: showSettings)
                                ContentUnavailableView(
                                    "No Plex home content",
                                    systemImage: "rectangle.stack.badge.play",
                                    description: Text(stateMessage)
                                )
                            }
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 28) {
                                    if !heroItems.isEmpty {
                                        ZStack(alignment: .top) {
                                            IOSPlexHero(
                                                items: heroItems,
                                                selection: $heroSelection,
                                                height: IOSPlexHero.height(in: geometry.size)
                                                    + heroArtworkTopInset,
                                                artworkTopInset: heroArtworkTopInset,
                                                isPortrait: portrait
                                            )
                                            IOSPlexTopChrome(showSettings: showSettings)
                                        }
                                    } else {
                                        IOSPlexTopChrome(showSettings: showSettings)
                                    }
                                    ForEach(homeShelves) { shelf in
                                        IOSPlexShelfView(
                                            shelf: shelf,
                                            excludedItemIDs: Set(heroItems.map(\.id))
                                        )
                                    }
                                }
                                .padding(.bottom, 28)
                            }
                            .refreshable { await plex.refresh() }
                        }
                    }
                }
                .ignoresSafeArea(edges: [.top, .horizontal])
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PlexMetadata.self) { item in
                IOSPlexDetailView(item: item)
            }
        }
    }

    private var stateMessage: String {
        if case .failed(let message) = plex.state { return message }
        return "Pull to refresh your Plex home."
    }
}

struct IOSPlexLibrariesView: View {
    @EnvironmentObject private var plex: IOSPlexSession

    var body: some View {
        NavigationStack {
            Group {
                if !plex.isConfigured {
                    IOSPlexConnectView()
                } else if plex.libraries.isEmpty, plex.isLoadingContent {
                    ProgressView("Loading libraries…")
                } else {
                    List(plex.libraries) { library in
                        NavigationLink(value: library) {
                            Label(library.title, systemImage: library.icon)
                        }
                    }
                    .navigationDestination(for: PlexLibrary.self) { library in
                        IOSPlexLibraryView(library: library)
                    }
                    .refreshable { await plex.refresh() }
                }
            }
            .navigationTitle("Libraries")
        }
    }
}

struct IOSPlexLibraryView: View {
    let library: PlexLibrary
    let showSettings: () -> Void
    @EnvironmentObject private var plex: IOSPlexSession
    @State private var items: [PlexMetadata] = []
    @State private var libraryShelves: [PlexHub] = []
    @State private var error: String?
    @State private var heroSelection = 0
    @State private var isLoading = true

    init(library: PlexLibrary, showSettings: @escaping () -> Void = {}) {
        self.library = library
        self.showSettings = showSettings
    }

    var body: some View {
        GeometryReader { geometry in
            let portrait = iosInterfaceIsPortrait(fallback: geometry.size)
            let heroArtworkTopInset = portrait
                ? max(geometry.safeAreaInsets.top, iosStatusBarHeight) + 12
                : 0
            let heroItems = libraryHeroItems
            let columnCount = portrait ? 3 : max(4, Int(geometry.size.width / 150))
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: 14),
                count: columnCount
            )

            ZStack {
                IOSPlexAmbientBackdrop(
                    item: heroItems[safe: heroSelection],
                    isPortrait: portrait
                )

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if isLoading {
                            IOSPlexTopChrome(showSettings: showSettings)
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 56)
                        } else if let error {
                            IOSPlexTopChrome(showSettings: showSettings)
                            ContentUnavailableView(
                                "Couldn’t load library",
                                systemImage: "exclamationmark.triangle",
                                description: Text(error)
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            if !heroItems.isEmpty {
                                ZStack(alignment: .top) {
                                    IOSPlexHero(
                                        items: heroItems,
                                        selection: $heroSelection,
                                        height: IOSPlexHero.height(in: geometry.size)
                                            + heroArtworkTopInset,
                                        artworkTopInset: heroArtworkTopInset,
                                        isPortrait: portrait
                                    )
                                    IOSPlexTopChrome(showSettings: showSettings)
                                }
                            } else {
                                IOSPlexTopChrome(showSettings: showSettings)
                            }

                            ForEach(libraryShelves) { shelf in
                                IOSPlexShelfView(shelf: shelf)
                            }

                            Text(library.title)
                                .font(.title2.bold())
                                .padding(.horizontal)

                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(items) { item in
                                    NavigationLink(value: item) {
                                        IOSPlexPosterCard(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .frame(width: geometry.size.width, alignment: .leading)
                }
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: PlexMetadata.self) { item in
            IOSPlexDetailView(item: item)
        }
        .task { await load() }
    }

    /// Feature the first distinct non-Continue-Watching items from Plex's own
    /// ordered section hubs. Fall back to the full library when a server does
    /// not expose library hubs.
    private var libraryHeroItems: [PlexMetadata] {
        var seen = Set<String>()
        let hubItems = libraryShelves
            .filter { !$0.isContinueWatching }
            .flatMap(\.items)
            .filter { seen.insert($0.id).inserted }
        return Array((hubItems.isEmpty ? items : hubItems).prefix(5))
    }

    private func load() async {
        isLoading = true
        error = nil

        let itemsTask = Task { try await plex.items(in: library) }
        let hubsTask = Task { try? await plex.hubs(in: library) }

        do {
            items = try await itemsTask.value
        } catch {
            self.error = error.localizedDescription
        }
        libraryShelves = await hubsTask.value ?? []
        isLoading = false
    }
}

struct IOSPlexSearchView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    let showSettings: () -> Void
    @State private var query = ""
    @State private var results: [PlexMetadata] = []
    @State private var isSearching = false
    @State private var error: String?

    init(showSettings: @escaping () -> Void = {}) {
        self.showSettings = showSettings
    }

    var body: some View {
        NavigationStack {
            Group {
                if !plex.isConfigured {
                    IOSPlexConnectView()
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Search Plex", systemImage: "magnifyingglass", description: Text("Movies, shows, episodes and people on your server."))
                } else if isSearching {
                    ProgressView("Searching…")
                } else if let error {
                    ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { item in
                        NavigationLink(value: item) {
                            IOSPlexSearchRow(item: item)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movies, shows, episodes")
            .navigationDestination(for: PlexMetadata.self) { item in
                IOSPlexDetailView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    IOSAccountMenu(showSettings: showSettings)
                }
            }
            .task(id: query) { await search() }
        }
    }

    private func search() async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, plex.isConfigured else {
            results = []
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        error = nil
        do { results = try await plex.search(value) }
        catch { self.error = error.localizedDescription }
        isSearching = false
    }
}

struct IOSPlexSettingsView: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @EnvironmentObject private var navigation: IOSNavigationSettings
    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipCredits") private var autoSkipCredits = false
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("autoSkipRecap") private var autoSkipRecap = false
    @AppStorage("useIntroDB") private var useIntroDB = false
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30
    @State private var showingConnection = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Plex") {
                    LabeledContent("Status", value: plex.isConfigured ? "Connected" : "Not connected")
                    if let server = plex.selectedServerName {
                        LabeledContent("Server", value: server)
                    }
                    if plex.isConfigured {
                        Button("Refresh Plex", systemImage: "arrow.clockwise") {
                            Task { await plex.refresh() }
                        }
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            plex.signOut()
                        }
                    } else {
                        Button("Connect Plex", systemImage: "link") { showingConnection = true }
                    }
                }

                Section {
                    Toggle("Automatically skip intros", isOn: $autoSkipIntro)
                    Toggle("Automatically skip recaps", isOn: $autoSkipRecap)
                    Toggle("Automatically skip commercials", isOn: $autoSkipAds)
                    Toggle("Automatically skip credits", isOn: $autoSkipCredits)
                } header: {
                    Text("Skip markers")
                } footer: {
                    Text("Marker buttons are always offered during playback. Auto-skip applies only to the types enabled here.")
                }

                Section {
                    Toggle("Use IntroDB", isOn: $useIntroDB)
                } header: {
                    Text("Community markers")
                } footer: {
                    Text("When Plex has no marker of that type, Rivulet can query introdb.app using the show’s IMDb ID and episode number. No Plex token is shared.")
                }

                Section("Playback") {
                    LabeledContent("Engine", value: "AetherEngine")
                    LabeledContent("System captions", value: "Enabled")
                    Picker("Double-tap rewind", selection: $skipBackwardSeconds) {
                        ForEach([5, 10, 15, 30], id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    Picker("Double-tap forward", selection: $skipForwardSeconds) {
                        ForEach([10, 15, 30, 60], id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    Text("Audio and subtitle streams use the same AVFoundation media-selection APIs as the tvOS player when Aether selects its native backend.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(navigation.visibleItems(for: plex.libraries)) { item in
                        Label(item.title, systemImage: item.icon)
                    }
                    .onMove { offsets, destination in
                        navigation.moveSelected(from: offsets, to: destination, libraries: plex.libraries)
                    }
                } header: {
                    Text("Bottom tab order")
                } footer: {
                    Text("Apple’s native tab bar supports five items. Drag these rows to change their order.")
                }

                Section {
                    ForEach(navigation.availableItems(for: plex.libraries)) { item in
                        let selected = navigation.isSelected(item, libraries: plex.libraries)
                        Toggle(isOn: Binding(
                            get: { selected },
                            set: { navigation.setSelected(item, selected: $0, libraries: plex.libraries) }
                        )) {
                            Label(item.title, systemImage: item.icon)
                        }
                        .disabled(!selected && !navigation.canSelectMore(libraries: plex.libraries))
                    }
                } header: {
                    Text("Choose bottom tabs")
                } footer: {
                    Text("Choose up to five. Settings remains available from the account button at the top even when its tab is turned off.")
                }

                Section {
                    NavigationLink("Licenses & Legal") { IOSLicensesView() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { EditButton() }
            .sheet(isPresented: $showingConnection) { IOSPlexConnectionSheet() }
        }
    }
}

struct IOSPlexDetailView: View {
    let item: PlexMetadata
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.dismiss) private var dismiss
    @State private var fullItem: PlexMetadata?
    @State private var seasons: [PlexMetadata] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [PlexMetadata] = []
    @State private var episodeCache: [String: [PlexMetadata]] = [:]
    @State private var highlightedEpisodeID: String?
    @State private var playback: IOSPlexPlaybackRequest?
    @State private var isLoading = true
    @State private var isLoadingEpisodes = false
    @State private var isPreparingPlayback = false
    @State private var error: String?

    var body: some View {
        GeometryReader { geometry in
            let portrait = iosInterfaceIsPortrait(fallback: geometry.size)
            let horizontalInset: CGFloat = portrait ? 20 : 48

            ZStack {
                IOSPlexAmbientBackdrop(item: displayedItem, isPortrait: portrait)

                ScrollView {
                    VStack(alignment: .leading, spacing: portrait ? 18 : 22) {
                        heroHeader(
                            in: geometry.size,
                            isPortrait: portrait
                        )
                        if portrait {
                            actionRow(
                                isPortrait: true,
                                availableWidth: geometry.size.width
                            )
                        }

                        if let error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, horizontalInset)
                        }

                        if let summary = displayedItem.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.86))
                                .lineSpacing(3)
                                .padding(.horizontal, horizontalInset)
                                .frame(maxWidth: portrait ? .infinity : 820, alignment: .leading)
                        }

                        if !seasons.isEmpty {
                            seasonSelector(horizontalInset: horizontalInset)
                        }

                        if isLoadingEpisodes {
                            ProgressView("Loading episodes…")
                                .padding(.horizontal, horizontalInset)
                        } else if !episodes.isEmpty {
                            Text("Episodes")
                                .font(.title2.bold())
                                .padding(.horizontal, horizontalInset)

                            ScrollViewReader { reader in
                                ScrollView(.horizontal) {
                                    LazyHStack(alignment: .top, spacing: 14) {
                                        ForEach(episodes) { episode in
                                            NavigationLink(value: episode) {
                                                IOSPlexEpisodeCard(
                                                    item: episode,
                                                    isCurrent: episode.id == highlightedEpisodeID
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .id(episode.id)
                                        }
                                    }
                                    .padding(.horizontal, horizontalInset)
                                }
                                .scrollIndicators(.hidden)
                                .task(id: episodeScrollTargetID) {
                                    guard let target = episodeScrollTargetID else { return }
                                    await Task.yield()
                                    withAnimation(.easeInOut(duration: 0.32)) {
                                        reader.scrollTo(target, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                IOSPlexBackButton { dismiss() }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: PlexMetadata.self) { child in
            IOSPlexDetailView(item: child)
        }
        .task { await load() }
        .task(id: selectedSeasonID) { await loadSelectedSeason() }
        .fullScreenCover(item: $playback) { request in
            IOSPlexPlayerView(request: request)
        }
        .preferredColorScheme(.dark)
    }

    private var displayedItem: PlexMetadata { fullItem ?? item }

    private func heroHeader(
        in size: CGSize,
        isPortrait: Bool
    ) -> some View {
        let artworkWidth = size.width
        // Detail pages deliberately retain the portrait poster treatment;
        // the shorter 16:9 banner height is reserved for browsing heroes.
        let height = isPortrait ? size.width * 1.5 : size.width * 9 / 16
        let artworkURL = plex.artworkURL(
            for: displayedItem,
            kind: isPortrait ? .poster : .backdrop,
            width: isPortrait ? 900 : 1600,
            height: isPortrait ? 1350 : 900
        )

        return ZStack(alignment: isPortrait ? .bottom : .bottomLeading) {
            LinearGradient(
                colors: [.gray.opacity(0.7), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            IOSPlexRetainedArtwork(url: artworkURL)
            .frame(width: artworkWidth, height: height)
            .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.42), location: 0.72),
                    .init(color: .black.opacity(0.96), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            if !isPortrait {
                LinearGradient(
                    colors: [.black.opacity(0.78), .black.opacity(0.18), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }

            if isPortrait {
                detailTitleBlock(isPortrait: true, maxWidth: size.width - 40)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    detailTitleBlock(
                        isPortrait: false,
                        maxWidth: min(artworkWidth * 0.62, 760)
                    )
                    actionRow(
                        isPortrait: false,
                        availableWidth: max(0, artworkWidth - 104)
                    )
                }
                .padding(.horizontal, 52)
                .padding(.bottom, 28)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .bottomLeading
                )
            }
        }
        .frame(width: artworkWidth, height: height)
    }

    private func detailTitleBlock(
        isPortrait: Bool,
        maxWidth: CGFloat
    ) -> some View {
        VStack(alignment: isPortrait ? .center : .leading, spacing: 8) {
            IOSPlexResolvedLogo(
                item: displayedItem,
                fallbackTitle: displayedItem.displayTitle,
                maxWidth: maxWidth,
                maxHeight: isPortrait ? 92 : 112,
                fallbackFont: .system(
                    size: isPortrait ? 32 : 38,
                    weight: .bold,
                    design: .rounded
                ),
                alignment: isPortrait ? .center : .leading,
                textAlignment: isPortrait ? .center : .leading
            )
            HStack(spacing: 8) {
                if let subtitle = displayedItem.subtitle { Text(subtitle) }
                if let rating = displayedItem.contentRating { Text(rating).plexPill() }
                if let duration = displayedItem.duration, duration > 0 {
                    Text(formatDuration(duration)).foregroundStyle(.white.opacity(0.78))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
        }
        .frame(
            maxWidth: maxWidth,
            alignment: isPortrait ? .center : .leading
        )
    }

    @ViewBuilder
    private func actionRow(
        isPortrait: Bool,
        availableWidth: CGFloat
    ) -> some View {
        if isPortrait {
            let playWidth = max(0, availableWidth - 48)
            VStack(spacing: 14) {
                primaryPlayButton(width: playWidth)
                HStack {
                    Spacer(minLength: 0)
                    IOSPlexRoundAction(systemName: "eye", title: "Watched") { }
                    Spacer(minLength: 0)
                    IOSPlexRoundAction(systemName: "arrow.down.to.line", title: "Download") { }
                    Spacer(minLength: 0)
                    IOSPlexRoundAction(systemName: "bookmark", title: "Watchlist") { }
                    Spacer(minLength: 0)
                }
            }
            .frame(width: availableWidth)
        } else {
            let playWidth = min(240, max(180, availableWidth * 0.28))
            HStack(spacing: 14) {
                primaryPlayButton(width: playWidth)
                IOSPlexRoundAction(systemName: "eye", title: "Watched") { }
                IOSPlexRoundAction(systemName: "arrow.down.to.line", title: "Download") { }
                IOSPlexRoundAction(systemName: "bookmark", title: "Watchlist") { }
                if isPreparingPlayback { ProgressView().tint(.white) }
                Spacer(minLength: 0)
            }
        }
    }

    private func primaryPlayButton(width: CGFloat) -> some View {
        Button {
            Task { await preparePlayback() }
        } label: {
            ZStack(alignment: .trailing) {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    if let progress = playbackProgress {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.black.opacity(0.22))
                                Capsule()
                                    .fill(.black.opacity(0.88))
                                    .frame(width: geometry.size.width * progress)
                            }
                        }
                        .frame(width: min(84, max(54, width * 0.24)), height: 3)
                    }
                    Text(playButtonTitle)
                        .lineLimit(1)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isPreparingPlayback {
                    ProgressView()
                        .tint(.black)
                        .padding(.trailing, 18)
                }
            }
            .frame(width: width, height: 50)
            .foregroundStyle(.black)
            .background(Color.white, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: 50)
        .opacity(playbackTarget == nil || isLoading ? 0.45 : 1)
        .disabled(playbackTarget == nil || isPreparingPlayback || isLoading)
    }

    private func seasonSelector(horizontalInset: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(seasons) { season in
                    let selected = selectedSeasonID == season.id
                    Button {
                        selectedSeasonID = season.id
                    } label: {
                        Text(seasonLabel(season))
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .black : .white.opacity(0.76))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(selected ? Color.white.opacity(0.9) : Color.clear, in: Capsule())
                            .overlay {
                                if !selected {
                                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, horizontalInset)
        }
        .scrollIndicators(.hidden)
    }

    private var playbackTarget: PlexMetadata? {
        if displayedItem.isPlayable { return displayedItem }
        return episodes.first(where: { $0.id == highlightedEpisodeID })
            ?? episodes.first(where: { $0.resumeSeconds > 0 })
            ?? episodes.first(where: { ($0.viewCount ?? 0) == 0 })
            ?? episodes.first
    }

    private var playbackProgress: CGFloat? {
        guard let target = playbackTarget,
              target.durationSeconds > 0,
              target.resumeSeconds > 0 else { return nil }
        let fraction = target.resumeSeconds / target.durationSeconds
        guard fraction > 0, fraction < 1 else { return nil }
        return CGFloat(fraction)
    }

    private var episodeScrollTargetID: String? {
        guard let highlightedEpisodeID,
              episodes.contains(where: { $0.id == highlightedEpisodeID }) else { return nil }
        return highlightedEpisodeID
    }

    private var playButtonTitle: String {
        guard let target = playbackTarget else { return isLoading ? "Loading…" : "Play" }
        return target.resumeSeconds > 0
            ? "Resume \(formatDuration(Int(target.resumeSeconds * 1000)))"
            : "Play"
    }

    private func seasonLabel(_ season: PlexMetadata) -> String {
        guard let index = season.index else { return season.displayTitle }
        return index == 0 ? "Specials" : "Season \(index)"
    }

    private func load() async {
        do {
            let full = try await plex.metadata(for: item)
            fullItem = full

            switch full.type {
            case "show":
                let loadedSeasons = try await plex.children(of: full)
                seasons = loadedSeasons.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
                await preloadEpisodesAndSelectNextUp()
            case "season":
                seasons = [full]
                selectedSeasonID = full.id
            default:
                break
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadSelectedSeason() async {
        guard let selectedSeasonID,
              let season = seasons.first(where: { $0.id == selectedSeasonID }) else { return }

        if let cached = episodeCache[selectedSeasonID] {
            episodes = cached
            isLoadingEpisodes = false
            if highlightedEpisodeID == nil {
                highlightedEpisodeID = nextEpisode(in: cached)?.id
            }
            return
        }

        isLoadingEpisodes = true
        do {
            let loadedEpisodes = try await plex.children(of: season)
            guard self.selectedSeasonID == selectedSeasonID else { return }
            let sorted = loadedEpisodes.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            episodeCache[selectedSeasonID] = sorted
            episodes = sorted
            if highlightedEpisodeID == nil {
                highlightedEpisodeID = nextEpisode(in: sorted)?.id
            }
        } catch {
            guard self.selectedSeasonID == selectedSeasonID else { return }
            self.error = error.localizedDescription
            episodes = []
        }
        if self.selectedSeasonID == selectedSeasonID {
            isLoadingEpisodes = false
        }
    }

    /// Loads the season rails together, then selects an active resume point
    /// first or the earliest unwatched episode second. This makes a show open
    /// directly on the relevant season and gives ScrollViewReader a stable ID
    /// to centre as soon as the rail appears.
    private func preloadEpisodesAndSelectNextUp() async {
        let seasonList = seasons
        let loaded: [String: [PlexMetadata]] = await withTaskGroup(
            of: (String, [PlexMetadata]).self,
            returning: [String: [PlexMetadata]].self
        ) { group in
            for season in seasonList {
                group.addTask {
                    let children = (try? await plex.children(of: season)) ?? []
                    return (
                        season.id,
                        children.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
                    )
                }
            }

            var result: [String: [PlexMetadata]] = [:]
            for await (seasonID, children) in group {
                result[seasonID] = children
            }
            return result
        }

        guard !Task.isCancelled else { return }
        episodeCache.merge(loaded) { _, new in new }

        let chronologicalSeasons = seasonList.sorted {
            let lhs = ($0.index ?? 0) == 0 ? Int.max : ($0.index ?? Int.max - 1)
            let rhs = ($1.index ?? 0) == 0 ? Int.max : ($1.index ?? Int.max - 1)
            return lhs < rhs
        }
        let ordered = chronologicalSeasons.flatMap { loaded[$0.id] ?? [] }
        let target = ordered.first(where: { $0.resumeSeconds > 0 })
            ?? ordered.first(where: { ($0.viewCount ?? 0) == 0 })
            ?? ordered.first

        highlightedEpisodeID = target?.id
        let targetSeason = chronologicalSeasons.first {
            loaded[$0.id]?.contains(where: { $0.id == target?.id }) == true
        }
        selectedSeasonID = targetSeason?.id
            ?? chronologicalSeasons.first?.id
            ?? seasonList.first?.id
        if let selectedSeasonID {
            episodes = loaded[selectedSeasonID] ?? []
        }
    }

    private func nextEpisode(in candidates: [PlexMetadata]) -> PlexMetadata? {
        candidates.first(where: { $0.resumeSeconds > 0 })
            ?? candidates.first(where: { ($0.viewCount ?? 0) == 0 })
            ?? candidates.first
    }

    private func preparePlayback() async {
        guard let playbackTarget else { return }
        isPreparingPlayback = true
        do { playback = try await plex.playback(for: playbackTarget) }
        catch { self.error = error.localizedDescription }
        isPreparingPlayback = false
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let minutes = max(0, milliseconds / 60000)
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct IOSPlexConnectView: View {
    @State private var showingConnection = false

    var body: some View {
        ContentUnavailableView {
            Label("Connect Plex", systemImage: "server.rack")
        } description: {
            Text("Sign in to browse and play your Plex libraries on iPhone or iPad.")
        } actions: {
            Button("Connect Plex") { showingConnection = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $showingConnection) { IOSPlexConnectionSheet() }
    }
}

struct IOSAccountMenu: View {
    @EnvironmentObject private var plex: IOSPlexSession
    let showSettings: () -> Void

    var body: some View {
        Menu {
            Button("Settings", systemImage: "gearshape") { showSettings() }
            if plex.isConfigured {
                Button("Refresh Plex", systemImage: "arrow.clockwise") {
                    Task { await plex.refresh() }
                }
                if let name = plex.selectedServerName {
                    Divider()
                    Label(name, systemImage: "server.rack")
                }
            }
        } label: {
            IOSPlexAccountAvatar(url: plex.profileImageURL)
        }
        .accessibilityLabel(
            plex.profileDisplayName.map { "Account for \($0) and settings" }
                ?? "Account and settings"
        )
    }
}

private struct IOSPlexAccountAvatar: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(.thinMaterial)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.75)
        }
        .task(id: url) {
            image = nil
            guard let url,
                  let loaded = await IOSArtworkCache.shared.image(for: url),
                  !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private struct IOSPlexTopChrome: View {
    let showSettings: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            IOSAccountMenu(showSettings: showSettings)
                .frame(width: 44, height: 44)
        }
        .padding(.leading, max(16, iosActiveSafeAreaInsets.left + 8))
        .padding(.trailing, max(16, iosActiveSafeAreaInsets.right + 8))
        // Artwork still owns the unsafe area, while the interactive account
        // control begins just inside the device's actual safe region.
        .padding(.top, max(4, iosActiveSafeAreaInsets.top + 4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(true)
    }
}

private struct IOSPlexBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.thinMaterial, in: Circle())
        .padding(.leading, 16)
        .padding(.top, max(2, iosStatusBarHeight - 8))
        .accessibilityLabel("Back")
    }
}

struct IOSPlexConnectionSheet: View {
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                switch plex.state {
                case .requestingPIN, .findingServers:
                    ProgressView("Connecting to Plex…")
                case .waitingForPIN:
                    Image(systemName: "person.badge.key.fill").font(.system(size: 54)).foregroundStyle(.tint)
                    Text(plex.pinCode ?? "").font(.system(.largeTitle, design: .monospaced, weight: .bold)).textSelection(.enabled)
                    Text("Open Plex, sign in, and enter this code. Rivulet will continue automatically.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if let url = plex.authenticationURL {
                        Button("Open Plex Sign In", systemImage: "safari") { openURL(url) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                case .selectingServer:
                    Text("Choose a server").font(.title2.bold())
                    List(plex.availableServers) { server in
                        Button {
                            Task { await plex.selectServer(server) }
                        } label: {
                            HStack {
                                Label(server.name, systemImage: server.owned == false ? "person.2" : "server.rack")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                    }
                case .failed(let message):
                    ContentUnavailableView("Couldn’t connect", systemImage: "exclamationmark.triangle", description: Text(message))
                    Button("Try Again") { Task { await plex.beginSignIn() } }.buttonStyle(.borderedProminent)
                case .connected:
                    ContentUnavailableView("Plex connected", systemImage: "checkmark.circle.fill", description: Text(plex.selectedServerName ?? "Your library is ready."))
                case .signedOut:
                    ProgressView()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Plex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { plex.cancelSignIn(); dismiss() } } }
            .task { if !plex.isConfigured { await plex.beginSignIn() } }
            .onChange(of: plex.state) { _, state in
                if state == .connected { Task { try? await Task.sleep(for: .milliseconds(500)); dismiss() } }
            }
        }
    }
}

private struct IOSPlexHero: View {
    let items: [PlexMetadata]
    @Binding var selection: Int
    let height: CGFloat
    let artworkTopInset: CGFloat
    let isPortrait: Bool
    @EnvironmentObject private var plex: IOSPlexSession

    static func height(in size: CGSize) -> CGFloat {
        // Browsing heroes use landscape Plex art in both orientations. This
        // avoids showing a poster that already contains its own title directly
        // behind a second clear-logo/title treatment.
        size.width * 9 / 16
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                NavigationLink(value: item) {
                    let artworkURL = plex.artworkURL(
                        for: item,
                        kind: .backdrop,
                        width: 1600,
                        height: 900
                    )
                    let artworkHeight = max(0, height - artworkTopInset)

                    ZStack(alignment: .top) {
                        if isPortrait, artworkTopInset > 0 {
                            // A second, heavily softened copy carries the
                            // artwork's colour through the Dynamic Island /
                            // status-bar region. Detail is intentionally lost
                            // here so the page chrome stays legible.
                            IOSPlexRetainedArtwork(url: artworkURL)
                                .blur(radius: 28)
                                .scaleEffect(1.14)
                                .frame(maxWidth: .infinity)
                                .frame(height: height)
                                .clipped()

                            LinearGradient(
                                colors: [.black.opacity(0.16), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: artworkTopInset + 42)
                        }

                        ZStack(alignment: isPortrait ? .bottom : .bottomLeading) {
                            LinearGradient(
                                colors: [.cyan.opacity(0.55), .indigo.opacity(0.4), .black],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )

                            IOSPlexRetainedArtwork(url: artworkURL)

                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.32),
                                    .init(color: .black.opacity(0.34), location: 0.67),
                                    .init(color: .black.opacity(0.94), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )

                            if !isPortrait {
                                LinearGradient(
                                    colors: [.black.opacity(0.8), .black.opacity(0.2), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            }

                            VStack(
                                alignment: isPortrait ? .center : .leading,
                                spacing: isPortrait ? 6 : 8
                            ) {
                                IOSPlexResolvedLogo(
                                    item: item,
                                    fallbackTitle: item.type == "episode"
                                        ? (item.grandparentTitle ?? item.displayTitle)
                                        : item.displayTitle,
                                    maxWidth: isPortrait ? 280 : 430,
                                    maxHeight: isPortrait ? 56 : 104,
                                    fallbackFont: .system(
                                        size: isPortrait ? 27 : 38,
                                        weight: .bold,
                                        design: .rounded
                                    ),
                                    alignment: isPortrait ? .center : .leading,
                                    textAlignment: isPortrait ? .center : .leading
                                )
                                if let summary = item.summary {
                                    Text(summary)
                                        .lineLimit(isPortrait ? 1 : 3)
                                        .multilineTextAlignment(isPortrait ? .center : .leading)
                                        .foregroundStyle(.white.opacity(0.82))
                                }
                                Label("View details", systemImage: "play.fill")
                                    .font(isPortrait ? .subheadline.weight(.semibold) : .headline)
                                    .padding(.horizontal, isPortrait ? 16 : 20)
                                    .padding(.vertical, isPortrait ? 8 : 11)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .foregroundStyle(.white)
                            .frame(
                                maxWidth: isPortrait ? 340 : 620,
                                alignment: isPortrait ? .center : .leading
                            )
                            .padding(.horizontal, isPortrait ? 24 : 52)
                            .padding(
                                .bottom,
                                isPortrait
                                    ? (items.count > 1 ? 34 : 16)
                                    : (items.count > 1 ? 48 : 24)
                            )
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: isPortrait ? .bottom : .bottomLeading
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: artworkHeight)
                        .mask {
                            if isPortrait, artworkTopInset > 0 {
                                // Fade from the blurred continuation into the
                                // sharp hero instead of exposing a hard seam.
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .white, location: 0.12),
                                        .init(color: .white, location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            } else {
                                Rectangle()
                            }
                        }
                        // Apply the transition mask in the artwork's own
                        // coordinate space, then move both down together.
                        // Offsetting first leaves the mask at y=0 and clips
                        // the bottom controls by exactly artworkTopInset.
                        .offset(y: artworkTopInset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .frame(height: height)
        .onChange(of: items.count) { _, count in
            if count == 0 { selection = 0 }
            else if selection >= count { selection = count - 1 }
        }
    }
}

/// The same two-layer treatment used by the tvOS home: artwork supplies a
/// full-screen colour wash, the native material destroys its detail, and the
/// crisp hero above fades into that wash instead of ending at a card edge.
private struct IOSPlexAmbientBackdrop: View {
    let item: PlexMetadata?
    let isPortrait: Bool
    @EnvironmentObject private var plex: IOSPlexSession

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.12), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )

            if let item {
                IOSPlexRetainedArtwork(
                    url: plex.artworkURL(
                        for: item,
                        // Browse heroes now use 16:9 Plex art in every
                        // orientation, so the ambient wash must follow that
                        // same asset. Hub payloads can omit the portrait thumb;
                        // retaining it here made the old background appear
                        // frozen while the hero itself changed.
                        kind: .backdrop,
                        width: 1600,
                        height: 900
                    ),
                    transitionDuration: 0.28
                )
                .ignoresSafeArea()

                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
            }

            LinearGradient(
                colors: [.black.opacity(0.08), .black.opacity(0.3), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Holds the last decoded frame while the next Plex artwork is fetched, then
/// crossfades it without ever inserting AsyncImage's empty phase. Explicit
/// geometry gives scaledToFill a stable, centred crop in either orientation.
private struct IOSPlexRetainedArtwork: View {
    let url: URL?
    var transitionDuration: Double = 0.22

    @State private var outgoingImage: UIImage?
    @State private var incomingImage: UIImage?
    @State private var displayedURL: URL?
    @State private var transitionProgress: Double = 1

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let outgoingImage {
                    centredImage(outgoingImage, size: geometry.size)
                        .opacity(1 - transitionProgress)
                }

                if let incomingImage {
                    centredImage(incomingImage, size: geometry.size)
                        .opacity(transitionProgress)
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .center
            )
            .clipped()
        }
        .task(id: url) {
            await transition(to: url)
        }
    }

    private func centredImage(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height, alignment: .center)
            .clipped()
    }

    @MainActor
    private func transition(to newURL: URL?) async {
        guard displayedURL != newURL else { return }

        let newImage: UIImage?
        if let newURL {
            newImage = await IOSArtworkCache.shared.image(for: newURL)
            guard !Task.isCancelled else { return }
            // A failed request must not blank artwork that is already visible.
            guard newImage != nil else { return }
        } else {
            newImage = nil
        }

        var seed = Transaction()
        seed.disablesAnimations = true
        withTransaction(seed) {
            outgoingImage = incomingImage ?? outgoingImage
            incomingImage = newImage
            displayedURL = newURL
            transitionProgress = outgoingImage == nil ? 1 : 0
        }

        guard outgoingImage != nil else { return }
        withAnimation(.easeInOut(duration: transitionDuration)) {
            transitionProgress = 1
        }

        do {
            try await Task.sleep(for: .seconds(transitionDuration))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        outgoingImage = nil
    }
}

private struct IOSPlexShelfView: View {
    let shelf: PlexHub
    let excludedItemIDs: Set<String>

    init(shelf: PlexHub, excludedItemIDs: Set<String> = []) {
        self.shelf = shelf
        self.excludedItemIDs = excludedItemIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.displayTitle).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items.filter { !excludedItemIDs.contains($0.id) }) { item in
                        NavigationLink(value: item) {
                            if shelf.isContinueWatching {
                                IOSPlexContinueCard(item: item)
                            } else {
                                IOSPlexPosterCard(item: item, width: IOSPlexPosterCard.tileWidth)
                            }
                        }
                        .frame(width: shelf.isContinueWatching ? 220 : IOSPlexPosterCard.tileWidth)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Sizes a tile from a known width, or falls back to the flexible aspect-ratio
/// behaviour when the parent decides the width (grid columns, search rows).
private struct TileSize: ViewModifier {
    let width: CGFloat?
    let ratio: CGFloat

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, height: width / ratio)
        } else {
            content.aspectRatio(ratio, contentMode: .fit)
        }
    }
}

private struct IOSPlexPosterCard: View {
    let item: PlexMetadata
    /// Fixed tile width, or nil to fill whatever the parent offers (grid
    /// columns, the compact search row).
    var width: CGFloat? = nil
    @EnvironmentObject private var plex: IOSPlexSession

    /// Music keeps the poster WIDTH and only the height changes, mirroring tvOS
    /// `MediaRowMetrics`, so a mixed shelf still lines up.
    static let tileWidth: CGFloat = 144
    private var ratio: CGFloat { item.isMusic ? 1 : 2 / 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AsyncImage(
                url: plex.artworkURL(
                    for: item,
                    kind: item.isMusic ? .thumb : .poster,
                    width: 420,
                    height: item.isMusic ? 420 : 630
                )
            ) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary).overlay { Image(systemName: item.isMusic ? "music.note" : "play.rectangle") } }
            }
            // A known width is sized outright rather than left to
            // `aspectRatio(_:contentMode: .fit)`. In a rail the height offered
            // to the card is whatever the title and subtitle leave behind, and
            // `.fit` honours it: a 2:3 poster stays width-limited and looks
            // right, but a 1:1 square goes height-limited and pulls in from the
            // edges of its slot, which is why only music showed it.
            .modifier(TileSize(width: width, ratio: ratio))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) {
                if item.durationSeconds > 0, item.resumeSeconds > 0 {
                    ProgressView(value: min(item.resumeSeconds / item.durationSeconds, 1)).tint(.white).padding(6)
                }
            }
            Text(item.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white)
            if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

private struct IOSPlexContinueCard: View {
    let item: PlexMetadata
    @EnvironmentObject private var plex: IOSPlexSession

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            IOSPlexRetainedArtwork(
                url: plex.artworkURL(
                    for: item,
                    kind: .backdrop,
                    width: 720,
                    height: 405
                )
            )

            LinearGradient(
                colors: [.clear, .black.opacity(0.34)],
                startPoint: .center,
                endPoint: .bottom
            )

            IOSPlexResolvedLogo(
                item: item,
                fallbackTitle: item.type == "episode"
                    ? (item.grandparentTitle ?? item.displayTitle)
                    : item.displayTitle,
                maxWidth: 165,
                maxHeight: 74,
                fallbackFont: .title3.bold(),
                alignment: .center,
                textAlignment: .center
            )
            .padding(.horizontal, 18)

            if item.durationSeconds > 0, item.resumeSeconds > 0 {
                ProgressView(value: min(item.resumeSeconds / item.durationSeconds, 1))
                    .tint(.white)
                    .padding(10)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        // The source remains 16:9 and scaled-to-fill; the visible card is the
        // tighter 4:3 crop requested for iPhone/iPad Continue Watching.
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(item.displayTitle)
    }
}

/// Clear-logo renderer shared by detail heroes and Continue Watching. It
/// preserves transparent artwork, sizes it to fit the current surface, and
/// retains a readable text title while Plex metadata or the image is loading.
private struct IOSPlexResolvedLogo: View {
    let item: PlexMetadata
    let fallbackTitle: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let fallbackFont: Font
    let alignment: Alignment
    let textAlignment: TextAlignment

    @EnvironmentObject private var plex: IOSPlexSession
    @State private var logoImage: UIImage?

    private var sourceIdentity: String {
        let key = item.type == "episode"
            ? item.grandparentRatingKey
            : (item.type == "season" ? item.parentRatingKey : item.ratingKey)
        return "\(key ?? item.id)|\(item.clearLogoPath ?? "")"
    }

    var body: some View {
        ZStack(alignment: alignment) {
            Text(fallbackTitle)
                .font(fallbackFont)
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
                .minimumScaleFactor(0.72)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
                .opacity(logoImage == nil ? 1 : 0)

            if let logoImage {
                Image(uiImage: logoImage)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
        .animation(.easeInOut(duration: 0.22), value: logoImage != nil)
        .task(id: sourceIdentity) {
            logoImage = nil
            guard let url = await plex.logoURL(for: item),
                  !Task.isCancelled,
                  let image = await IOSArtworkCache.shared.image(for: url),
                  !Task.isCancelled else { return }
            logoImage = image
        }
    }
}

private struct IOSPlexSearchRow: View {
    let item: PlexMetadata
    var body: some View {
        HStack(spacing: 12) {
            IOSPlexPosterCard(item: item).frame(width: 64)
            VStack(alignment: .leading) {
                Text(item.displayTitle).font(.headline)
                if let subtitle = item.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                Text(item.type?.capitalized ?? "Media").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct IOSPlexChildRow: View {
    let item: PlexMetadata
    @EnvironmentObject private var plex: IOSPlexSession
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: plex.artworkURL(for: item, width: 320, height: 180)) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 132, height: 78).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.headline).lineLimit(2)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                if let summary = item.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            Image(systemName: item.isPlayable ? "play.circle.fill" : "chevron.right").foregroundStyle(.secondary)
        }
        .padding(10).background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct IOSPlexEpisodeCard: View {
    let item: PlexMetadata
    let isCurrent: Bool
    @EnvironmentObject private var plex: IOSPlexSession

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Episode thumbs are Plex's 16:9 stills. Using `art` here would
            // repeat the show's backdrop for every episode in the rail.
            AsyncImage(url: plex.artworkURL(for: item, width: 560, height: 315)) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 164, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.white : Color.clear,
                        lineWidth: isCurrent ? 3 : 0
                    )
            }
            Text(item.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle = item.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 164, alignment: .leading)
        .accessibilityValue(isCurrent ? "Current episode" : "")
    }
}

private struct IOSPlexRoundAction: View {
    let systemName: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.14), in: Circle())
                Text(title).font(.caption2).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

private extension View {
    func plexPill() -> some View {
        self.font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in: Capsule())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private var iosActiveWindowScene: UIWindowScene? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
}

private var iosStatusBarHeight: CGFloat {
    iosActiveWindowScene?.statusBarManager?.statusBarFrame.height ?? 0
}

private var iosActiveSafeAreaInsets: UIEdgeInsets {
    iosActiveWindowScene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets
        ?? .zero
}

private func iosInterfaceIsPortrait(fallback size: CGSize) -> Bool {
    iosActiveWindowScene?.effectiveGeometry.interfaceOrientation.isPortrait
        ?? (size.height >= size.width)
}

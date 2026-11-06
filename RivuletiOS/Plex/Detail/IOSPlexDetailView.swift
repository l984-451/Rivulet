// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import SwiftUI

/// Movie, show, season or episode page in the TV app's layout: full-bleed
/// art under a transparent bar, actions, episodes, then related rows.
struct IOSPlexDetailView: View {
    let item: MediaItem
    @EnvironmentObject private var browse: IOSBrowseStore
    @Environment(\.plexActions) private var actions
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var detail: MediaItemDetail?
    @State private var seasons: [MediaItem] = []
    @State private var seasonKey: MediaItemRef?
    @State private var episodes: [MediaItem] = []
    @State private var episodesSeasonKey: MediaItemRef?
    @State private var related: [MediaItem] = []
    @State private var error: String?
    @State private var loadedRevision: Int?
    @State private var summaryExpanded = false

    private var shown: MediaItem { detail?.item ?? item }
    private var isSeries: Bool { shown.kind == .show || shown.kind == .season }
    private var regular: Bool { sizeClass == .regular }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    IOSPlexDetailHeader(
                        item: shown,
                        detail: detail,
                        playTarget: playTarget,
                        isLoading: detail == nil && error == nil,
                        size: CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top)
                    )
                    if detail == nil, let error {
                        IOSPlexErrorView(title: "Couldn't Load", message: error) { await load() }
                    } else {
                        sections(leading: IOSShelfGeometry.leading)
                    }
                }
                .padding(.bottom, 32)
            }
            .ignoresSafeArea(edges: .top)
            .refreshable { await load() }
        }
        // The page is dark in both modes, like the header art it continues.
        .iosPlexAmbient(shown)
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle(shown.showTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .task(id: browse.watchStateRevision) {
            guard loadedRevision != browse.watchStateRevision else { return }
            await load()
        }
        .task(id: seasonKey) { await loadEpisodes() }
    }

    @ViewBuilder
    private func sections(leading: CGFloat) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, leading)
        }
        if let summary = shown.overview, !summary.isEmpty {
            summaryView(summary).padding(.horizontal, leading)
        }
        if isSeries {
            episodesSection(leading: leading)
        }
        IOSPlexCastRow(item: shown, detail: detail)
        if !related.isEmpty {
            IOSPlexRail(title: String(localized: "More Like This"), kind: .poster, items: related) {
                IOSPlexPosterCard(item: $0, width: $1)
            }
        }
        IOSPlexExtrasRow(detail: detail)
        IOSPlexInformationSection(item: shown, detail: detail).padding(.horizontal, leading)
    }

    private func summaryView(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary)
                .font(.body)
                .lineLimit(summaryExpanded ? nil : 3)
            if summary.count > 160 {
                Button(summaryExpanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) { summaryExpanded.toggle() }
                }
                .font(.subheadline.bold())
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    // MARK: - Episodes

    private var currentSeason: MediaItem? { seasons.first { $0.ref == seasonKey } }

    /// Highlighted only when there is something left to watch in this season.
    private var nextUpID: MediaItemRef? {
        if let next = detail?.nextEpisode, episodes.contains(where: { $0.id == next.id }) {
            return next.id
        }
        return (episodes.first(where: \.isInProgress) ?? episodes.first(where: { !$0.countsAsWatched }))?.id
    }

    private func episodesSection(leading: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            seasonPicker.padding(.horizontal, leading)
            if episodesSeasonKey != seasonKey {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if regular {
                IOSShelfRow(kind: .landscape, items: episodes, initialID: nextUpID) {
                    EmptyView()
                } tile: { episode, width in
                    IOSPlexEpisodeCell(episode: episode, isNextUp: episode.id == nextUpID, layout: .card(width))
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(episodes) { episode in
                        IOSPlexEpisodeCell(episode: episode, isNextUp: episode.id == nextUpID, layout: .row)
                    }
                }
                .padding(.horizontal, leading)
            }
        }
    }

    /// The season menu: switch seasons, or download the one showing.
    @ViewBuilder
    private var seasonPicker: some View {
        let title = currentSeason.map(seasonLabel) ?? String(localized: "Episodes")
        if seasons.count > 1 || (currentSeason != nil && canDownload) {
            Menu {
                if seasons.count > 1 {
                    Picker("Season", selection: $seasonKey) {
                        ForEach(seasons) { Text(seasonLabel($0)).tag(Optional($0.ref)) }
                    }
                }
                if let season = currentSeason, canDownload {
                    Section {
                        Button("Download Season", systemImage: "arrow.down.circle") { actions.download(season) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.title3.bold())
                    Image(systemName: "chevron.down").font(.subheadline.bold())
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("Season, \(title)")
        } else {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
        }
    }

    private var canDownload: Bool { browse.canDownload(item) }

    private func seasonLabel(_ season: MediaItem) -> String {
        guard let index = season.seasonNumber else { return season.displayTitle }
        return index == 0 ? String(localized: "Specials") : String(localized: "Season \(index)")
    }

    // MARK: - Play target

    /// Movies and episodes play themselves; a show plays On Deck, then the
    /// next episode of the loaded season.
    private var playTarget: MediaItem? {
        if shown.isPlayable { return shown }
        if shown.kind == .show, let next = detail?.nextEpisode { return next }
        guard episodesSeasonKey != nil else { return nil }
        return MediaItem.nextUp(in: episodes)
    }

    // MARK: - Loading

    private func load() async {
        do {
            let provider = try browse.provider(for: item.ref)
            let loaded = try await provider.fullDetail(for: item.ref)
            detail = loaded
            error = nil
            switch loaded.item.kind {
            case .show:
                seasons = try await provider.children(of: loaded.item.ref).filter { $0.kind == .season }.sortedByNumber()
                let keep = seasons.contains { $0.ref == seasonKey }
                await selectSeason(keep ? seasonKey : initialSeasonKey(show: loaded))
            case .season:
                seasons = [loaded.item]
                await selectSeason(loaded.item.ref)
            default:
                break
            }
            loadedRevision = browse.watchStateRevision
            if related.isEmpty, loaded.item.kind == .movie || loaded.item.kind == .show {
                related = (try? await provider.moreLikeThis(for: loaded.item.ref, kind: loaded.item.kind)) ?? []
            }
        } catch let error where isCancellationError(error) {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Selecting a new season loads it through `.task(id: seasonKey)`; the
    /// same season reloads here so watch state repaints.
    private func selectSeason(_ key: MediaItemRef?) async {
        if key == seasonKey {
            await loadEpisodes(force: true)
        } else {
            seasonKey = key
        }
    }

    /// The next episode's season, else the first season with unwatched
    /// episodes, else the first real season.
    private func initialSeasonKey(show: MediaItemDetail) -> MediaItemRef? {
        if let key = show.nextEpisode?.parentRef, seasons.contains(where: { $0.ref == key }) {
            return key
        }
        let real = seasons.filter { ($0.seasonNumber ?? 0) > 0 }
        return (real.first { !$0.countsAsWatched } ?? real.first ?? seasons.first)?.ref
    }

    private func loadEpisodes(force: Bool = false) async {
        guard let key = seasonKey, force || episodesSeasonKey != key,
              let season = seasons.first(where: { $0.ref == key }) else { return }
        do {
            let loaded = try await browse.provider(for: season.ref).children(of: season.ref).sortedByNumber()
            guard seasonKey == key else { return }
            episodes = loaded
            episodesSeasonKey = key
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Header

private struct IOSPlexDetailHeader: View {
    let item: MediaItem
    let detail: MediaItemDetail?
    let playTarget: MediaItem?
    let isLoading: Bool
    /// Screen size including the area under the navigation bar.
    let size: CGSize
    @Environment(\.plexActions) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var browse: IOSBrowseStore
    /// Asked of the server for the page's title; nil until it answers.
    @State private var onList: Bool?
    @State private var onScreen = false
    @State private var inView = true

    private var isWide: Bool { size.width > size.height }

    private var height: CGFloat {
        let natural = isWide ? min(size.width * 9 / 16, size.height * 0.7) : size.height * 0.62
        return max(natural, 360)
    }

    var body: some View {
        ZStack(alignment: isWide ? .bottomLeading : .bottom) {
            // The fade is extended with the art, so the strip under a side bar darkens with it.
            IOSItemArtwork(item: item, kind: .backdrop, width: size.width, aspectRatio: 16 / 9)
                .overlay {
                    IOSThemeVideoBackdrop(item: item.ref, isActive: onScreen && inView)
                        .allowsHitTesting(false)
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.25),
                            .init(color: .black.opacity(0.7), location: 0.7),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .backgroundExtensionEffect()
                // The art and its scrim fade out into the page's ambient wash.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0.75),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            titleBlock
                .frame(maxWidth: isWide ? 560 : .infinity, alignment: isWide ? .leading : .center)
                .padding(.horizontal, IOSShelfGeometry.leading)
                .padding(.bottom, 20)
        }
        .frame(height: height)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onScrollVisibilityChange(threshold: 0.3) { inView = $0 }
    }

    private var metadataItems: [String] {
        let date: String? = item.kind == .episode
            ? item.releaseDate.flatMap(IOSPlexInformationSection.formattedDate)
            : item.year.map(String.init)
        let genres = (detail?.genres.nilIfEmpty ?? item.genres)?.prefix(2).joined(separator: ", ")
        return [date, item.runtimeText, genres]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    private var titleBlock: some View {
        VStack(alignment: isWide ? .leading : .center, spacing: 10) {
            IOSPlexResolvedLogo(
                item: item,
                fallbackTitle: item.showTitle,
                maxWidth: isWide ? 360 : 280,
                maxHeight: isWide ? 110 : 90,
                fallbackFont: .largeTitle.bold(),
                alignment: isWide ? .bottomLeading : .bottom,
                textAlignment: isWide ? .leading : .center
            )
            if item.kind == .episode || item.kind == .season {
                Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(isWide ? .leading : .center)
            }
            HStack(spacing: 8) {
                Text(metadataItems.joined(separator: " · "))
                if let rating = detail?.contentRating ?? item.contentRating, !rating.isEmpty {
                    Text(rating).plexPill()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)

            actionRow.padding(.top, 6)

            if let target = playTarget, target.id != item.id, let code = target.episodeCode {
                Text([code, target.title].joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }

    /// Play fills the row; watched state lives in More. Accessibility sizes stack the circles below.
    private var actionRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            // Play shows only where `IOSPlaybackGate` allows it.
            if canPlay { playButton.layoutPriority(1) }
            HStack(spacing: 12) {
                if canPlay, item.kind == .show {
                    Button { actions.shuffleShow(item) } label: {
                        if actions.preparingID == IOSPlexActions.shuffleID(providerID: item.ref.providerID,
                                                                           itemID: item.ref.itemID) {
                            ProgressView().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "shuffle").frame(width: 22, height: 22)
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Shuffle")
                }
                if browse.supportsWatchlist(item) {
                    let onList = onList ?? false
                    circleButton(onList ? "checkmark" : "plus", label: onList ? "Remove from Watchlist" : "Add to Watchlist") {
                        actions.setWatchlisted(item, !onList)
                    }
                }
                if FavoritesFeed.canFavorite(item) {
                    let isFavorite = browse.isFavorite(item)
                    circleButton(isFavorite ? "heart.fill" : "heart",
                                 label: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                        actions.setFavorite(item, !isFavorite)
                    }
                }
                if item.isPlayable, canDownload {
                    IOSDownloadButton(item: item)
                }
                Menu {
                    // No Delete: the page would be left showing what it deleted.
                    IOSPlexItemMenu(item: item, showsPlay: false, showsWatchlist: false, showsFavorite: false, showsDelete: false)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More")
            }
        }
        .frame(maxWidth: 480)
        .controlSize(.large)
        .task(id: item.ref) { await loadWatchlistState() }
        .onReceive(PlexWatchlistService.shared.$watchlistItems.dropFirst()) { _ in
            Task { await loadWatchlistState() }
        }
    }

    private var canPlay: Bool { IOSPlaybackGate.canPlay(item.ref) }
    private var canDownload: Bool { browse.canDownload(item) }

    /// Plex answers from its watchlist; an episode or season stands for its show.
    private func loadWatchlistState() async {
        guard browse.supportsWatchlist(item), let provider = browse.provider(for: item.ref.providerID) else { return }
        onList = await provider.isOnWatchlist(item.ref)
    }

    private var playButton: some View {
        Button {
            if let playTarget { actions.play(playTarget) }
        } label: {
            // Drops the bar, then the time left, before it would truncate.
            ViewThatFits(in: .horizontal) {
                playLabel(bar: true, timeLeft: true)
                playLabel(bar: false, timeLeft: true)
                playLabel(bar: false, timeLeft: false)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .disabled(playTarget == nil)
        .opacity(playTarget == nil && isLoading ? 0.6 : 1)
    }

    private func playLabel(bar: Bool, timeLeft: Bool) -> some View {
        HStack(spacing: 8) {
            if actions.preparingID == playTarget?.ref.actionKey, playTarget != nil {
                ProgressView()
            } else {
                Image(systemName: "play.fill")
            }
            Text(playTarget?.isInProgress == true ? "Resume" : "Play")
            if let target = playTarget, target.isInProgress {
                if bar, let fraction = target.progressBarFraction {
                    ProgressView(value: fraction)
                        .frame(width: 36)
                        .accessibilityHidden(true)
                }
                if timeLeft, let left = target.timeLeftText {
                    Text(bar ? left : "\u{00B7} \(left)").font(.subheadline)
                }
            }
        }
    }

    private func circleButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

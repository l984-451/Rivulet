// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Movie, show, season or episode page in the TV app's layout: full-bleed
/// art under a transparent bar, actions, episodes, then related rows.
struct IOSPlexDetailView: View {
    let item: PlexMetadata
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.plexActions) private var actions
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var watchlist = PlexWatchlistService.shared

    @State private var full: PlexMetadata?
    @State private var seasons: [PlexMetadata] = []
    @State private var seasonKey: String?
    @State private var episodes: [PlexMetadata] = []
    @State private var episodesSeasonKey: String?
    @State private var related: [PlexMetadata] = []
    @State private var error: String?
    @State private var loadedRevision: Int?
    @State private var summaryExpanded = false
    /// PlexMetadata's == compares only ratingKey, so SwiftUI keeps children built from the
    /// stub item; a new identity per load makes them read the loaded one.
    @State private var loadCount = 0

    private var shown: PlexMetadata { full ?? item }
    private var isSeries: Bool { shown.type == "show" || shown.type == "season" }
    private var regular: Bool { sizeClass == .regular }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    IOSPlexDetailHeader(
                        item: shown,
                        playTarget: playTarget,
                        isLoading: full == nil && error == nil,
                        size: CGSize(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.top)
                    )
                    if full == nil, let error {
                        IOSPlexErrorView(title: "Couldn't Load", message: error) { await load() }
                    } else {
                        sections(leading: IOSShelfGeometry.leading)
                    }
                }
                .id(loadCount)
                .padding(.bottom, 32)
            }
            .ignoresSafeArea(edges: .top)
            .refreshable { await load() }
        }
        // The page is dark in both modes, like the header art it continues.
        .background(.black)
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle(shown.showTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .task(id: plex.watchStateRevision) {
            guard loadedRevision != plex.watchStateRevision else { return }
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
        if let summary = shown.summary, !summary.isEmpty {
            summaryView(summary).padding(.horizontal, leading)
        }
        if isSeries {
            episodesSection(leading: leading)
        }
        IOSPlexCastRow(item: shown)
        if !related.isEmpty {
            IOSPlexRail(title: "More Like This", kind: .poster, items: related) {
                IOSPlexPosterCard(item: $0, width: $1)
            }
        }
        IOSPlexExtrasRow(item: shown)
        IOSPlexInformationSection(item: shown).padding(.horizontal, leading)
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

    private var currentSeason: PlexMetadata? { seasons.first { $0.ratingKey == seasonKey } }

    /// Highlighted only when there is something left to watch in this season.
    private var nextUpID: String? {
        if let onDeck = full?.OnDeck?.Metadata?.first, episodes.contains(where: { $0.id == onDeck.id }) {
            return onDeck.id
        }
        return (episodes.first(where: \.isInProgress) ?? episodes.first(where: { !$0.isWatched }))?.id
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
        let title = currentSeason.map(seasonLabel) ?? "Episodes"
        if seasons.count > 1 || (currentSeason != nil && plex.isConfigured) {
            Menu {
                if seasons.count > 1 {
                    Picker("Season", selection: $seasonKey) {
                        ForEach(seasons) { Text(seasonLabel($0)).tag($0.ratingKey) }
                    }
                }
                if let season = currentSeason, plex.isConfigured {
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

    private func seasonLabel(_ season: PlexMetadata) -> String {
        guard let index = season.index else { return season.displayTitle }
        return index == 0 ? "Specials" : "Season \(index)"
    }

    // MARK: - Play target

    /// Movies and episodes play themselves; a show plays On Deck, then the
    /// next episode of the loaded season.
    private var playTarget: PlexMetadata? {
        if shown.isPlayable { return shown }
        if shown.type == "show", let onDeck = full?.OnDeck?.Metadata?.first { return onDeck }
        guard episodesSeasonKey != nil else { return nil }
        return IOSPlexSession.nextUp(in: episodes)
    }

    // MARK: - Loading

    private func load() async {
        do {
            let loaded = try await plex.metadata(for: item)
            full = loaded
            error = nil
            switch loaded.type {
            case "show":
                seasons = try await plex.children(of: loaded)
                let keep = seasons.contains { $0.ratingKey == seasonKey }
                await selectSeason(keep ? seasonKey : initialSeasonKey(show: loaded))
            case "season":
                seasons = [loaded]
                await selectSeason(loaded.ratingKey)
            default:
                break
            }
            loadedRevision = plex.watchStateRevision
            loadCount += 1
        } catch let error where isCancellationError(error) {
            return
        } catch {
            self.error = error.localizedDescription
        }
        if related.isEmpty, shown.type == "movie" || shown.type == "show" {
            related = (try? await plex.related(to: shown)) ?? []
        }
    }

    /// Selecting a new season loads it through `.task(id: seasonKey)`; the
    /// same season reloads here so watch state repaints.
    private func selectSeason(_ key: String?) async {
        if key == seasonKey {
            await loadEpisodes(force: true)
        } else {
            seasonKey = key
        }
    }

    /// The On Deck episode's season, else the first season with unwatched
    /// episodes, else the first real season.
    private func initialSeasonKey(show: PlexMetadata) -> String? {
        if let key = show.OnDeck?.Metadata?.first?.parentRatingKey,
           seasons.contains(where: { $0.ratingKey == key }) {
            return key
        }
        let real = seasons.filter { ($0.index ?? 0) > 0 }
        return (real.first { !$0.isWatched } ?? real.first ?? seasons.first)?.ratingKey
    }

    private func loadEpisodes(force: Bool = false) async {
        guard let key = seasonKey, force || episodesSeasonKey != key,
              let season = seasons.first(where: { $0.ratingKey == key }) else { return }
        do {
            let loaded = try await plex.children(of: season)
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
    let item: PlexMetadata
    let playTarget: PlexMetadata?
    let isLoading: Bool
    /// Screen size including the area under the navigation bar.
    let size: CGSize
    @Environment(\.plexActions) private var actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var plex: IOSPlexSession

    private var isWide: Bool { size.width > size.height }

    private var height: CGFloat {
        let natural = isWide ? min(size.width * 9 / 16, size.height * 0.7) : size.height * 0.62
        return max(natural, 360)
    }

    var body: some View {
        ZStack(alignment: isWide ? .bottomLeading : .bottom) {
            IOSPlexArtwork(item: item, kind: .backdrop, width: size.width, aspectRatio: 16 / 9)
                .backgroundExtensionEffect()
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.25),
                    .init(color: .black.opacity(0.7), location: 0.7),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            titleBlock
                .frame(maxWidth: isWide ? 560 : .infinity, alignment: isWide ? .leading : .center)
                .padding(.horizontal, IOSShelfGeometry.leading)
                .padding(.bottom, 20)
        }
        .frame(height: height)
    }

    private var metadataItems: [String] {
        let date: String? = item.type == "episode"
            ? item.originallyAvailableAt.flatMap(IOSPlexInformationSection.formattedDate)
            : item.year.map(String.init)
        return [date, item.runtimeText, item.Genre?.prefix(2).compactMap(\.tag).joined(separator: ", ")]
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
            if item.type == "episode" || item.type == "season" {
                Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(isWide ? .leading : .center)
            }
            HStack(spacing: 8) {
                Text(metadataItems.joined(separator: " · "))
                if let rating = item.contentRating, !rating.isEmpty {
                    Text(rating).plexPill()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)

            actionRow.padding(.top, 6)

            if let target = playTarget, target.id != item.id, let code = target.episodeCode {
                Text([code, target.title].compactMap { $0 }.joined(separator: " · "))
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
            playButton.layoutPriority(1)
            HStack(spacing: 12) {
                if ["movie", "show", "season", "episode"].contains(item.type ?? "") {
                    let onList = plex.isOnWatchlist(item)
                    circleButton(onList ? "checkmark" : "plus", label: onList ? "Remove from Watchlist" : "Add to Watchlist") {
                        actions.setWatchlisted(item, !onList)
                    }
                }
                if item.isPlayable {
                    IOSDownloadButton(item: item)
                }
                Menu {
                    IOSPlexItemMenu(item: item, showsPlay: false, showsWatchlist: false)
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
            if actions.preparingID == playTarget?.id, playTarget != nil {
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

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

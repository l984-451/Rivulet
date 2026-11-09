// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Movie, show, season, episode or collection page: art, actions, episodes, then related rows.
/// Parity source: RivuletiOS/Plex/Detail/IOSPlexDetailView.swift and IOSPlexDetailSections.swift.
struct MacDetailView: View {
    let item: MediaItem
    @EnvironmentObject private var browse: BrowseStore

    @State private var detail: MediaItemDetail?
    @State private var seasons: [MediaItem] = []
    @State private var seasonKey: MediaItemRef?
    @State private var episodes: [MediaItem] = []
    @State private var episodesSeasonKey: MediaItemRef?
    /// The picked season's own extras, shown with the show's.
    @State private var seasonExtras: [MediaItemDetail.Extra] = []
    @State private var related: [MediaItem] = []
    @State private var members: [MediaItem] = []
    @State private var error: String?
    @State private var loadedRevision: Int?
    @State private var summaryExpanded = false

    private var shown: MediaItem { detail?.item ?? item }
    private var isSeries: Bool { shown.kind == .show || shown.kind == .season }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    MacDetailHeader(item: shown, detail: detail, playTarget: playTarget,
                                    isLoading: detail == nil && error == nil, width: proxy.size.width)
                    if detail == nil, let error {
                        MacErrorView(title: "Couldn't Load", message: error) { await load() }
                    } else {
                        sections
                    }
                }
                .padding(.bottom, 32)
            }
        }
        // The page is dark in both modes, like the header art it continues.
        .background(.black)
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .navigationTitle(shown.showTitle)
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .help("Reload this page")
            }
        }
        .macPageRefresh { Task { await load() } }
        .task(id: browse.watchStateRevision) {
            guard loadedRevision != browse.watchStateRevision else { return }
            await load()
        }
        .task(id: seasonKey) { await loadEpisodes() }
        .task(id: seasonKey) { await loadSeasonExtras() }
    }

    @ViewBuilder
    private var sections: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, MacMetrics.pageMargin)
        }
        if detail != nil || shown.overview != nil {
            summaryView.padding(.horizontal, MacMetrics.pageMargin)
        }
        if isSeries { episodesSection }
        MacDetailExtras(detail: detail?.adding(extras: seasonExtras))
        if !members.isEmpty {
            MacRail(title: String(localized: "In This Collection"), kind: .poster, items: members) { member, width in
                MacTileButton(item: member) { MacPosterCard(item: member, width: width) }
            }
        }
        if !related.isEmpty {
            MacRail(title: String(localized: "More Like This"), kind: .poster, items: related) { related, width in
                MacTileButton(item: related) { MacPosterCard(item: related, width: width) }
            }
        }
        MacDetailCast(item: shown, detail: detail)
        MacDetailInformation(item: shown, detail: detail).padding(.horizontal, MacMetrics.pageMargin)
    }

    @ViewBuilder
    private var summaryView: some View {
        let episode = playTarget.flatMap {
            EpisodePicker.episodeDescription(for: $0, overview: nil, on: shown.kind)
        }
        let summary = episode?.body ?? shown.overview ?? ""
        VStack(alignment: .leading, spacing: 6) {
            if let tagline = detail?.tagline, !tagline.isEmpty {
                Text(verbatim: tagline).font(.headline).foregroundStyle(.secondary)
            }
            if !summary.isEmpty {
                (Text(verbatim: episode.map { $0.prefix + " " } ?? "").bold() + Text(verbatim: summary))
                    .font(.body)
                    .lineLimit(summaryExpanded ? nil : 4)
                    .textSelection(.enabled)
                if summary.count > 260 {
                    Button(summaryExpanded ? "Less" : "More") {
                        withAnimation(.easeInOut(duration: 0.2)) { summaryExpanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.subheadline.bold())
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
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

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            seasonPicker.padding(.horizontal, MacMetrics.pageMargin)
            if episodesSeasonKey != seasonKey {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if episodes.isEmpty {
                Text("No Episodes").foregroundStyle(.secondary).padding(.horizontal, MacMetrics.pageMargin)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: MacMetrics.tileGap) {
                            ForEach(episodes) { episode in
                                MacEpisodeCell(episode: episode, isNextUp: episode.id == nextUpID, width: 300)
                                    .id(episode.id)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .contentMargins(.horizontal, MacMetrics.pageMargin, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .onAppear { scrollToNextUp(proxy) }
                    .onChange(of: episodesSeasonKey) { scrollToNextUp(proxy) }
                }
            }
        }
    }

    private func scrollToNextUp(_ proxy: ScrollViewProxy) {
        guard let id = nextUpID else { return }
        proxy.scrollTo(id, anchor: .leading)
    }

    @ViewBuilder
    private var seasonPicker: some View {
        let title = currentSeason.map(seasonLabel) ?? String(localized: "Episodes")
        if seasons.count > 1 {
            Picker("Season", selection: $seasonKey) {
                ForEach(seasons) { Text(verbatim: seasonLabel($0)).tag(Optional($0.ref)) }
            }
            .pickerStyle(.menu)
            .fixedSize()
        } else {
            Text(verbatim: title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
        }
    }

    private func seasonLabel(_ season: MediaItem) -> String {
        guard let index = season.seasonNumber else { return season.displayTitle }
        return index == 0 ? String(localized: "Specials") : String(localized: "Season \(index)")
    }

    // MARK: - Play target

    /// Movies and episodes play themselves; a show plays On Deck, then the next episode of the loaded season.
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
            case .collection:
                members = (try? await provider.children(of: loaded.item.ref)) ?? []
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

    /// Selecting a new season loads it through `.task(id: seasonKey)`; the same season reloads here so watch state repaints.
    private func selectSeason(_ key: MediaItemRef?) async {
        if key == seasonKey {
            await loadEpisodes(force: true)
        } else {
            seasonKey = key
        }
    }

    /// The next episode's season, else the first season with unwatched episodes, else the first real season.
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
            // A deleted episode fades out of the list.
            let shrank = episodesSeasonKey == key && loaded.count < episodes.count
            withAnimation(shrank ? .default : nil) { episodes = loaded }
            episodesSeasonKey = key
        } catch let error where isCancellationError(error) {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSeasonExtras() async {
        seasonExtras = []
        guard shown.kind == .show, let key = seasonKey else { return }
        let loaded = try? await browse.provider(for: key).fullDetail(for: key).extras
        if seasonKey == key { seasonExtras = loaded ?? [] }
    }
}

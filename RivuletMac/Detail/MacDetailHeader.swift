// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine
import SwiftUI

/// Backdrop with the title block over it: logo, metadata and the action row.
struct MacDetailHeader: View {
    let item: MediaItem
    let detail: MediaItemDetail?
    let playTarget: MediaItem?
    let isLoading: Bool
    let width: CGFloat

    @Environment(\.macActions) private var actions
    @EnvironmentObject private var browse: BrowseStore
    @EnvironmentObject private var playback: MacPlaybackController
    @ObservedObject private var watchlist = PlexWatchlistService.shared
    /// Asked of the server for the page's title; nil until it answers.
    @State private var onList: Bool?
    @State private var onScreen = false
    @State private var inView = true
    /// What Versions plays (a show's Play episode) and the other copies of it.
    @State private var versionSubject: MediaItemDetail?
    @State private var otherCopies: [VersionPicker.Copy] = []

    private var height: CGFloat { min(max(width * 0.42, 380), 640) }
    private var canPlay: Bool { IOSPlaybackGate.canPlay(item.ref) }
    private var versionOptions: [VersionPicker.Option] {
        versionSubject.map { VersionPicker.options(for: $0, copies: otherCopies) } ?? []
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MacItemArtwork(item: item, kind: .backdrop, width: width, aspectRatio: 16 / 9)
                .overlay {
                    MacThemeVideoBackdrop(item: item.ref, isActive: onScreen && inView, isCovered: playback.isPresented)
                        .allowsHitTesting(false)
                }
                .overlay {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.2), .init(color: .black.opacity(0.7), location: 0.7),
                                .init(color: .black, location: 1)],
                        startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                }
            titleBlock
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, MacMetrics.pageMargin)
                .padding(.bottom, 24)
        }
        .frame(height: height)
        .clipped()
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onScrollVisibilityChange(threshold: 0.3) { inView = $0 }
        .task(id: item.ref) { await loadWatchlistState() }
        .task(id: [detail?.item.ref, playTarget?.ref]) { await loadVersions() }
        .onReceive(watchlist.$watchlistItems.dropFirst()) { _ in Task { await loadWatchlistState() } }
    }

    private var metadataItems: [String] {
        let date: String? = item.kind == .episode
            ? item.releaseDate.flatMap(MacDetailInformation.formattedDate)
            : item.year.map(String.init)
        let genres = (detail?.genres.nilIfEmpty ?? item.genres)?.prefix(2).joined(separator: ", ")
        return [date, item.runtimeText, genres].compactMap { $0 }.filter { !$0.isEmpty }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacResolvedLogo(item: item, fallbackTitle: item.showTitle, maxWidth: 400, maxHeight: 120,
                            fallbackFont: .largeTitle.bold(), alignment: .bottomLeading, textAlignment: .leading)
            if item.kind == .episode || item.kind == .season {
                Text([item.episodeCode, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            HStack(spacing: 8) {
                Text(metadataItems.joined(separator: " · "))
                if let rating = detail?.contentRating ?? item.contentRating, !rating.isEmpty {
                    Text(rating).macPill()
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

    private var actionRow: some View {
        HStack(spacing: 10) {
            if canPlay {
                playButton
                if let target = playTarget, target.isInProgress {
                    Button { actions.playFromBeginning(target) } label: {
                        Label("From Beginning", systemImage: "arrow.counterclockwise")
                    }
                }
                if !versionOptions.isEmpty { versionMenu }
                if item.kind == .show {
                    Button { actions.shuffleShow(item) } label: {
                        if actions.preparingID == MacActions.shuffleID(providerID: item.ref.providerID, itemID: item.ref.itemID) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "shuffle")
                        }
                    }
                    .help("Shuffle")
                    .accessibilityLabel("Shuffle")
                }
            }
            // A TMDB title (Discover) has nothing to play: Watchlist is its main button, as on tvOS.
            if item.isMetadataOnly, browse.supportsWatchlist(item) {
                watchlistButton
            } else if browse.supportsWatchlist(item) {
                let onList = onList ?? false
                iconButton(onList ? "checkmark" : "plus", help: onList ? "Remove from Watchlist" : "Add to Watchlist") {
                    actions.setWatchlisted(item, !onList)
                }
            }
            if FavoritesFeed.canFavorite(item) {
                let isFavorite = browse.isFavorite(item)
                iconButton(isFavorite ? "heart.fill" : "heart", help: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                    actions.setFavorite(item, !isFavorite)
                }
            }
            // Its actions (watched, refresh metadata) need the title on a server.
            if !item.isMetadataOnly {
                Menu {
                    // No Delete: the page would be left showing what it deleted.
                    MacItemMenu(item: item, showsPlay: false, showsWatchlist: false, showsFavorite: false, showsDelete: false)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var watchlistButton: some View {
        let onList = onList ?? false
        let help: LocalizedStringKey = onList ? "Remove from Watchlist" : "Add to Watchlist"
        return Button { actions.setWatchlisted(item, !onList) } label: {
            Label("Watchlist", systemImage: onList ? "checkmark" : "plus")
        }
        .buttonStyle(.borderedProminent)
        .help(help)
        .accessibilityLabel(help)
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(help)
            .accessibilityLabel(help)
    }

    private var playButton: some View {
        Button { if let playTarget { actions.play(playTarget) } } label: {
            HStack(spacing: 8) {
                if actions.preparingID == playTarget?.ref.actionKey, playTarget != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(playTarget?.isInProgress == true ? "Resume" : "Play")
                if let target = playTarget, target.isInProgress {
                    if let fraction = target.progressBarFraction {
                        MacProgressBar(fraction: fraction).frame(width: 36)
                    }
                    if let left = target.timeLeftText { Text(left).font(.subheadline) }
                }
            }
            .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(playTarget == nil)
        .opacity(playTarget == nil && isLoading ? 0.6 : 1)
    }

    /// Plays one of the title's files, or another copy's, instead of the best one.
    private var versionMenu: some View {
        let options = versionOptions
        return Menu {
            ForEach(Array(zip(options.indices, VersionPicker.labels(for: options))), id: \.0) { index, label in
                Button(label) { pick(options[index]) }
            }
        } label: {
            Label("Version", systemImage: "square.stack.3d.up")
        }
        .fixedSize()
        .help("Play a different version")
    }

    private func pick(_ option: VersionPicker.Option) {
        guard let subject = versionSubject?.item else { return }
        switch VersionPicker.pick(option, playTarget: nil, shown: subject) {
        case .version(let id): playback.play(subject, sourceID: id)
        case .item(let copy, let id):
            // The copy carries this page's resume point when that is further in.
            let offset = copy.userState.viewOffset
            playback.play(copy, sourceID: id, startOffset: offset > 0 ? offset : nil)
        }
    }

    /// Versions' files first, then the other libraries' and servers' copies.
    private func loadVersions() async {
        versionSubject = nil
        otherCopies = []
        guard let detail, let subject = await TitleCopies.subject(of: detail, playTarget: playTarget),
              !Task.isCancelled else { return }
        versionSubject = subject
        let servers = TitleCopies.servers(for: item, libraries: browse.libraries)
        guard !servers.isEmpty else { return }
        let found = await TitleCopies.versions(of: subject, on: servers)
        guard !Task.isCancelled else { return }
        otherCopies = found.copies
    }

    private func loadWatchlistState() async {
        if let state = await browse.watchlistState(item) { onList = state }
    }
}

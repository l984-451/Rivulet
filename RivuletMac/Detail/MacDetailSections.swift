// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// One episode as a card in the season's rail. Click plays; the menu has Details.
struct MacEpisodeCell: View {
    let episode: MediaItem
    let isNextUp: Bool
    let width: CGFloat
    @Environment(\.macActions) private var actions

    private var title: String {
        episode.episodeNumber.map { "\($0). \(episode.displayTitle)" } ?? episode.displayTitle
    }

    private var detail: String? { episode.timeLeftText ?? episode.runtimeText }
    private var canPlay: Bool { IOSPlaybackGate.canPlay(episode.ref) }

    var body: some View {
        // A server the gate refuses opens the episode's page instead.
        Button { canPlay ? actions.play(episode) : actions.open(episode) } label: {
            VStack(alignment: .leading, spacing: 8) {
                MacItemArtwork(item: episode, kind: .thumb, width: width, aspectRatio: 16 / 9)
                    .frame(width: width, height: width * 9 / 16)
                    .macWatchState(episode)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        if actions.preparingID == episode.ref.actionKey { ProgressView().controlSize(.small) }
                    }
                    .macTileHover()
                VStack(alignment: .leading, spacing: 2) {
                    if isNextUp { Text("Up Next").font(.caption.bold()).foregroundStyle(.tint) }
                    Text(verbatim: title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let detail { Text(verbatim: detail).font(.caption).foregroundStyle(.secondary) }
                }
                if let summary = episode.overview, !summary.isEmpty {
                    Text(verbatim: summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macContextMenu(episode, showsDetails: true)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([isNextUp ? String(localized: "Up Next") : nil, title, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(episode.watchStateDescription)
    }
}

/// Cast & Crew: actors, then directors.
struct MacDetailCast: View {
    let item: MediaItem
    let detail: MediaItemDetail?
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    @Environment(\.macOpen) private var open

    private struct Person: Identifiable {
        let id: Int
        let name: String
        let role: String?
        let image: URL?
        let source: MediaPerson
    }

    private var people: [Person] {
        guard let detail else { return [] }
        let cast = detail.cast.prefix(30).map { (name: $0.name, role: $0.role, image: $0.imageURL, source: $0) }
        let directors = detail.directors.map { (name: $0.name, role: Optional(String(localized: "Director")), image: $0.imageURL, source: $0) }
        return (cast + directors).filter { !$0.name.isEmpty }.enumerated().map {
            Person(id: $0.offset, name: $0.element.name, role: $0.element.role, image: $0.element.image, source: $0.element.source)
        }
    }

    var body: some View {
        let people = self.people
        if !people.isEmpty {
            let size: CGFloat = 110
            let pixels = Int((size * displayScale).rounded(.up))
            VStack(alignment: .leading, spacing: 10) {
                Text("Cast & Crew").font(.title3.bold()).padding(.horizontal, MacMetrics.pageMargin)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: MacMetrics.tileGap) {
                        ForEach(people) { person in
                            Button { open(.person(person.source, providerID: item.ref.providerID)) } label: {
                            VStack(spacing: 6) {
                                MacImage(url: browse.imageURL(person.image, providerID: item.ref.providerID, width: pixels, height: pixels))
                                    .overlay {
                                        if person.image == nil {
                                            Image(systemName: "person.fill").font(.title).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: size, height: size)
                                    .clipShape(Circle())
                                Text(verbatim: person.name).font(.caption.weight(.semibold)).lineLimit(1)
                                if let role = person.role {
                                    Text(verbatim: role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: size + 20)
                            .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .contentMargins(.horizontal, MacMetrics.pageMargin, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }
}

/// Trailers and extras from the full detail; clicking one plays it (`IOSPlaybackGate`).
struct MacDetailExtras: View {
    let detail: MediaItemDetail?
    @Environment(\.macActions) private var actions
    @EnvironmentObject private var browse: BrowseStore
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL

    private static let youTubePrefix = "youtube:"
    private let width: CGFloat = 240

    private var extras: [MediaItemDetail.Extra] {
        var rows = (detail?.orderedExtras ?? []).filter {
            IOSPlaybackGate.canPlay(MediaItemRef(providerID: $0.providerID, itemID: $0.id))
                && ($0.providerID.hasPrefix("plex:") ? Int($0.id) != nil : true)
        }
        // A title with no trailer of its own gets its YouTube one (Jellyfin, Emby), on the title's artwork.
        if let detail, let id = detail.youTubeTrailerID {
            let art = detail.item.artwork
            rows.insert(MediaItemDetail.Extra(
                id: Self.youTubePrefix + id, title: ExtraSubtype.trailer.displayName,
                thumbnailURL: art.thumbnail ?? art.backdrop ?? art.poster, duration: nil, playbackKey: nil,
                providerID: detail.item.ref.providerID, subtype: .trailer), at: 0)
        }
        return rows
    }

    private func tapped(_ extra: MediaItemDetail.Extra) {
        if extra.id.hasPrefix(Self.youTubePrefix) {
            if let url = YouTubeTrailer.webURL(videoID: String(extra.id.dropFirst(Self.youTubePrefix.count))) { openURL(url) }
        } else {
            actions.playExtra(extra)
        }
    }

    private func runtime(_ extra: MediaItemDetail.Extra) -> String? {
        if extra.id.hasPrefix(Self.youTubePrefix) { return "YouTube" }
        guard let duration = extra.duration, duration > 0 else { return nil }
        let minutes = Int(duration / 60)
        return minutes >= 60 ? String(localized: "\(minutes / 60)h \(minutes % 60)m") : String(localized: "\(minutes)m")
    }

    var body: some View {
        let extras = self.extras
        if !extras.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Extras").font(.title3.bold()).padding(.horizontal, MacMetrics.pageMargin)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: MacMetrics.tileGap) {
                        ForEach(extras) { extra in
                            Button { tapped(extra) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    MacImage(url: browse.imageURL(extra.thumbnailURL, providerID: extra.providerID,
                                                                  width: Int(width * displayScale), height: Int(width * displayScale * 9 / 16)))
                                        .frame(width: width, height: width * 9 / 16)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay {
                                            if actions.preparingID == extra.id { ProgressView().controlSize(.small) }
                                        }
                                        .macTileHover()
                                    Text(verbatim: extra.title).font(.footnote.weight(.semibold)).lineLimit(1)
                                    if let runtime = runtime(extra) {
                                        Text(verbatim: runtime).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: width, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .contentMargins(.horizontal, MacMetrics.pageMargin, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
    }
}

/// Studio, genres, rating, release date, languages: whatever the item has.
struct MacDetailInformation: View {
    let item: MediaItem
    let detail: MediaItemDetail?

    /// A release date as the server wrote it ("2020-01-31", or with a time after it), long form.
    nonisolated static func formattedDate(_ isoDay: String) -> String? {
        guard let date = try? Date(String(isoDay.prefix(10)), strategy: .iso8601.year().month().day().dateSeparator(.dash)) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    private func languages(_ codes: [String?]) -> String? {
        var seen = Set<String>()
        let names = codes.compactMap { $0 }.map { LanguageLabel.display($0) }.filter { seen.insert($0).inserted }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var rows: [(String, String)] {
        let source = detail?.mediaSources.first
        return [
            (String(localized: "Studio"), detail?.studios.joined(separator: ", ")),
            (String(localized: "Genre"), (detail?.genres.nilIfEmpty ?? item.genres)?.joined(separator: ", ")),
            (String(localized: "Rated"), detail?.contentRating ?? item.contentRating),
            (String(localized: "Released"), item.releaseDate.flatMap(Self.formattedDate)),
            (String(localized: "Runtime"), item.runtimeText),
            (String(localized: "Audio"), languages(source?.audioTracks.map(\.language) ?? [])),
            (String(localized: "Subtitles"), languages(source?.subtitleTracks.map(\.language) ?? []))
        ].compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return (label, value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let ratings = detail?.ratings, !ratings.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ratings").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    HStack(alignment: .top, spacing: 28) {
                        ForEach(ratings, id: \.source) { rating in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: rating.badgeText + (rating.scale ?? "")).font(.title2.weight(.semibold))
                                Text(verbatim: rating.name).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .help(rating.detailText)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Information").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .topLeading)],
                              alignment: .leading, spacing: 14) {
                        ForEach(rows, id: \.0) { label, value in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: label).font(.subheadline.weight(.semibold))
                                Text(verbatim: value).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// One episode: a full-width row on compact width, a card in a horizontal
/// rail on regular width. Tapping plays; the menu has Details.
struct IOSPlexEpisodeCell: View {
    enum Layout { case row, card(CGFloat) }

    let episode: MediaItem
    let isNextUp: Bool
    let layout: Layout
    @Environment(\.plexActions) private var actions
    @ScaledMetric(relativeTo: .body) private var rowStillWidth: CGFloat = 150

    private var title: String {
        episode.episodeNumber.map { "\($0). \(episode.displayTitle)" } ?? episode.displayTitle
    }

    private var detail: String? {
        episode.timeLeftText ?? episode.runtimeText
    }

    var body: some View {
        // A server the gate refuses opens the episode's page instead (`IOSPlaybackGate`).
        Button { IOSPlaybackGate.canPlay(episode.ref) ? actions.play(episode) : actions.open(episode) } label: {
            switch layout {
            case .row: row
            case .card(let width): card(width: width)
            }
        }
        .buttonStyle(.plain)
        .plexContextMenu(episode, showsDetails: true)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([isNextUp ? String(localized: "Up Next") : nil, title, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(episode.watchStateDescription)
        .accessibilityHint(IOSPlaybackGate.canPlay(episode.ref) ? LocalizedStringKey("Plays the episode") : LocalizedStringKey("Opens the episode"))
    }

    private func still(width: CGFloat) -> some View {
        IOSItemArtwork(item: episode, kind: .thumb, width: width, aspectRatio: 16 / 9)
            .frame(width: width, height: width * 9 / 16)
            .plexWatchState(episode)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if actions.preparingID == episode.ref.actionKey { ProgressView().tint(.white) }
            }
            .tileHover(cornerRadius: 10)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isNextUp {
                Text("Up Next").font(.caption.bold()).foregroundStyle(.tint)
            }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                still(width: min(rowStillWidth, 220))
                heading
                Spacer(minLength: 0)
            }
            if let summary = episode.overview, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
    }

    private func card(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            still(width: width)
            heading
            if let summary = episode.overview, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Cast & Crew: actors, then directors.
struct IOSPlexCastRow: View {
    let item: MediaItem
    let detail: MediaItemDetail?
    @EnvironmentObject private var browse: IOSBrowseStore
    @Environment(\.displayScale) private var displayScale

    private struct Person: Identifiable {
        let id: Int
        let name: String
        let role: String?
        let image: URL?
    }

    private var people: [Person] {
        guard let detail else { return [] }
        let cast = detail.cast.prefix(20).map { (name: $0.name, role: $0.role, image: $0.imageURL) }
        let directors = detail.directors.map { (name: $0.name, role: Optional("Director"), image: $0.imageURL) }
        return (cast + directors).filter { !$0.name.isEmpty }.enumerated().map {
            Person(id: $0.offset, name: $0.element.name, role: $0.element.role, image: $0.element.image)
        }
    }

    var body: some View {
        let people = self.people
        if !people.isEmpty {
            IOSShelfRow(kind: .person, items: people) {
                IOSPlexShelfHeader(title: String(localized: "Cast & Crew"))
            } tile: { person, width in
                let pixels = Int((width * displayScale).rounded(.up))
                VStack(spacing: 6) {
                    IOSPlexImage(url: browse.imageURL(person.image, providerID: item.ref.providerID, width: pixels, height: pixels))
                        .overlay {
                            if person.image == nil {
                                Image(systemName: "person.fill").font(.title).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: width, height: width)
                        .clipShape(Circle())
                    Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                    if let role = person.role {
                        Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: width)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Extras and trailers from the full detail; tapping one plays it (`IOSPlaybackGate`).
struct IOSPlexExtrasRow: View {
    let detail: MediaItemDetail?
    @Environment(\.plexActions) private var actions
    @EnvironmentObject private var browse: IOSBrowseStore
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openURL) private var openURL
    /// The YouTube trailer awaiting its confirm.
    @State private var youTubeID: String?

    private var extras: [MediaItemDetail.Extra] {
        var rows = (detail?.orderedExtras ?? []).filter { IOSPlaybackGate.canPlay(MediaItemRef(providerID: $0.providerID, itemID: $0.id)) && ($0.providerID.hasPrefix("plex:") ? Int($0.id) != nil : true) }
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

    private static let youTubePrefix = "youtube:"

    private func tapped(_ extra: MediaItemDetail.Extra) {
        if extra.id.hasPrefix(Self.youTubePrefix) {
            youTubeID = String(extra.id.dropFirst(Self.youTubePrefix.count))
        } else {
            actions.playExtra(extra)
        }
    }

    /// The YouTube app, else the trailer on the web.
    private func openYouTube(_ videoID: String) {
        guard let app = YouTubeTrailer.appURL(videoID: videoID) else { return }
        openURL(app) { opened in
            if !opened, let web = YouTubeTrailer.webURL(videoID: videoID) { openURL(web) }
        }
    }

    var body: some View {
        let extras = self.extras
        if !extras.isEmpty {
            IOSShelfRow(kind: .landscape, items: extras) {
                IOSPlexShelfHeader(title: String(localized: "Extras"))
            } tile: { extra, width in
                Button { tapped(extra) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        IOSPlexImage(url: browse.imageURL(extra.thumbnailURL, providerID: extra.providerID,
                                                          width: Int(width * displayScale), height: Int(width * displayScale * 9 / 16)))
                            .frame(width: width, height: width * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if actions.preparingID == extra.id { ProgressView().tint(.white) }
                            }
                            .tileHover(cornerRadius: 10)
                        Text(extra.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        if let runtime = extra.runtimeText {
                            Text(runtime).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: width, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .confirmationDialog(String(localized: "Open in YouTube"), isPresented: Binding(
                get: { youTubeID != nil }, set: { if !$0 { youTubeID = nil } }), titleVisibility: .visible) {
                Button(String(localized: "Open in YouTube")) { youTubeID.map(openYouTube) }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("This trailer plays in the YouTube app.")
            }
        }
    }
}

private extension MediaItemDetail.Extra {
    var runtimeText: String? {
        if id.hasPrefix("youtube:") { return "YouTube" }
        guard let duration, duration > 0 else { return nil }
        let minutes = Int(duration / 60)
        return minutes >= 60 ? String(localized: "\(minutes / 60)h \(minutes % 60)m") : String(localized: "\(minutes)m")
    }
}

/// Studio, genres, rating, release date, languages: whatever the item has.
struct IOSPlexInformationSection: View {
    let item: MediaItem
    let detail: MediaItemDetail?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// With iPhone Duo's fold down its middle, four columns instead of three so none sits on it.
    @State private var crossesFold = false

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
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Information").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), alignment: .topLeading),
                        count: crossesFold ? 4 : sizeClass == .regular ? 3 : 2
                    ),
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(rows, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.subheadline.weight(.semibold))
                            Text(value).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .onGeometryChange(for: Bool.self) { $0.duoFoldDividesMiddle() } action: { crossesFold = $0 }
            }
        }
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// One episode: a full-width row on compact width, a card in a horizontal
/// rail on regular width. Tapping plays; the menu has Details.
struct IOSPlexEpisodeCell: View {
    enum Layout { case row, card(CGFloat) }

    let episode: PlexMetadata
    let isNextUp: Bool
    let layout: Layout
    private let watchStamp: [Int]
    @Environment(\.plexActions) private var actions
    @ScaledMetric(relativeTo: .body) private var rowStillWidth: CGFloat = 150

    init(episode: PlexMetadata, isNextUp: Bool, layout: Layout) {
        self.episode = episode
        self.isNextUp = isNextUp
        self.layout = layout
        watchStamp = episode.watchStamp
    }

    private var title: String {
        episode.index.map { "\($0). \(episode.displayTitle)" } ?? episode.displayTitle
    }

    private var detail: String? {
        episode.timeLeftText ?? episode.runtimeText
    }

    var body: some View {
        Button { actions.play(episode) } label: {
            switch layout {
            case .row: row
            case .card(let width): card(width: width)
            }
        }
        .buttonStyle(.plain)
        .plexContextMenu(episode, showsDetails: true)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([isNextUp ? "Up Next" : nil, title, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(episode.watchStateDescription)
        .accessibilityHint("Plays the episode")
    }

    private func still(width: CGFloat) -> some View {
        IOSPlexArtwork(episode: episode, width: width)
            .frame(width: width, height: width * 9 / 16)
            .plexWatchState(episode)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if actions.preparingID == episode.id { ProgressView().tint(.white) }
            }
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
            if let summary = episode.summary, !summary.isEmpty {
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
            if let summary = episode.summary, !summary.isEmpty {
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

private extension IOSPlexArtwork {
    /// Episode thumbs are Plex's 16:9 stills, not the show's backdrop.
    init(episode: PlexMetadata, width: CGFloat) {
        self.init(item: episode, kind: .thumb, width: width, aspectRatio: 16 / 9)
    }
}

/// Cast & Crew: actors, then directors.
struct IOSPlexCastRow: View {
    let item: PlexMetadata
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale

    private struct Person: Identifiable {
        let id: Int
        let name: String
        let role: String?
        let thumb: String?
    }

    private var people: [Person] {
        let cast = (item.Role ?? []).prefix(20).compactMap { role in
            role.tag.map { (name: $0, role: role.role, thumb: role.thumb) }
        }
        let directors = (item.Director ?? []).compactMap { member in
            member.tag.map { (name: $0, role: Optional("Director"), thumb: member.thumb) }
        }
        return (cast + directors).enumerated().map {
            Person(id: $0.offset, name: $0.element.name, role: $0.element.role, thumb: $0.element.thumb)
        }
    }

    var body: some View {
        let people = self.people
        if !people.isEmpty {
            IOSShelfRow(kind: .person, items: people) {
                IOSPlexShelfHeader(title: "Cast & Crew")
            } tile: { person, width in
                let pixels = Int((width * displayScale).rounded(.up))
                VStack(spacing: 6) {
                    IOSPlexImage(url: plex.imageURL(path: person.thumb, width: pixels, height: pixels))
                        .overlay {
                            if person.thumb == nil {
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

/// Extras and trailers from the full metadata; tapping one plays it.
struct IOSPlexExtrasRow: View {
    let item: PlexMetadata
    @Environment(\.plexActions) private var actions

    private var extras: [PlexMetadata] {
        item.allExtras
            .sorted { ExtraSubtype.from(subtype: $0.subtype, extraType: $0.extraType)
                < ExtraSubtype.from(subtype: $1.subtype, extraType: $1.extraType) }
            .compactMap { extra in
                extra.ratingKey.map {
                    PlexMetadata(ratingKey: $0, type: "clip", title: extra.title, thumb: extra.thumb, duration: extra.duration)
                }
            }
    }

    var body: some View {
        let extras = self.extras
        if !extras.isEmpty {
            IOSShelfRow(kind: .landscape, items: extras) {
                IOSPlexShelfHeader(title: "Extras")
            } tile: { extra, width in
                Button { actions.play(extra) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        IOSPlexArtwork(item: extra, kind: .thumb, width: width, aspectRatio: 16 / 9)
                            .frame(width: width, height: width * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if actions.preparingID == extra.id { ProgressView().tint(.white) }
                            }
                        Text(extra.displayTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                        if let runtime = extra.runtimeText {
                            Text(runtime).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: width, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Studio, genres, rating, release date, languages: whatever the item has.
struct IOSPlexInformationSection: View {
    let item: PlexMetadata
    @Environment(\.horizontalSizeClass) private var sizeClass

    nonisolated static func formattedDate(_ isoDay: String) -> String? {
        guard let date = try? Date(isoDay, strategy: .iso8601.year().month().day().dateSeparator(.dash)) else { return nil }
        return date.formatted(date: .long, time: .omitted)
    }

    private func languages(streamType: Int) -> String? {
        let streams = item.Media?.first?.Part?.first?.Stream ?? []
        var seen = Set<String>()
        let names = streams
            .filter { $0.streamType == streamType }
            .compactMap { $0.language ?? $0.languageTag }
            .filter { seen.insert($0).inserted }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var rows: [(String, String)] {
        [
            ("Studio", item.studio),
            ("Genre", item.Genre?.compactMap(\.tag).joined(separator: ", ")),
            ("Rated", item.contentRating),
            ("Released", item.originallyAvailableAt.flatMap(Self.formattedDate)),
            ("Runtime", item.runtimeText),
            ("Audio", languages(streamType: 2)),
            ("Subtitles", languages(streamType: 3))
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
                    columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: sizeClass == .regular ? 3 : 2),
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
            }
        }
    }
}

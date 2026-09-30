// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BelowFoldContentLoader.swift
//  Rivulet
//
//  Loads the below-fold detail content (seasons, episodes, cast/crew, related)
//  for the UIKit expanded detail. Decoupled from any view — it just fetches
//  through the agnostic `MediaProvider` and returns a value.
//
//  The host (container / VC) calls `load(for:detail:)` when its item is set,
//  then feeds the result into EpisodeCell / SeasonPillView / CastCell /
//  PosterCell. Wiring that into the container is a later, runtime-verified
//  step; this loader is independently testable.
//
//  The collection row and Related come from the same `related(for:kind:)`
//  call.
//

import Foundation

/// The below-fold content for one detail item.
struct BelowFoldContent: Sendable {
    var seasons: [MediaItem] = []
    /// Episodes unified across seasons (shows/episodes) or the season's
    /// episodes (season route).
    var episodes: [MediaItem] = []
    var cast: [MediaPerson] = []
    var directors: [MediaPerson] = []
    var trailers: [BelowFoldTrailer] = []
    var extras: [BelowFoldTrailer] = []   // non-trailer extras (behind the scenes, etc.)
    var related: [MediaItem] = []
    /// The collection row (Plex's collection hub for a movie or show, minus
    /// this item), from the same `related(for:kind:)` call as `related`.
    var collection: CollectionRow?
    /// Default season to select in the pill bar.
    var selectedSeason: MediaItem?
    /// Full detail for the About + Information/Languages/Accessibility block
    /// (genres, contentRating, rating, studios, mediaSources, synopsis, year).
    var detail: MediaItemDetail?
    /// The SHOW's detail when the opened item is an episode/season. The About
    /// card always describes the SHOW (the episode specifics live in the chrome
    /// at the top), while Languages/Accessibility stay episode-level (the file).
    /// nil for movies and show-level details (use `detail`).
    var showDetail: MediaItemDetail?

    var hasEpisodes: Bool { !episodes.isEmpty }
    var hasCast: Bool { !cast.isEmpty || !directors.isEmpty }
}

struct BelowFoldTrailer: Hashable, Sendable {
    let id: String
    let title: String
    let artworkURL: URL?
    let durationFormatted: String?
    var subtype: ExtraSubtype = .unknown
    /// Plex's handle for actually PLAYING this extra, which is not always the
    /// same thing as `id`. User-added (disc-ripped) extras carry a real library
    /// ratingKey; Plex's own IVA-supplied extras carry only a `key` path like
    /// `/services/iva/assets/...`. Feeding the latter to /library/metadata/{id}
    /// 404s, which is what made trailer playback fail more often than not.
    var playbackKey: String?
}

@MainActor
final class BelowFoldContentLoader {

    /// Load all below-fold content for `item`. `detail` (if the chrome already
    /// fetched it) supplies cast/directors without a second round-trip; if nil,
    /// it's fetched here. Any sub-fetch failure degrades to empty for that
    /// section rather than failing the whole load.
    func load(for item: MediaItem, detail: MediaItemDetail?) async -> BelowFoldContent {
        var content = BelowFoldContent()
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else {
            return content
        }

        // Cast / directors come from the full detail (reuse the chrome's if
        // present, otherwise fetch). Not via `??` — its RHS is a non-async
        // autoclosure and can't host the await.
        let resolvedDetail: MediaItemDetail?
        if let detail {
            resolvedDetail = detail
        } else {
            resolvedDetail = try? await provider.fullDetail(for: item.ref)
        }
        content.cast = resolvedDetail?.cast ?? []
        content.directors = resolvedDetail?.directors ?? []
        content.detail = resolvedDetail
        // Real Plex extras, split into Trailers vs other Extras (behind the
        // scenes, featurettes, etc.) by the extra's type.
        let fallbackArt = item.artwork.thumbnail ?? item.artwork.backdrop ?? item.artwork.poster
        func makeTrailer(_ extra: MediaItemDetail.Extra) -> BelowFoldTrailer {
            BelowFoldTrailer(
                id: extra.id,
                title: extra.title,
                artworkURL: extra.thumbnailURL ?? fallbackArt,
                durationFormatted: extra.duration.map(Self.formatTrailerDuration),
                subtype: extra.subtype,
                playbackKey: extra.playbackKey
            )
        }
        let allExtras = resolvedDetail?.extras ?? []
        content.trailers = allExtras.filter { $0.isTrailer }.map(makeTrailer)
        content.extras = allExtras.filter { !$0.isTrailer }.map(makeTrailer)

        // Seasons + episodes (TV route), keyed off the item kind exactly like
        // the SwiftUI loaders.
        switch item.kind {
        case .show:
            content.seasons = (try? await provider.children(of: item.ref)) ?? []
            content.selectedSeason = content.seasons.first
            content.episodes = (try? await provider.allEpisodes(of: item.ref)) ?? []

        case .episode:
            if let showRef = item.grandparentRef {
                content.seasons = (try? await provider.children(of: showRef)) ?? []
                let currentSeasonID = item.parentRef?.itemID
                content.selectedSeason = content.seasons.first(where: { $0.ref.itemID == currentSeasonID })
                    ?? content.seasons.first
                content.episodes = (try? await provider.allEpisodes(of: showRef)) ?? []
                // About card describes the SHOW, not this episode.
                content.showDetail = try? await provider.fullDetail(for: showRef)
            }

        case .season:
            if let showRef = item.parentRef {
                content.seasons = (try? await provider.children(of: showRef)) ?? []
                content.selectedSeason = content.seasons.first(where: { $0.ref.itemID == item.ref.itemID })
                    ?? content.seasons.first
                content.showDetail = try? await provider.fullDetail(for: showRef)
            }
            content.episodes = (try? await provider.children(of: item.ref)) ?? []

        default:
            break  // movies: no seasons/episodes
        }

        // Related row and the collection row: one `/related` call feeds both.
        if let related = try? await provider.related(for: item.ref, kind: item.kind) {
            content.related = related.items
            content.collection = related.collection
        }

        return content
    }

    /// Deferred Common Sense Media fetch — runs AFTER the below-fold renders so
    /// the rich advisory (Plex Discover, network) never blocks the initial layout.
    func loadAdvisory(for item: MediaItem) async -> ContentAdvisory? {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return nil }
        return (try? await provider.contentAdvisory(for: item.ref)) ?? nil
    }

    /// "1m" / "2m 30s" / "45s" — feeds the on-thumbnail ▶ duration badge.
    private static func formatTrailerDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        if m == 0 { return "\(s)s" }
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }
}

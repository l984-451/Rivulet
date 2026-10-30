// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Fetches the below-fold content (seasons, episodes, cast, collection, related) through
//  `MediaProvider`. No view state, so it is testable alone.

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
    /// The show's detail for an episode or season, since About describes the show; nil otherwise.
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
    /// What plays this extra: a library ratingKey, or for a Plex IVA extra its
    /// `/services/iva/assets/...` path, which 404s under /library/metadata.
    var playbackKey: String?
    var providerID: String
    var externalURL: URL? = nil
}

@MainActor
final class BelowFoldContentLoader {

    /// Pass the chrome's `detail` to skip refetching it. A failed sub-fetch empties only its section.
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
        // Native local extras and remote provider videos share the existing rows.
        // Their distinct playback destinations survive the detail-to-tile mapping.
        let fallbackArt = item.artwork.thumbnail ?? item.artwork.backdrop ?? item.artwork.poster
        func makeTrailer(_ extra: MediaItemDetail.Extra) -> BelowFoldTrailer {
            BelowFoldTrailer(
                id: extra.id,
                title: extra.title,
                artworkURL: extra.thumbnailURL ?? fallbackArt,
                durationFormatted: extra.duration.map(Self.formatTrailerDuration),
                subtype: extra.subtype,
                playbackKey: extra.playbackKey,
                providerID: extra.providerID,
                externalURL: extra.externalURL
            )
        }
        let allExtras = resolvedDetail?.extras ?? []
        content.trailers = allExtras.filter { $0.isTrailer }.map(makeTrailer)
        content.extras = allExtras.filter { !$0.isTrailer }.map(makeTrailer)

        // Seasons and episodes, by item kind.
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

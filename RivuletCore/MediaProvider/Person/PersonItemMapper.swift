// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

enum PersonItemMapper {
    /// Metadata-only MediaItem for a filmography title not present on the server.
    /// Keyed by tmdb id so it routes through the existing Discover/metadata-only
    /// presentation (`isMetadataOnly == true`, `tmdbID` decodes).
    static func metadataOnlyItem(tmdbId: Int,
                                 isMovie: Bool,
                                 title: String,
                                 year: Int?,
                                 posterURL: URL?,
                                 overview: String?) -> MediaItem {
        let type: TMDBMediaType = isMovie ? .movie : .tv
        return MediaItem(
            ref: MediaItemRef(providerID: TMDBMediaMapper.providerID,
                              itemID: TMDBMediaMapper.encodeItemID(tmdbId: tmdbId, type: type)),
            kind: isMovie ? .movie : .show,
            title: title,
            sortTitle: nil,
            overview: overview,
            year: year,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: posterURL, backdrop: nil, thumbnail: posterURL, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }
}

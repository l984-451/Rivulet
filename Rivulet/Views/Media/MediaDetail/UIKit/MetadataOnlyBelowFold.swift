// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The detail page's lower rows for a title the library doesn't have. The loader fills them
// through a server, which such a title has none of. Cast & Crew comes from the page's own detail
// (Plex Discover, see `DiscoverDetailSource`), its trailer too; More Like This from Seerr when
// it is set up, else TMDB (`SeerrCatalog.related`).

import Foundation

@MainActor
enum MetadataOnlyBelowFold {
    /// The rows for a metadata-only item, or nil for anything else (the loader's own path runs).
    static func content(for item: MediaItem, detail: MediaItemDetail?) async -> BelowFoldContent? {
        guard item.isMetadataOnly,
              let source = MetadataSourceRegistry.shared.source(for: item.ref.providerID) else { return nil }
        var content = BelowFoldContent()
        let resolved: MediaItemDetail?
        if let detail { resolved = detail } else { resolved = try? await source.itemDetail(item.ref) }
        content.detail = resolved
        content.cast = resolved?.cast ?? []
        content.directors = resolved?.directors ?? []

        let art = item.artwork.backdrop ?? item.artwork.thumbnail ?? item.artwork.poster
        content.trailers = BelowFoldContentLoader.extraTiles(
            from: [], fallbackArt: art, youTubeVideoID: resolved?.youTubeTrailerID, providerID: item.ref.providerID).trailers
        content.related = await SeerrCatalog.related(to: item)
        return content
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItem.swift
//  Rivulet
//
//  List/browse shape consumed by carousels, hub rows, search results, and
//  any view that renders a media tile. All fields are populated at
//  construction by the provider — nothing is "filled in later." Optional
//  fields mean "this backend doesn't have this data."
//

import Foundation

struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let kind: MediaKind

    let title: String
    let sortTitle: String?
    let overview: String?
    let year: Int?
    let releaseDate: String?
    let contentRating: String?
    let runtime: TimeInterval?           // seconds; nil for shows

    /// Music (artist/album/track). `MediaKind` collapses these to `.unknown`,
    /// so this carries the one bit the UI needs: music tiles render 1:1 square
    /// instead of the 2:3 poster ratio. Optional so old cached items (encoded
    /// before this field existed) still decode — read via `item.isMusic == true`.
    let isMusic: Bool?

    // Hierarchy
    let parentRef: MediaItemRef?         // season → show, episode → season
    let grandparentRef: MediaItemRef?    // episode → show
    let episodeNumber: Int?              // episodes only — Plex `index`
    let seasonNumber: Int?               // episodes/seasons only — Plex `parentIndex`
    let childProgress: ChildProgress?    // shows/seasons only — for "12/24 watched"

    let userState: MediaUserState

    // Artwork — own + hierarchy
    let artwork: MediaArtwork
    let parentArtwork: MediaArtwork?     // episode → season art; season → show art
    let grandparentArtwork: MediaArtwork? // episode → show art

    init(
        ref: MediaItemRef,
        kind: MediaKind,
        title: String,
        sortTitle: String?,
        overview: String?,
        year: Int?,
        releaseDate: String? = nil,
        contentRating: String? = nil,
        runtime: TimeInterval?,
        isMusic: Bool? = false,
        parentRef: MediaItemRef?,
        grandparentRef: MediaItemRef?,
        episodeNumber: Int?,
        seasonNumber: Int?,
        childProgress: ChildProgress?,
        userState: MediaUserState,
        artwork: MediaArtwork,
        parentArtwork: MediaArtwork?,
        grandparentArtwork: MediaArtwork?
    ) {
        self.ref = ref
        self.kind = kind
        self.title = title
        self.sortTitle = sortTitle
        self.overview = overview
        self.year = year
        self.releaseDate = releaseDate
        self.contentRating = contentRating
        self.runtime = runtime
        self.isMusic = isMusic
        self.parentRef = parentRef
        self.grandparentRef = grandparentRef
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.childProgress = childProgress
        self.userState = userState
        self.artwork = artwork
        self.parentArtwork = parentArtwork
        self.grandparentArtwork = grandparentArtwork
    }
}

extension MediaItem {
    /// Stand-in for a library-grid slot whose page has not loaded. The empty
    /// itemID is the marker: cells draw a blank card for it and tap / menu /
    /// play paths ignore it.
    static let gridPlaceholder = MediaItem(
        ref: MediaItemRef(providerID: "", itemID: ""),
        kind: .unknown,
        title: "",
        sortTitle: nil,
        overview: nil,
        year: nil,
        runtime: nil,
        parentRef: nil,
        grandparentRef: nil,
        episodeNumber: nil,
        seasonNumber: nil,
        childProgress: nil,
        userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
        artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
        parentArtwork: nil,
        grandparentArtwork: nil
    )

    var isGridPlaceholder: Bool { ref.itemID.isEmpty }
}

extension MediaItem {
    /// Returns a copy with `artwork.logo` filled in if it's currently nil.
    /// Used by the prefetch ring to splice a TMDB-resolved logo URL into a
    /// MediaItem whose provider mapper didn't have one at construction time.
    /// A non-nil existing logo is never overwritten.
    func withLogoIfMissing(_ logo: URL?) -> MediaItem {
        guard let logo, artwork.logo == nil else { return self }
        return MediaItem(
            ref: ref,
            kind: kind,
            title: title,
            sortTitle: sortTitle,
            overview: overview,
            year: year,
            releaseDate: releaseDate,
            contentRating: contentRating,
            runtime: runtime,
            isMusic: isMusic,
            parentRef: parentRef,
            grandparentRef: grandparentRef,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            childProgress: childProgress,
            userState: userState,
            artwork: MediaArtwork(
                poster: artwork.poster,
                backdrop: artwork.backdrop,
                thumbnail: artwork.thumbnail,
                logo: logo
            ),
            parentArtwork: parentArtwork,
            grandparentArtwork: grandparentArtwork
        )
    }
}

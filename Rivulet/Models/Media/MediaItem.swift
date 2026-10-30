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

/// Native Home action anchor. The timestamp remains the server's exact string.
nonisolated struct MediaItemDismissalMetadata: Hashable, Sendable, Codable {
    let rail: MediaDismissalRail
    let contentID: String
    let progressUpdatedAt: String?
    let seriesID: String?
    let providerIdentity: String
    let authorityRevision: UInt64
}

nonisolated struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    var id: MediaItemRef { ref }
    let ref: MediaItemRef
    let kind: MediaKind

    let title: String
    let sortTitle: String?
    let overview: String?
    /// Optional so saved items encoded before provenance existed still decode.
    var overviewIsMachineTranslated: Bool? = nil
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
    /// Show title for episodes and seasons. Optional so stored items
    /// (Recently Searched) encoded before it existed still decode.
    let seriesTitle: String?
    let episodeNumber: Int?              // episodes only — Plex `index`
    let seasonNumber: Int?               // episodes/seasons only — Plex `parentIndex`
    let childProgress: ChildProgress?    // shows/seasons only — for "12/24 watched"

    var userState: MediaUserState

    // Artwork — own + hierarchy
    let artwork: MediaArtwork
    let parentArtwork: MediaArtwork?     // episode → season art; season → show art
    let grandparentArtwork: MediaArtwork? // episode → show art

    /// Distinct files behind a movie or episode; nil when the list didn't say.
    let versionCount: Int?
    /// Plex edition name ("Director's Cut"); each edition is its own item.
    let editionTitle: String?
    /// Keys naming the same title on any server (`ContinueWatchingMerge`); set
    /// on Continue Watching items only. Optional so cached items still decode.
    var identity: [String]?
    /// False for catalog titles that are saved but not present on their server.
    /// Nil keeps existing cached library cards available.
    let isAvailable: Bool?
    /// Owning library where the server supplies one; external catalog titles have none.
    let libraryID: String?
    /// Only populated from an authorized native Home row.
    var dismissalMetadata: MediaItemDismissalMetadata? = nil

    init(
        ref: MediaItemRef,
        kind: MediaKind,
        title: String,
        sortTitle: String?,
        overview: String?,
        overviewIsMachineTranslated: Bool? = nil,
        year: Int?,
        releaseDate: String? = nil,
        contentRating: String? = nil,
        runtime: TimeInterval?,
        isMusic: Bool? = false,
        parentRef: MediaItemRef?,
        grandparentRef: MediaItemRef?,
        seriesTitle: String? = nil,
        episodeNumber: Int?,
        seasonNumber: Int?,
        childProgress: ChildProgress?,
        userState: MediaUserState,
        artwork: MediaArtwork,
        parentArtwork: MediaArtwork?,
        grandparentArtwork: MediaArtwork?,
        versionCount: Int? = nil,
        editionTitle: String? = nil,
        identity: [String]? = nil,
        isAvailable: Bool? = nil,
        libraryID: String? = nil,
        dismissalMetadata: MediaItemDismissalMetadata? = nil
    ) {
        self.ref = ref
        self.kind = kind
        self.title = title
        self.sortTitle = sortTitle
        self.overview = overview
        self.overviewIsMachineTranslated = overviewIsMachineTranslated
        self.year = year
        self.releaseDate = releaseDate
        self.contentRating = contentRating
        self.runtime = runtime
        self.isMusic = isMusic
        self.parentRef = parentRef
        self.grandparentRef = grandparentRef
        self.seriesTitle = seriesTitle
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.childProgress = childProgress
        self.userState = userState
        self.artwork = artwork
        self.parentArtwork = parentArtwork
        self.grandparentArtwork = grandparentArtwork
        self.versionCount = versionCount
        self.editionTitle = editionTitle
        self.identity = identity
        self.isAvailable = isAvailable
        self.libraryID = libraryID
        self.dismissalMetadata = dismissalMetadata
    }
}

extension MediaItem {
    /// Only a card from a native Home rail can supply a versioned action.
    func dismissalAction() -> MediaDismissal? {
        guard let anchor = dismissalMetadata, anchor.providerIdentity == ref.providerID,
              anchor.contentID == ref.itemID else { return nil }
        switch anchor.rail {
        case .continueWatching where anchor.progressUpdatedAt?.isEmpty != false: return nil
        case .nextUp where anchor.seriesID?.isEmpty != false: return nil
        default: break
        }
        return MediaDismissal(item: ref, rail: anchor.rail, providerIdentity: anchor.providerIdentity,
                              progressUpdatedAt: anchor.progressUpdatedAt, seriesID: anchor.seriesID,
                              authorityRevision: anchor.authorityRevision)
    }

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

    /// Catalog lookup needed to merge a movie or the owning show across servers.
    var lookupKey: String? {
        let target: MediaItemRef? = switch kind {
        case .movie, .show: identity?.isEmpty == false ? nil : ref
        case .episode: grandparentRef
        case .season: parentRef
        default: nil
        }
        guard let target, !target.itemID.isEmpty else { return nil }
        return "\(target.providerID)|\(target.itemID)"
    }
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
            overviewIsMachineTranslated: overviewIsMachineTranslated,
            year: year,
            releaseDate: releaseDate,
            contentRating: contentRating,
            runtime: runtime,
            isMusic: isMusic,
            parentRef: parentRef,
            grandparentRef: grandparentRef,
            seriesTitle: seriesTitle,
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
            grandparentArtwork: grandparentArtwork,
            versionCount: versionCount,
            editionTitle: editionTitle,
            identity: identity,
            isAvailable: isAvailable,
            libraryID: libraryID,
            dismissalMetadata: dismissalMetadata
        )
    }
}

// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItemDetail.swift
//  Rivulet
//
//  Superset returned from provider.fullDetail(for:). The detail surface gates
//  its below-fold on detail arrival. Embeds the list-level MediaItem so
//  detail consumers don't need both types passed in.
//

import Foundation

struct MediaItemDetail: Sendable {
    let item: MediaItem

    let tagline: String?
    let genres: [String]
    let studios: [String]
    let cast: [MediaPerson]
    let directors: [MediaPerson]
    let writers: [MediaPerson]
    let chapters: [MediaChapter]
    let mediaSources: [MediaSource]
    let trailerURL: URL?
    let contentRating: String?
    var regionOfOrigin: String? = nil   // e.g. "United Kingdom" (Plex Country), if present
    let rating: MediaRating?

    // Wave 1 additions for the detail view
    let nextEpisode: MediaItem?      // shows only — Plex `OnDeck`, Jellyfin `/Shows/NextUp`
    let collections: [String]        // collection names this item is tagged with

    /// Trailers + extras (behind-the-scenes, featurettes, …). Provider-agnostic.
    /// Defaulted so existing constructors that don't supply it still compile.
    /// `playbackKey` is the provider's handle for playing the extra later.
    var extras: [Extra] = []

    /// Content advisory (Common Sense Media on Plex). Holds the local partial
    /// (age rating) first; replaced by the full Discover data when it arrives.
    /// Defaulted so existing constructors compile unchanged.
    var contentAdvisory: ContentAdvisory? = nil

    /// External ids keyed lowercase: "tmdb", "imdb", "tvdb".
    var externalIDs: [String: String] = [:]

    struct Extra: Sendable, Identifiable, Hashable {
        let id: String
        let title: String
        let thumbnailURL: URL?
        let duration: TimeInterval?   // seconds
        let playbackKey: String?      // provider-specific (Plex extra key / ratingKey)
        var subtype: ExtraSubtype = .unknown

        var isTrailer: Bool { subtype.isTrailer }
    }
}

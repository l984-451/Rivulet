//
//  MediaItemDetail.swift
//  Rivulet
//
//  Superset returned from provider.fullDetail(for:). MediaDetailView gates
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
    let rating: Double?              // normalized 0–10

    // Wave 1 additions for the detail view
    let nextEpisode: MediaItem?      // shows only — Plex `OnDeck`, Jellyfin `/Shows/NextUp`
    let collections: [String]        // collection names this item is tagged with

    // Full original-air/release date ("YYYY-MM-DD"). Episodes surface the full
    // date ("Sep 24, 2019") in the hero metadata row; movies keep year-only.
    let originallyAvailableAt: String?
}

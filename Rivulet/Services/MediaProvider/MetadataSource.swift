// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MetadataSource.swift
//  Rivulet
//
//  Read-only catalog backend (TMDB today, IMDB/TVDB/Trakt later).
//  Distinct from MediaProvider — sources can't play, don't have user state,
//  don't have libraries. They produce MediaItems that drop into the same
//  carousels and detail views.
//

import Foundation

protocol MetadataSource: Sendable {
    func curatedSection(_ section: CuratedSection) async throws -> [MediaItem]
    func itemDetail(_ ref: MediaItemRef) async throws -> MediaItemDetail
    func search(_ query: String) async throws -> [MediaItem]
    func recommendations(for ref: MediaItemRef) async throws -> [MediaItem]
}

enum CuratedSection: String, Sendable, CaseIterable, Identifiable, Hashable, Codable {
    case moviePopular
    case movieNowPlaying
    case movieUpcoming
    case movieTopRated
    case tvPopular
    case tvAiringToday
    case tvOnTheAir
    case tvTopRated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moviePopular: return String(localized: "Popular Movies")
        case .movieNowPlaying: return String(localized: "tmdb.nowPlaying", defaultValue: "Now Playing")
        case .movieUpcoming: return String(localized: "Upcoming")
        case .movieTopRated: return String(localized: "Top Rated Movies")
        case .tvPopular: return String(localized: "Popular TV")
        case .tvAiringToday: return String(localized: "Airing Today")
        case .tvOnTheAir: return String(localized: "On The Air")
        case .tvTopRated: return String(localized: "Top Rated TV")
        }
    }
}

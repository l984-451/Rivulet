// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TMDBDiscoverModels.swift
//  Rivulet
//
//  Models for TMDB list/discover endpoints used by the Discover page.
//

import Foundation

enum TMDBDiscoverSection: String, CaseIterable, Identifiable, Sendable {
    case movieTrending
    case moviePopular
    case movieNowPlaying
    case movieUpcoming
    case movieTopRated
    case tvTrending
    case tvPopular
    case tvAiringToday
    case tvOnTheAir
    case tvTopRated

    static let allCases: [TMDBDiscoverSection] = [
        .moviePopular,
        .movieNowPlaying,
        .movieUpcoming,
        .movieTopRated,
        .tvPopular,
        .tvAiringToday,
        .tvOnTheAir,
        .tvTopRated
    ]

    var id: String { rawValue }

    var mediaType: TMDBMediaType {
        switch self {
        case .movieTrending, .moviePopular, .movieNowPlaying, .movieUpcoming, .movieTopRated: return .movie
        case .tvTrending, .tvPopular, .tvAiringToday, .tvOnTheAir, .tvTopRated: return .tv
        }
    }

    var title: String {
        switch self {
        case .movieTrending: return "Trending Movies"
        case .moviePopular: return "Popular Movies"
        case .movieNowPlaying: return "Now Playing"
        case .movieUpcoming: return "Upcoming"
        case .movieTopRated: return "Top Rated Movies"
        case .tvTrending: return "Trending TV"
        case .tvPopular: return "Popular TV"
        case .tvAiringToday: return "Airing Today"
        case .tvOnTheAir: return "On The Air"
        case .tvTopRated: return "Top Rated TV"
        }
    }

    /// Path segment forwarded to the proxy after `/tmdb/list/`.
    var proxyPath: String {
        switch self {
        case .movieTrending, .tvTrending: return "trending"
        case .moviePopular, .tvPopular: return "popular"
        case .movieNowPlaying: return "now_playing"
        case .movieUpcoming: return "upcoming"
        case .movieTopRated, .tvTopRated: return "top_rated"
        case .tvAiringToday: return "airing_today"
        case .tvOnTheAir: return "on_the_air"
        }
    }
}

struct TMDBListItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let mediaType: TMDBMediaType

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case mediaType = "media_type"
    }

    init(id: Int, title: String, overview: String?, posterPath: String?, backdropPath: String?, releaseDate: String?, voteAverage: Double?, mediaType: TMDBMediaType) {
        self.id = id
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.voteAverage = voteAverage
        self.mediaType = mediaType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title))
            ?? (try? c.decode(String.self, forKey: .name))
            ?? ""
        overview = try? c.decode(String.self, forKey: .overview)
        posterPath = try? c.decode(String.self, forKey: .posterPath)
        backdropPath = try? c.decode(String.self, forKey: .backdropPath)
        releaseDate = (try? c.decode(String.self, forKey: .releaseDate))
            ?? (try? c.decode(String.self, forKey: .firstAirDate))
        voteAverage = try? c.decode(Double.self, forKey: .voteAverage)
        if c.contains(.mediaType) {
            let raw = try c.decode(String.self, forKey: .mediaType)
            guard let parsed = TMDBMediaType(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mediaType, in: c,
                    debugDescription: "Unknown TMDB media_type: \(raw)"
                )
            }
            mediaType = parsed
        } else {
            // Typed list endpoints (popular movies, popular tv, etc.) omit media_type.
            // The service layer stamps the correct type after decode using the section's mediaType.
            mediaType = .movie
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(posterPath, forKey: .posterPath)
        try c.encodeIfPresent(backdropPath, forKey: .backdropPath)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encodeIfPresent(voteAverage, forKey: .voteAverage)
        try c.encode(mediaType.rawValue, forKey: .mediaType)
    }
}

struct TMDBItemDetail: Codable, Identifiable, Sendable {
    let id: Int
    let title: String
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let runtime: Int?
    let genres: [TMDBGenre]
    let voteAverage: Double?
    let cast: [TMDBCredit]
    let mediaType: TMDBMediaType

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case runtime
        case genres
        case voteAverage = "vote_average"
        case cast
        case mediaType = "media_type"
    }

    init(
        id: Int,
        title: String,
        overview: String?,
        posterPath: String?,
        backdropPath: String?,
        releaseDate: String?,
        runtime: Int?,
        genres: [TMDBGenre],
        voteAverage: Double?,
        cast: [TMDBCredit],
        mediaType: TMDBMediaType
    ) {
        self.id = id
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.runtime = runtime
        self.genres = genres
        self.voteAverage = voteAverage
        self.cast = cast
        self.mediaType = mediaType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        guard let t = (try? c.decode(String.self, forKey: .title))
                   ?? (try? c.decode(String.self, forKey: .name)) else {
            throw DecodingError.keyNotFound(
                CodingKeys.title,
                DecodingError.Context(codingPath: c.codingPath, debugDescription: "Expected 'title' or 'name'")
            )
        }
        title = t
        overview = try? c.decode(String.self, forKey: .overview)
        posterPath = try? c.decode(String.self, forKey: .posterPath)
        backdropPath = try? c.decode(String.self, forKey: .backdropPath)
        releaseDate = (try? c.decode(String.self, forKey: .releaseDate))
            ?? (try? c.decode(String.self, forKey: .firstAirDate))
        runtime = try? c.decode(Int.self, forKey: .runtime)
        genres = (try? c.decode([TMDBGenre].self, forKey: .genres)) ?? []
        voteAverage = try? c.decode(Double.self, forKey: .voteAverage)
        cast = (try? c.decode([TMDBCredit].self, forKey: .cast)) ?? []
        if c.contains(.mediaType) {
            let raw = try c.decode(String.self, forKey: .mediaType)
            guard let parsed = TMDBMediaType(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mediaType, in: c,
                    debugDescription: "Unknown TMDB media_type: \(raw)"
                )
            }
            mediaType = parsed
        } else {
            // Typed detail endpoints omit media_type.
            // The service layer stamps the correct type after decode.
            mediaType = .movie
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(posterPath, forKey: .posterPath)
        try c.encodeIfPresent(backdropPath, forKey: .backdropPath)
        try c.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encode(genres, forKey: .genres)
        try c.encodeIfPresent(voteAverage, forKey: .voteAverage)
        try c.encode(cast, forKey: .cast)
        try c.encode(mediaType.rawValue, forKey: .mediaType)
    }
}

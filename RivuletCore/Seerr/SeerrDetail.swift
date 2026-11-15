// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// A title's detail page from Seerr, for an install without a Plex
// account (Jellyfin or Emby only), where Plex Discover can't be asked. Seerr passes TMDB's full
// record through (credits, release certifications, studios) and adds Rotten Tomatoes and IMDb
// scores. `DiscoverDetailSource` tries Plex Discover first, then this, then TMDB's catalog.

import Foundation

extension SeerrClient {
    /// The detail page's fields for a movie or show, with its review scores.
    func titleDetail(_ kind: SeerrTitle.Kind, _ tmdbID: Int) async throws -> MediaItemDetail {
        async let body = data("\(kind.rawValue)/\(tmdbID)")
        async let scores: Data? = try? await data(kind == .movie ? "movie/\(tmdbID)/ratingscombined" : "tv/\(tmdbID)/ratings")
        let scoreData = await scores
        let bodyData = try await body
        return try await MainActor.run {
            let ratings = scoreData.map { Self.ratings(from: $0, kind: kind) } ?? []
            return try Self.detail(from: bodyData, kind: kind, ratings: ratings)
        }
    }

    static let profileBase = "https://image.tmdb.org/t/p/w185"

    @MainActor static func detail(from data: Data, kind: SeerrTitle.Kind, ratings: [MediaRating]) throws -> MediaItemDetail {
        let dto: DetailDTO
        do { dto = try JSONDecoder().decode(DetailDTO.self, from: data) } catch { throw SeerrError.notSeerr }
        let isMovie = kind == .movie

        func person(_ id: Int?, _ name: String?, _ role: String?, _ path: String?) -> MediaPerson? {
            guard let name, !name.isEmpty else { return nil }
            var person = MediaPerson(id: id.map(String.init) ?? name, name: name, role: role,
                                     imageURL: path.flatMap { URL(string: profileBase + $0) })
            person.titleTmdbId = dto.id
            person.titleIsMovie = isMovie
            return person
        }

        let cast = (dto.credits?.cast ?? []).compactMap { person($0.id, $0.name, $0.character, $0.profilePath) }
        let crew = dto.credits?.crew ?? []
        let directors = unique(crew.filter { $0.job == "Director" }.compactMap { person($0.id, $0.name, $0.job, $0.profilePath) })
        // A show's makers are its creators; a movie's, its credited writers.
        let writers = isMovie
            ? unique(crew.filter { $0.department == "Writing" }.compactMap { person($0.id, $0.name, $0.job, $0.profilePath) })
            : unique((dto.createdBy ?? []).compactMap { person($0.id, $0.name, nil, $0.profilePath) })
        let studios = ((isMovie ? dto.productionCompanies : (dto.networks ?? dto.productionCompanies)) ?? [])
            .compactMap(\.name).filter { !$0.isEmpty }

        let certification = isMovie ? dto.releases.flatMap(movieCertification) : dto.contentRatings.flatMap(showRating)
        let runtimeMinutes = isMovie ? dto.runtime : dto.episodeRunTime?.first
        let title = (isMovie ? dto.title : dto.name) ?? dto.title ?? dto.name ?? ""

        let base = TMDBMediaMapper.item(TMDBListItem(
            id: dto.id, title: title, overview: dto.overview, posterPath: dto.posterPath,
            backdropPath: dto.backdropPath, releaseDate: isMovie ? dto.releaseDate : dto.firstAirDate,
            voteAverage: dto.voteAverage, mediaType: isMovie ? .movie : .tv))
        let item = MediaItem(
            ref: base.ref, kind: base.kind, title: base.title, sortTitle: base.sortTitle,
            overview: base.overview, year: base.year, releaseDate: base.releaseDate,
            contentRating: certification,
            runtime: runtimeMinutes.map { TimeInterval($0 * 60) },
            parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
            childProgress: nil, userState: base.userState, artwork: base.artwork,
            parentArtwork: nil, grandparentArtwork: nil)

        var detail = MediaItemDetail(
            item: item,
            tagline: dto.tagline.flatMap { $0.isEmpty ? nil : $0 },
            genres: (dto.genres ?? []).compactMap(\.name),
            studios: studios,
            cast: cast,
            directors: directors,
            writers: writers,
            chapters: [],
            mediaSources: [],
            trailerURL: nil,
            contentRating: certification,
            ratings: MediaRating.ordered(ratings + [MediaRating(dto.voteAverage, source: .tmdb)]),
            nextEpisode: nil,
            collections: []
        )
        var ids = ["tmdb": String(dto.id)]
        if let imdb = dto.externalIds?.imdbId ?? dto.imdbId, !imdb.isEmpty { ids["imdb"] = imdb }
        if let tvdb = dto.externalIds?.tvdbId { ids["tvdb"] = String(tvdb) }
        detail.externalIDs = ids
        return detail
    }

    /// Rotten Tomatoes critics and audience, and IMDb. RT's percentages are stored as tenths
    /// (85% → 8.5), which is how `MediaRating` displays them.
    @MainActor static func ratings(from data: Data, kind: SeerrTitle.Kind) -> [MediaRating] {
        func rt(_ s: ScoresDTO.RT?) -> [MediaRating?] {
            [MediaRating(s?.criticsScore.map { $0 / 10 }, source: .rottenTomatoes),
             MediaRating(s?.audienceScore.map { $0 / 10 }, source: .rottenTomatoesAudience)]
        }
        if kind == .movie, let combined = try? JSONDecoder().decode(ScoresDTO.self, from: data) {
            return MediaRating.ordered(rt(combined.rt) + [MediaRating(combined.imdb?.criticsScore, source: .imdb)])
        }
        guard let show = try? JSONDecoder().decode(ScoresDTO.RT.self, from: data) else { return [] }
        return MediaRating.ordered(rt(show))
    }

    /// The US theatrical certification, else any US one, else the first country's.
    private static func movieCertification(_ releases: DetailDTO.Releases) -> String? {
        let results = releases.results ?? []
        let us = results.first { $0.iso_3166_1 == "US" }
        let pick: (DetailDTO.Releases.Country?) -> String? = { country in
            let dates = country?.release_dates ?? []
            return (dates.first { $0.type == 3 && !($0.certification ?? "").isEmpty }
                ?? dates.first { !($0.certification ?? "").isEmpty })?.certification
        }
        return pick(us) ?? results.lazy.compactMap { pick($0) }.first
    }

    private static func showRating(_ ratings: DetailDTO.ContentRatings) -> String? {
        let results = ratings.results ?? []
        let rating = (results.first { $0.iso_3166_1 == "US" } ?? results.first)?.rating
        return rating.flatMap { $0.isEmpty ? nil : $0 }
    }

    @MainActor private static func unique(_ people: [MediaPerson]) -> [MediaPerson] {
        var seen = Set<String>()
        return people.filter { seen.insert($0.name).inserted }
    }
}

// MARK: - Wire types

nonisolated private struct DetailDTO: Decodable {
    struct Named: Decodable { let name: String? }
    struct Credit: Decodable {
        let id: Int?
        let name: String?
        let character: String?
        let job: String?
        let department: String?
        let profilePath: String?
    }
    struct Credits: Decodable { let cast: [Credit]?; let crew: [Credit]? }
    struct Releases: Decodable {
        struct Country: Decodable {
            struct Release: Decodable { let certification: String?; let type: Int? }
            let iso_3166_1: String?
            let release_dates: [Release]?
        }
        let results: [Country]?
    }
    struct ContentRatings: Decodable {
        struct Rating: Decodable { let iso_3166_1: String?; let rating: String? }
        let results: [Rating]?
    }
    struct ExternalIDs: Decodable { let imdbId: String?; let tvdbId: Int? }

    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let tagline: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [Named]?
    let productionCompanies: [Named]?
    let networks: [Named]?
    let createdBy: [Credit]?
    let credits: Credits?
    let releases: Releases?
    let contentRatings: ContentRatings?
    let voteAverage: Double?
    let imdbId: String?
    let externalIds: ExternalIDs?
}

nonisolated private struct ScoresDTO: Decodable {
    struct RT: Decodable { let criticsScore: Double?; let audienceScore: Double? }
    struct IMDb: Decodable { let criticsScore: Double? }
    let rt: RT?
    let imdb: IMDb?
}

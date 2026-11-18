// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaRatingTests.swift
//  RivuletTests
//
//  Field shapes measured on PMS 1.43.4 and Jellyfin 12.1.
//

import XCTest
@testable import Rivulet

@MainActor
final class MediaRatingTests: XCTestCase {

    private func plex(
        rating: Double? = nil, ratingImage: String? = nil,
        audience: Double? = nil, audienceImage: String? = nil,
        entries: [PlexRatingEntry]? = nil
    ) -> [MediaRating] {
        var meta = PlexMetadata()
        meta.rating = rating
        meta.ratingImage = ratingImage
        meta.audienceRating = audience
        meta.audienceRatingImage = audienceImage
        meta.Rating = entries
        return PlexMediaMapper.ratings(meta)
    }

    private func jellyfin(_ fields: String) -> [MediaRating] {
        let json = #"{"Id":"m1","Name":"M","Type":"Movie"\#(fields)}"#
        return JellyfinMediaMapper.detail(
            JellyfinFixtures.decode(json), nextEpisode: nil,
            providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL, token: "t"
        ).ratings
    }

    private func texts(_ r: [MediaRating]) -> [String] {
        r.map { "\($0.name) \($0.badgeText)\($0.scale ?? "")" }
    }

    // MARK: - Plex

    /// The Matrix on PMS 1.43.4: the full `Rating` array beats the flat pair.
    func test_plex_ratingArray_allSourcesInOrder() {
        let r = plex(audience: 8.3, audienceImage: "themoviedb://image.rating", entries: [
            PlexRatingEntry(image: "imdb://image.rating", value: 8.7, type: "audience"),
            PlexRatingEntry(image: "rottentomatoes://image.rating.ripe", value: 8.3, type: "critic"),
            PlexRatingEntry(image: "rottentomatoes://image.rating.upright", value: 8.5, type: "audience"),
            PlexRatingEntry(image: "themoviedb://image.rating", value: 8.26, type: "audience"),
        ])
        XCTAssertEqual(texts(r), ["Rotten Tomatoes 83%", "RT Audience 85%", "IMDb 8.7/10", "TMDB 8.3/10"])
    }

    /// Hub items carry only the flat pair.
    func test_plex_flatPair_criticAndAudience() {
        let r = plex(rating: 8.9, ratingImage: "rottentomatoes://image.rating.ripe",
                     audience: 9.1, audienceImage: "rottentomatoes://image.rating.upright")
        XCTAssertEqual(texts(r), ["Rotten Tomatoes 89%", "RT Audience 91%"])
    }

    func test_plex_legacyRatingWithoutImage_isUnknownSource() {
        XCTAssertEqual(texts(plex(rating: 8.6)), ["Rating 8.6/10"])
    }

    func test_plex_nothing_isEmpty() {
        XCTAssertTrue(plex().isEmpty)
    }

    func test_zeroScore_isDropped() {
        XCTAssertTrue(plex(rating: 0, audience: 0, audienceImage: "themoviedb://image.rating").isEmpty)
    }

    // MARK: - Jellyfin

    func test_jellyfin_criticAndCommunity() {
        let r = jellyfin(#","CommunityRating":7.5,"CriticRating":89"#)
        XCTAssertEqual(texts(r), ["Rotten Tomatoes 89%", "Rating 7.5/10"])
    }

    func test_jellyfin_nothing_isEmpty() {
        XCTAssertTrue(jellyfin("").isEmpty)
    }

    // MARK: - Merge and Worker

    func test_ordered_providerWinsPerSource_unknownDroppedOnceNamed() {
        let r = MediaRating.ordered([
            MediaRating(7.5, source: .unknown),
            MediaRating(8.7, source: .imdb),
            MediaRating(9.0, source: .imdb),
        ])
        XCTAssertEqual(texts(r), ["IMDb 8.7/10"])
    }

    /// The Worker's response for The Matrix, native scales.
    func test_worker_decode_nativeScales() {
        let json = #"{"ratings":[{"source":"imdb","value":8.7},{"source":"metacritic","value":73},{"source":"tomatoes","value":83,"fresh":true},{"source":"popcorn","value":85},{"source":"tmdb","value":82},{"source":"letterboxd","value":4.2},{"source":"trakt","value":87}]}"#
        XCTAssertEqual(texts(RatingsClient.decode(Data(json.utf8))), [
            "Rotten Tomatoes 83%", "RT Audience 85%", "IMDb 8.7/10",
            "Metacritic 73/100", "Letterboxd 4.2/5", "TMDB 8.2/10",
        ])
    }

    func test_worker_decode_garbage_isEmpty() {
        XCTAssertTrue(RatingsClient.decode(Data("nope".utf8)).isEmpty)
    }

    // MARK: Detail row

    /// The chosen source, then Rotten Tomatoes, then the server's unnamed score.
    func test_detailRating_fallsBackToServerScore() {
        let key = MediaRating.detailSourceKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(MediaRating.Source.imdb.rawValue, forKey: key)

        let community = MediaRating(7.8, source: .unknown)
        let tomatoes = MediaRating(8.9, source: .rottenTomatoes)
        let imdb = MediaRating(7.6, source: .imdb)
        XCTAssertEqual(MediaRating.detailRating(in: MediaRating.ordered([community, imdb]))?.source, .imdb)
        XCTAssertEqual(MediaRating.detailRating(in: MediaRating.ordered([community, tomatoes]))?.source, .rottenTomatoes)
        // Jellyfin and Emby with no critic score: their community rating, as their own web apps show it.
        XCTAssertEqual(MediaRating.detailRating(in: MediaRating.ordered([community]))?.value, 7.8)
        XCTAssertNil(MediaRating.detailRating(in: []))
    }
}

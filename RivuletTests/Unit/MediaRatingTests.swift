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
        audience: Double? = nil, audienceImage: String? = nil
    ) -> MediaRating? {
        var meta = PlexMetadata()
        meta.rating = rating
        meta.ratingImage = ratingImage
        meta.audienceRating = audience
        meta.audienceRatingImage = audienceImage
        return PlexMediaMapper.rating(meta)
    }

    private func jellyfin(_ fields: String) -> MediaRating? {
        let json = #"{"Id":"m1","Name":"M","Type":"Movie"\#(fields)}"#
        return JellyfinMediaMapper.detail(
            JellyfinFixtures.decode(json), nextEpisode: nil,
            providerID: "jellyfin:srv", baseURL: JellyfinFixtures.baseURL, token: "t"
        ).rating
    }

    // MARK: - Plex

    func test_plex_rtCritic_beatsAudience_asPercent() {
        let r = plex(rating: 8.9, ratingImage: "rottentomatoes://image.rating.ripe",
                     audience: 9.1, audienceImage: "rottentomatoes://image.rating.upright")
        XCTAssertEqual(r?.source, .rottenTomatoes)
        XCTAssertEqual(r?.badgeText, "89%")
        XCTAssertEqual(r?.showsStar, false)
        XCTAssertEqual(r?.summary, "89% on Rotten Tomatoes")
    }

    func test_plex_rtAudienceOnly_asPercent() {
        let r = plex(audience: 5.4, audienceImage: "rottentomatoes://image.rating.spilled")
        XCTAssertEqual(r?.badgeText, "54%")
        XCTAssertEqual(r?.showsStar, false)
    }

    func test_plex_imdbAudience_keepsStar() {
        let r = plex(audience: 7.6, audienceImage: "imdb://image.rating")
        XCTAssertEqual(r?.badgeText, "7.6")
        XCTAssertEqual(r?.showsStar, true)
        XCTAssertEqual(r?.summary, "7.6 on IMDb")
    }

    func test_plex_tmdbAudience_keepsStar() {
        let r = plex(audience: 6.5, audienceImage: "themoviedb://image.rating")
        XCTAssertEqual(r?.badgeText, "6.5")
        XCTAssertEqual(r?.summary, "6.5 on TMDB")
    }

    func test_plex_legacyRatingWithoutImage_isUnknownSource() {
        let r = plex(rating: 8.6)
        XCTAssertEqual(r?.source, .unknown)
        XCTAssertEqual(r?.badgeText, "8.6")
        XCTAssertEqual(r?.showsStar, true)
        XCTAssertEqual(r?.summary, "8.6 / 10 average rating")
    }

    func test_plex_nothing_isNil() {
        XCTAssertNil(plex())
    }

    func test_zeroScore_isNil() {
        XCTAssertNil(plex(rating: 0, audience: 0, audienceImage: "themoviedb://image.rating"))
    }

    // MARK: - Jellyfin

    func test_jellyfin_criticBeatsCommunity_asRTPercent() {
        let r = jellyfin(#","CommunityRating":7.5,"CriticRating":89"#)
        XCTAssertEqual(r?.source, .rottenTomatoes)
        XCTAssertEqual(r?.badgeText, "89%")
        XCTAssertEqual(r?.summary, "89% on Rotten Tomatoes")
    }

    func test_jellyfin_communityOnly_isUnknownSource() {
        let r = jellyfin(#","CommunityRating":7.5"#)
        XCTAssertEqual(r, MediaRating(7.5, source: .unknown))
        XCTAssertEqual(r?.showsStar, true)
    }

    func test_jellyfin_nothing_isNil() {
        XCTAssertNil(jellyfin(""))
    }
}
